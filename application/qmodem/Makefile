include $(TOPDIR)/rules.mk
include $(INCLUDE_DIR)/kernel.mk

# Include unified version
include ../../version.mk

PKG_NAME:=qmodem
PKG_RELEASE:=$(QMODEM_RELEASE)
PKG_VERSION:=$(QMODEM_VERSION)

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=QModem scripts
  DEPENDS:=	\
  		+kmod-usb2 +kmod-usb3 \
		+kmod-usb-serial +kmod-usb-serial-option +kmod-usb-serial-qualcomm \
		+kmod-usb-net +kmod-usb-acm \
		+kmod-usb-wdm \
  		+kmod-usb-net-cdc-ether \
		+kmod-usb-net-cdc-mbim \
		+kmod-usb-net-rndis \
		+kmod-usb-net-cdc-ncm +kmod-usb-net-huawei-cdc-ncm \
		+ubus-at-daemon +qmodem-settings +tom_modem +terminfo +sms-tool_q \
		+modem_scan \
		+jq +flock +bc\
		+coreutils +coreutils-stat +xxd \
		+PACKAGE_qmodem_INCLUDE_SEAL:qmodem-seal \
		+usbutils \
		+PACKAGE_qmodem_INCLUDE_rdisc6:rdisc6 \
		+PACKAGE_qmodem_INCLUDE_ndisc6:ndisc6 \
		+PACKAGE_qmodem_INCLUDE_generic-qmi-wwan:kmod-usb-net-qmi-wwan \
		+PACKAGE_qmodem_INCLUDE_vendor-qmi-wwan:kmod-qmi_wwan_q \
		+PACKAGE_qmodem_INCLUDE_vendor-qmi-wwan:kmod-qmi_wwan_f \
		+PACKAGE_qmodem_INCLUDE_vendor-qmi-wwan:kmod-qmi_wwan_s \
		+PACKAGE_qmodem_INCLUDE_nss-qmi-wwan:kmod-rmnet-nss \
		+PACKAGE_qmodem_INCLUDE_nss-qmi-wwan:kmod-qmi_wwan_q_nss \
		+PACKAGE_qmodem_VENDOR_MHI_PCIe_DRIVER:kmod-pcie_mhi \
		+PACKAGE_qmodem_GENERIC_MHI_PCIe_DRIVER:kmod-mhi-net \
		+PACKAGE_qmodem_GENERIC_MHI_PCIe_DRIVER:kmod-mhi-pci-generic \
		+PACKAGE_qmodem_GENERIC_MHI_PCIe_DRIVER:kmod-mhi-wwan-ctrl \
		+PACKAGE_qmodem_GENERIC_MHI_PCIe_DRIVER:kmod-mhi-wwan-mbim \
		+PACKAGE_qmodem_NSS_MHI_PCIe_DRIVER:kmod-rmnet-nss \
		+PACKAGE_qmodem_NSS_MHI_PCIe_DRIVER:kmod-pcie_mhi_nss \
		+PACKAGE_qmodem_INCLUDE_ADD_PCI_SUPPORT:pciutils \
		+PACKAGE_qmodem_INCLUDE_ADD_MTK_T7XX_SUPPORT:umbim \
		+PACKAGE_qmodem_INCLUDE_ADD_MTK_T7XX_SUPPORT:kmod-mtk-t7xx \
		+PACKAGE_qmodem_INCLUDE_ADD_QFIREHOSE_SUPPORT:qfirehose \
		+PACKAGE_qmodem_USE_TOM_CUSTOMIZED_QUECTEL_CM:quectel-CM-5G-M \
		+PACKAGE_qmodem_USING_QWRT_QUECTEL_CM_5G:quectel-CM-5G \
		+PACKAGE_qmodem_USING_NORMAL_QUECTEL_CM:quectel-cm
endef

define Package/$(PKG_NAME)/config
	config PACKAGE_qmodem_INCLUDE_SEAL
		bool "Include encrypted feedback support (qmodem-seal)"
		default y
		help
		  Build and install qmodem-seal. When omitted, qmodem_collect
		  falls back to an explicitly marked unencrypted archive.

	choice
		prompt "IPv6 Neighbor Discovery Selection"
		default PACKAGE_qmodem_INCLUDE_ndisc6

		config PACKAGE_qmodem_INCLUDE_ndisc6
			bool "Include ndisc6 for IPv6 Neighbor Discovery"

		config PACKAGE_qmodem_INCLUDE_rdisc6
			bool "Include rdisc6 for IPv6 Router Discovery"

		config PACKAGE_qmodem_INCLUDE_no_ndisc_rdisc6
			bool "Do not include any IPv6 Neighbor/Router Discovery tool"
	endchoice

	choice
		prompt "Qualcomm QMI WWAN Driver Selection"
		default PACKAGE_qmodem_INCLUDE_vendor-qmi-wwan

		config PACKAGE_qmodem_INCLUDE_vendor-qmi-wwan
			bool "Vendor QMI driver"

		config PACKAGE_qmodem_INCLUDE_generic-qmi-wwan
			bool "Generic QMI driver"

		config PACKAGE_qmodem_INCLUDE_nss-qmi-wwan
			bool "NSS QMI driver"
			depends on TARGET_qualcommax_ipq807x || TARGET_qualcommax_ipq50xx
	endchoice

	choice
		prompt "MHI PCIe Modem Driver Selection"
		default PACKAGE_qmodem_VENDOR_MHI_PCIe_DRIVER
		depends on PACKAGE_qmodem_INCLUDE_ADD_PCI_SUPPORT

		config PACKAGE_qmodem_VENDOR_MHI_PCIe_DRIVER
			bool "Use Vendor MHI PCIe Driver"

		config PACKAGE_qmodem_GENERIC_MHI_PCIe_DRIVER
			bool "Use Generic MHI PCIe Driver"

		config PACKAGE_qmodem_NSS_MHI_PCIe_DRIVER
			bool "Use NSS MHI PCIe Driver"
			depends on TARGET_qualcommax_ipq807x || TARGET_qualcommax_ipq50xx
	endchoice

	choice
		prompt "Quectel Connect Manager Selection"
		default PACKAGE_qmodem_USE_TOM_CUSTOMIZED_QUECTEL_CM

		config PACKAGE_qmodem_USE_TOM_CUSTOMIZED_QUECTEL_CM
			bool "Tom customized Quectel CM"

		config PACKAGE_qmodem_USING_QWRT_QUECTEL_CM_5G
			bool "QWRT Quectel-CM-5G"

		config PACKAGE_qmodem_USING_NORMAL_QUECTEL_CM
			bool "NORMAL Quectel-CM"
	endchoice

	config PACKAGE_qmodem_INCLUDE_ADD_PCI_SUPPORT
		bool "Add PCIe Modem SUPPORT"
		default n

	config PACKAGE_qmodem_INCLUDE_ADD_MTK_T7XX_SUPPORT
		bool "Add MTK-T7XX Modem PCI SUPPORT"
		default n

	config PACKAGE_qmodem_INCLUDE_ADD_QFIREHOSE_SUPPORT
		bool "Add Qfirehose SUPPORT"
		default n
endef

define Package/$(PKG_NAME)/description
	QModem scripts
endef

define Package/$(PKG_NAME)/conffiles
/etc/config/qmodem_led
endef

define Build/Prepare
endef

define Build/Compile
endef

define Package/$(PKG_NAME)/install
		$(CP) ./files/* $(1)/
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
