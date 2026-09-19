# Copyright (C) 2024 Tom <fjrcn@outlook.com>
# This is free software, licensed under the GNU General Public License v3.

include $(TOPDIR)/rules.mk

# Include unified version
include ../../version.mk

PKG_NAME:=luci-app-qmodem-next
PKGARCH:=all
PKG_RELEASE:=4
PKG_MAINTAINER:=Tom <fjrcn@outlook.com>
PKG_LICENSE:=GPLv3
PKG_DEPENDS:=+qmodem +qmodem-smsd +sms-forwarder-next
PKG_BUILD_DEPENDS:=luci-base/host
PKG_VERSION:=$(QMODEM_VERSION)

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=luci
  CATEGORY:=LuCI
  SUBMENU:=3. Applications
  TITLE:=LuCI Modern UI for QModem
  DEPENDS:=$(PKG_DEPENDS) +luci-base
  CONFLICTS:=luci-app-qmodem
  PROVIDES:=qmodem-luci-ui
  PKGARCH:=all
endef

define Package/$(PKG_NAME)/description
  LuCI modern (JavaScript) interface for QModem.
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(CP) ./root/* $(1)/
	$(INSTALL_DIR) $(1)/www
	$(CP) ./htdocs/* $(1)/www/
endef

define Package/luci-i18n-qmodem-next-zh-cn
	SECTION:=luci
	CATEGORY:=LuCI
	TITLE:=luci-app-qmodem-next - zh-cn translation
	HIDDEN:=1
	DEFAULT:=LUCI_LANG_zh_Hans||(ALL&&m)
	DEPENDS:=luci-app-qmodem-next
	PKGARCH:=all
endef

define Package/luci-i18n-qmodem-next-zh-cn/description
	Translation for luci-app-qmodem-next - 简体中文 (Simplified Chinese)
endef

define Package/luci-i18n-qmodem-next-zh-cn/install
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	echo "uci set luci.languages.zh_cn='简体中文 (Simplified Chinese)'; uci commit luci" \
		> $(1)/etc/uci-defaults/luci-i18n-qmodem-next-zh-cn
	$(INSTALL_DIR) $(1)/usr/lib/lua/luci/i18n
	po2lmo ./po/zh_Hans/luci-app-qmodem-next.po \
		$(1)/usr/lib/lua/luci/i18n/luci-app-qmodem-next.zh-cn.lmo
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
$(eval $(call BuildPackage,luci-i18n-qmodem-next-zh-cn))
