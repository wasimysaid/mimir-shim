#!/bin/sh
set -eu

MIMIR_RELEASE_REPO=${MIMIR_RELEASE_REPO:-wasimysaid/mimir-shim}
version=${MIMIR_VERSION:-}
binary_source=
no_modify_path=false

fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
require() { command -v "$1" >/dev/null 2>&1 || fail "'$1' is required"; }
usage() {
    cat <<'USAGE'
Mimir Installer
Usage: install.sh [--version VERSION] [--no-modify-path] [--binary PATH]

Installs Mimir and configure-mimir into ~/.agents/skills/configure-mimir.
MIMIR_INSTALL_DIR overrides the binary directory (default ~/.mimir/bin).
MIMIR_VERSION selects a release; --version takes precedence.
--binary installs only a local development executable, without downloading skills.

curl -fsSL https://mimir.kernelvm.xyz/install.sh | sh
curl -fsSL https://mimir.kernelvm.xyz/install.sh | sh -s -- --version 0.2.3
curl -fsSL https://mimir.kernelvm.xyz/install.sh | MIMIR_INSTALL_DIR=/usr/local/bin sh
USAGE
}
while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        -v|--version|-b|--binary)
            [ "$#" -ge 2 ] && [ -n "$2" ] || fail "$1 requires a value"
            case "$1" in -v|--version) version=$2 ;; *) binary_source=$2 ;; esac
            shift 2 ;;
        --no-modify-path) no_modify_path=true; shift ;;
        *) fail "unknown option '$1'" ;;
    esac
done

case "$(uname -s)" in
    Linux*) os=linux ;;
    Darwin*) os=darwin ;;
    MINGW*|MSYS*|CYGWIN*) os=windows ;;
    *) fail 'supported systems are Linux, macOS and Windows' ;;
esac
case "$(uname -m)" in
    x86_64|amd64) arch=x64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) fail 'unsupported CPU architecture' ;;
esac
if [ "$os" = darwin ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || true)" = 1 ]; then
    arch=arm64
fi
case "$os-$arch" in
    linux-x64|darwin-x64|darwin-arm64|windows-x64) target=$os-$arch ;;
    *) fail "no release asset for $os-$arch" ;;
esac

user_dir=${HOME:?HOME is required}
if [ "$os" = windows ]; then
    require cygpath
    user_dir=$(cygpath -u "${USERPROFILE:?USERPROFILE is required}")
fi
install_dir=${MIMIR_INSTALL_DIR:-${XDG_BIN_DIR:-$user_dir/.mimir/bin}}
# Colab's root-owned notebooks need a directory already on PATH.
if [ -z "${MIMIR_INSTALL_DIR:-}${XDG_BIN_DIR:-}" ] && [ -d /content ] && [ -w /usr/local/bin ] && [ "$(id -u)" = 0 ]; then
    install_dir=/usr/local/bin
fi
if [ "$os" = windows ]; then install_dir=$(cygpath -u "$install_dir"); fi
mkdir -p "$install_dir"
install_dir=$(CDPATH= cd -- "$install_dir" && pwd)
skill_dir=$user_dir/.agents/skills/configure-mimir
binary_name=mimir
extension=tar.gz
if [ "$os" = windows ]; then binary_name=mimir.exe; extension=zip; fi

configure_path() {
    if [ -n "${GITHUB_PATH:-}" ]; then
        action_path=$install_dir
        if [ "$os" = windows ]; then action_path=$(cygpath -w "$install_dir"); fi
        printf '%s\n' "$action_path" >> "$GITHUB_PATH"
    fi
    [ "$no_modify_path" = false ] || return 0
    # Double-quoted shell values must preserve literal $, backticks and quotes.
    quoted=$(printf '%s' "$install_dir" | sed 's/[\\"$`]/\\&/g')
    case "$(basename "${SHELL:-sh}")" in
        fish)
            set -- "${XDG_CONFIG_HOME:-$user_dir/.config}/fish/config.fish"
            path_line="fish_add_path -- \"$quoted\"" ;;
        zsh)
            set -- "${ZDOTDIR:-$user_dir}/.zshrc"
            path_line="case \":\$PATH:\" in *\":$quoted:\"*) ;; *) export PATH=\"$quoted:\$PATH\" ;; esac" ;;
        bash)
            login_profile=$user_dir/.profile
            if [ -f "$user_dir/.bash_profile" ]; then login_profile=$user_dir/.bash_profile; fi
            set -- "$user_dir/.bashrc" "$login_profile"
            path_line="case \":\$PATH:\" in *\":$quoted:\"*) ;; *) export PATH=\"$quoted:\$PATH\" ;; esac" ;;
        *)
            set -- "$user_dir/.profile"
            path_line="case \":\$PATH:\" in *\":$quoted:\"*) ;; *) export PATH=\"$quoted:\$PATH\" ;; esac" ;;
    esac
    for profile in "$@"; do
        if [ -f "$profile" ] && grep -Fxq "$path_line" "$profile"; then continue; fi
        mkdir -p "$(dirname "$profile")"
        if ! { printf '\n# Mimir\n%s\n' "$path_line" >> "$profile"; }; then
            printf 'Add Mimir to PATH manually: %s\n' "$path_line" >&2
        fi
    done
}

staging=$(mktemp -d "$install_dir/.mimir-install.XXXXXX")
trap 'rm -rf "$staging"' EXIT
trap 'exit 1' HUP INT TERM
if [ -n "$binary_source" ]; then
    [ -f "$binary_source" ] || fail "binary not found: $binary_source"
    cp "$binary_source" "$staging/$binary_name"
else
    require curl
    require tar
    if [ -z "$version" ]; then
        if ! release=$(curl -fsSL --retry 3 "https://api.github.com/repos/$MIMIR_RELEASE_REPO/releases/latest"); then
            fail 'could not resolve the latest release from GitHub'
        fi
        version=$(printf '%s\n' "$release" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n 1)
    else
        version=${version#v}
        http_code=$(curl -sI -o /dev/null -w '%{http_code}' --retry 3 "https://github.com/$MIMIR_RELEASE_REPO/releases/tag/v$version" || true)
        if [ "$http_code" = 404 ]; then
            fail "release v$version not found; available releases: https://github.com/$MIMIR_RELEASE_REPO/releases"
        fi
    fi
    version=${version#v}
    [ -n "$version" ] || fail 'could not resolve release version'
    filename=mimir-$target.$extension
    base_url=https://github.com/$MIMIR_RELEASE_REPO/releases/download/v$version
    printf 'Installing Mimir %s for %s\n' "$version" "$target"
    if ! curl -fL --retry 3 --progress-bar "$base_url/$filename" -o "$staging/$filename"; then
        fail "could not download $filename from release v$version"
    fi
    if ! curl -fsSL --retry 3 "$base_url/SHA256SUMS" -o "$staging/SHA256SUMS"; then
        fail "could not download SHA256SUMS from release v$version"
    fi
    awk -v file="$filename" '$2 == file { print }' "$staging/SHA256SUMS" > "$staging/selected.sha256"
    [ "$(wc -l < "$staging/selected.sha256" | tr -d ' ')" = 1 ] || fail 'missing or duplicate archive checksum'
    if command -v sha256sum >/dev/null 2>&1; then
        (cd "$staging" && sha256sum -c selected.sha256)
    elif command -v shasum >/dev/null 2>&1; then
        (cd "$staging" && shasum -a 256 -c selected.sha256)
    else
        fail 'sha256sum or shasum is required'
    fi
    if [ "$os" = windows ]; then
        if command -v unzip >/dev/null 2>&1; then
            unzip -q "$staging/$filename" -d "$staging"
        elif command -v powershell.exe >/dev/null 2>&1; then
            # Git Bash ships GNU tar, which cannot read zip archives.
            archive_win=$(cygpath -w "$staging/$filename" | sed "s/'/''/g")
            staging_win=$(cygpath -w "$staging" | sed "s/'/''/g")
            powershell.exe -NoProfile -NonInteractive -Command "Expand-Archive -LiteralPath '$archive_win' -DestinationPath '$staging_win' -Force" >/dev/null
        else
            tar -xf "$staging/$filename" -C "$staging"
        fi
    else
        tar -xzf "$staging/$filename" -C "$staging"
    fi
    [ -f "$staging/skills/configure-mimir/SKILL.md" ] || fail 'release archive is missing configure-mimir'
fi
chmod 755 "$staging/$binary_name"
actual=$("$staging/$binary_name" --version)
actual=${actual#mimir }; actual=${actual#v}
if [ -z "$binary_source" ] && [ "$actual" != "$version" ]; then fail "expected $version, archive contains $actual"; fi
# Rename a verified executable instead of truncating a running Unix executable.
mv -f "$staging/$binary_name" "$install_dir/$binary_name"
if [ -z "$binary_source" ]; then
    mkdir -p "$(dirname "$skill_dir")"
    rm -rf "$skill_dir"
    cp -R "$staging/skills/configure-mimir" "$skill_dir"
    printf 'Installed skill: %s\n' "$skill_dir"
fi
configure_path
printf 'Installed Mimir %s to %s/%s\n' "$actual" "$install_dir" "$binary_name"
printf 'Open a new terminal, or run: "%s/%s"\n' "$install_dir" "$binary_name"
