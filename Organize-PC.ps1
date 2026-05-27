#Requires -Version 5.1
<#
.SYNOPSIS
    PC 文件智能整理工具
    将游戏迁移到 SSD/E 盘，AI 资料归集到 AI 盘，游戏存档跟随迁移，原位建目录联接。
.PARAMETER Apply
    实际执行文件移动。不加此参数时只做 dry-run，生成 plan.json 供审核。
.PARAMETER ConfigPath
    指定 config.psd1 路径，默认与脚本同目录。
#>
param(
    [switch]$Apply,
    [string]$ConfigPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#──────────────────────────────────────────────────────────────────────────────
#  0.  管理员自检 + UAC 自动提权
#──────────────────────────────────────────────────────────────────────────────
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = [Security.Principal.WindowsPrincipal]$id
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host "需要管理员权限，正在请求 UAC 提权……" -ForegroundColor Yellow
    $args2 = "-NoExit -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($Apply)      { $args2 += ' -Apply' }
    if ($ConfigPath) { $args2 += " -ConfigPath `"$ConfigPath`"" }
    Start-Process powershell -Verb RunAs -ArgumentList $args2
    exit
}

#──────────────────────────────────────────────────────────────────────────────
#  1.  载入模块和配置
#──────────────────────────────────────────────────────────────────────────────
$scriptDir = Split-Path $PSCommandPath -Parent
$modulesDir = Join-Path $scriptDir 'modules'
$logsDir    = Join-Path $scriptDir 'logs'

if (-not (Test-Path $logsDir)) { New-Item -ItemType Directory -Path $logsDir -Force | Out-Null }

foreach ($mod in @('DiskScan','DetectGames','DetectAI','DetectSaves',
                    'Move-WithJunction','Setup-AIDrive','Rollback')) {
    Import-Module (Join-Path $modulesDir "$mod.psm1") -Force -ErrorAction Stop
}

if (-not $ConfigPath) { $ConfigPath = Join-Path $scriptDir 'config.psd1' }
if (-not (Test-Path $ConfigPath)) {
    Write-Error "找不到配置文件: $ConfigPath"
    exit 1
}
$Config = Import-PowerShellDataFile $ConfigPath

#──────────────────────────────────────────────────────────────────────────────
#  2.  全局状态
#──────────────────────────────────────────────────────────────────────────────
$Inventory  = $null
$GameList   = $null
$AIList     = $null
$PlanFile   = $null
$DryRun     = -not $Apply

#──────────────────────────────────────────────────────────────────────────────
#  3.  菜单辅助函数
#──────────────────────────────────────────────────────────────────────────────
function Show-Header {
    Clear-Host
    $mode = if ($DryRun) { "DRY-RUN（只预览，不移动文件）" } else { "APPLY（实际移动文件）" }
    Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  PC 文件智能整理工具  ·  模式: $mode" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
}

function Show-Menu {
    Write-Host "  1) 扫描磁盘 + 文件" -ForegroundColor White
    Write-Host "  2) 生成整理方案 (dry-run 报告)" -ForegroundColor White
    Write-Host "  3) 执行游戏迁移" -ForegroundColor White
    Write-Host "  4) 执行 AI 资料归集 + 初始化 AI 盘" -ForegroundColor White
    Write-Host "  5) 升级 AI 盘为真实分区" -ForegroundColor Yellow
    Write-Host "  6) 回滚上一次操作" -ForegroundColor Magenta
    Write-Host "  7) 查看操作日志" -ForegroundColor White
    Write-Host "  Q) 退出" -ForegroundColor DarkGray
    Write-Host ""
}

function Prompt-Continue {
    Read-Host "按 Enter 继续" | Out-Null
}

#──────────────────────────────────────────────────────────────────────────────
#  4.  各功能实现
#──────────────────────────────────────────────────────────────────────────────

function Do-Scan {
    Write-Host "`n正在扫描磁盘……" -ForegroundColor Cyan
    $script:Inventory = Get-DiskInventory
    Show-DiskInventory $script:Inventory

    Write-Host "`n正在识别游戏目录……" -ForegroundColor Cyan
    $script:GameList = Find-GameDirectories -Config $Config
    Write-Host "  找到 $($script:GameList.Count) 个游戏目录" -ForegroundColor Green

    Write-Host "`n正在识别 AI 资料……" -ForegroundColor Cyan
    $script:AIList = Find-AIContent -Config $Config
    Write-Host "  找到 $($script:AIList.Count) 个 AI 资料目录" -ForegroundColor Green

    # 存档匹配
    foreach ($game in $script:GameList) {
        $game.SaveHints = Find-SaveDirectories -GameName $game.GameName -Config $Config
    }

    # 保存 inventory
    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    $invFile = Join-Path $logsDir "inventory_$ts.json"
    @{ Disks = $script:Inventory; Games = $script:GameList; AI = $script:AIList } |
        ConvertTo-Json -Depth 6 | Set-Content $invFile -Encoding UTF8
    Write-Host "`n清单已保存: $invFile" -ForegroundColor DarkGray
}

function Do-DryRun {
    if (-not $script:GameList) { Do-Scan }

    $ts      = Get-Date -Format 'yyyyMMdd_HHmmss'
    $planPath = Join-Path $logsDir "plan_$ts.json"

    $gamePlans = foreach ($game in $script:GameList) {
        $totalGB = $game.SizeGB
        $target  = Select-BestTarget -Targets $Config.GameTargets -RequiredGB $totalGB
        [PSCustomObject]@{
            GameName    = $game.GameName
            Source      = $game.Path
            Destination = if ($target) { Join-Path $target $game.GameName } else { '(空间不足，跳过)' }
            SizeGB      = $totalGB
            SaveHints   = $game.SaveHints
            Feasible    = $null -ne $target
        }
    }

    $aiPlans = foreach ($item in $script:AIList) {
        [PSCustomObject]@{
            Path        = $item.Path
            Category    = $item.Category
            Destination = Join-Path $Config.AIRoot $item.Category (Split-Path $item.Path -Leaf)
            SizeGB      = $item.SizeGB
            Reason      = $item.Reason
        }
    }

    $plan = @{
        GeneratedAt = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        TotalGamesGB = [math]::Round(($gamePlans | Measure-Object SizeGB -Sum).Sum, 2)
        TotalAIGB    = [math]::Round(($aiPlans   | Measure-Object SizeGB -Sum).Sum, 2)
        Games        = $gamePlans
        AI           = $aiPlans
    }

    $plan | ConvertTo-Json -Depth 6 | Set-Content $planPath -Encoding UTF8
    $script:PlanFile = $planPath

    Write-Host "`n─── 整理方案预览 ──────────────────────────────────────" -ForegroundColor Cyan
    Write-Host "  游戏: $($gamePlans.Count) 项，合计 $($plan.TotalGamesGB) GB" -ForegroundColor White
    foreach ($g in $gamePlans) {
        $mark = if ($g.Feasible) { '✓' } else { '✗' }
        $saveInfo = if ($g.SaveHints.Count -gt 0) { "  [存档: $($g.SaveHints.Count) 处]" } else { '' }
        Write-Host "    $mark $($g.GameName) ($($g.SizeGB) GB)$saveInfo" -ForegroundColor $(if ($g.Feasible) {'White'} else {'DarkYellow'})
        Write-Host "       → $($g.Destination)" -ForegroundColor DarkGray
    }
    Write-Host "`n  AI 资料: $($aiPlans.Count) 项，合计 $($plan.TotalAIGB) GB" -ForegroundColor White
    foreach ($a in $aiPlans) {
        Write-Host "    [$($a.Category)] $($a.Path) ($($a.SizeGB) GB)" -ForegroundColor White
        Write-Host "       → $($a.Destination)" -ForegroundColor DarkGray
    }
    Write-Host "`n完整方案已保存: $planPath" -ForegroundColor DarkGray
}

function Do-MoveGames {
    if (-not $script:GameList) { Do-Scan }
    if ($DryRun) {
        Write-Host "`n当前为 DRY-RUN 模式，仅预览移动操作。" -ForegroundColor Yellow
        Write-Host "若要实际执行，请用 -Apply 参数重新启动脚本。`n" -ForegroundColor Yellow
    }

    $opLog   = [System.Collections.Generic.List[hashtable]]::new()
    $ts      = Get-Date -Format 'yyyyMMdd_HHmmss'
    $logPath = Join-Path $logsDir "op_games_$ts.json"

    foreach ($game in $script:GameList) {
        $totalGB = $game.SizeGB
        $target  = Select-BestTarget -Targets $Config.GameTargets -RequiredGB $totalGB
        if (-not $target) {
            Write-Warning "没有足够空间容纳 $($game.GameName) ($totalGB GB)，已跳过。"
            continue
        }
        $dest  = Join-Path $target $game.GameName
        $entry = @{ Type = 'Game'; GameName = $game.GameName }
        Move-DirectoryWithJunction -Source $game.Path -Destination $dest -LogEntry $entry -DryRun:$DryRun
        $opLog.Add($entry)

        # 同步迁移存档
        foreach ($saveSrc in $game.SaveHints) {
            if (-not (Test-Path $saveSrc)) { continue }
            $relPath  = $saveSrc.Substring([System.IO.Path]::GetPathRoot($saveSrc).Length)
            $saveDest = Join-Path $dest '__saves__' $relPath
            $saveEntry = @{ Type = 'Save'; GameName = $game.GameName; SaveSource = $saveSrc }
            Move-DirectoryWithJunction -Source $saveSrc -Destination $saveDest -LogEntry $saveEntry -DryRun:$DryRun
            $opLog.Add($saveEntry)
        }
    }

    if (-not $DryRun) {
        @{ Operations = $opLog } | ConvertTo-Json -Depth 6 | Set-Content $logPath -Encoding UTF8
        Write-Host "`n操作日志已保存: $logPath" -ForegroundColor DarkGray
    }
}

function Do-MoveAI {
    if (-not $script:AIList) { Do-Scan }

    $opLog   = [System.Collections.Generic.List[hashtable]]::new()
    $ts      = Get-Date -Format 'yyyyMMdd_HHmmss'
    $logPath = Join-Path $logsDir "op_ai_$ts.json"

    Write-Host "`n初始化 AI 盘……" -ForegroundColor Cyan
    Initialize-AIDrive -Config $Config -DryRun:$DryRun

    Write-Host "`n归集 AI 资料……" -ForegroundColor Cyan
    Move-AIContent -AIItems $script:AIList -Config $Config -OpLog $opLog -DryRun:$DryRun

    if (-not $DryRun) {
        @{ Operations = $opLog } | ConvertTo-Json -Depth 6 | Set-Content $logPath -Encoding UTF8
        Write-Host "`n操作日志已保存: $logPath" -ForegroundColor DarkGray
    }
}

function Do-UpgradeAIDrive {
    Write-Host "`n⚠  此功能会修改磁盘分区，请确保已备份重要数据！" -ForegroundColor Red
    $confirm = Read-Host "输入 UPGRADE 继续"
    if ($confirm -ne 'UPGRADE') { Write-Host "已取消。"; return }
    Convert-AIDriveToRealPartition -Config $Config
}

function Do-Rollback {
    $files = Get-OperationLogs
    if (-not $files) { return }
    $choice = Read-Host "`n输入要回滚的日志序号（直接 Enter 选最新）"
    if ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $files.Count) {
        $logFile = $files[[int]$choice - 1].FullName
    } else {
        $logFile = $files[0].FullName
    }
    $dr = Read-Host "是否 dry-run？(y/n)"
    Invoke-Rollback -LogFile $logFile -DryRun:($dr -eq 'y')
}

#──────────────────────────────────────────────────────────────────────────────
#  5.  主循环
#──────────────────────────────────────────────────────────────────────────────
while ($true) {
    Show-Header
    Show-Menu
    $choice = Read-Host "请选择 (1-7 / Q)"

    switch ($choice.ToUpper()) {
        '1' { Do-Scan;         Prompt-Continue }
        '2' { Do-DryRun;       Prompt-Continue }
        '3' { Do-MoveGames;    Prompt-Continue }
        '4' { Do-MoveAI;       Prompt-Continue }
        '5' { Do-UpgradeAIDrive; Prompt-Continue }
        '6' { Do-Rollback;     Prompt-Continue }
        '7' { Get-OperationLogs; Prompt-Continue }
        'Q' { Write-Host "再见！" -ForegroundColor Cyan; exit }
        default { Write-Host "无效选项，请重试。" -ForegroundColor Red; Start-Sleep 1 }
    }
}
