#!/usr/bin/env bash
set -euo pipefail

SOURCE_DIR="${SOURCE_DIR:-.}"
OUT_DIR="${OUT_DIR:-release-assets}"
PLATFORM="${MIMIR_PLATFORM:-}"
VERSION="${VERSION:-}"
CARGO_FLAGS="${CARGO_FLAGS:---locked}"

usage() {
    cat <<EOF
Build and package a Mimir release asset.

Usage: scripts/build-release.sh --platform <platform> [options]

Options:
    --source-dir <path>   Private cersei checkout. Default: SOURCE_DIR or .
    --out <path>          Output directory. Default: OUT_DIR or release-assets
    --platform <name>     linux-x64, windows-x64
    --version <version>   Expected mimir --version output, with or without v
    --no-locked           Do not pass --locked to cargo
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-dir)
            SOURCE_DIR="$2"
            shift 2
            ;;
        --out)
            OUT_DIR="$2"
            shift 2
            ;;
        --platform)
            PLATFORM="$2"
            shift 2
            ;;
        --version)
            VERSION="$2"
            shift 2
            ;;
        --no-locked)
            CARGO_FLAGS=""
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ -z "$PLATFORM" ]]; then
    echo "--platform is required" >&2
    usage >&2
    exit 1
fi

case "$PLATFORM" in
    linux-x64|windows-x64) ;;
    *)
        echo "Unsupported platform: $PLATFORM" >&2
        exit 1
        ;;
esac

normalize_version() {
    local value="$1"
    value="${value#mimir }"
    value="${value#v}"
    printf '%s' "$value"
}

SOURCE_DIR="$(cd "$SOURCE_DIR" && pwd)"
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"

cd "$SOURCE_DIR"

echo "==> Building Mimir for $PLATFORM"
cargo build -p mimir-cli --bin mimir --release $CARGO_FLAGS

binary="target/release/mimir"
archive_ext=".tar.gz"
if [[ "$PLATFORM" == windows-* ]]; then
    binary="target/release/mimir.exe"
    archive_ext=".zip"
fi

if [[ ! -f "$binary" ]]; then
    echo "Built binary not found: $binary" >&2
    exit 1
fi

actual_version="$("$binary" --version)"
actual_version="$(normalize_version "$actual_version")"
if [[ -n "$VERSION" ]]; then
    expected_version="$(normalize_version "$VERSION")"
    if [[ "$actual_version" != "$expected_version" ]]; then
        echo "Version mismatch: expected $expected_version, got $actual_version" >&2
        exit 1
    fi
fi

to_powershell_path() {
    local path="$1"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -w "$path"
    else
        printf '%s' "$path"
    fi
}

escape_powershell_single_quoted() {
    printf '%s' "$1" | sed "s/'/''/g"
}


tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mimir-package.XXXXXX")"
trap 'rm -rf "$tmp_dir"' EXIT

asset="mimir-${PLATFORM}${archive_ext}"
stage_dir="$tmp_dir/mimir"
mkdir -p "$stage_dir"

if [[ "$PLATFORM" == windows-* ]]; then
    cp "$binary" "$stage_dir/mimir.exe"
    if command -v zip >/dev/null 2>&1; then
        (cd "$stage_dir" && zip -q -r "$OUT_DIR/$asset" .)
    elif command -v powershell.exe >/dev/null 2>&1; then
        stage_dir_ps="$(escape_powershell_single_quoted "$(to_powershell_path "$stage_dir")")"
        asset_ps="$(escape_powershell_single_quoted "$(to_powershell_path "$OUT_DIR/$asset")")"
        powershell.exe -NoProfile -NonInteractive -Command \
            "\$ErrorActionPreference = 'Stop'; Compress-Archive -Path (Join-Path '$stage_dir_ps' '*') -DestinationPath '$asset_ps' -Force"
    elif command -v pwsh >/dev/null 2>&1; then
        stage_dir_ps="$(escape_powershell_single_quoted "$(to_powershell_path "$stage_dir")")"
        asset_ps="$(escape_powershell_single_quoted "$(to_powershell_path "$OUT_DIR/$asset")")"
        pwsh -NoProfile -NonInteractive -Command \
            "\$ErrorActionPreference = 'Stop'; Compress-Archive -Path (Join-Path '$stage_dir_ps' '*') -DestinationPath '$asset_ps' -Force"
    else
        echo "zip, powershell.exe, or pwsh is required to create Windows archives" >&2
        exit 1
    fi
else
    cp "$binary" "$stage_dir/mimir"
    chmod 755 "$stage_dir/mimir"
    (cd "$stage_dir" && tar -czf "$OUT_DIR/$asset" mimir)
fi

if command -v sha256sum >/dev/null 2>&1; then
    (cd "$OUT_DIR" && sha256sum "$asset" > "$asset.sha256")
elif command -v shasum >/dev/null 2>&1; then
    (cd "$OUT_DIR" && shasum -a 256 "$asset" > "$asset.sha256")
else
    echo "sha256sum or shasum is required" >&2
    exit 1
fi

verify_dir="$tmp_dir/verify"
mkdir -p "$verify_dir"
if [[ "$PLATFORM" == windows-* ]]; then
    if command -v unzip >/dev/null 2>&1; then
        unzip -q "$OUT_DIR/$asset" -d "$verify_dir"
    elif command -v powershell.exe >/dev/null 2>&1; then
        asset_ps="$(escape_powershell_single_quoted "$(to_powershell_path "$OUT_DIR/$asset")")"
        verify_dir_ps="$(escape_powershell_single_quoted "$(to_powershell_path "$verify_dir")")"
        powershell.exe -NoProfile -NonInteractive -Command \
            "\$ErrorActionPreference = 'Stop'; Expand-Archive -Path '$asset_ps' -DestinationPath '$verify_dir_ps' -Force"
    elif command -v pwsh >/dev/null 2>&1; then
        asset_ps="$(escape_powershell_single_quoted "$(to_powershell_path "$OUT_DIR/$asset")")"
        verify_dir_ps="$(escape_powershell_single_quoted "$(to_powershell_path "$verify_dir")")"
        pwsh -NoProfile -NonInteractive -Command \
            "\$ErrorActionPreference = 'Stop'; Expand-Archive -Path '$asset_ps' -DestinationPath '$verify_dir_ps' -Force"
    else
        echo "unzip, powershell.exe, or pwsh is required to verify Windows archives" >&2
        exit 1
    fi
else
    tar -xzf "$OUT_DIR/$asset" -C "$verify_dir"
fi

verified_binary="$(find "$verify_dir" -type f \( -name mimir -o -name mimir.exe \) -print -quit)"
if [[ -z "$verified_binary" ]]; then
    echo "Archive verification failed: Mimir binary missing from $asset" >&2
    exit 1
fi
chmod 755 "$verified_binary"
verified_version="$("$verified_binary" --version)"
verified_version="$(normalize_version "$verified_version")"
if [[ "$verified_version" != "$actual_version" ]]; then
    echo "Archive verification failed: expected $actual_version, got $verified_version" >&2
    exit 1
fi

echo "==> Built $OUT_DIR/$asset"
echo "==> Version $actual_version"
