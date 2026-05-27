function Find-GameDirectories {
    <#
    .SYNOPSIS
        扫描所有本地 NTFS 卷，返回识别到的游戏目录列表。
    .OUTPUTS
        PSCustomObject[]  每项含 Path / GameName / SizeGB / Source / SaveHints
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

    #── 1. 启动器已知路径 ──────────────────────────────────────────────────
    foreach ($letter in $driveLetters) {
        foreach ($pattern in $Config.LauncherPatterns) {
            $resolved = $pattern -replace '^\*', $letter
            if (Test-Path $resolved) {
                Get-ChildItem -LiteralPath $resolved -Directory -ErrorAction SilentlyContinue |
                    ForEach-Object { _AddGame $_ 'Launcher' $Config $results $seen }
            }
        }
    }

    #── 2. 启发式扫描（深度 ≤ 3，跳过已加入项的父路径）───────────────────
    foreach ($letter in $driveLetters) {
        Get-ChildItem -LiteralPath $letter -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin @('Windows','Users','Program Files','Program Files (x86)','ProgramData','System Volume Information','$Recycle.Bin') } |
            ForEach-Object { _ScanHeuristic $_ 0 3 $Config $results $seen }
    }

    return $results
}

function _AddGame {
    param($Dir, $Source, $Config, $List, $Seen)

    if ($Seen.Contains($Dir.FullName)) { return }

    $name = $Dir.Name
    # 黑名单
    foreach ($pat in $Config.GameBlacklist) {
        if ($name -like $pat) { return }
    }

    $sizeGB = _GetDirSizeGB $Dir.FullName

    # 白名单直接加；否则按体积过滤
    $whitelisted = $Config.GameWhitelist -contains $name
    if (-not $whitelisted -and $sizeGB -lt $Config.GameMinSizeGB) { return }

    $null = $Seen.Add($Dir.FullName)
    $List.Add([PSCustomObject]@{
        Path      = $Dir.FullName
        GameName  = $name
        SizeGB    = [math]::Round($sizeGB, 2)
        Source    = $Source
        SaveHints = @()
    })
}

function _ScanHeuristic {
    param($Dir, $Depth, $MaxDepth, $Config, $List, $Seen)

    if ($Depth -ge $MaxDepth) { return }
    if ($Seen.Contains($Dir.FullName)) { return }

    $name = $Dir.Name
    foreach ($pat in $Config.GameBlacklist) { if ($name -like $pat) { return } }

    $gameKeywords = @('bin','data','engine','_commonredist','redist','directx','vcredist',
                       'saves','savegames','config','shader','shaders','content','binaries',
                       'unreal','unity','cooked','gamedata','streamingassets')

    $children = Get-ChildItem -LiteralPath $Dir.FullName -ErrorAction SilentlyContinue
    $hasExe   = $children | Where-Object { $_.Extension -eq '.exe' } | Select-Object -First 1
    $hasGameSub = $children | Where-Object {
        $_.PSIsContainer -and $gameKeywords -contains $_.Name.ToLower()
    } | Select-Object -First 1

    if ($hasExe -and $hasGameSub) {
        _AddGame $Dir 'Heuristic' $Config $List $Seen
        return
    }

    foreach ($sub in ($children | Where-Object { $_.PSIsContainer })) {
        _ScanHeuristic $sub ($Depth + 1) $MaxDepth $Config $List $Seen
    }
}

function _GetDirSizeGB {
    param([string]$Path)
    try {
        $bytes = (Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue |
                  Measure-Object -Property Length -Sum).Sum
        return $bytes / 1GB
    } catch { return 0 }
}

Export-ModuleMember -Function Find-GameDirectories
