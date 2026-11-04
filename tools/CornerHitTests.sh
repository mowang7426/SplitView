#!/bin/sh
set -eu
# Extract the exact production class, including both interface and implementation.
awk '
/^@interface ZNSCornerHitView / { capture=1; ends=0 }
capture { print }
capture && /^@end/ { ends++; if(ends==2) capture=0 }
' Sources/ZNSWindowManager.m > tools/CornerHitTests.generated.inc
clang -arch arm64 -fobjc-arc -Wall -Wextra -Werror tools/CornerHitTests.m -framework Foundation -framework UIKit -framework CoreGraphics -o tools/CornerHitTests
ldid -Stools/Tool.entitlements tools/CornerHitTests
./tools/CornerHitTests
