#!/bin/bash
set -euo pipefail

project="$(cd "$(dirname "$0")" && pwd)"
archives="${1:-}"
mkdir -p "$project/.tmp"
stage="$(mktemp -d "$project/.tmp/amap-install.XXXXXX")"
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/sdk"

fetch() {
    local name="$1" artifact="$2" digest="$3"
    local archive="$stage/$name.zip" actual
    if [[ -n "$archives" ]]; then
        cp "$archives/$name.zip" "$archive"
    else
        curl -fsSL --retry 3 --connect-timeout 15 --max-time 300 \
            "https://a.amap.com/lbs/static/zip/$artifact" -o "$archive"
    fi
    actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
    [[ "$actual" == "$digest" ]] || { echo "高德 SDK 校验失败：$name" >&2; exit 1; }
    unzip -qo "$archive" -d "$stage/sdk"
}

fetch foundation AMap_iOS_Foundation_NO_IDFA_Lib_V1.9.5.zip 6800a9d47225e3be49fcc2efec7f343acd529fa10a4a05945d04ca3638dd5835
fetch search AMap_iOS_Search_Lib_V9.8.1.zip d11e0b418319c74abf5228611f678b58130eac791e267d6d6e3e7ec9f41b2007
fetch nav AMap_iOS_Navi_Lib_V11.3.300.zip 819f734826cf8b37686cd594919fa7abf5ca7a457d86eb0a532b22253c90db97

cat > "$stage/sdk/Enabled.xcconfig" <<'CONFIG'
KNIGHT_AMAP_SDK_ENABLED[sdk=iphoneos*] = YES
GCC_PREPROCESSOR_DEFINITIONS[sdk=iphoneos*] = $(inherited) KNIGHT_AMAP_SDK=1
FRAMEWORK_SEARCH_PATHS[sdk=iphoneos*] = $(inherited) "$(SRCROOT)/.tmp/AMapSDK"
OTHER_LDFLAGS[sdk=iphoneos*] = $(inherited) -ObjC -framework AMapFoundationKit -framework AMapNaviKit -framework AMapSearchKit -framework CoreLocation -framework CoreMotion -framework SystemConfiguration -framework CoreTelephony -framework GLKit -framework CallKit -lc++ -lz -liconv
CONFIG

dest="$project/.tmp/AMapSDK"
if [[ -e "$dest" ]]; then mv "$dest" "$stage/previous"; fi
if ! mv "$stage/sdk" "$dest"; then
    if [[ -e "$stage/previous" ]]; then mv "$stage/previous" "$dest"; fi
    exit 1
fi
echo '高德骑行导航 SDK 已配置'
