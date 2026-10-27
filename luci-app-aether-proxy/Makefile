include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for aether-proxy
LUCI_DEPENDS:=+aether-proxy +luci-base +rpcd-mod-ucode
LUCI_PKGARCH:=all

PKG_NAME:=luci-app-aether-proxy
PKG_VERSION:=0.4.0
PKG_RELEASE:=1

PKG_LICENSE:=GPL-3.0-or-later
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=leochien0102 <leochien0102@users.noreply.github.com>

# docs/10 T10.12: stamp both files from this package, not the backend version.
define Build/Prepare/luci-app-aether-proxy
	sed -i 's|@@VERSION@@|$(PKG_VERSION)-r$(PKG_RELEASE)|g' \
		$(PKG_BUILD_DIR)/htdocs/luci-static/resources/aether-proxy/common.js \
		$(PKG_BUILD_DIR)/htdocs/luci-static/resources/aether-proxy/build.json
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
