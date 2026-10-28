include $(TOPDIR)/rules.mk
include ../../version.mk

PKG_NAME:=qmodem-sipd
PKG_VERSION:=$(QMODEM_VERSION)
PKG_RELEASE:=$(QMODEM_RELEASE)
PKG_LICENSE:=GPL-2.0-or-later
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=QModem SIP transport service (experimental)
  DEPENDS:=+qmodem-voip +qmodem-smsd +libubus +libubox +libblobmsg-json +libjson-c +libuci \
	+libpj +libpjlib-util +libpjsip +libpjsip-ua +libsoxr +alsa-lib
endef

define Package/$(PKG_NAME)/description
  Independent SIP transport service for the QModem voice and SMS daemons.
endef

define Package/$(PKG_NAME)/conffiles
/etc/config/qmodem_sip
endef

define Build/Prepare
	$(RM) -r $(PKG_BUILD_DIR)
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ../voipd/src/g711.h ../voipd/src/media.h ../voipd/src/media_socket.h \
		../voipd/src/modem_profile.h \
		../voipd/src/rtp_transport.h $(PKG_BUILD_DIR)/
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(TARGET_CC) $(TARGET_CPPFLAGS) $(TARGET_CFLAGS) \
		-DPJ_AUTOCONF=1 -DPJ_IS_BIG_ENDIAN=0 -DPJ_IS_LITTLE_ENDIAN=1 \
		-I$(STAGING_DIR)/usr/include \
		-Wall -Wextra -Werror -std=gnu11 \
		-o $(PKG_BUILD_DIR)/qmodem_voip_sip_consumer \
		$(PKG_BUILD_DIR)/sip_consumer.c $(PKG_BUILD_DIR)/sip_gateway.c \
		$(PKG_BUILD_DIR)/sip_activation.c $(PKG_BUILD_DIR)/sip_registration.c \
		$(PKG_BUILD_DIR)/media_socket_client.c \
		$(TARGET_LDFLAGS) \
		-lpjsip -lpjsip-ua -lpjlib-util -lpj -lsoxr -lasound \
		-lubus -lubox -lblobmsg_json -ljson-c -lm
	$(TARGET_CC) $(TARGET_CPPFLAGS) $(TARGET_CFLAGS) \
		-I$(STAGING_DIR)/usr/include -Wall -Wextra -Werror -std=gnu11 \
		-o $(PKG_BUILD_DIR)/qmodem_voip_sipd \
		$(PKG_BUILD_DIR)/sip_control.c $(PKG_BUILD_DIR)/sip_credentials.c \
		$(PKG_BUILD_DIR)/sip_gateway.c $(TARGET_LDFLAGS) \
		-lubus -lubox -lblobmsg_json -ljson-c -luci
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/bin $(1)/usr/sbin $(1)/etc/init.d $(1)/etc/config \
		$(1)/etc/qmodem_voip $(1)/etc/uci-defaults
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/qmodem_voip_sip_consumer $(1)/usr/bin/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/qmodem_voip_sipd $(1)/usr/sbin/
	$(INSTALL_BIN) ./files/usr/sbin/* $(1)/usr/sbin/
	$(INSTALL_BIN) ./files/etc/init.d/qmodem_voip_sipd $(1)/etc/init.d/
	$(INSTALL_CONF) ./files/etc/config/qmodem_sip $(1)/etc/config/
	$(INSTALL_BIN) ./files/etc/qmodem_voip/firewall.include $(1)/etc/qmodem_voip/
	$(INSTALL_BIN) ./files/etc/uci-defaults/89-qmodem-sip-migrate $(1)/etc/uci-defaults/
	$(INSTALL_BIN) ./files/etc/uci-defaults/90-qmodem-sip-firewall $(1)/etc/uci-defaults/
	$(INSTALL_BIN) ./files/etc/uci-defaults/91-qmodem-sip-bootlink $(1)/etc/uci-defaults/
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
