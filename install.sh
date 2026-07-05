#!/bin/sh
set -eu

APP="mimir"
MIMIR_RELEASE_REPO="${MIMIR_RELEASE_REPO:-wasimysaid/mimir-shim}"
REQUESTED_VERSION="${VERSION:-}"
NO_MODIFY_PATH=false
BINARY_PATH=""

RED='\033[0;31m'
MUTED='\033[0;2m'
NC='\033[0m'

print_error() {
    printf '%b\n' "${RED}$*${NC}" >&2
}

print_muted() {
    printf '%b\n' "${MUTED}$*${NC}"
}

default_install_dir() {
    if [ -n "${MIMIR_INSTALL_DIR:-}" ]; then
        printf '%s' "$MIMIR_INSTALL_DIR"
        return 0
    fi

    if [ -n "${XDG_BIN_DIR:-}" ]; then
        printf '%s' "$XDG_BIN_DIR"
        return 0
    fi

    # Google Colab starts users in /content but runs as root. Installing into
    # /usr/local/bin makes `mimir` immediately available in notebooks without
    # relying on a new login shell to source /root/.profile.
    if [ -d /content ] && [ -w /usr/local/bin ] && [ "$(id -u 2>/dev/null || printf '1')" = "0" ]; then
        printf '%s' "/usr/local/bin"
        return 0
    fi

    printf '%s/.mimir/bin' "${HOME:-/root}"
}

INSTALL_DIR="$(default_install_dir)"

usage() {
    cat <<EOF
Mimir Installer

Usage: install.sh [options]

Options:
    -h, --help              Display this help message
    -v, --version <version> Install a specific version, for example 0.1.10
    -b, --binary <path>     Install from a local binary instead of downloading
        --no-modify-path    Do not modify shell config files

Examples:
    curl -fsSL https://mimir.kernelvm.xyz/install.sh | sh
    curl -fsSL https://mimir.kernelvm.xyz/install.sh | sh -s -- --version 0.1.10
    ./install.sh --binary ./target/release/mimir
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -v|--version)
            if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
                print_error "Error: --version requires a value"
                exit 1
            fi
            REQUESTED_VERSION="$2"
            shift 2
            ;;
        -b|--binary)
            if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
                print_error "Error: --binary requires a path"
                exit 1
            fi
            BINARY_PATH="$2"
            shift 2
            ;;
        --no-modify-path)
            NO_MODIFY_PATH=true
            shift
            ;;
        *)
            print_error "Error: unknown option '$1'"
            usage >&2
            exit 1
            ;;
    esac
done

require_command() {
    required_command="$1"
    if ! command -v "$required_command" >/dev/null 2>&1; then
        print_error "Error: '$required_command' is required but was not found"
        exit 1
    fi
}

normalize_version() {
    version_value="$1"
    app_prefix="$APP "
    case "$version_value" in
        "$app_prefix"*) version_value=${version_value#"$app_prefix"} ;;
    esac
    case "$version_value" in
        v*) version_value=${version_value#v} ;;
    esac
    printf '%s' "$version_value"
}

detect_platform() {
    raw_os="$(uname -s)"
    case "$raw_os" in
        Darwin*) os="darwin" ;;
        Linux*) os="linux" ;;
        MINGW*|MSYS*|CYGWIN*) os="windows" ;;
        *)
            print_error "Unsupported OS: $raw_os"
            exit 1
            ;;
    esac

    raw_arch="$(uname -m)"
    case "$raw_arch" in
        x86_64|amd64) arch="x64" ;;
        aarch64|arm64) arch="arm64" ;;
        *)
            print_error "Unsupported architecture: $raw_arch"
            exit 1
            ;;
    esac

    case "$os-$arch" in
        linux-x64|windows-x64)
            printf '%s-%s' "$os" "$arch"
            ;;
        *)
            print_error "Only Linux x64 and Windows x64 release assets are published. Detected: $os/$arch"
            exit 1
            ;;
    esac
}

archive_ext_for_target() {
    case "$1" in
        windows-*) printf '.zip' ;;
        *) printf '.tar.gz' ;;
    esac
}

binary_name_for_target() {
    case "$1" in
        windows-*) printf '%s.exe' "$APP" ;;
        *) printf '%s' "$APP" ;;
    esac
}

latest_version() {
    require_command curl
    tag="$(curl -fsSL "https://api.github.com/repos/${MIMIR_RELEASE_REPO}/releases/latest" | sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' | head -n 1)"
    if [ -z "$tag" ]; then
        print_error "Failed to resolve latest Mimir release from ${MIMIR_RELEASE_REPO}"
        exit 1
    fi
    printf '%s' "$tag"
}

version_from_path() {
    candidate_path="$1"
    if [ -n "$candidate_path" ] && [ -x "$candidate_path" ]; then
        version_output="$("$candidate_path" --version 2>/dev/null || true)"
        if [ -n "$version_output" ]; then
            normalize_version "$version_output"
            return 0
        fi
    fi
    return 1
}

installed_version() {
    binary_name="$1"
    if version_from_path "$INSTALL_DIR/$binary_name"; then
        return 0
    fi

    path_from_env="$(command -v "$APP" 2>/dev/null || true)"
    if [ -n "$path_from_env" ] && [ "$path_from_env" != "$INSTALL_DIR/$binary_name" ]; then
        version_from_path "$path_from_env"
        return $?
    fi

    return 1
}

verify_checksum() {
    checksums="$1"
    filename="$2"
    line_file="$3"

    grep "  ${filename}\$" "$checksums" > "$line_file" || {
        print_error "Checksum for ${filename} is missing from SHA256SUMS"
        exit 1
    }

    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum -c "$line_file"
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 -c "$line_file"
    else
        print_error "Error: sha256sum or shasum is required for checksum verification"
        exit 1
    fi
}

extract_archive() {
    archive="$1"
    target="$2"
    destination="$3"

    case "$target" in
        windows-*)
            require_command unzip
            unzip -q "$archive" -d "$destination"
            ;;
        *)
            require_command tar
            tar -xzf "$archive" -C "$destination"
            ;;
    esac
}

install_binary() {
    source_binary="$1"
    binary_name="$2"

    mkdir -p "$INSTALL_DIR"
    cp "$source_binary" "$INSTALL_DIR/$binary_name"
    chmod 755 "$INSTALL_DIR/$binary_name"
}

add_to_path() {
    config_file="$1"
    path_command="$2"

    if grep -Fxq "$path_command" "$config_file"; then
        print_muted "PATH entry already exists in ${config_file}"
    elif [ -w "$config_file" ]; then
        {
            printf '\n'
            printf '%s\n' "# Mimir"
            printf '%s\n' "$path_command"
        } >> "$config_file"
        printf '%s\n' "Added Mimir to PATH in $config_file"
    else
        printf '%s\n' "Manually add Mimir to PATH: $path_command"
    fi
}

configure_path() {
    if [ "$NO_MODIFY_PATH" = "true" ]; then
        return 0
    fi

    case ":$PATH:" in
        *":$INSTALL_DIR:"*) return 0 ;;
    esac

    xdg_config_home="${XDG_CONFIG_HOME:-${HOME:-/root}/.config}"
    current_shell="$(basename "${SHELL:-sh}")"

    case "$current_shell" in
        fish) config_files="${HOME:-/root}/.config/fish/config.fish" ;;
        zsh) config_files="${ZDOTDIR:-${HOME:-/root}}/.zshrc ${ZDOTDIR:-${HOME:-/root}}/.zshenv $xdg_config_home/zsh/.zshrc $xdg_config_home/zsh/.zshenv" ;;
        bash) config_files="${HOME:-/root}/.bashrc ${HOME:-/root}/.bash_profile ${HOME:-/root}/.profile $xdg_config_home/bash/.bashrc $xdg_config_home/bash/.bash_profile" ;;
        ash|sh) config_files="${HOME:-/root}/.ashrc ${HOME:-/root}/.profile /etc/profile" ;;
        *) config_files="${HOME:-/root}/.bashrc ${HOME:-/root}/.bash_profile ${HOME:-/root}/.profile" ;;
    esac

    config_file=""
    for file in $config_files; do
        if [ -f "$file" ]; then
            config_file="$file"
            break
        fi
    done

    if [ -z "$config_file" ]; then
        printf '%s\n' "No shell config file found. Add Mimir to PATH manually:"
        printf '%s\n' "  export PATH=$INSTALL_DIR:\$PATH"
        return 0
    fi

    case "$current_shell" in
        fish) add_to_path "$config_file" "fish_add_path $INSTALL_DIR" ;;
        *) add_to_path "$config_file" "export PATH=$INSTALL_DIR:\$PATH" ;;
    esac
}

main() {
    target="$(detect_platform)"
    archive_ext="$(archive_ext_for_target "$target")"
    binary_name="$(binary_name_for_target "$target")"

    if [ -n "$BINARY_PATH" ]; then
        if [ ! -f "$BINARY_PATH" ]; then
            print_error "Error: binary not found at ${BINARY_PATH}"
            exit 1
        fi
        install_binary "$BINARY_PATH" "$binary_name"
        configure_path
        printf '%s\n' "Installed Mimir from local binary to $INSTALL_DIR/$binary_name"
        return 0
    fi

    require_command curl
    version="${REQUESTED_VERSION:-$(latest_version)}"
    version="$(normalize_version "$version")"
    release_tag="v${version}"
    filename="${APP}-${target}${archive_ext}"
    base_url="https://github.com/${MIMIR_RELEASE_REPO}/releases/download/${release_tag}"

    if current_version="$(installed_version "$binary_name")" && [ "$current_version" = "$version" ]; then
        printf '%s\n' "Mimir $version is already installed"
        return 0
    fi

    tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mimir-install.XXXXXX")"
    trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

    archive_path="$tmp_dir/$filename"
    checksums_path="$tmp_dir/SHA256SUMS"

    print_muted "Installing Mimir ${version} for ${target}"
    curl -fL --progress-bar -o "$archive_path" "$base_url/$filename"
    curl -fsSL -o "$checksums_path" "$base_url/SHA256SUMS"

    (cd "$tmp_dir" && verify_checksum "$checksums_path" "$filename" "$tmp_dir/$filename.sha256")

    mkdir -p "$tmp_dir/extract"
    extract_archive "$archive_path" "$target" "$tmp_dir/extract"

    found_binary="$(find "$tmp_dir/extract" -type f \( -name "$APP" -o -name "${APP}.exe" \) -print -quit)"
    if [ -z "$found_binary" ]; then
        print_error "Archive ${filename} did not contain a Mimir binary"
        exit 1
    fi

    install_binary "$found_binary" "$binary_name"
    configure_path

    if [ "${GITHUB_ACTIONS:-}" = "true" ] && [ -n "${GITHUB_PATH:-}" ]; then
        printf '%s\n' "$INSTALL_DIR" >> "$GITHUB_PATH"
        printf '%s\n' "Added $INSTALL_DIR to GITHUB_PATH"
    fi

    printf '%s\n' "Mimir $version installed to $INSTALL_DIR/$binary_name"
    printf '%s\n' "Run: mimir"
}

main "$@"
