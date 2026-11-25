#!/bin/sh
set -eu

sdk_dir="$SRCROOT/.tmp/AMapSDK"
resources="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"

for bundle in AMap.bundle AMapNavi.bundle AMapSearch.bundle; do
    case "$bundle" in
        AMap.bundle|AMapNavi.bundle) framework=AMapNaviKit ;;
        AMapSearch.bundle) framework=AMapSearchKit ;;
    esac
    /usr/bin/ditto "$sdk_dir/$framework.framework/$bundle" "$resources/$bundle"
done
