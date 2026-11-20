include $(THEOS)/makefiles/common.mk

# Debug builds only (see the parent Makefile): a settings page to get the log off the device.
BUNDLE_NAME = SafariFullURLPrefs

SafariFullURLPrefs_FILES = FUBRootListController.m
SafariFullURLPrefs_FRAMEWORKS = UIKit
SafariFullURLPrefs_PRIVATE_FRAMEWORKS = Preferences
SafariFullURLPrefs_INSTALL_PATH = /Library/PreferenceBundles
SafariFullURLPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk
