function Find-AIContent {
    <#
    .SYNOPSIS
        扫描所有本地 NTFS 卷，按文件后缀和目录名把 AI 资料分成
        models / datasets / docs / misc 四类返回。
    .OUTPUTS
        PSCustomObject[]  每项含 Path / Category / SizeGB / Reason
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [hashtable]$Config
    )

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    $seen    = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    $driveLetters = Get-Volume |
        Where-Object { $_.DriveType -eq 'Fixed' -and $_.FileSystemType -eq 'NTFS' -and $_.DriveLetter } |
        ForEach-Object { "$($_.DriveLetter):" }

    foreach ($letter in $driveLetters) {
        _ScanForAI $letter $Config $results $seen
    }

    return $results
}

function _ScanForAI {
    param([string]$Root, [hashtable]$Config, $List, $Seen)

    $skipDirs = @('Windows','$Recycle.Bin','System Volume Information',
                   'WindowsApps','WinSxS')

    try {
        $items = Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue |
                 Where-Object { $skipDirs -notcontains $_.Name }
    } catch { return }

    foreach ($dir in $items) {
        _EvalDirectory $dir $Config $List $Seen
    }
}

function _EvalDirectory {
    param($Dir, [hashtable]$Config, $List, $Seen)

    if ($Seen.Contains($Dir.FullName)) { return }

    $dirNameLower = $Dir.Name.ToLower()

    #── 数据集目录名命中 ───────────────────────────────────────────────────
    foreach ($kw in $Config.DatasetDirKeywords) {
        if ($dirNameLower -eq $kw -or $dirNameLower -like "*$kw*") {
            _RegisterAI $Dir 'datasets' "目录名含关键字: $kw" $Config $List $Seen
            return
        }
    }

    #── 统计目录内各类型文件 ──────────────────────────────────────────────
    $allFiles = Get-ChildItem -LiteralPath $Dir.FullName -File -Recurse -ErrorAction SilentlyContinue
    if (-not $allFiles) {
        # 递归进子目录
        Get-ChildItem -LiteralPath $Dir.FullName -Directory -ErrorAction SilentlyContinue |
            ForEach-Object { _EvalDirectory $_ $Config $List $Seen }
        return
    }

    $modelFiles   = $allFiles | Where-Object { $Config.ModelExtensions   -contains $_.Extension.ToLower() }
    $datasetFiles = $allFiles | Where-Object { $Config.DatasetExtensions -contains $_.Extension.ToLower() }
    $docFiles     = $allFiles | Where-Object { $Config.DocExtensions     -contains $_.Extension.ToLower() }

    $modelSize   = ($modelFiles   | Measure-Object Length -Sum).Sum
    $datasetSize = ($datasetFiles | Measure-Object Length -Sum).Sum

    if ($modelFiles.Count -gt 0 -and $modelSize -gt 10MB) {
        _RegisterAI $Dir 'models' "含 $($modelFiles.Count) 个模型权重文件" $Config $List $Seen
        return
    }

    if ($datasetFiles.Count -gt 5 -and $datasetSize -gt 1MB) {
        _RegisterAI $Dir 'datasets' "含 $($datasetFiles.Count) 个数据集文件" $Config $List $Seen
        return
    }

    if ($docFiles.Count -ge $Config.DocMinCount) {
        _RegisterAI $Dir 'docs' "含 $($docFiles.Count) 个文档文件" $Config $List $Seen
        return
    }

    #── 大型单文件（模型或数据集）也命中 ────────────────────────────────
    $bigModels = $allFiles | Where-Object {
        $Config.ModelExtensions -contains $_.Extension.ToLower() -and $_.Length -gt 100MB
    }
    if ($bigModels.Count -gt 0) {
        _RegisterAI $Dir 'models' "含大型模型文件 (>100MB)" $Config $List $Seen
        return
    }

    # 递归子目录
    Get-ChildItem -LiteralPath $Dir.FullName -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { _EvalDirectory $_ $Config $List $Seen }
}

function _RegisterAI {
    param($Dir, [string]$Category, [string]$Reason, [hashtable]$Config, $List, $Seen)

    if ($Seen.Contains($Dir.FullName)) { return }

    # 跳过已经在 AI 根目录内的
    if ($Dir.FullName.StartsWith($Config.AIRoot, [StringComparison]::OrdinalIgnoreCase)) { return }

    $null = $Seen.Add($Dir.FullName)
    $sizeGB = try {
        [math]::Round(((Get-ChildItem -LiteralPath $Dir.FullName -Recurse -Force -ErrorAction SilentlyContinue |
            Measure-Object Length -Sum).Sum) / 1GB, 2)
    } catch { 0 }

    $List.Add([PSCustomObject]@{
        Path     = $Dir.FullName
        Category = $Category
        SizeGB   = $sizeGB
        Reason   = $Reason
    })
}

Export-ModuleMember -Function Find-AIContent
