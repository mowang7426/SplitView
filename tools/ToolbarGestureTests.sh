#!/bin/sh
set -eu
awk '
/^[-+] \(/ || /^@end/ {
    capture=0;
    if ($0 ~ /^- \(BOOL\)gestureRecognizer:\(UIGestureRecognizer \*\)gesture shouldReceiveTouch:/ || $0 ~ /^- \(void\)drag:/) capture=1;
}
capture {print}
' Sources/ZNSWindowManager.m > tools/ToolbarGestureTests.generated.inc
clang -arch arm64 -fobjc-arc -Wall -Wextra -Werror tools/ToolbarGestureTests.m -framework Foundation -framework UIKit -framework CoreGraphics -o tools/ToolbarGestureTests
ldid -Stools/Tool.entitlements tools/ToolbarGestureTests
./tools/ToolbarGestureTests
