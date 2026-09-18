<# Install Mimir and its configure-mimir skill on native Windows. #>
[CmdletBinding()]
param(
    [string]$Version = $env:MIMIR_VERSION,
    [string]$InstallDir = $(if ($env:MIMIR_INSTALL_DIR) { $env:MIMIR_INSTALL_DIR } else { Join-Path $env:USERPROFILE '.mimir\bin' }),
    [string]$ReleaseRepo = $(if ($env:MIMIR_RELEASE_REPO) { $env:MIMIR_RELEASE_REPO } else { 'wasimysaid/mimir-shim' }),
    [string]$Binary = $env:MIMIR_BINARY,
    [switch]$NoModifyPath = ($env:MIMIR_NO_MODIFY_PATH -in @('1', 'true', 'yes')),
    [switch]$Help
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Normalize-Version([string]$Value) {
    return ($Value.Trim() -replace '^mimir ', '' -replace '^v', '')
}

function Download([string]$Uri, [string]$Destination) {
    try {
        Invoke-WebRequest -Uri $Uri -OutFile $Destination -UseBasicParsing -Headers @{ 'User-Agent' = 'mimir-installer' }
    }
    catch {
        throw "Could not download $Uri. $($_.Exception.Message)"
    }
}

function Add-InstallPath([string]$Directory) {
    if ($env:GITHUB_PATH) { Add-Content -LiteralPath $env:GITHUB_PATH -Value $Directory -Encoding utf8 }
    if ($NoModifyPath) { return }
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $entries = @($userPath -split ';' | Where-Object { $_ })
    $present = @($entries | Where-Object {
        [Environment]::ExpandEnvironmentVariables($_).TrimEnd('\') -eq $Directory.TrimEnd('\')
    }).Count -gt 0
    if (-not $present) {
        [Environment]::SetEnvironmentVariable('Path', (($entries + $Directory) -join ';'), 'User')
    }
    if (-not (($env:Path -split ';') | Where-Object { $_.TrimEnd('\') -eq $Directory.TrimEnd('\') })) {
        $env:Path = "$Directory;$env:Path"
    }
}

function Install-Mimir {
    if ($Help) {
        @'
Mimir Windows Installer
irm https://mimir.kernelvm.xyz/install.ps1 | iex

Options: -Version VERSION -InstallDir PATH -NoModifyPath -Binary PATH
For irm | iex, use MIMIR_VERSION, MIMIR_INSTALL_DIR, MIMIR_NO_MODIFY_PATH.
Installs configure-mimir into %USERPROFILE%\.agents\skills\configure-mimir.
-Binary installs only a local development executable without downloading skills.
'@
        return
    }
    if ($env:OS -ne 'Windows_NT') { throw 'Use install.sh on Linux/macOS.' }
    $architecture = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    if ($architecture -notin @('AMD64', 'x86_64')) { throw "No Windows release for $architecture." }

    $destination = [IO.Path]::GetFullPath($InstallDir)
    New-Item -ItemType Directory -Force -Path $destination | Out-Null
    $staging = Join-Path $destination ('.mimir-install-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $staging | Out-Null
    try {
        $stagedBinary = Join-Path $staging 'mimir.exe'
        if ($Binary) {
            Copy-Item -LiteralPath $Binary -Destination $stagedBinary
        }
        else {
            $resolved = $Version
            if (-not $resolved) {
                try {
                    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$ReleaseRepo/releases/latest" -Headers @{ 'User-Agent' = 'mimir-installer' }
                    $resolved = [string]$release.tag_name
                }
                catch {
                    throw "Could not resolve the latest release from GitHub. $($_.Exception.Message)"
                }
            }
            $resolved = Normalize-Version $resolved
            if (-not $resolved) { throw 'Could not resolve release version.' }
            $tagStatusCode = 0
            try {
                $tagResponse = Invoke-WebRequest -Uri "https://github.com/$ReleaseRepo/releases/tag/v$resolved" -Method Head -UseBasicParsing -Headers @{ 'User-Agent' = 'mimir-installer' }
                $tagStatusCode = [int]$tagResponse.StatusCode
            }
            catch {
                if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
                    $tagStatusCode = [int]$_.Exception.Response.StatusCode
                }
            }
            if ($tagStatusCode -eq 404) {
                throw "Release v$resolved not found. Available releases: https://github.com/$ReleaseRepo/releases"
            }
            $baseUrl = "https://github.com/$ReleaseRepo/releases/download/v$resolved"
            $archive = Join-Path $staging 'mimir-windows-x64.zip'
            $checksums = Join-Path $staging 'SHA256SUMS'
            Write-Host "Installing Mimir $resolved for Windows x64"
            Download "$baseUrl/mimir-windows-x64.zip" $archive
            Download "$baseUrl/SHA256SUMS" $checksums
            $lines = @(Get-Content -LiteralPath $checksums | Where-Object { $_ -match '^([a-fA-F0-9]{64})\s+\*?mimir-windows-x64\.zip$' })
            if ($lines.Count -ne 1) { throw 'Missing or duplicate archive checksum.' }
            $expected = ($lines[0] -split '\s+')[0]
            if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $expected) { throw 'Archive checksum mismatch.' }
            Expand-Archive -LiteralPath $archive -DestinationPath $staging -Force
            if (-not (Test-Path -LiteralPath (Join-Path $staging 'skills\configure-mimir\SKILL.md') -PathType Leaf)) {
                throw 'Release archive is missing configure-mimir.'
            }
        }
        $actual = & $stagedBinary --version
        if ($LASTEXITCODE -ne 0) { throw 'Downloaded executable could not run.' }
        $actual = Normalize-Version ([string]$actual)
        if (-not $Binary -and $actual -ne $resolved) { throw "Expected $resolved, archive contains $actual." }
        # Windows refuses to replace an in-use executable; report that failure.
        Move-Item -LiteralPath $stagedBinary -Destination (Join-Path $destination 'mimir.exe') -Force
        if (-not $Binary) {
            $skills = Join-Path $env:USERPROFILE '.agents\skills'
            $skill = Join-Path $skills 'configure-mimir'
            New-Item -ItemType Directory -Force -Path $skills | Out-Null
            if (Test-Path -LiteralPath $skill) { Remove-Item -LiteralPath $skill -Recurse -Force }
            Copy-Item -LiteralPath (Join-Path $staging 'skills\configure-mimir') -Destination $skill -Recurse
            Write-Host "Installed skill: $skill"
        }
        Add-InstallPath $destination
        Write-Host "Installed Mimir $actual to $destination\mimir.exe"
        Write-Host 'Run: mimir. Open a new terminal to use it elsewhere.'
    }
    finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Install-Mimir
