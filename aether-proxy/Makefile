include $(TOPDIR)/rules.mk

PKG_NAME:=aether-proxy
PKG_VERSION:=0.2.0
PKG_RELEASE:=6

PKG_LICENSE:=GPL-3.0-or-later
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=leochien0102 <leochien0102@users.noreply.github.com>

include $(INCLUDE_DIR)/package.mk

define Package/aether-proxy
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Transparent proxy manager (Xray, ChinaDNS-NG) for fw4
  URL:=https://github.com/leochien0102/aether-proxy
  PKGARCH:=all
  DEPENDS:= \
	+kmod-nft-tproxy +kmod-nft-socket +ip-full +curl +ca-bundle \
	+firewall4 +resolveip +usign +dnsmasq \
	+ucode +ucode-mod-fs +ucode-mod-uci +ucode-mod-uloop +ucode-mod-socket \
	+ucode-mod-log
endef

define Package/aether-proxy/description
  Manages Xray and ChinaDNS-NG as a transparent proxy on OpenWrt (fw4/nftables only).
endef

define Package/aether-proxy/conffiles
/etc/config/aetherproxy
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/. $(PKG_BUILD_DIR)/
endef

define Build/Compile
endef

# The placeholder in const.uc becomes "<PKG_VERSION>-<PKG_RELEASE>".
define Package/aether-proxy/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/aether-proxy $(1)/usr/bin/aether-proxy
	$(INSTALL_DIR) $(1)/usr/share/ucode/aetherproxy
	$(CP) $(PKG_BUILD_DIR)/lib/. $(1)/usr/share/ucode/aetherproxy/
	sed -i 's|@@VERSION@@|$(PKG_VERSION)-r$(PKG_RELEASE)|' $(1)/usr/share/ucode/aetherproxy/const.uc
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/aether-proxy.config $(1)/etc/config/aetherproxy
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/aether-proxy.init $(1)/etc/init.d/aether-proxy
	$(INSTALL_DIR) $(1)/etc/hotplug.d/iface
	$(INSTALL_BIN) ./files/aether-proxy.hotplug $(1)/etc/hotplug.d/iface/80-aether-proxy
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/aether-proxy.uci-defaults $(1)/etc/uci-defaults/99-aether-proxy
	$(INSTALL_DIR) $(1)/etc/aether-proxy/custom
	$(INSTALL_DIR) $(1)/etc/aether-proxy/keys
	$(foreach key,$(wildcard ./files/keys/*),$(INSTALL_DATA) $(key) $(1)/etc/aether-proxy/keys/;)
	$(INSTALL_DIR) $(1)/usr/share/aether-proxy/data
	$(INSTALL_DATA) ./files/data/*.txt $(1)/usr/share/aether-proxy/data/
	$(INSTALL_DATA) ./files/aether-proxy-logfilter.awk $(1)/usr/share/aether-proxy/logfilter.awk
	# Upstream sources and licenses of the bundled lists (gfwlist is LGPL-2.1, docs/08).
	$(INSTALL_DATA) ./files/data/SOURCES.md $(1)/usr/share/aether-proxy/data/SOURCES.md
	$(INSTALL_DIR) $(1)/usr/share/nftables.d/chain-pre/input
	$(INSTALL_DATA) ./files/30-aether-proxy.nft $(1)/usr/share/nftables.d/chain-pre/input/30-aether-proxy.nft
	# conffiles cannot list directories; keep.d entries may (sysupgrade runs find on them).
	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) ./files/aether-proxy.keep $(1)/lib/upgrade/keep.d/aether-proxy-data
endef

define Package/aether-proxy/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
fw4 reload || echo "aether-proxy: fw4 reload failed (rc=$$?), run it manually" >&2
exit 0
endef

define Package/aether-proxy/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
fw4 reload || echo "aether-proxy: fw4 reload failed (rc=$$?), run it manually" >&2
exit 0
endef

$(eval $(call BuildPackage,aether-proxy))
