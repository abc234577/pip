# 现代越狱(Dopamine/palera1n rootless, iOS 16.5)用 rootless 方案。
# 如果你的是 rootful(unc0ver/checkra1n 旧式)，把下面这行注释掉。
export THEOS_PACKAGE_SCHEME = rootless

# SE3 = A15 = arm64e；同时产出 arm64 兼容更多设备
ARCHS = arm64 arm64e
TARGET = iphone:clang:16.5:15.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = PiPNoShot
PiPNoShot_FILES = Tweak.x
PiPNoShot_CFLAGS = -fobjc-arc
PiPNoShot_FRAMEWORKS = UIKit QuartzCore

include $(THEOS)/makefiles/tweak.mk

after-install::
	install.exec "killall -9 PIPAgent SpringBoard || true"
