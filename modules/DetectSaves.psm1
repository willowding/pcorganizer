function Find-SaveDirectories {
    <#
    .SYNOPSIS
        在常见存档位置里找与给定游戏名匹配的存档目录。
    .PARAMETER GameName
        游戏目录名（用于模糊匹配）。
    .PARAMETER Config
        来自 config.psd1 的配置哈希表。
    .OUTPUTS
        字符串数组，每项为一个存档目录完整路径。
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]$GameName,
        [Parameter(Mandatory)] [hashtable]$Config
    )

    $found = [System.Collections.Generic.List[string]]::new()
    $cleanName = _NormalizeName $GameName

    foreach ($rawRoot in $Config.SaveRoots) {
        $root = [System.Environment]::ExpandEnvironmentVariables($rawRoot)
        if (-not (Test-Path $root)) { continue }

        Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            ForEach-Object {
                $candidate = _NormalizeName $_.Name
                if (_IsSimilar $cleanName $candidate) {
                    $found.Add($_.FullName)
                }
            }
    }

    # AppData\Local 下逐层扫（最多 2 层），匹配 Saves / SaveGames / SaveData 子目录
    $saveSubNames = @('saves','savegames','savedata','save','mygames','userdata')
    $localApp = [System.Environment]::ExpandEnvironmentVariables('%LOCALAPPDATA%')
    if (Test-Path $localApp) {
        Get-ChildItem -LiteralPath $localApp -Directory -ErrorAction SilentlyContinue |
            Where-Object { _IsSimilar $cleanName (_NormalizeName $_.Name) } |
            ForEach-Object {
                $parent = $_.FullName
                Get-ChildItem -LiteralPath $parent -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $saveSubNames -contains $_.Name.ToLower() } |
                    ForEach-Object { $found.Add($_.FullName) }
                # 也加父目录本身（如果含存档文件）
                $saveFiles = Get-ChildItem -LiteralPath $parent -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Extension -in @('.sav','.save','.dat','.bin','.bak','.profile') } |
                    Select-Object -First 1
                if ($saveFiles) { $found.Add($parent) }
            }
    }

    return ($found | Sort-Object -Unique)
}

function _NormalizeName {
    param([string]$Name)
    # 去除™®、替换分隔符为空格、小写
    $n = $Name -replace '[™®©:!\-_\.]', ' '
    $n = $n -replace '\s+', ' '
    return $n.Trim().ToLower()
}

function _IsSimilar {
    param([string]$A, [string]$B)

    # 完全匹配
    if ($A -eq $B) { return $true }

    # 前缀匹配（至少 4 字符）
    $minLen = [math]::Min($A.Length, $B.Length)
    if ($minLen -ge 4 -and $A.StartsWith($B.Substring(0, [math]::Min($B.Length, 6)))) { return $true }
    if ($minLen -ge 4 -and $B.StartsWith($A.Substring(0, [math]::Min($A.Length, 6)))) { return $true }

    # Levenshtein 距离（相对长度 ≤ 30%）
    $dist = _Levenshtein $A $B
    $threshold = [math]::Max(2, [math]::Floor([math]::Max($A.Length, $B.Length) * 0.3))
    return $dist -le $threshold
}

function _Levenshtein {
    param([string]$S, [string]$T)
    $m = $S.Length; $n = $T.Length
    if ($m -eq 0) { return $n }
    if ($n -eq 0) { return $m }
    $d = New-Object 'int[,]' ($m+1),($n+1)
    for ($i=0;$i-le$m;$i++) { $d[$i,0]=$i }
    for ($j=0;$j-le$n;$j++) { $d[0,$j]=$j }
    for ($j=1;$j-le$n;$j++) {
        for ($i=1;$i-le$m;$i++) {
            $cost = if ($S[$i-1] -eq $T[$j-1]) { 0 } else { 1 }
            $d[$i,$j] = [math]::Min([math]::Min($d[$i-1,$j]+1, $d[$i,$j-1]+1), $d[$i-1,$j-1]+$cost)
        }
    }
    return $d[$m,$n]
}

Export-ModuleMember -Function Find-SaveDirectories
