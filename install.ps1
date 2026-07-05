<#
.SYNOPSIS
Installs Mimir for Windows.

.DESCRIPTION
Downloads the published Windows x64 Mimir release asset from GitHub,
verifies SHA256SUMS, extracts mimir.exe, and adds the install directory to the
current user's PATH.

Typical usage:
  irm https://mimir.kernelvm.xyz/install.ps1 | iex

Pinned release:
  $env:MIMIR_VERSION = "0.1.10"; irm https://mimir.kernelvm.xyz/install.ps1 | iex
#>
[CmdletBinding()]
param(
    [string]$Version = $env:MIMIR_VERSION,
    [string]$InstallDir = $(if ($env:MIMIR_INSTALL_DIR) { $env:MIMIR_INSTALL_DIR } else { Join-Path $HOME ".mimir\bin" }),
    [string]$ReleaseRepo = $(if ($env:MIMIR_RELEASE_REPO) { $env:MIMIR_RELEASE_REPO } else { "wasimysaid/mimir-shim" }),
    [string]$Binary = $env:MIMIR_BINARY,
    [switch]$NoModifyPath = $(
        $env:MIMIR_NO_MODIFY_PATH -in @("1", "true", "TRUE", "yes", "YES")
    ),
    [switch]$Help
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$App = "mimir"
$Target = "windows-x64"
$ArchiveName = "$App-$Target.zip"
$BinaryName = "$App.exe"

function Show-Usage {
    @"
Mimir Windows Installer

Usage:
  irm https://mimir.kernelvm.xyz/install.ps1 | iex

Environment variables for irm | iex usage:
  MIMIR_VERSION          Install a specific version, for example 0.1.10
  MIMIR_INSTALL_DIR      Install directory. Default: `%USERPROFILE%\.mimir\bin
  MIMIR_RELEASE_REPO     Release repo. Default: wasimysaid/mimir-shim
  MIMIR_BINARY           Install from a local binary instead of downloading
  MIMIR_NO_MODIFY_PATH   Set to 1 to skip user PATH changes

Direct file usage:
  powershell -ExecutionPolicy Bypass -File .\install.ps1 -Version 0.1.10
  pwsh -File .\install.ps1 -Binary .\target\release\mimir.exe
"@
}

function Normalize-MimirVersion {
    param([Parameter(Mandatory = $true)][string]$Value)

    $normalized = $Value.Trim()
    if ($normalized.StartsWith("mimir ", [StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $normalized.Substring(6)
    }
    if ($normalized.StartsWith("v", [StringComparison]::OrdinalIgnoreCase)) {
        $normalized = $normalized.Substring(1)
    }
    return $normalized
}

function Assert-WindowsX64 {
    $runningOnWindows = $env:OS -eq "Windows_NT"
    if ((Get-Variable -Name IsWindows -Scope Global -ErrorAction SilentlyContinue) -and -not $global:IsWindows) {
        $runningOnWindows = $false
    }
    if (-not $runningOnWindows) {
        throw "install.ps1 supports Windows only. Use install.sh on Linux/macOS."
    }

    $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    switch -Regex ($arch) {
        "^(AMD64|x86_64)$" { return }
        "^ARM64$" { throw "Windows arm64 is not published yet." }
        default { throw "Unsupported Windows architecture: $arch" }
    }
}

function Invoke-MimirDownload {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$OutFile
    )

    $parameters = @{
        Uri = $Uri
        OutFile = $OutFile
        Headers = @{ "User-Agent" = "mimir-installer" }
    }
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        $parameters.UseBasicParsing = $true
    }
    Invoke-WebRequest @parameters
}

function Invoke-MimirRestJson {
    param([Parameter(Mandatory = $true)][string]$Uri)

    $parameters = @{
        Uri = $Uri
        Headers = @{ "User-Agent" = "mimir-installer" }
    }
    if ($PSVersionTable.PSVersion.Major -lt 6) {
        $parameters.UseBasicParsing = $true
    }
    Invoke-RestMethod @parameters
}

function Get-LatestMimirVersion {
    param([Parameter(Mandatory = $true)][string]$Repo)

    $release = Invoke-MimirRestJson -Uri "https://api.github.com/repos/$Repo/releases/latest"
    if (-not $release.tag_name) {
        throw "Failed to resolve latest Mimir release from $Repo."
    }
    return Normalize-MimirVersion -Value ([string]$release.tag_name)
}

function Get-InstalledMimirVersion {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }

    try {
        $output = & $Path --version 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $output) {
            return $null
        }
        return Normalize-MimirVersion -Value ([string]$output)
    }
    catch {
        return $null
    }
}

function Get-ExpectedChecksum {
    param(
        [Parameter(Mandatory = $true)][string]$ChecksumsPath,
        [Parameter(Mandatory = $true)][string]$FileName
    )

    foreach ($line in Get-Content -LiteralPath $ChecksumsPath) {
        if ($line -match "^\s*([A-Fa-f0-9]{64})\s+\*?(.+?)\s*$") {
            $hash = $Matches[1]
            $name = Split-Path -Leaf $Matches[2]
            if ($name -eq $FileName) {
                return $hash.ToLowerInvariant()
            }
        }
    }

    throw "Checksum for $FileName is missing from SHA256SUMS."
}

function Assert-Checksum {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string]$ChecksumsPath
    )

    $fileName = Split-Path -Leaf $FilePath
    $expected = Get-ExpectedChecksum -ChecksumsPath $ChecksumsPath -FileName $fileName
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $FilePath).Hash.ToLowerInvariant()
    if ($actual -ne $expected) {
        throw "Checksum mismatch for $fileName. Expected $expected, got $actual."
    }
}

function Install-MimirBinary {
    param(
        [Parameter(Mandatory = $true)][string]$SourcePath,
        [Parameter(Mandatory = $true)][string]$DestinationDir
    )

    New-Item -ItemType Directory -Force -Path $DestinationDir | Out-Null
    $destinationPath = Join-Path $DestinationDir $BinaryName
    Copy-Item -LiteralPath $SourcePath -Destination $destinationPath -Force
    return $destinationPath
}

function Add-MimirToUserPath {
    param([Parameter(Mandatory = $true)][string]$Directory)

    if ($NoModifyPath) {
        return
    }

    $fullDirectory = [IO.Path]::GetFullPath($Directory).TrimEnd('\')
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if (-not $userPath) {
        $userPath = ""
    }

    $entries = $userPath -split ";" | Where-Object { $_ -ne "" }
    foreach ($entry in $entries) {
        try {
            $normalizedEntry = [IO.Path]::GetFullPath($entry).TrimEnd('\')
        }
        catch {
            continue
        }

        if ($normalizedEntry.Equals($fullDirectory, [StringComparison]::OrdinalIgnoreCase)) {
            if ($env:Path -notlike "*$Directory*") {
                $env:Path = "$Directory;$env:Path"
            }
            return
        }
    }

    $newPath = if ($userPath.Trim()) { "$userPath;$fullDirectory" } else { $fullDirectory }
    [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
    $env:Path = "$fullDirectory;$env:Path"
    Write-Host "Added $fullDirectory to the current user's PATH. Open a new terminal to use mimir everywhere."
}

function Install-Mimir {
    if ($Help) {
        Show-Usage
        return
    }

    Assert-WindowsX64

    $installPath = Join-Path $InstallDir $BinaryName
    if ($Binary) {
        if (-not (Test-Path -LiteralPath $Binary -PathType Leaf)) {
            throw "Binary not found: $Binary"
        }
        $installed = Install-MimirBinary -SourcePath $Binary -DestinationDir $InstallDir
        Add-MimirToUserPath -Directory $InstallDir
        Write-Host "Installed Mimir from local binary to $installed"
        return
    }

    $resolvedVersion = if ($Version) { Normalize-MimirVersion -Value $Version } else { Get-LatestMimirVersion -Repo $ReleaseRepo }
    $installedVersion = Get-InstalledMimirVersion -Path $installPath
    if ($installedVersion -eq $resolvedVersion) {
        Write-Host "Mimir $resolvedVersion is already installed."
        return
    }

    $releaseTag = "v$resolvedVersion"
    $baseUrl = "https://github.com/$ReleaseRepo/releases/download/$releaseTag"
    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ("mimir-install-" + [Guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Force -Path $tempDir | Out-Null

    try {
        $archivePath = Join-Path $tempDir $ArchiveName
        $checksumsPath = Join-Path $tempDir "SHA256SUMS"
        $extractDir = Join-Path $tempDir "extract"

        Write-Host "Installing Mimir $resolvedVersion for $Target"
        Invoke-MimirDownload -Uri "$baseUrl/$ArchiveName" -OutFile $archivePath
        Invoke-MimirDownload -Uri "$baseUrl/SHA256SUMS" -OutFile $checksumsPath
        Assert-Checksum -FilePath $archivePath -ChecksumsPath $checksumsPath

        New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractDir -Force

        $mimirExe = Get-ChildItem -LiteralPath $extractDir -Recurse -Filter $BinaryName -File | Select-Object -First 1
        if (-not $mimirExe) {
            throw "$ArchiveName did not contain $BinaryName."
        }

        $installed = Install-MimirBinary -SourcePath $mimirExe.FullName -DestinationDir $InstallDir
        Add-MimirToUserPath -Directory $InstallDir

        $installedOutput = & $installed --version
        Write-Host "Mimir $installedOutput installed to $installed"
        Write-Host "Run: mimir"
    }
    finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Install-Mimir
