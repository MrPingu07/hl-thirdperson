<#
.SYNOPSIS
    Packages the 32-bit Windows build into dist\<ModName> plus a zip archive.

.DESCRIPTION
    Windows twin of tools/package-linux.sh.  Expects a CMake build to have been
    installed into dist\ first, i.e.:

        cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -B build -S . -DCMAKE_INSTALL_PREFIX=dist
        cmake --build build --target install
        pwsh -File tools/package-windows.ps1

    The Windows binaries are a release candidate: CI compiles them, but they
    have not been played yet, hence the -RcLabel suffix on the zip.

.PARAMETER Version
    Version string used in the file name (default: git describe --tags --always).

.PARAMETER RcLabel
    Release candidate label placed before "-windows" (default: rc1).

.PARAMETER ModName
    Mod folder name (default: hltps).

.PARAMETER DistRoot
    Directory holding the installed build (default: <repo>\dist).
#>
[CmdletBinding()]
param(
    [string]$Version = "",
    [string]$RcLabel = "rc1",
    [string]$ModName = "hltps",
    [string]$DistRoot = ""
)

$ErrorActionPreference = "Stop"

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if (-not $DistRoot) { $DistRoot = Join-Path $Root "dist" }
if (-not (Test-Path $DistRoot)) {
    throw "No build found at $DistRoot - run 'cmake --build build --target install' first."
}
$DistRoot = (Resolve-Path $DistRoot).Path
$Dist = Join-Path $DistRoot $ModName

if (-not $Version) {
    $Version = (& git -C $Root describe --tags --always | Out-String).Trim()
}

# --- locate the build outputs ------------------------------------------------
# CMake installs into <prefix>\<GAMEDIR>\{dlls,cl_dlls}; GAMEDIR is "valve" by
# default, but search for it instead of hardcoding the name.
function Find-Installed([string]$Leaf, [string]$DirName) {
    Get-ChildItem -Path $DistRoot -Recurse -File -Filter $Leaf -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Directory.Name -eq $DirName -and
            $_.FullName -notlike "$Dist*" -and
            $_.Name -notmatch '_amd64'
        } |
        Select-Object -First 1
}

$HlDll = Find-Installed "hl.dll" "dlls"
$ClDll = Find-Installed "client.dll" "cl_dlls"
if (-not $HlDll -or -not $ClDll) {
    throw "Build outputs not found under $DistRoot - run 'cmake --build build --target install' first."
}

# GoldSrc is a 32-bit game: refuse anything that is not PE32/i386.
function Assert-Pe32([System.IO.FileInfo]$File) {
    $stream = [IO.File]::OpenRead($File.FullName)
    try {
        $reader = New-Object IO.BinaryReader($stream)
        if ($reader.ReadUInt16() -ne 0x5A4D) { throw "Not a PE file: $($File.FullName)" }
        $stream.Position = 0x3C                  # e_lfanew: offset of the PE header
        $stream.Position = $reader.ReadInt32()
        if ($reader.ReadUInt32() -ne 0x00004550) { throw "Not a PE file: $($File.FullName)" }
        $machine = $reader.ReadUInt16()
        if ($machine -ne 0x014C) {
            throw ("Not 32-bit x86: {0} (machine 0x{1:X4}); GoldSrc needs i386" -f $File.FullName, $machine)
        }
    } finally {
        $stream.Dispose()
    }
}

Assert-Pe32 $HlDll
Assert-Pe32 $ClDll

# --- assemble the mod folder -------------------------------------------------
if (Test-Path $Dist) { Remove-Item -Recurse -Force $Dist }
New-Item -ItemType Directory -Force -Path (Join-Path $Dist "dlls"), (Join-Path $Dist "cl_dlls") | Out-Null

Copy-Item $HlDll.FullName (Join-Path $Dist "dlls\hl.dll")
Copy-Item $ClDll.FullName (Join-Path $Dist "cl_dlls\client.dll")
Copy-Item (Join-Path $Root "tools\liblist.gam") (Join-Path $Dist "liblist.gam")
Copy-Item (Join-Path $Root "THIRDPERSON.md") (Join-Path $Dist "README.md")
Get-ChildItem -Path $Root -File -Filter "LICENSE*" | Copy-Item -Destination $Dist

# cmd.exe wants CRLF; normalise, so the archive is right whatever git did.
$bat = [IO.File]::ReadAllText((Join-Path $Root "tools\link-game-content.bat"))
$bat = ($bat -replace "`r`n", "`n") -replace "`n", "`r`n"
[IO.File]::WriteAllText((Join-Path $Dist "link-game-content.bat"), $bat, (New-Object Text.UTF8Encoding($false)))

# --- archive -----------------------------------------------------------------
$ZipName = "$ModName-$Version-$RcLabel-windows.zip"
$ZipPath = Join-Path $DistRoot $ZipName
if (Test-Path $ZipPath) { Remove-Item -Force $ZipPath }

# bsdtar (shipped with Windows) writes entry names with forward slashes;
# Compress-Archive in Windows PowerShell writes backslashes instead.
& tar.exe -a -c -f $ZipPath -C $DistRoot $ModName
if ($LASTEXITCODE -ne 0) { throw "tar failed with exit code $LASTEXITCODE" }

# --- verify ------------------------------------------------------------------
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($ZipPath)
try {
    $entries = @($archive.Entries | ForEach-Object { $_.FullName })
} finally {
    $archive.Dispose()
}

if ($entries | Where-Object { $_ -like "*\*" }) {
    throw "Archive entry names must use forward slashes"
}
$wanted = @(
    "$ModName/liblist.gam",
    "$ModName/dlls/hl.dll",
    "$ModName/cl_dlls/client.dll",
    "$ModName/link-game-content.bat",
    "$ModName/README.md",
    "$ModName/LICENSE"
)
foreach ($entry in $wanted) {
    if ($entries -notcontains $entry) { throw "Missing from the archive: $entry" }
}

$entries | Sort-Object | ForEach-Object { Write-Host "  $_" }
Write-Host ("Package: dist\{0} ({1:N0} bytes)" -f $ZipName, (Get-Item $ZipPath).Length)
