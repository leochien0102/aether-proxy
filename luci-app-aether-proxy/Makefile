include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for aether-proxy
LUCI_DEPENDS:=+aether-proxy +luci-base +rpcd-mod-ucode
LUCI_PKGARCH:=all

PKG_NAME:=luci-app-aether-proxy
PKG_VERSION:=0.2.0
PKG_RELEASE:=3

# TODO(design): license and maintainer are not specified in docs/.

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
