# Copyright (C) 2024 Tom <fjrcn@outlook.com>
# This is free software, licensed under the GNU General Public License v3.

include $(TOPDIR)/rules.mk

# Include unified version
include ../../version.mk

PKG_NAME:=luci-app-qmodem
LUCI_TITLE:=LuCI support for QWRT Modem
LUCI_PKGARCH:=all
PKG_VERSION:=$(QMODEM_VERSION)
PKG_RELEASE:=$(QMODEM_RELEASE)
PKG_LICENSE:=GPLv3
PKG_LINCESE_FILES:=LICENSE
PKG_MAINTAINER:=Tom <fjrcn@outlook.com>
PKG_PROVIDES:=qmodem-luci-ui
LUCI_DEPENDS:=@!PACKAGE_luci-app-qmodem-next \
		+luci-compat \
		+qmodem


define Package/luci-app-qmodem/conffiles
/etc/config/qmodem
endef
include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
