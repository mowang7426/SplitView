include ../SplitViewBuild.mk
include $(THEOS)/makefiles/common.mk
BUNDLE_NAME = ZNSPreferences
ZNSPreferences_FILES = ZNSRootListController.m
# The imported Apelin source relied on a prefix header for PSSpecifier.
ZNSPreferences_CFLAGS = -include Preferences/PSSpecifier.h
ZNSPreferences_FRAMEWORKS = Foundation UIKit CoreGraphics QuartzCore
ZNSPreferences_PRIVATE_FRAMEWORKS = Preferences
ZNSPreferences_INSTALL_PATH = /Library/PreferenceBundles
ZNSPreferences_RESOURCE_DIRS = Resources
ZNSPreferences_RESOURCE_FILES = Info.plist
include $(THEOS_MAKE_PATH)/bundle.mk
