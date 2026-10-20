#!/bin/sh
name=$1
shift
stub_dir=$(dirname "$0")
. "$stub_dir/../stub.env"
printf '%s %s\n' "$name" "$*" >>"$STUB_LOG"
case "$name" in
	nft) rc=${STUB_NFT_RC:-0}; out=${STUB_NFT_OUT_FILE:-} ;;
	ip) rc=${STUB_IP_RC:-0}; out=${STUB_IP_OUT_FILE:-} ;;
	resolveip) rc=${STUB_RESOLVEIP_RC:-0}; out=${STUB_RESOLVEIP_OUT_FILE:-} ;;
	killall) rc=${STUB_KILLALL_RC:-1}; out=${STUB_KILLALL_OUT_FILE:-} ;;
esac
# T9.5: opt-in numbered DNS responses; absent entries retain the original behavior.
if [ "$name" = resolveip ] && [ -n "${STUB_RESOLVEIP_SEQUENCE:-}" ]; then
	count=0
	if [ -f "$STUB_RESOLVEIP_SEQUENCE/count" ]; then read -r count < "$STUB_RESOLVEIP_SEQUENCE/count"; fi
	count=$((count + 1))
	printf '%s\n' "$count" > "$STUB_RESOLVEIP_SEQUENCE/count"
	if [ -f "$STUB_RESOLVEIP_SEQUENCE/$count.rc" ]; then
		read -r rc < "$STUB_RESOLVEIP_SEQUENCE/$count.rc"
	fi
	if [ -f "$STUB_RESOLVEIP_SEQUENCE/$count.out" ]; then out="$STUB_RESOLVEIP_SEQUENCE/$count.out"; fi
fi
if [ "$name" = nft ]; then
	case " $* " in
		*" gfw4 "*) out=${STUB_NFT_GFW4_OUT_FILE:-$out} ;;
		*" udirect4 "*) out=${STUB_NFT_UDIRECT4_OUT_FILE:-$out} ;;
		*" uproxy4 "*) out=${STUB_NFT_UPROXY4_OUT_FILE:-$out} ;;
	esac
fi
if [ "$name" = ip ] && [ -n "${STUB_IP_RULES_FILE:-}" ]; then
	case " $* " in
		*" rule show "*) out=$STUB_IP_RULES_FILE ;;
		*" rule add "*) printf '%s\n' "${STUB_IP_RULE_LINE:-}" >>"$STUB_IP_RULES_FILE" ;;
		*" rule del "*) sed '1d' "$STUB_IP_RULES_FILE" >"$STUB_IP_RULES_FILE.tmp"; mv "$STUB_IP_RULES_FILE.tmp" "$STUB_IP_RULES_FILE" ;;
	esac
fi
# ip(8) on a device: flushing an already empty table fails; the wording differs between
# builds (STUB_IP_FLUSH_ERR), ESRCH being the first one seen.
[ "${STUB_IP_FLUSH_ESRCH:-0}" = 1 ] && STUB_IP_FLUSH_ERR='Failed to send flush request: No such process'
if [ "$name" = ip ] && [ -n "${STUB_IP_FLUSH_ERR:-}" ]; then
	case " $* " in *" route flush "*) echo "$STUB_IP_FLUSH_ERR" >&2; exit 2 ;; esac
fi
# Linux 6.18 / iproute2 6.18 (H28K): per-table show/flush fail while table 233 never existed;
# `show table all` still works.
if [ "$name" = ip ] && [ "${STUB_IP_TABLE_MISSING:-0}" = 1 ]; then
	case " $* " in
		*" route show table 233 "*) echo 'Dump terminated' >&2; exit 2 ;;
		*" route flush "*) echo 'Flush terminated' >&2; exit 2 ;;
	esac
fi
# `ip -4 route show table all`: STUB_IP_ROUTES_FILE holds the routes present (none by default).
if [ "$name" = ip ]; then
	case " $* " in *" route show table all "*) [ -n "${STUB_IP_ROUTES_FILE:-}" ] && cat "$STUB_IP_ROUTES_FILE"; exit 0 ;; esac
fi
if [ -n "$out" ]; then cat "$out"; fi
exit "$rc"
