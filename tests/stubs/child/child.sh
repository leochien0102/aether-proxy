#!/bin/sh
mode=$1

case "$mode" in
	crash)
		sleep 0.08
		exit 7
		;;
	ignore-term)
		trap '' TERM
		exec sleep 60
		;;
	hold)
		exec sleep 60
		;;
	*)
		exit 64
		;;
esac
