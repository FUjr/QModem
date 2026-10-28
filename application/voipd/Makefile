include $(TOPDIR)/rules.mk

# Include unified version
include ../../version.mk

PKG_NAME:=qmodem-voip
PKG_VERSION:=$(QMODEM_VERSION)
PKG_RELEASE:=$(QMODEM_RELEASE)
PKG_LICENSE:=GPL-2.0-or-later
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)

include $(INCLUDE_DIR)/package.mk

QMODEM_VOIP_MODULE_CC?=clang

define Package/$(PKG_NAME)
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=QModem VoIP daemon (experimental)
  DEPENDS:=+libubus +libubox +libblobmsg-json +libjson-c +libuci +uci +jsonfilter +jshn +adb \
	+alsa-lib +libsoxr \
	+PACKAGE_libwebsockets-full:libwebsockets-full \
	+!PACKAGE_libwebsockets-full:libwebsockets-openssl +px5g-mbedtls \
	+kmod-usb-serial +kmod-usb-serial-option
endef

define Package/$(PKG_NAME)/description
  Experimental QModem voice daemon. Owns the exclusive modem audio PCM fd and
  drives call control through module profiles. SIP and web consumers attach to
  the daemon's media socket.
endef

define Build/Prepare
	$(RM) -r $(PKG_BUILD_DIR)
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Compile
	$(QMODEM_VOIP_MODULE_CC) --target=arm-linux-gnueabihf -march=armv7-a \
		-fuse-ld=lld -shared -fPIC -Os -nostdlib -std=gnu11 \
		-Wall -Wextra -Werror -Wl,--build-id=none -Wl,--hash-style=gnu \
		-Wl,-soname,libqvoice_media_gate.so \
		-o $(PKG_BUILD_DIR)/libqvoice_media_gate.so \
		$(PKG_BUILD_DIR)/qvoice_media_gate.c
	$(TARGET_CC) $(TARGET_CPPFLAGS) $(TARGET_CFLAGS) -std=gnu11 -Wall -Wextra -Werror \
		-I$(STAGING_DIR)/usr/include \
		-o $(PKG_BUILD_DIR)/qmodem_voip_adb_unlock \
		$(PKG_BUILD_DIR)/adb_unlock.c $(TARGET_LDFLAGS) -lcrypt
	$(TARGET_CC) $(TARGET_CPPFLAGS) $(TARGET_CFLAGS) -std=gnu11 -Wall -Wextra -Werror \
		-I$(STAGING_DIR)/usr/include \
		-o $(PKG_BUILD_DIR)/qmodem_voip \
		$(PKG_BUILD_DIR)/main.c $(PKG_BUILD_DIR)/daemon_core.c \
		$(PKG_BUILD_DIR)/media_manager.c $(PKG_BUILD_DIR)/call_state.c \
		$(PKG_BUILD_DIR)/modem_profile.c $(PKG_BUILD_DIR)/at_direct.c \
		$(PKG_BUILD_DIR)/call_history.c \
		$(PKG_BUILD_DIR)/media_core.c $(PKG_BUILD_DIR)/media_alsa.c \
		$(PKG_BUILD_DIR)/media_serial.c $(PKG_BUILD_DIR)/media_pcm_socket.c \
		$(PKG_BUILD_DIR)/browser_media.c \
		$(PKG_BUILD_DIR)/media_socket.c \
		$(PKG_BUILD_DIR)/rtp_transport.c \
		$(TARGET_LDFLAGS) \
		-lubus -lubox -lblobmsg_json -ljson-c -lsoxr -lasound \
		-lwebsockets -luci -lm -lpthread
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/qmodem_voip $(1)/usr/bin/
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/qmodem_voip_adb_unlock $(1)/usr/bin/
	$(INSTALL_DIR) $(1)/usr/lib/qmodem_voip $(1)/usr/share/qmodem $(1)/usr/sbin \
		$(1)/usr/share/qmodem_voip $(1)/etc/init.d $(1)/etc/config \
		$(1)/etc/qmodem_voip $(1)/etc/uci-defaults $(1)/etc/hotplug.d/usb
	$(INSTALL_BIN) ./files/usr/lib/qmodem_voip/*.sh $(1)/usr/lib/qmodem_voip/
	$(INSTALL_DATA) ./files/usr/share/qmodem/modem_supports.json $(1)/usr/share/qmodem/
	$(INSTALL_DATA) ./files/usr/share/qmodem_voip/modem_profiles.json $(1)/usr/share/qmodem_voip/
	$(INSTALL_DIR) $(1)/usr/share/qmodem_voip/module
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/libqvoice_media_gate.so $(1)/usr/share/qmodem_voip/module/
	$(INSTALL_BIN) ./files/usr/share/qmodem_voip/module/install_media_gate.sh \
		$(1)/usr/share/qmodem_voip/module/
	$(INSTALL_BIN) ./files/usr/sbin/qmodem_voip_modem_safety $(1)/usr/sbin/
	$(INSTALL_BIN) ./files/usr/sbin/qmodem_voip_daemon_wait $(1)/usr/sbin/
	$(INSTALL_BIN) ./files/usr/sbin/qmodem_voip_web $(1)/usr/sbin/
	$(INSTALL_BIN) ./files/etc/init.d/qmodem_voip $(1)/etc/init.d/
	$(INSTALL_CONF) ./files/etc/config/qmodem_voip $(1)/etc/config/
	$(INSTALL_BIN) ./files/etc/hotplug.d/usb/21-qmodem-voip-audio $(1)/etc/hotplug.d/usb/
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
