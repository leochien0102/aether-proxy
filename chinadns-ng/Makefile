#
# chinadns-ng for aether-proxy users whose firmware feeds lack it (official OpenWrt).
#
# Packages the static binary that upstream publishes for each architecture (wolfssl build,
# needed for tls:// upstreams), pinned by sha256 below; nothing is compiled. The package is
# published to the release and listed in the signed manifest, but devices never check,
# install or update it: DNS breaking takes down the whole network, so it only changes when
# the user installs it (docs/08 of aether-proxy). Version bumps are manual.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=chinadns-ng
PKG_VERSION:=2025.08.09
PKG_RELEASE:=1

# aarch64: the noasm wolfssl build, because aarch64_generic packages must run on every armv8
# core; the assembly build is only safe on known boards. x86_64: the baseline x86_64 build.
# Only the channel's targets are listed; others fail loudly.
ifeq ($(ARCH),aarch64)
  CHINADNS_ASSET:=chinadns-ng+wolfssl_noasm@aarch64-linux-musl@generic+v8a@fast+lto
  PKG_HASH:=42ddd494200ec6d88b35902927688d316bc23e06e6c08d9e01eb2412196ab845
else ifeq ($(ARCH),x86_64)
  CHINADNS_ASSET:=chinadns-ng+wolfssl@x86_64-linux-musl@x86_64@fast+lto
  PKG_HASH:=842ea4e9816efd91d39bc76ead5c4a42e79011757e37c521b4270b675cfcb30c
else
  CHINADNS_ASSET:=unsupported
  PKG_HASH:=skip
endif

PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION)-$(ARCH)
PKG_SOURCE_URL:=https://github.com/zfl9/chinadns-ng/releases/download/$(PKG_VERSION)/$(CHINADNS_ASSET)?
PKG_LICENSE:=AGPL-3.0-only
PKG_MAINTAINER:=leochien0102 <leochien0102@users.noreply.github.com>

include $(INCLUDE_DIR)/package.mk

# Upstream ships it stripped and statically linked.
RSTRIP:=:

define Package/chinadns-ng
  SECTION:=net
  CATEGORY:=Network
  TITLE:=ChinaDNS-NG DNS forwarder (upstream static build, aether-proxy channel)
  URL:=https://github.com/zfl9/chinadns-ng
  DEPENDS:=@(aarch64||x86_64)
endef

define Package/chinadns-ng/description
  The upstream release binary of ChinaDNS-NG (wolfssl build), installed as
  /usr/bin/chinadns-ng. aether-proxy runs it as its DNS splitter.
endef

# The download is the binary itself: no archive to unpack.
define Build/Prepare
	@[ "$(CHINADNS_ASSET)" != unsupported ] || { echo "chinadns-ng: unsupported ARCH '$(ARCH)'" >&2; exit 1; }
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) $(DL_DIR)/$(PKG_SOURCE) $(PKG_BUILD_DIR)/chinadns-ng
endef

define Build/Compile
endef

define Package/chinadns-ng/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/chinadns-ng $(1)/usr/bin/chinadns-ng
endef

$(eval $(call BuildPackage,chinadns-ng))
