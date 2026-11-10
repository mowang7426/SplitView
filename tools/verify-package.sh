#!/bin/sh
set -eu
mkdir -p build/extracted
for deb in packages/*.deb; do
  dpkg-deb -I "$deb"
  dpkg-deb -c "$deb"
  test "$(dpkg-deb -f "$deb" Architecture)" = iphoneos-arm64e
  test "$(dpkg-deb -f "$deb" Package)" = com.zengniu.splitview
  test "$(dpkg-deb -f "$deb" Version)" = 0.7.66+keyboard11.animations4
  dpkg-deb -x "$deb" build/extracted
  shasum -a 256 "$deb"
done
for binary in build/extracted/Library/MobileSubstrate/DynamicLibraries/ZengNiuSplitView.dylib build/extracted/Library/PreferenceBundles/ZNSPreferences.bundle/ZNSPreferences; do
  test -f "$binary"
  lipo -info "$binary"
  test "$(lipo -archs "$binary")" = arm64e
  codesign --verify --verbose=4 "$binary"
  codesign -d --verbose=4 "$binary" 2>&1
  otool -L "$binary"
  otool -l "$binary"
done
