#!/bin/sh
set -eu
# Extract current production methods, not a separately maintained algorithm.
awk '
/^[-+] \(/ || /^@end/ {
    if (capture) print "#endif";
    capture=0;
    if ($0 !~ /\{/) next;
    if ($0 ~ /^- \(BOOL\)isStackParticipant/ || $0 ~ /^- \(CGRect\)thumbnailFrameInSafe/ || $0 ~ /^- \(void\)thumbnailTapped:/) {
        print "#ifdef ZNS_TEST_FLOATING"; capture=1;
    }
    if ($0 ~ /^- \(void\)(raiseWindow:|updateWindowStack |collapseParkedToIcon:|arrangeParked )/) {
        print "#ifdef ZNS_TEST_MANAGER"; capture=1;
    }
}
capture {print}
END {if(capture) print "#endif"}
' Sources/ZNSWindowManager.m > tools/WindowStackTests.generated.inc
clang -arch arm64 -fobjc-arc -Wall -Wextra -Werror tools/WindowStackTests.m -framework Foundation -framework UIKit -framework CoreGraphics -o tools/WindowStackTests
ldid -Stools/Tool.entitlements tools/WindowStackTests
./tools/WindowStackTests
