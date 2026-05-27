function Invoke-Rollback {
    <#
    .SYNOPSIS
        读取最近一次操作日志，反向执行：删联接 → robocopy 回原位。
    .PARAMETER LogFile
        指定日志文件路径；不指定则自动选最新的 logs\op_*.json。
    #>
    [CmdletBinding()]
    param(
        [string]$LogFile = '',
        [switch]$DryRun
    )

    $logsDir = Join-Path $PSScriptRoot '..\logs'

    if (-not $LogFile) {
        $latest = Get-ChildItem -LiteralPath $logsDir -Filter 'op_*.json' -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $latest) {
            Write-Warning "logs\ 目录下没有找到操作日志。"
            return
        }
        $LogFile = $latest.FullName
    }

    if (-not (Test-Path $LogFile)) {
        Write-Warning "日志文件不存在: $LogFile"
        return
    }

    $log = Get-Content -LiteralPath $LogFile -Raw | ConvertFrom-Json
    $entries = if ($log.Operations) { $log.Operations } else { @($log) }

    Write-Host "`n将回滚以下 $($entries.Count) 条操作（来自 $LogFile）：" -ForegroundColor Cyan

    $successEntries = $entries | Where-Object { $_.Status -eq 'success' -and $_.JunctionCreated -eq $true }

    if (-not $successEntries) {
        Write-Host "没有可回滚的成功操作。" -ForegroundColor Yellow
        return
    }

    foreach ($e in ($successEntries | Sort-Object StartTime -Descending)) {
        Write-Host "  回滚: $($e.Destination) → $($e.Source)" -ForegroundColor Yellow

        if ($DryRun) {
            Write-Host "  [DRY-RUN] 跳过实际操作" -ForegroundColor DarkCyan
            continue
        }

        # 删除 Junction
        $junc = Get-Item -LiteralPath $e.Source -Force -ErrorAction SilentlyContinue
        if ($junc -and ($junc.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            Remove-Item -LiteralPath $e.Source -Force -ErrorAction SilentlyContinue
        } elseif (Test-Path $e.Source) {
            Write-Warning "源路径不是 Junction，跳过: $($e.Source)"
            continue
        }

        # robocopy 回原位
        $roboArgs = @($e.Destination, $e.Source, '/E', '/COPYALL', '/DCOPY:DAT',
                       '/R:2', '/W:5', '/MT:8', '/XJ', '/NFL', '/NDL', '/NP')
        $proc = Start-Process robocopy -ArgumentList $roboArgs -Wait -PassThru -WindowStyle Hidden
        if ($proc.ExitCode -le 7) {
            Remove-Item -LiteralPath $e.Destination -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "  ✓ 已回滚: $($e.Source)" -ForegroundColor Green
        } else {
            Write-Warning "  robocopy 回滚失败（退出码 $($proc.ExitCode)）: $($e.Source)"
        }
    }

    Write-Host "`n回滚完成。" -ForegroundColor Cyan
}

function Get-OperationLogs {
    <#
    .SYNOPSIS
        列出所有操作日志文件，并显示摘要。
    #>
    $logsDir = Join-Path $PSScriptRoot '..\logs'
    $files = Get-ChildItem -LiteralPath $logsDir -Filter 'op_*.json' -ErrorAction SilentlyContinue |
             Sort-Object LastWriteTime -Descending

    if (-not $files) {
        Write-Host "暂无操作日志。" -ForegroundColor Yellow
        return
    }

    Write-Host "`n操作日志列表：" -ForegroundColor Cyan
    $i = 0
    foreach ($f in $files) {
        $i++
        try {
            $log = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json
            $ops = if ($log.Operations) { $log.Operations } else { @($log) }
            $success = ($ops | Where-Object { $_.Status -eq 'success' }).Count
            $total   = $ops.Count
            Write-Host "  [$i] $($f.Name)  ($success/$total 成功)  $($f.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))"
        } catch {
            Write-Host "  [$i] $($f.Name)  (解析失败)"
        }
    }
    return $files
}

Export-ModuleMember -Function Invoke-Rollback, Get-OperationLogs
