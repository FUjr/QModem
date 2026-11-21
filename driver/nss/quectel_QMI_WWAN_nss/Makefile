include $(TOPDIR)/rules.mk

PKG_NAME:=qmi_wwan_q_nss
PKG_VERSION:=1.2.9
PKG_RELEASE:=2

include $(INCLUDE_DIR)/kernel.mk
include $(INCLUDE_DIR)/package.mk

PKG_BUILD_PARALLEL:=1
PKG_CONFIG_DEPENDS:= \
	CONFIG_QMODEM_QMI_NSS_RX_WAKE_FALLBACK \
	CONFIG_QMODEM_QMI_NSS_REGISTRATION_RETRY

define KernelPackage/qmi_wwan_q_nss
  SUBMENU:=WWAN Support
  TITLE:=QMI WWAN driver for Quectel modules
  DEPENDS:=+kmod-usb-net +kmod-usb-wdm
  DEPENDS:=@(TARGET_qualcommax_ipq807x||TARGET_qualcommax_ipq50xx) \
	    +kmod-usb-net \
	    +kmod-usb-wdm \
	    +kmod-rmnet-nss
  FILES:=$(PKG_BUILD_DIR)/qmi_wwan_q.ko
  AUTOLOAD:=$(call AutoLoad,81,qmi_wwan_q)
endef

define KernelPackage/qmi_wwan_q_nss/config
config QMODEM_QMI_NSS_RX_WAKE_FALLBACK
	bool "Wake QMAP TX queues from RX completion (kernel 6.10+)"
	default n
	help
	  Enable the RX-side queue wake fallback for kernels whose usbnet BH
	  is no longer a tasklet. Keep disabled unless the target needs it.

config QMODEM_QMI_NSS_REGISTRATION_RETRY
	bool "Retry QCA NSS registration after a transient failure"
	default n
	help
	  Retry NSS context creation for up to 90 seconds when registration is
	  not ready during USB probe.
endef

EXTRA_CFLAGS+= \
	-Wno-unused-function \
	-Wno-missing-prototypes \
	-Wno-missing-declarations

ifneq ($(CONFIG_PACKAGE_kmod-rmnet-nss),)
EXTRA_CFLAGS += -I$(STAGING_DIR)/usr/include/qca-nss-rmnet
EXTRA_CFLAGS += -DCONFIG_QCA_NSS_DRV
endif
ifneq ($(CONFIG_QMODEM_QMI_NSS_RX_WAKE_FALLBACK),)
EXTRA_CFLAGS += -DQMODEM_QMI_NSS_RX_WAKE_FALLBACK
endif
ifneq ($(CONFIG_QMODEM_QMI_NSS_REGISTRATION_RETRY),)
EXTRA_CFLAGS += -DQMODEM_QMI_NSS_REGISTRATION_RETRY
endif

define Build/Compile
	+$(KERNEL_MAKE) ccflags-y="$(EXTRA_CFLAGS)" M="$(PKG_BUILD_DIR)" \
		modules
endef

$(eval $(call KernelPackage,qmi_wwan_q_nss))
