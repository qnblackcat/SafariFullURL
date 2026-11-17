TARGET = iphone:clang:16.5:15.0
ARCHS = arm64 arm64e
INSTALL_TARGET_PROCESSES = MobileSafari

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = SafariFullURL

SafariFullURL_FILES = Core.xm Capsule.xm TextField.xm
SafariFullURL_FRAMEWORKS = UIKit
SafariFullURL_CFLAGS = -fobjc-arc

ifeq ($(SAFARIFULLURL_DEBUG),1)
SafariFullURL_FILES += Debug.xm
SafariFullURL_CFLAGS += -DSAFARIFULLURL_DEBUG=1
endif

include $(THEOS_MAKE_PATH)/tweak.mk
