include SplitViewBuild.mk
include $(THEOS)/makefiles/common.mk
TWEAK_NAME = ZengNiuSplitView
ZengNiuSplitView_FILES = $(wildcard Sources/*.m)
ZengNiuSplitView_FRAMEWORKS = Foundation UIKit QuartzCore CoreGraphics
ZengNiuSplitView_LIBRARIES = substrate
include $(THEOS_MAKE_PATH)/tweak.mk
SUBPROJECTS += Preferences
include $(THEOS_MAKE_PATH)/aggregate.mk
