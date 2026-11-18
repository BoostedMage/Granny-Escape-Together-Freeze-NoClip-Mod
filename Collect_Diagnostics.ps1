# Only reads UE4SS logs and installed mod/script version. No game process attachment.
param([string]$GameRoot='')
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'Find-GETGame.ps1')
Write-Host 'Granny Escape Together - Mod Diagnostics v0.1.2'
$game=Find-GETGameRoot -ManualPath $GameRoot
if (-not $game) {
    $manual=Read-Host 'Paste the Granny Escape Together game folder path'
    if ($manual) { $game=Find-GETGameRoot -ManualPath $manual }
}
if (-not $game) { Write-Host 'Game not found; nothing read.' -ForegroundColor Red; exit 2 }
$win64=Join-Path $game 'GrannyEscapeTogether\Binaries\Win64'
$logCandidates=@(
    (Join-Path $win64 'ue4ss\UE4SS.log'),
    (Join-Path $win64 'UE4SS.log'),
    (Join-Path $win64 'ue4ss\UE4SS\UE4SS.log')
)
$logs=@($logCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
$stamp=Get-Date -Format 'yyyyMMdd_HHmmss'
$stage=Join-Path ([IO.Path]::GetTempPath()) ('GET_Diagnostics_'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage -Force | Out-Null
$out=Join-Path ([Environment]::GetFolderPath('UserProfile')) ('Downloads\UPLOAD_THIS_GrannyEscapeTogether_ModTest_'+$stamp+'.zip')
try {
    $summary=@(
        'GET Freeze/NoClip v0.1.2 diagnostic collector',
        ('Collected: '+(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')),
        ('UE4SS logs located: '+$logs.Count),
        ('Modern loader: '+(Test-Path (Join-Path $win64 'ue4ss\UE4SS.dll'))),
        ('Proxy present: '+(Test-Path (Join-Path $win64 'dwmapi.dll'))),
        ('Our mod present: '+(Test-Path (Join-Path $win64 'ue4ss\Mods\GETFreezeNoClip\scripts\main.lua'))),
        'The diagnostic collector does NOT attach to a game or alter saves, binaries, or network settings.',
        'Only filtered GETMOD and UE4SS startup/error lines are included. No raw game logs.'
    )
    [IO.File]::WriteAllLines((Join-Path $stage 'Summary.txt'),$summary)
    $pattern='\[GETMOD\]|Starting Lua mod.*GETFreezeNoClip|Failed to.*GETFreezeNoClip|Lua.*Error|Unable to find.*UE4SS'
    $kept=New-Object 'System.Collections.Generic.List[string]'
    foreach($path in $logs) {
        $kept.Add('[UE4SS log, source filename only: '+[IO.Path]::GetFileName($path)+']')
        foreach ($line in (Get-Content -LiteralPath $path -Tail 3000 -ErrorAction SilentlyContinue)) {
            if ($line -match $pattern) {
                $safe=$line
                $safe=[regex]::Replace($safe,'(?i)[A-Z]:\\[^\s"'']+','<path>')
                $safe=[regex]::Replace($safe,'(?i)https?://\S+','<url>')
                $safe=[regex]::Replace($safe,'\b\d{17}\b','<steam_id>')
                $safe=[regex]::Replace($safe,'\b(?:\d{1,3}\.){3}\d{1,3}\b','<ip>')
                $kept.Add($safe.Substring(0,[Math]::Min($safe.Length,800)))
            }
        }
    }
    if ($kept.Count -eq 0) { $kept.Add('No UE4SS log found. Is the loader installed and has the game run?') }
    [IO.File]::WriteAllLines((Join-Path $stage 'Filtered_Mod_Log.txt'),$kept)
    $exe=Join-Path $win64 'GrannyEscapeTogether-Win64-Shipping.exe'
    if (Test-Path $exe) {
        $ver=(Get-Item $exe).VersionInfo.FileVersion
        [IO.File]::WriteAllText((Join-Path $stage 'Exe_Version.txt'),"FileVersion: $ver`r`n")
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }
    [IO.Compression.ZipFile]::CreateFromDirectory($stage,$out)
    Write-Host "Created ZIP: $out" -ForegroundColor Green
    Write-Host 'Upload that UPLOAD_THIS_GrannyEscapeTogether_ModTest ZIP here.'
} finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
}
