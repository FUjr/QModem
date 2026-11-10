include $(TOPDIR)/rules.mk

include ../../version.mk

LUCI_TITLE:=LuCI support for independent QModem SIP service
LUCI_DEPENDS:=+qmodem-sipd +luci-base
LUCI_PKGARCH:=all
PKG_VERSION:=$(QMODEM_VERSION)
PKG_RELEASE:=$(QMODEM_RELEASE)
PKG_LICENSE:=GPL-3.0-or-later
PKG_LICENSE_FILES:=LICENSE

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
