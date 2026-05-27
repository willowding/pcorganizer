function Move-DirectoryWithJunction {
    <#
    .SYNOPSIS
        用 robocopy 把源目录完整迁移到目标路径，校验后在原位建目录联接。
    .PARAMETER Source
        源目录完整路径（会被删除并替换为 Junction）。
    .PARAMETER Destination
        目标完整路径（若已存在且非空则中止）。
    .PARAMETER LogEntry
        调用方传入的操作记录哈希表，本函数填写结果字段。
    .PARAMETER DryRun
        仅模拟，不实际执行。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$Source,
        [Parameter(Mandatory)] [string]$Destination,
        [Parameter(Mandatory)] [hashtable]$LogEntry,
        [switch]$DryRun
    )

    $LogEntry.Source      = $Source
    $LogEntry.Destination = $Destination
    $LogEntry.StartTime   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    $LogEntry.Status      = 'pending'
    $LogEntry.JunctionCreated = $false

    if ($DryRun) {
        $LogEntry.Status = 'dry-run'
        Write-Host "  [DRY-RUN] $Source  →  $Destination" -ForegroundColor DarkCyan
        return $true
    }

    # 目标不能已有非 Junction 内容
    if (Test-Path $Destination) {
        $existing = Get-Item -LiteralPath $Destination -Force
        if ($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            Write-Warning "目标已是联接点，跳过: $Destination"
            $LogEntry.Status = 'skipped-junction-exists'
            return $false
        }
        $existingItems = Get-ChildItem -LiteralPath $Destination -ErrorAction SilentlyContinue
        if ($existingItems) {
            Write-Warning "目标目录非空，跳过: $Destination"
            $LogEntry.Status = 'skipped-dest-nonempty'
            return $false
        }
    }

    # 检查目标盘 NTFS（Junction 要求）
    $destDrive = Split-Path $Destination -Qualifier
    $vol = Get-Volume -DriveLetter $destDrive.TrimEnd(':') -ErrorAction SilentlyContinue
    if ($vol -and $vol.FileSystemType -ne 'NTFS') {
        Write-Warning "目标盘不是 NTFS，无法建 Junction: $destDrive"
        $LogEntry.Status = 'error-not-ntfs'
        return $false
    }

    # 记录源大小用于校验
    $srcSize = _GetDirSize $Source
    $LogEntry.SourceSizeBytes = $srcSize

    Write-Host "  复制中: $Source" -ForegroundColor Yellow
    Write-Host "       → $Destination" -ForegroundColor Yellow

    New-Item -ItemType Directory -Force -Path $Destination | Out-Null

    $roboArgs = @($Source, $Destination, '/E', '/COPYALL', '/DCOPY:DAT',
                   '/R:2', '/W:5', '/MT:8', '/XJ', '/NFL', '/NDL', '/NP')
    $proc = Start-Process robocopy -ArgumentList $roboArgs -Wait -PassThru -WindowStyle Hidden
    # robocopy 返回码 0-7 均为成功
    if ($proc.ExitCode -gt 7) {
        Write-Warning "robocopy 出错，退出码: $($proc.ExitCode)"
        $LogEntry.Status = 'error-robocopy'
        $LogEntry.RobocopyExitCode = $proc.ExitCode
        return $false
    }

    # 大小校验
    $dstSize = _GetDirSize $Destination
    $LogEntry.DestSizeBytes = $dstSize
    if ([math]::Abs($srcSize - $dstSize) -gt 1MB) {
        Write-Warning "大小校验失败（源: $srcSize B，目标: $dstSize B），保留源目录不变"
        $LogEntry.Status = 'error-size-mismatch'
        return $false
    }

    # 删除源并建 Junction
    try {
        Remove-Item -LiteralPath $Source -Recurse -Force -ErrorAction Stop
        New-Item -ItemType Junction -Path $Source -Target $Destination -ErrorAction Stop | Out-Null
        $LogEntry.JunctionCreated = $true
        $LogEntry.Status = 'success'
        Write-Host "  ✓ 完成，Junction 已建立" -ForegroundColor Green
        return $true
    } catch {
        Write-Warning "删除/建联接失败: $_"
        $LogEntry.Status = 'error-junction'
        return $false
    }
}

function _GetDirSize {
    param([string]$Path)
    try {
        return (Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
                Measure-Object -Property Length -Sum).Sum
    } catch { return 0 }
}

function Select-BestTarget {
    <#
    .SYNOPSIS
        从配置的 GameTargets 列表里选剩余空间足够且最大的盘。
    #>
    param(
        [string[]]$Targets,
        [double]$RequiredGB
    )
    $best = $null
    $bestFree = 0
    foreach ($t in $Targets) {
        $drive = (Split-Path $t -Qualifier).TrimEnd(':')
        $vol = Get-Volume -DriveLetter $drive -ErrorAction SilentlyContinue
        if (-not $vol) { continue }
        $freeGB = $vol.SizeRemaining / 1GB
        if ($freeGB -ge $RequiredGB -and $freeGB -gt $bestFree) {
            $bestFree = $freeGB
            $best = $t
        }
    }
    return $best
}

Export-ModuleMember -Function Move-DirectoryWithJunction, Select-BestTarget
