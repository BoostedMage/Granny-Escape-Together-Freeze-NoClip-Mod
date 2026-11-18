# Internal helper. Does not run the game, scan drives, or modify files.
function Find-GETGameRoot {
    param([string]$ManualPath = "")
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    if (-not [string]::IsNullOrWhiteSpace($ManualPath)) { $candidates.Add($ManualPath.Trim('"')) }
    $programX86 = [Environment]::GetFolderPath('ProgramFilesX86')
    if ($programX86) { $candidates.Add((Join-Path $programX86 'Steam\steamapps\common\Granny Escape Together')) }
    $candidates.Add('C:\Steam\steamapps\common\Granny Escape Together')
    $candidates.Add('D:\SteamLibrary\steamapps\common\Granny Escape Together')
    $candidates.Add('E:\SteamLibrary\steamapps\common\Granny Escape Together')
    $steamRoots = New-Object 'System.Collections.Generic.List[string]'
    try {
        $reg = Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue
        if ($reg -and $reg.SteamPath) { $steamRoots.Add($reg.SteamPath.Replace('/', '\')) }
    } catch { }
    if ($programX86) { $steamRoots.Add((Join-Path $programX86 'Steam')) }
    foreach ($root in @($steamRoots)) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $candidates.Add((Join-Path $root 'steamapps\common\Granny Escape Together'))
        $vdf = Join-Path $root 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf -PathType Leaf) {
            try {
                $raw = Get-Content -LiteralPath $vdf -Raw
                foreach ($match in [regex]::Matches($raw, '"path"\s+"([^"]+)"')) {
                    $libraryRoot = $match.Groups[1].Value -replace '\\\\','\'
                    $candidates.Add((Join-Path $libraryRoot 'steamapps\common\Granny Escape Together'))
                }
            } catch { }
        }
    }
    foreach ($dir in $candidates) {
        try {
            $real = [IO.Path]::GetFullPath($dir)
            $exe = Join-Path $real 'GrannyEscapeTogether\Binaries\Win64\GrannyEscapeTogether-Win64-Shipping.exe'
            if (Test-Path -LiteralPath $exe -PathType Leaf) { return $real }
        } catch { }
    }
    return $null
}
