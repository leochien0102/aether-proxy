#
# Package the upstream static aether-dns binary for the aetherproxy feed.
# See docs/tasks/m4.md M4-20 and docs/design/versioning-20261114.md section 6.
# Downloads are pinned per architecture; no Rust toolchain is needed here.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=aether-dns
PKG_VERSION:=1.0.2
PKG_RELEASE:=1

# ARCH is the CPU architecture, while release assets use the package architecture.
ifeq ($(ARCH),aarch64)
  AETHER_DNS_ARCH:=aarch64_generic
  PKG_HASH:=9c21f7d9d35a2b9784719bebb17f88dce3fcba0b446acb06bb38cbec4c95e223
else ifeq ($(ARCH),x86_64)
  AETHER_DNS_ARCH:=x86_64
  PKG_HASH:=d7ad176292664bb5f4d070d3d3ed98b483c2403fc6ef87efa1ff1e0483a499eb
else
  AETHER_DNS_ARCH:=unsupported
  PKG_HASH:=skip
endif

PKG_SOURCE:=aether-dns-$(PKG_VERSION)-r$(PKG_RELEASE)-$(AETHER_DNS_ARCH)
PKG_SOURCE_URL:=https://github.com/leochien0102/aether-dns/releases/download/v$(PKG_VERSION)/
PKG_LICENSE:=GPL-3.0-or-later
PKG_MAINTAINER:=leochien0102 <leochien0102@users.noreply.github.com>

# The upstream binary is statically linked: no SDK-default libc dependency.
PKG_DEFAULT_DEPENDS:=

include $(INCLUDE_DIR)/package.mk

# Upstream ships it stripped and statically linked.
RSTRIP:=:

define Package/aether-dns
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Aether DNS forwarder (upstream static build)
  URL:=https://github.com/leochien0102/aether-dns
  DEPENDS:=@(aarch64||x86_64)
  PROVIDES:=dns-engine
  DEFAULT_VARIANT:=1
endef

define Package/aether-dns/description
  The upstream release binary of Aether DNS, installed as /usr/bin/aether-dns.
  Provides the default DNS engine for aether-proxy.
endef

# The download is a bare binary, not an archive. Release assets lose executable mode.
define Build/Prepare
	@[ "$(AETHER_DNS_ARCH)" != unsupported ] || { echo "aether-dns: unsupported ARCH '$(ARCH)'" >&2; exit 1; }
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) $(DL_DIR)/$(PKG_SOURCE) $(PKG_BUILD_DIR)/aether-dns
	chmod 0755 $(PKG_BUILD_DIR)/aether-dns
endef

define Build/Compile
endef

define Package/aether-dns/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/aether-dns $(1)/usr/bin/aether-dns
endef

$(eval $(call BuildPackage,aether-dns))
