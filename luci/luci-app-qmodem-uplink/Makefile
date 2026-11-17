include $(TOPDIR)/rules.mk
include ../../version.mk
LUCI_TITLE:=QModem IPv4 uplink balancing
LUCI_DEPENDS:=+luci-base +qmodem-uplink-manager
LUCI_PKGARCH:=all
PKG_VERSION:=$(QMODEM_VERSION)
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0
include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
