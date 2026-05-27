function Initialize-AIDrive {
    <#
    .SYNOPSIS
        在 AIRoot 下建好 models/datasets/docs/misc 子目录，
        用 subst 把它映射成虚拟盘，并把重建脚本写到开机启动项。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$Config,
        [switch]$DryRun
    )

    $root   = $Config.AIRoot
    $letter = $Config.AIDriveLetter.ToUpper()
    $subdirs = @('models','datasets','docs','misc')

    if ($DryRun) {
        Write-Host "  [DRY-RUN] 将在 $root 建子目录: $($subdirs -join ', ')" -ForegroundColor DarkCyan
        Write-Host "  [DRY-RUN] subst ${letter}: $root" -ForegroundColor DarkCyan
        return
    }

    foreach ($sub in $subdirs) {
        $p = Join-Path $root $sub
        if (-not (Test-Path $p)) {
            New-Item -ItemType Directory -Path $p -Force | Out-Null
            Write-Host "  已创建: $p" -ForegroundColor Green
        }
    }

    # subst 映射
    $existing = & subst 2>$null | Where-Object { $_ -match "^${letter}:" }
    if ($existing) {
        Write-Host "  虚拟盘 ${letter}: 已存在，跳过 subst" -ForegroundColor Yellow
    } else {
        & subst "${letter}:" $root
        Write-Host "  虚拟盘 ${letter}: → $root 已创建" -ForegroundColor Green
    }

    # 开机自动重建虚拟盘的 cmd 文件
    $startupDir = [System.Environment]::GetFolderPath('Startup')
    $cmdPath    = Join-Path $startupDir "Mount-AIDrive.cmd"
    $cmdContent = "@echo off`r`nsubst ${letter}: `"$root`"`r`n"
    Set-Content -LiteralPath $cmdPath -Value $cmdContent -Encoding ASCII -Force
    Write-Host "  开机启动项已写入: $cmdPath" -ForegroundColor Green
}

function Move-AIContent {
    <#
    .SYNOPSIS
        把检测到的 AI 资料目录移动（或复制）到 AIRoot 对应子目录，
        原位建 Junction，并记录操作日志。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [array]$AIItems,
        [Parameter(Mandatory)] [hashtable]$Config,
        [Parameter(Mandatory)] [System.Collections.Generic.List[hashtable]]$OpLog,
        [switch]$DryRun
    )

    foreach ($item in $AIItems) {
        $dest = Join-Path $Config.AIRoot $item.Category (Split-Path $item.Path -Leaf)
        $entry = @{ Type = 'AI'; Category = $item.Category; Reason = $item.Reason }

        Move-DirectoryWithJunction -Source $item.Path -Destination $dest `
            -LogEntry $entry -DryRun:$DryRun

        $OpLog.Add($entry)
    }
}

function Convert-AIDriveToRealPartition {
    <#
    .SYNOPSIS
        把 E 盘压缩出空间，新建真实分区替代 subst 虚拟盘。
        ⚠ 高危操作，三次确认，请先备份重要数据。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$Config,
        [double]$PartitionSizeGB = 0   # 0 = 自动使用当前 AIRoot 大小 + 10% 余量
    )

    Write-Host "`n警告：此操作将对磁盘分区进行不可逆修改！" -ForegroundColor Red
    Write-Host "强烈建议先把重要数据备份到外接存储再继续。" -ForegroundColor Red

    for ($i = 1; $i -le 3; $i++) {
        $ans = Read-Host "第 $i/3 次确认：确实要继续？(输入 YES 继续)"
        if ($ans -ne 'YES') {
            Write-Host "已取消。" -ForegroundColor Yellow
            return
        }
    }

    $srcDrive = Split-Path $Config.AIRoot -Qualifier
    $srcLetter = $srcDrive.TrimEnd(':')

    # 计算需要多少空间
    if ($PartitionSizeGB -le 0) {
        $usedBytes = (Get-ChildItem -LiteralPath $Config.AIRoot -Recurse -Force -ErrorAction SilentlyContinue |
                      Measure-Object Length -Sum).Sum
        $PartitionSizeGB = [math]::Ceiling($usedBytes / 1GB * 1.1)
    }
    $neededBytes = [long]($PartitionSizeGB * 1GB)

    Write-Host "计划新分区大小: ${PartitionSizeGB} GB" -ForegroundColor Cyan

    # 检查是否可以从源盘压缩出足够空间
    $partition = Get-Partition -DriveLetter $srcLetter -ErrorAction Stop
    $sizes     = Get-PartitionSupportedSize -DriveLetter $srcLetter -ErrorAction Stop
    $shrinkable = $partition.Size - $sizes.SizeMin

    if ($shrinkable -lt $neededBytes) {
        Write-Warning "$srcDrive 仅能压缩出 $([math]::Round($shrinkable/1GB,1)) GB，不足 ${PartitionSizeGB} GB，操作中止。"
        return
    }

    $newSize = $partition.Size - $neededBytes
    Write-Host "压缩 $srcDrive: $([math]::Round($partition.Size/1GB,1)) GB → $([math]::Round($newSize/1GB,1)) GB" -ForegroundColor Yellow
    Resize-Partition -DriveLetter $srcLetter -Size $newSize -ErrorAction Stop

    $disk      = Get-Disk -Number $partition.DiskNumber
    $newPart   = New-Partition -DiskNumber $disk.Number -UseMaximumSize `
                     -DriveLetter $Config.AIDriveLetter -ErrorAction Stop
    Format-Volume -DriveLetter $Config.AIDriveLetter -FileSystem NTFS `
                  -NewFileSystemLabel 'AI' -Confirm:$false -ErrorAction Stop

    Write-Host "新分区 $($Config.AIDriveLetter): 已创建并格式化为 NTFS" -ForegroundColor Green

    # 迁移 AIRoot 内容到新分区根目录
    $newRoot = "$($Config.AIDriveLetter):\"
    Write-Host "正在把 $($Config.AIRoot) 内容迁移到 $newRoot ..." -ForegroundColor Yellow
    $roboArgs = @($Config.AIRoot, $newRoot, '/E', '/COPYALL', '/DCOPY:DAT', '/R:2', '/W:5', '/MT:8', '/NFL', '/NDL', '/NP')
    Start-Process robocopy -ArgumentList $roboArgs -Wait -WindowStyle Hidden

    # 删除 subst 开机项和旧目录
    $cmdPath = Join-Path ([System.Environment]::GetFolderPath('Startup')) 'Mount-AIDrive.cmd'
    if (Test-Path $cmdPath) { Remove-Item $cmdPath -Force }
    Remove-Item -LiteralPath $Config.AIRoot -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host "升级完成！AI 盘现在是真实分区 $($Config.AIDriveLetter):" -ForegroundColor Green
    Write-Host "请更新 config.psd1 中的 AIRoot = '$newRoot' 并重新运行扫描。" -ForegroundColor Cyan
}

Export-ModuleMember -Function Initialize-AIDrive, Move-AIContent, Convert-AIDriveToRealPartition
