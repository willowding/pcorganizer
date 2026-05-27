function Get-DiskInventory {
    <#
    .SYNOPSIS
        列出所有本地 NTFS 卷，含容量、剩余空间、是否 SSD、可压缩上限。
    #>
    [CmdletBinding()]
    param()

    $physDisks = @{}
    try {
        Get-PhysicalDisk | ForEach-Object {
            $pd = $_
            Get-Disk | Where-Object { $_.FriendlyName -eq $pd.FriendlyName } | ForEach-Object {
                $_.DiskNumber | ForEach-Object { $physDisks[$_] = $pd.MediaType }
            }
        }
    } catch { }

    $result = [System.Collections.Generic.List[PSCustomObject]]::new()

    Get-Volume | Where-Object {
        $_.DriveType -eq 'Fixed' -and
        $_.FileSystemType -eq 'NTFS' -and
        $_.DriveLetter
    } | ForEach-Object {
        $vol = $_
        $letter = $vol.DriveLetter

        $isSSD = $false
        try {
            $partition = Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue
            if ($partition) {
                $mediaType = $physDisks[$partition.DiskNumber]
                $isSSD = ($mediaType -eq 'SSD' -or $mediaType -eq 'NVMe')
            }
        } catch { }

        $shrinkable = 0
        try {
            $sizes = Get-PartitionSupportedSize -DriveLetter $letter -ErrorAction SilentlyContinue
            if ($sizes) {
                $partition2 = Get-Partition -DriveLetter $letter -ErrorAction SilentlyContinue
                if ($partition2) {
                    $shrinkable = $partition2.Size - $sizes.SizeMin
                }
            }
        } catch { }

        $result.Add([PSCustomObject]@{
            DriveLetter  = "$letter`:"
            Label        = $vol.FileSystemLabel
            TotalGB      = [math]::Round($vol.Size / 1GB, 1)
            FreeGB       = [math]::Round($vol.SizeRemaining / 1GB, 1)
            UsedGB       = [math]::Round(($vol.Size - $vol.SizeRemaining) / 1GB, 1)
            FreePercent  = if ($vol.Size -gt 0) { [math]::Round($vol.SizeRemaining * 100 / $vol.Size, 1) } else { 0 }
            IsSSD        = $isSSD
            ShrinkableGB = [math]::Round($shrinkable / 1GB, 1)
        })
    }

    return $result
}

function Show-DiskInventory {
    param([array]$Inventory)
    Write-Host "`n磁盘概览：" -ForegroundColor Cyan
    Write-Host ("-" * 72)
    $fmt = "{0,-6} {1,-16} {2,8} {3,8} {4,8} {5,7} {6,6} {7,10}"
    Write-Host ($fmt -f "盘符","卷标","总量(GB)","已用(GB)","剩余(GB)","剩余%","SSD","可压缩(GB)")
    Write-Host ("-" * 72)
    foreach ($d in $Inventory) {
        $ssdMark = if ($d.IsSSD) { "✓" } else { "-" }
        Write-Host ($fmt -f $d.DriveLetter, $d.Label, $d.TotalGB, $d.UsedGB, $d.FreeGB, "$($d.FreePercent)%", $ssdMark, $d.ShrinkableGB)
    }
    Write-Host ("-" * 72)
}

Export-ModuleMember -Function Get-DiskInventory, Show-DiskInventory
