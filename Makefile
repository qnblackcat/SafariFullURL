TARGET = iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = MobileSafari

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SafariFullURL

SafariFullURL_FILES = Core.xm Capsule.xm Pad.xm TextField.xm
SafariFullURL_FRAMEWORKS = UIKit
SafariFullURL_CFLAGS = -fobjc-arc

ifeq ($(SAFARIFULLURL_DEBUG),1)
SafariFullURL_FILES += Debug.xm
SafariFullURL_CFLAGS += -DSAFARIFULLURL_DEBUG=1
# Settings page (Enabled, log buttons): debug builds only, never in a release.
SUBPROJECTS = prefs
INSTALL_TARGET_PROCESSES += Preferences
endif

include $(THEOS_MAKE_PATH)/tweak.mk
ifeq ($(SAFARIFULLURL_DEBUG),1)
include $(THEOS_MAKE_PATH)/aggregate.mk
endif
