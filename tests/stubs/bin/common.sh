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
# ip(8) on a device: flushing an already empty table fails with ESRCH.
if [ "$name" = ip ] && [ "${STUB_IP_FLUSH_ESRCH:-0}" = 1 ]; then
	case " $* " in *" route flush "*) echo 'Failed to send flush request: No such process' >&2; exit 2 ;; esac
fi
if [ -n "$out" ]; then cat "$out"; fi
exit "$rc"
