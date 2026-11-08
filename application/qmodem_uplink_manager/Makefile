include $(TOPDIR)/rules.mk
PKG_NAME:=qmodem-uplink-manager
PKG_RELEASE:=1
PKG_LICENSE:=GPL-2.0
include $(INCLUDE_DIR)/package.mk
define Package/qmodem-uplink-manager
  PKGARCH:=all
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Connection-based IPv4 uplink manager
  DEPENDS:=+qmodem +firewall4 +nftables-json +conntrack +ip-full +jq +flock +rpcd +rpcd-mod-ucode +ucode-mod-fs +ucode-mod-uci
endef
define Package/qmodem-uplink-manager/conffiles
/etc/config/qmodem_uplink
/etc/qmodem-uplink/
endef
define Build/Compile
endef
define Package/qmodem-uplink-manager/install
	$(INSTALL_DIR) $(1)/etc/qmodem-uplink
	$(CP) ./root/* $(1)/
endef
$(eval $(call BuildPackage,qmodem-uplink-manager))
