include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for aether-proxy
LUCI_DEPENDS:=+aether-proxy +luci-base +rpcd-mod-ucode
LUCI_PKGARCH:=all

PKG_NAME:=luci-app-aether-proxy
PKG_VERSION:=0.2.0
PKG_RELEASE:=4

PKG_LICENSE:=GPL-3.0-or-later
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=leochien0102 <leochien0102@users.noreply.github.com>

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
