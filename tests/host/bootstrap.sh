#!/usr/bin/env bash
# Build json-c (only if missing), libubox, uci and ucode from source into
# tests/host/prefix. Idempotent: each component records its commit in
# prefix/.stamp/<name>; a matching stamp skips the build entirely.
# Needs only: git, cmake, make, a C compiler, pkg-config. No root required.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="$HERE/prefix"
SRC="$HERE/src"
STAMP="$PREFIX/.stamp"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"

# Pinned revisions.
# ucode: oldest supported release, OpenWrt 24.10 ucode 2025.07.18 (docs/12-ucode.md).
UCODE_REV=3f64c8089bf3ea4847c96b91df09fbfcaec19e1d
# libubox / uci: PKG_SOURCE_VERSION in the openwrt-24.10 branch of openwrt/openwrt
# (package/libs/libubox/Makefile dated 2025-07-23, package/system/uci/Makefile dated 2025-01-20).
LIBUBOX_REV=49056d178f42da98048a5d4c23f83a6f6bc6dd80
UCI_REV=16ff0badbde7e17ec3bd1f827ffe45922956cf86
# json-c: only built when pkg-config cannot find it (OpenWrt 24.10 ships 0.18).
JSONC_REV=41a55cfcedb54d9c1874f2f0eb07b504091d7e37 # tag json-c-0.18-20240915

UCODE_URLS=(https://github.com/jow-/ucode.git)
LIBUBOX_URLS=(https://git.openwrt.org/project/libubox.git https://github.com/openwrt/libubox.git)
UCI_URLS=(https://git.openwrt.org/project/uci.git https://github.com/openwrt/uci.git)
JSONC_URLS=(https://github.com/json-c/json-c.git)

# Print the exact revision list for CI cache keys: `bootstrap.sh --revs`.
if [ "${1:-}" = "--revs" ]; then
	echo "ucode=$UCODE_REV libubox=$LIBUBOX_REV uci=$UCI_REV json-c=$JSONC_REV"
	exit 0
fi

mkdir -p "$PREFIX" "$SRC" "$STAMP"

# Decide on json-c before our prefix is added to the search path.
if pkg-config --exists json-c; then SYSTEM_JSONC=1; else SYSTEM_JSONC=0; fi
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"

done_already() { [ "$(cat "$STAMP/$1" 2>/dev/null || true)" = "$2" ]; }

# fetch <name> <rev> <url...>: check out exactly <rev> into $SRC/<name>.
fetch() {
	local name=$1 rev=$2; shift 2
	local dir="$SRC/$name" url
	if [ -d "$dir/.git" ] && [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)" = "$rev" ]; then
		return 0
	fi
	rm -rf "$dir"
	for url in "$@"; do
		git init -q "$dir"
		git -C "$dir" remote add origin "$url"
		# Fetching by sha needs server support; fall back to a full fetch.
		if git -C "$dir" fetch -q --depth 1 origin "$rev" 2>/dev/null ||
		   git -C "$dir" fetch -q --tags origin 2>/dev/null; then
			if git -C "$dir" checkout -q --detach "$rev"; then
				return 0
			fi
		fi
		echo "bootstrap: fetching $name from $url failed, trying next mirror" >&2
		rm -rf "$dir"
	done
	echo "bootstrap: cannot fetch $name at $rev" >&2
	return 1
}

# Note -Wno-error=discarded-qualifiers: the pinned ucode trips -Werror on newer glibc (const strrchr).
# build <name> <rev> <cmake args...>
build() {
	local name=$1 rev=$2; shift 2
	echo "bootstrap: building $name @ ${rev:0:8}"
	rm -rf "$SRC/$name/build"
	cmake -S "$SRC/$name" -B "$SRC/$name/build" \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_INSTALL_PREFIX="$PREFIX" \
		-DCMAKE_PREFIX_PATH="$PREFIX" \
		-DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
		-DCMAKE_INSTALL_LIBDIR=lib \
		-DCMAKE_C_FLAGS="-Wno-error=discarded-qualifiers" \
		"$@" > "$SRC/$name/build.log" 2>&1 || { tail -30 "$SRC/$name/build.log"; return 1; }
	cmake --build "$SRC/$name/build" -j "$JOBS" >> "$SRC/$name/build.log" 2>&1 || { tail -30 "$SRC/$name/build.log"; return 1; }
	cmake --install "$SRC/$name/build" >> "$SRC/$name/build.log" 2>&1 || { tail -30 "$SRC/$name/build.log"; return 1; }
	echo "$rev" > "$STAMP/$name"
}

# json-c: use the system one when pkg-config finds it.
if [ "$SYSTEM_JSONC" = 1 ]; then
	echo "bootstrap: using system json-c"
elif ! done_already json-c "$JSONC_REV"; then
	fetch json-c "$JSONC_REV" "${JSONC_URLS[@]}"
	build json-c "$JSONC_REV" -DBUILD_SHARED_LIBS=ON -DBUILD_STATIC_LIBS=OFF -DBUILD_TESTING=OFF -DDISABLE_WERROR=ON
fi

if ! done_already libubox "$LIBUBOX_REV"; then
	fetch libubox "$LIBUBOX_REV" "${LIBUBOX_URLS[@]}"
	build libubox "$LIBUBOX_REV" -DBUILD_LUA=OFF -DBUILD_EXAMPLES=OFF -DBUILD_STATIC=OFF
fi

if ! done_already uci "$UCI_REV"; then
	fetch uci "$UCI_REV" "${UCI_URLS[@]}"
	build uci "$UCI_REV" -DBUILD_LUA=OFF -DBUILD_STATIC=OFF
fi

# The ucode stamp also covers the dependency revisions it was linked against.
UCODE_STAMP="$UCODE_REV+$LIBUBOX_REV+$UCI_REV"
if ! done_already ucode "$UCODE_STAMP"; then
	fetch ucode "$UCODE_REV" "${UCODE_URLS[@]}"
	build ucode "$UCODE_STAMP" -DUCI_SUPPORT=ON -DULOOP_SUPPORT=ON -DUBUS_SUPPORT=OFF \
		-DRTNL_SUPPORT=OFF -DNL80211_SUPPORT=OFF
fi

"$HERE/ucode" -e 'import * as uci from "uci"; import * as fs from "fs"; print("bootstrap: ready, ucode modules uci+fs load OK\n")'
