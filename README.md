# Mimir public release shim

This directory is the template for the public Mimir shim repository. The private
source stays in `wasimysaid/mimir`; this repository only hosts the installer,
release workflow, checksums, and binary release assets.

## Install

```sh
curl -fsSL https://<your-cloudflare-domain>/install.sh | sh
```

Pin a release:

```sh
curl -fsSL https://<your-cloudflare-domain>/install.sh | sh -s -- --version 0.1.9
```

Install into a custom directory:

```sh
MIMIR_INSTALL_DIR=/usr/local/bin curl -fsSL https://<your-cloudflare-domain>/install.sh | sh
```

## Supported platforms

- Linux x64: `mimir-linux-x64.tar.gz`
- Linux arm64: `mimir-linux-arm64.tar.gz`
- macOS x64: `mimir-darwin-x64.tar.gz`
- macOS arm64: `mimir-darwin-arm64.tar.gz`
- Windows x64 from Git Bash/MSYS/Cygwin: `mimir-windows-x64.zip`

## Cloudflare redirect

Configure Cloudflare for the install domain/path, for example:

- Source: `https://<your-cloudflare-domain>/install.sh`
- Target: `https://raw.githubusercontent.com/wasimysaid/mimir-shim/main/install.sh`
- Status: `302` while testing, `301` after stable

If the public shim repo is not `wasimysaid/mimir-shim`, update `MIMIR_RELEASE_REPO` in
`install.sh` before publishing.

## Required GitHub secret

`MIMIR_SOURCE_TOKEN` must be a read-only fine-grained token or deploy credential
that can checkout the private `wasimysaid/mimir` repository. Do not grant write
access to the private source repository.

## Release process

1. Tag or choose a source ref in the private `wasimysaid/mimir` repo.
2. Run the public shim repo's `Release Mimir` workflow manually.
3. Provide `version` without or with `v`, for example `0.1.9`.
4. Optionally provide `source_ref`; otherwise the workflow builds `v<version>`.
5. The workflow builds the matrix, smoke-tests `mimir --version`, creates
   `SHA256SUMS`, stages a draft GitHub Release, validates the asset set, and
   publishes the release.

The public release must contain only binary archives, `SHA256SUMS`, and release
notes. Never upload source archives from the private repository.
