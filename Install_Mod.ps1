# Granny Escape Together - Freeze/No-Clip v0.1.2
# User-invoked installer. No injection or game process manipulation.
# UE4SS is an independently released project: https://github.com/UE4SS-RE/RE-UE4SS
param(
    [ValidateSet('Install','Remove')][string]$Action='Install',
    [string]$GameRoot=''
)
$ErrorActionPreference='Stop'
$modName='GETFreezeNoClip'
$officialRelease='https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/v4.0.0'
$officialZip='https://github.com/UE4SS-RE/RE-UE4SS/releases/download/v4.0.0/UE4SS_v4.0.0.zip'
. (Join-Path $PSScriptRoot 'Find-GETGame.ps1')
Write-Host '===================================================='
Write-Host ' Granny Escape Together | Freeze/No-Clip v0.1.2 ALPHA'
Write-Host '===================================================='
Write-Host 'Build evidence: Steam 26710650 | Unreal Engine 5.8'
Write-Host 'F6 freeze + attacks + local damage guard | F7 noclip/smooth rise | F8 scan'
Write-Host 'No multiplayer-only lockout. Network replication remains unverified.'
Write-Host ''
$game = Find-GETGameRoot -ManualPath $GameRoot
if (-not $game) {
    Write-Host 'Could not automatically locate the installed game.' -ForegroundColor Yellow
    $manual = Read-Host 'Paste Granny Escape Together GAME FOLDER path (or Enter to cancel)'
    if (-not $manual) { exit 2 }
    $game = Find-GETGameRoot -ManualPath $manual
}
if (-not $game) { Write-Host 'Game folder invalid; nothing changed.' -ForegroundColor Red; exit 2 }
$win64=Join-Path $game 'GrannyEscapeTogether\Binaries\Win64'
$ue4ss=Join-Path $win64 'ue4ss'
$modRoot=Join-Path $ue4ss ('Mods\'+$modName)
Write-Host "Game: $game"
$active=Get-Process -Name 'GrannyEscapeTogether-Win64-Shipping' -ErrorAction SilentlyContinue
if ($active) { Write-Host 'Please EXIT the game before installing or removing the mod.' -ForegroundColor Yellow; exit 3 }
if ($Action -eq 'Remove') {
    $oldRoot=Join-Path $win64 ('Mods\'+$modName)
    $removed=$false
    foreach ($path in @($modRoot,$oldRoot)) {
        if (Test-Path -LiteralPath $path -PathType Container) {
            Remove-Item -LiteralPath $path -Recurse -Force
            Write-Host "Removed our mod: $path"
            $removed=$true
        }
    }
    if (-not $removed) { Write-Host 'This mod does not appear installed.' }
    Write-Host 'Left third-party UE4SS and other mods alone. Game files/saves untouched.'
    exit 0
}
$oldDll=Join-Path $win64 'UE4SS.dll'
$oldProxy=Join-Path $win64 'dwmapi.dll'
$modernDll=Join-Path $ue4ss 'UE4SS.dll'
$staging=$null
$mustInstallLoader=$false
if (Test-Path -LiteralPath $modernDll -PathType Leaf) {
    if (-not (Test-Path -LiteralPath $oldProxy -PathType Leaf)) {
        throw 'Found UE4SS in a subfolder, but dwmapi.dll is absent. Repair the official loader installation before proceeding.'
    }
    Write-Host 'Existing UE4SS loader found. Preserving it.'
} elseif ((Test-Path -LiteralPath $oldDll -PathType Leaf) -or
          (Test-Path -LiteralPath $oldProxy -PathType Leaf) -or
          (Test-Path -LiteralPath $ue4ss -PathType Container)) {
    throw 'An older/partial UE4SS or different dwmapi.dll is already present. Refusing to overwrite it; please resolve the existing loader first.'
} else {
    $mustInstallLoader=$true
}
if ($mustInstallLoader) {
    Write-Host ''
    Write-Host 'UE4SS v4.0.0 is REQUIRED to run this Lua mod; it supports Unreal Engine 5.8.'
    Write-Host "Official publisher: $officialRelease"
    Write-Host 'Installing it adds a third-party dwmapi.dll loader next to the game EXE.'
    Write-Host 'This may be incompatible with some games/online policies; test privately.'
    $zipCandidates=@(
        (Join-Path $PSScriptRoot 'UE4SS_v4.0.0.zip'),
        (Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Downloads\UE4SS_v4.0.0.zip')
    )
    $zipPath=$null
    foreach($candidate in $zipCandidates) { if (Test-Path -LiteralPath $candidate -PathType Leaf) { $zipPath=$candidate; break } }
    if (-not $zipPath) {
        Write-Host 'Official ZIP not already downloaded.'
        $answer=Read-Host 'Download UE4SS v4.0.0 DIRECTLY from official GitHub? [Y/N]'
        if ($answer -notmatch '^[yY]') {
            Write-Host "Download UE4SS_v4.0.0.zip at $officialRelease"
            Write-Host 'Save it to Downloads and run Install_Mod.cmd again. No changes made.'
            exit 4
        }
        $staging=Join-Path ([IO.Path]::GetTempPath()) ('GET_UE4SS_'+[guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        $zipPath=Join-Path $staging 'UE4SS_v4.0.0.zip'
        Write-Host 'Downloading official loader over HTTPS from the UE4SS GitHub release...'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        try { Invoke-WebRequest -Uri $officialZip -OutFile $zipPath -UseBasicParsing -TimeoutSec 120 }
        catch { throw ('Unable to download official UE4SS. You can download manually from '+$officialRelease+'. '+$_.Exception.Message) }
    }
    Write-Host ('Loader SHA256: '+(Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $arc=[IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $names=@($arc.Entries | ForEach-Object { $_.FullName.Replace('\','/').TrimStart('./') })
        if (-not ($names -contains 'dwmapi.dll') -or -not ($names -contains 'ue4ss/UE4SS.dll')) {
            throw 'This is not the expected official UE4SS v4.0.0 layout. No game files changed.'
        }
        foreach ($name in $names) {
            if ($name.StartsWith('/') -or $name -match '(^|/)\.\.(/|$)' -or $name.Contains(':')) {
                throw 'Unsafe ZIP member detected; refusing extraction.'
            }
        }
    } finally { $arc.Dispose() }
    if (-not $staging) {
        $staging=Join-Path ([IO.Path]::GetTempPath()) ('GET_UE4SS_'+[guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
    }
    $extracted=Join-Path $staging 'unpacked'
    Expand-Archive -LiteralPath $zipPath -DestinationPath $extracted -Force
    $proxySource=Join-Path $extracted 'dwmapi.dll'
    $folderSource=Join-Path $extracted 'ue4ss'
    if (-not (Test-Path -LiteralPath $proxySource -PathType Leaf) -or -not (Test-Path -LiteralPath (Join-Path $folderSource 'UE4SS.dll') -PathType Leaf)) {
        throw 'Expected official files are absent. No game files changed.'
    }
    # Only add if no files are present; never overwrite DLLs, configs or other mods.
    if ((Test-Path -LiteralPath $oldProxy) -or (Test-Path -LiteralPath $ue4ss)) {
        throw 'Installation directory changed during setup; refusing to overwrite.'
    }
    try {
        Copy-Item -LiteralPath $folderSource -Destination $ue4ss -Recurse -Force
        Copy-Item -LiteralPath $proxySource -Destination $oldProxy
    } catch {
        if (Test-Path -LiteralPath $oldProxy) { Remove-Item -LiteralPath $oldProxy -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $ue4ss) { Remove-Item -LiteralPath $ue4ss -Recurse -Force -ErrorAction SilentlyContinue }
        throw
    }
    Write-Host 'Official UE4SS loader installed.' -ForegroundColor Green
}
$payload=Join-Path $PSScriptRoot 'payload\Mods\GETFreezeNoClip'
if (-not (Test-Path -LiteralPath (Join-Path $payload 'scripts\main.lua'))) {
    throw 'Mod payload missing. Re-extract the entire ZIP and try again.'
}
if (Test-Path -LiteralPath $modRoot) {
    $existingBackup=Join-Path $modRoot 'scripts\main.lua'
    if (Test-Path -LiteralPath $existingBackup) {
        $backupTarget=Join-Path $modRoot ('main.lua.backup.'+(Get-Date -Format 'yyyyMMdd_HHmmss'))
        Copy-Item -LiteralPath $existingBackup -Destination $backupTarget -Force
        Write-Host 'Previous installed script backed up before update.'
    }
}
# Explicit file-to-file update: safe when the old GETFreezeNoClip folder exists.
# Do not accidentally nest payload/GETFreezeNoClip inside the installed folder.
New-Item -ItemType Directory -Path (Join-Path $modRoot 'scripts') -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $payload 'scripts\main.lua') -Destination (Join-Path $modRoot 'scripts\main.lua') -Force
New-Item -ItemType File -Path (Join-Path $modRoot 'enabled.txt') -Force | Out-Null
Write-Host ''
Write-Host 'Installed GETFreezeNoClip v0.1.2 ALPHA. Previous script was backed up.' -ForegroundColor Green
Write-Host 'Launch from Steam. F6 freezes & tries to block attacks; F7 no-clips; F8 scans.'
Write-Host 'You can test a private session with Chris, but replication is not yet confirmed.'
Write-Host 'After testing, close the game and run Collect_Diagnostics.cmd.'
Write-Host ('Mod path: '+$modRoot)
if ($staging -and (Test-Path -LiteralPath $staging)) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
