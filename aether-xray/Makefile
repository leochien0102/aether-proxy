#
# Independent aether-xray package for aether-proxy (docs/08-updates.md, T11.5).
#
# Xray needs a newer Go than the golang package in the OpenWrt 24.10 feeds, so this
# Makefile does not use golang-package.mk: it downloads an official Go toolchain (pinned
# by version and sha256 below, like the source archive) and cross-compiles a static
# binary with it. Keep this package separate from the aether-proxy application.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=aether-xray
PKG_VERSION:=26.10.29
PKG_RELEASE:=1

PKG_SOURCE:=Xray-core-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/XTLS/Xray-core/tar.gz/v$(PKG_VERSION)?
PKG_HASH:=ee22c6f21855f70a52e19bff02fa71f4b28ce071d83ff9154fafcaa0f315a642
# Keep upstream sources/stamps apart from feeds' patched xray-core, even when
# both packages use the same upstream version. The archive's root is unchanged.
PKG_BUILD_DIR:=$(BUILD_DIR)/aether-xray-$(PKG_VERSION)/Xray-core-$(PKG_VERSION)

PKG_LICENSE:=MPL-2.0
PKG_LICENSE_FILES:=LICENSE
PKG_MAINTAINER:=leochien0102 <leochien0102@users.noreply.github.com>

# Must satisfy the `go` line of Xray's go.mod for PKG_VERSION.
GO_TOOLCHAIN_VERSION:=1.27.2
GO_TOOLCHAIN_FILE:=go$(GO_TOOLCHAIN_VERSION).linux-amd64.tar.gz
GO_TOOLCHAIN_HASH:=ecbadb99091a3f46e31f5f934b068b1864eafa7995211b39eaddf76996045fe5

include $(INCLUDE_DIR)/package.mk

# The binary is already built with -s -w; nothing for the SDK strip step to do.
RSTRIP:=:

define Download/go-toolchain
  URL:=https://go.dev/dl/
  FILE:=$(GO_TOOLCHAIN_FILE)
  HASH:=$(GO_TOOLCHAIN_HASH)
endef
$(eval $(call Download,go-toolchain))

# OpenWrt ARCH -> GOARCH. Only the channel's targets are listed; others fail loudly.
GO_TARGET_ARCH:=$(if $(filter aarch64,$(ARCH)),arm64,$(if $(filter x86_64,$(ARCH)),amd64,))

define Package/aether-xray
  SECTION:=net
  CATEGORY:=Network
  TITLE:=aether-xray, unpatched upstream Xray for the aether-proxy channel
  URL:=https://github.com/XTLS/Xray-core
  DEPENDS:=@(aarch64||x86_64) +ca-bundle
endef

define Package/aether-xray/description
  aether-xray built without patches from the upstream Xray source release by
  the aether-proxy update channel: a static binary (CGO disabled) installed
  as /usr/bin/aether-xray, leaving /usr/bin/xray to feeds/ssr-plus.
endef

GO_TOOLCHAIN_DIR:=$(PKG_BUILD_DIR)/.toolchain
GO_BUILD_ENV:= \
	GOROOT="$(GO_TOOLCHAIN_DIR)/go" \
	GOPATH="$(PKG_BUILD_DIR)/.gopath" \
	GOCACHE="$(PKG_BUILD_DIR)/.gocache" \
	GOTOOLCHAIN=local \
	GOFLAGS="-mod=readonly -modcacherw -trimpath" \
	CGO_ENABLED=0 \
	GOOS=linux \
	GOARCH="$(GO_TARGET_ARCH)"

define Build/Prepare
	$(call Build/Prepare/Default)
	mkdir -p "$(GO_TOOLCHAIN_DIR)"
	$(HOST_TAR) -C "$(GO_TOOLCHAIN_DIR)" -xzf "$(DL_DIR)/$(GO_TOOLCHAIN_FILE)"
endef

define Build/Compile
	@[ -n "$(GO_TARGET_ARCH)" ] || { echo "aether-xray: unsupported ARCH '$(ARCH)'" >&2; exit 1; }
	@[ "$(HOST_ARCH)" = x86_64 ] || { echo "aether-xray: the pinned Go toolchain is linux-amd64" >&2; exit 1; }
	cd "$(PKG_BUILD_DIR)" && env $(GO_BUILD_ENV) "$(GO_TOOLCHAIN_DIR)/go/bin/go" build \
		-ldflags "-s -w -buildid=" -o "$(PKG_BUILD_DIR)/aether-xray" ./main
endef

define Package/aether-xray/install
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/aether-xray $(1)/usr/bin/aether-xray
endef

$(eval $(call BuildPackage,aether-xray))
