#!/usr/bin/env bash
set -euo pipefail

APP="mimir"
MIMIR_RELEASE_REPO="${MIMIR_RELEASE_REPO:-wasimysaid/mimir-shim}"
INSTALL_DIR="${MIMIR_INSTALL_DIR:-${XDG_BIN_DIR:-$HOME/.mimir/bin}}"
REQUESTED_VERSION="${VERSION:-}"
NO_MODIFY_PATH=false
BINARY_PATH=""

RED='\033[0;31m'
MUTED='\033[0;2m'
NC='\033[0m'

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

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -v|--version)
            if [[ -z "${2:-}" ]]; then
                echo -e "${RED}Error: --version requires a value${NC}" >&2
                exit 1
            fi
            REQUESTED_VERSION="$2"
            shift 2
            ;;
        -b|--binary)
            if [[ -z "${2:-}" ]]; then
                echo -e "${RED}Error: --binary requires a path${NC}" >&2
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
            echo -e "${RED}Error: unknown option '$1'${NC}" >&2
            usage >&2
            exit 1
            ;;
    esac
done

require_command() {
    local command="$1"
    if ! command -v "$command" >/dev/null 2>&1; then
        echo -e "${RED}Error: '$command' is required but was not found${NC}" >&2
        exit 1
    fi
}

normalize_version() {
    local value="$1"
    value="${value#${APP} }"
    value="${value#v}"
    printf '%s' "$value"
}

detect_platform() {
    local raw_os os arch
    raw_os="$(uname -s)"
    case "$raw_os" in
        Darwin*) os="darwin" ;;
        Linux*) os="linux" ;;
        MINGW*|MSYS*|CYGWIN*) os="windows" ;;
        *)
            echo -e "${RED}Unsupported OS: $raw_os${NC}" >&2
            exit 1
            ;;
    esac

    arch="$(uname -m)"
    case "$arch" in
        x86_64|amd64) arch="x64" ;;
        aarch64|arm64) arch="arm64" ;;
        *)
            echo -e "${RED}Unsupported architecture: $arch${NC}" >&2
            exit 1
            ;;
    esac


    case "$os-$arch" in
        linux-x64|windows-x64)
            printf '%s-%s' "$os" "$arch"
            ;;
        *)
            echo -e "${RED}Only Linux x64 and Windows x64 release assets are published. Detected: $os/$arch${NC}" >&2
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
    local tag
    tag="$(curl -fsSL "https://api.github.com/repos/${MIMIR_RELEASE_REPO}/releases/latest" | sed -n 's/.*"tag_name": *"v\{0,1\}\([^"]*\)".*/\1/p' | head -n 1)"
    if [[ -z "$tag" ]]; then
        echo -e "${RED}Failed to resolve latest Mimir release from ${MIMIR_RELEASE_REPO}${NC}" >&2
        exit 1
    fi
    printf '%s' "$tag"
}

installed_version() {
    local binary_name path output
    binary_name="$1"

    for path in "$INSTALL_DIR/$binary_name" "$(command -v "$APP" 2>/dev/null || true)"; do
        if [[ -n "$path" && -x "$path" ]]; then
            output="$($path --version 2>/dev/null || true)"
            if [[ -n "$output" ]]; then
                normalize_version "$output"
                return 0
            fi
        fi
    done

    return 1
}

verify_checksum() {
    local checksums="$1"
    local filename="$2"
    local line_file="$3"

    grep "  ${filename}$" "$checksums" > "$line_file" || {
        echo -e "${RED}Checksum for ${filename} is missing from SHA256SUMS${NC}" >&2
        exit 1
    }

    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum -c "$line_file"
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 -c "$line_file"
    else
        echo -e "${RED}Error: sha256sum or shasum is required for checksum verification${NC}" >&2
        exit 1
    fi
}

extract_archive() {
    local archive="$1"
    local target="$2"
    local destination="$3"

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
    local source_binary="$1"
    local binary_name="$2"

    mkdir -p "$INSTALL_DIR"
    cp "$source_binary" "$INSTALL_DIR/$binary_name"
    chmod 755 "$INSTALL_DIR/$binary_name"
}

add_to_path() {
    local config_file="$1"
    local command="$2"

    if grep -Fxq "$command" "$config_file"; then
        echo -e "${MUTED}PATH entry already exists in ${config_file}${NC}"
    elif [[ -w "$config_file" ]]; then
        {
            echo ""
            echo "# Mimir"
            echo "$command"
        } >> "$config_file"
        echo "Added Mimir to PATH in $config_file"
    else
        echo "Manually add Mimir to PATH: $command"
    fi
}

configure_path() {
    if [[ "$NO_MODIFY_PATH" == "true" ]]; then
        return 0
    fi

    if [[ ":$PATH:" == *":$INSTALL_DIR:"* ]]; then
        return 0
    fi

    local current_shell config_files config_file xdg_config_home
    xdg_config_home="${XDG_CONFIG_HOME:-$HOME/.config}"
    current_shell="$(basename "${SHELL:-sh}")"

    case "$current_shell" in
        fish) config_files="$HOME/.config/fish/config.fish" ;;
        zsh) config_files="${ZDOTDIR:-$HOME}/.zshrc ${ZDOTDIR:-$HOME}/.zshenv $xdg_config_home/zsh/.zshrc $xdg_config_home/zsh/.zshenv" ;;
        bash) config_files="$HOME/.bashrc $HOME/.bash_profile $HOME/.profile $xdg_config_home/bash/.bashrc $xdg_config_home/bash/.bash_profile" ;;
        ash|sh) config_files="$HOME/.ashrc $HOME/.profile /etc/profile" ;;
        *) config_files="$HOME/.bashrc $HOME/.bash_profile $HOME/.profile" ;;
    esac

    config_file=""
    for file in $config_files; do
        if [[ -f "$file" ]]; then
            config_file="$file"
            break
        fi
    done

    if [[ -z "$config_file" ]]; then
        echo "No shell config file found. Add Mimir to PATH manually:"
        echo "  export PATH=$INSTALL_DIR:\$PATH"
        return 0
    fi

    case "$current_shell" in
        fish) add_to_path "$config_file" "fish_add_path $INSTALL_DIR" ;;
        *) add_to_path "$config_file" "export PATH=$INSTALL_DIR:\$PATH" ;;
    esac
}

main() {
    local target archive_ext binary_name version release_tag filename base_url tmp_dir archive_path checksums_path found_binary current_version

    target="$(detect_platform)"
    archive_ext="$(archive_ext_for_target "$target")"
    binary_name="$(binary_name_for_target "$target")"

    if [[ -n "$BINARY_PATH" ]]; then
        if [[ ! -f "$BINARY_PATH" ]]; then
            echo -e "${RED}Error: binary not found at ${BINARY_PATH}${NC}" >&2
            exit 1
        fi
        install_binary "$BINARY_PATH" "$binary_name"
        configure_path
        echo "Installed Mimir from local binary to $INSTALL_DIR/$binary_name"
        return 0
    fi

    require_command curl
    version="${REQUESTED_VERSION:-$(latest_version)}"
    version="$(normalize_version "$version")"
    release_tag="v${version}"
    filename="${APP}-${target}${archive_ext}"
    base_url="https://github.com/${MIMIR_RELEASE_REPO}/releases/download/${release_tag}"

    if current_version="$(installed_version "$binary_name")" && [[ "$current_version" == "$version" ]]; then
        echo "Mimir $version is already installed"
        return 0
    fi

    tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mimir-install.XXXXXX")"
    trap 'rm -rf "$tmp_dir"' EXIT

    archive_path="$tmp_dir/$filename"
    checksums_path="$tmp_dir/SHA256SUMS"

    echo -e "${MUTED}Installing Mimir ${version} for ${target}${NC}"
    curl -fL --progress-bar -o "$archive_path" "$base_url/$filename"
    curl -fsSL -o "$checksums_path" "$base_url/SHA256SUMS"

    (cd "$tmp_dir" && verify_checksum "$checksums_path" "$filename" "$tmp_dir/$filename.sha256")

    mkdir -p "$tmp_dir/extract"
    extract_archive "$archive_path" "$target" "$tmp_dir/extract"

    found_binary="$(find "$tmp_dir/extract" -type f \( -name "$APP" -o -name "${APP}.exe" \) -print -quit)"
    if [[ -z "$found_binary" ]]; then
        echo -e "${RED}Archive ${filename} did not contain a Mimir binary${NC}" >&2
        exit 1
    fi

    install_binary "$found_binary" "$binary_name"
    configure_path

    if [[ -n "${GITHUB_ACTIONS:-}" && "${GITHUB_ACTIONS}" == "true" && -n "${GITHUB_PATH:-}" ]]; then
        echo "$INSTALL_DIR" >> "$GITHUB_PATH"
        echo "Added $INSTALL_DIR to GITHUB_PATH"
    fi

    echo "Mimir $version installed to $INSTALL_DIR/$binary_name"
    echo "Run: mimir"
}

main "$@"
