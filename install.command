#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIRECTORY="/Applications"
OPEN_AFTER_INSTALL=true

while (( $# > 0 )); do
    case "$1" in
        --destination)
            if (( $# < 2 )); then
                echo '请在 --destination 后指定安装目录。' >&2
                exit 1
            fi
            INSTALL_DIRECTORY="$2"
            shift 2
            ;;
        --no-open)
            OPEN_AFTER_INSTALL=false
            shift
            ;;
        *)
            echo "未知参数 $1" >&2
            exit 1
            ;;
    esac
done

if [[ "$(uname -s)" != Darwin ]]; then
    echo '影桥需要 macOS 14 或更高版本。' >&2
    exit 1
fi
MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if (( MACOS_MAJOR < 14 )); then
    echo '影桥需要 macOS 14 或更高版本。' >&2
    exit 1
fi
if [[ "$INSTALL_DIRECTORY" == /Applications && ! -w /Applications ]]; then
    INSTALL_DIRECTORY="$HOME/Applications"
fi

ARCHIVE="$PROJECT_ROOT/Distribution/Yingqiao-macOS-universal.zip"
if [[ ! -f "$ARCHIVE" ]]; then
    echo '缺少安装包，请完整下载或拉取 GitHub 仓库。' >&2
    exit 1
fi
(
    cd "$PROJECT_ROOT/Distribution"
    shasum -a 256 -c SHA256SUMS
)

mkdir -p "$INSTALL_DIRECTORY"
INSTALL_DIRECTORY="$(cd "$INSTALL_DIRECTORY" && pwd)"
TARGET_APP="$INSTALL_DIRECTORY/影桥.app"
if /bin/ps -ax -o comm= | /usr/bin/grep -Fqx "$TARGET_APP/Contents/MacOS/PhoneMediaImporter"; then
    echo '请先退出正在运行的影桥，再重新运行安装。' >&2
    exit 1
fi
INSTALL_STAGE="$(mktemp -d "$INSTALL_DIRECTORY/.yingqiao-install.XXXXXX")"
cleanup() {
    if [[ -e "$INSTALL_STAGE/previous.app" && ! -e "$TARGET_APP" ]]; then
        mv "$INSTALL_STAGE/previous.app" "$TARGET_APP"
    fi
    rm -rf "$INSTALL_STAGE"
}
trap cleanup EXIT

ditto -x -k "$ARCHIVE" "$INSTALL_STAGE"
STAGED_APP="$INSTALL_STAGE/影桥.app"
codesign --verify --deep --strict "$STAGED_APP"
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$STAGED_APP/Contents/Info.plist")" != com.gravity.phone-media-importer ]]; then
    echo '安装包的应用标识不匹配。' >&2
    exit 1
fi
if [[ -e "$TARGET_APP" || -L "$TARGET_APP" ]]; then
    mv "$TARGET_APP" "$INSTALL_STAGE/previous.app"
fi
mv "$STAGED_APP" "$TARGET_APP"
echo "影桥已安装到 $TARGET_APP"

if [[ "$OPEN_AFTER_INSTALL" == true ]]; then
    open "$TARGET_APP"
fi
