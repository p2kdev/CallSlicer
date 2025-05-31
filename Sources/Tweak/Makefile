include $(THEOS)/makefiles/common.mk

TWEAK_NAME = CallSlicer
export TARGET = iphone:clang:13.7:13.0
export ARCHS = arm64 arm64e

CallSlicer_FILES = Tweak.x

# cf: https://github.com/theos/sdks

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "sbreload"
