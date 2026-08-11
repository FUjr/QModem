#
# Copyright (C) 2015 OpenWrt.org
#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=qmi_wwan_f
PKG_VERSION:=1.0
PKG_RELEASE:=5

include $(INCLUDE_DIR)/kernel.mk
include $(INCLUDE_DIR)/package.mk

define KernelPackage/qmi_wwan_f
  SUBMENU:=WWAN Support
  TITLE:=Fibocom Linux USB QMI WWAN Driver
  DEPENDS:=+kmod-usb-net +kmod-usb-wdm
  KCONFIG:= \
	CONFIG_USB_SUPPORT=y \
	CONFIG_USB_USBNET \
	CONFIG_USB_NET_DRIVERS \
	CONFIG_USB_WDM
  FILES:=$(PKG_BUILD_DIR)/qmi_wwan_f.ko
  AUTOLOAD:=$(call AutoLoad,82,qmi_wwan_f)
endef

define KernelPackage/qmi_wwan_f/description
  Fibocom Linux USB QMI WWAN Driver
endef

EXTRA_CFLAGS+= \
	-Wno-unused-function \
	-Wno-missing-prototypes \
	-Wno-missing-declarations

MAKE_OPTS:= \
	ARCH="$(LINUX_KARCH)" \
	CROSS_COMPILE="$(TARGET_CROSS)" \
	CXXFLAGS="$(TARGET_CXXFLAGS)" \
	M="$(PKG_BUILD_DIR)" \
	ccflags-y="$(EXTRA_CFLAGS)" \
	$(EXTRA_KCONFIG)

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(MAKE) -C "$(LINUX_DIR)" \
		$(MAKE_OPTS) \
		modules
endef

$(eval $(call KernelPackage,qmi_wwan_f))
