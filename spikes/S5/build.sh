#!/bin/bash
v=$1; cd /workspace/openwrt/sdk-spike/sdk-$v
exec > /workspace/openwrt/sdk-spike/build-$v.log 2>&1
./scripts/feeds install aether-proxy luci-app-aether-proxy; echo "install rc=$?"
make defconfig; echo "defconfig rc=$?"
make package/feeds/aetherproxy/aether-proxy/compile V=s; echo "compile1 rc=$?"
make package/feeds/aetherproxy/luci-app-aether-proxy/compile V=s; echo "compile2 rc=$?"
