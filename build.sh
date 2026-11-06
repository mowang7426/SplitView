#!/bin/sh
set -eu
: "${THEOS:?Set THEOS to a RootHide Theos checkout}"
make clean
make package THEOS_PACKAGE_SCHEME=roothide FINALPACKAGE=1
# RootHide's staging patcher changes Mach-O load commands after Theos signing.
# Sign the final staged bytes, not the intermediate object; never install.
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
for deb in packages/*.deb; do
    dpkg-deb -R "$deb" "$stage"
    for binary in "$stage/Library/MobileSubstrate/DynamicLibraries/ZengNiuSplitView.dylib" "$stage/Library/PreferenceBundles/ZNSPreferences.bundle/ZNSPreferences"; do
        codesign --force --sign - --timestamp=none "$binary"
        codesign --verify --strict --verbose=4 "$binary"
    done
    dpkg-deb --root-owner-group -Zxz -b "$stage" "$deb"
done
