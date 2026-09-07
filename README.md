# Install Mimir

This repository publishes Mimir installers, binary releases, and the
`configure-mimir` skill. The Mimir source repository remains private.

Linux, macOS, or Windows Git Bash:

```sh
curl -fsSL https://mimir.kernelvm.xyz/install.sh | sh
```

Native Windows PowerShell (5.1 or 7):

```powershell
irm https://mimir.kernelvm.xyz/install.ps1 | iex
```

The installer checks the archive checksum, verifies that the executable runs,
and installs the complete `configure-mimir` skill to
`~/.agents/skills/configure-mimir`. Mimir discovers it globally, outside any
particular project. Updating replaces this supplied skill and its references;
other skills, settings, credentials, and plugins are untouched.

| Platform | Archive |
| --- | --- |
| Linux x64 (static musl) | `mimir-linux-x64.tar.gz` |
| Windows x64 | `mimir-windows-x64.zip` |
| macOS Intel | `mimir-darwin-x64.tar.gz` |
| macOS Apple Silicon | `mimir-darwin-arm64.tar.gz` |

The shell installer detects Rosetta and selects the native Apple Silicon build.
Linux ARM64 and Windows ARM64 are not published. Installation needs no Rust or
Node toolchain. The shell installer uses curl, tar and sha256sum or shasum;
Git Bash also supplies cygpath. PowerShell uses its built-in download and ZIP
commands. macOS binaries are not notarized.

## Options

```sh
# Pin a release.
curl -fsSL https://mimir.kernelvm.xyz/install.sh | sh -s -- --version 0.2.3
# Apply the environment setting to the installer, not just to curl.
curl -fsSL https://mimir.kernelvm.xyz/install.sh | MIMIR_INSTALL_DIR=/usr/local/bin sh
# Leave shell configuration unchanged.
curl -fsSL https://mimir.kernelvm.xyz/install.sh | sh -s -- --no-modify-path
```

```powershell
$env:MIMIR_VERSION = '0.2.3'
$env:MIMIR_INSTALL_DIR = "$env:USERPROFILE\.mimir\bin"
irm https://mimir.kernelvm.xyz/install.ps1 | iex
```

Binary location: `MIMIR_INSTALL_DIR`, then `XDG_BIN_DIR` (shell installer), then
`~/.mimir/bin`. Root-owned Google Colab notebooks default to `/usr/local/bin`.
The skill location is independent of `MIMIR_CODING_AGENT_DIR`, matching Mimir's
normal global skill discovery. Git Bash and PowerShell use the native Windows
user home. Open a new terminal after installation for persistent PATH changes.

Rerun the installer to upgrade or repair the same version, including missing skill
files. Close a running Windows Mimir before replacing its executable. For local
development, `install.sh --binary PATH` or `install.ps1 -Binary PATH` installs
only that executable and performs no downloads.

## Releases

Run the `Release Mimir` workflow with a version matching the source and an exact
source ref. It resolves the ref once, builds all four native archives with their
matching skill, and publishes a prerelease candidate. Native runners execute the
real public installers before the workflow marks the release latest. A failed
installation leaves the candidate as a prerelease for diagnosis; published assets
are not overwritten.

`MIMIR_SOURCE_SSH_KEY` is a read-only deploy key for the private Mimir source
checkout. Release assets contain binaries and skill documentation, never source
archives, credentials, sessions, or integration traces. Detailed plugin integration
tests run separately in the private integration CI repository.

The install domain redirects `/install.sh` and `/install.ps1` to the corresponding
files on this repository's `main` branch. Archive downloads use GitHub Releases.
