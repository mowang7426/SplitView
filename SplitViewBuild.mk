ARCHS = arm64e
TARGET = iphone:clang:16.5:16.0
THEOS_PACKAGE_SCHEME = roothide
DEBUG = 0
FINALPACKAGE = 1
ZNS_BUILD_ID ?= $(shell git rev-parse --short=12 HEAD)
# Existing UIButton imageEdgeInsets usage remains supported on iOS 16/17.
# Keep deprecation diagnostics visible, without downgrading any other error.
ADDITIONAL_CFLAGS += -Wno-error=deprecated-declarations -fobjc-arc -DAPELIN_PACKAGE_ID='"com.zengniu.splitview"' -DAPELIN_BUILD_ID='"$(ZNS_BUILD_ID)"'
