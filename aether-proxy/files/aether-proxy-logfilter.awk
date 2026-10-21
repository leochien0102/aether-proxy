# Limit each child's output before procd/logd (docs/09 "child process logs").
BEGIN {
	SECOND_LIMIT = 20
	MINUTE_LIMIT = 120
	WINDOW_SECONDS = 60
}

function summary() {
	if (!dropped)
		return
	# TODO(design): summary lines are not specified as part of the quota; keep them
	# outside it so a saturated minute cannot hide the loss notification.
	printf "aether-proxy: %s output rate limited, dropped %d lines between %s and %s\n", \
		name, dropped, strftime("%H:%M:%S", first_drop), strftime("%H:%M:%S", last_drop)
	fflush()
	dropped = 0
}

{
	now = systime()
	if (test_clock == 1) {
		now = $0 + 0
		sub(/^[0-9]+ /, "")
	}
	# TODO(design): window alignment and clock rollback are unspecified. A rolling
	# 60-second window prevents boundary bursts; clamp rollback to avoid new quota.
	if (now < previous)
		now = previous
	previous = now
	for (second in accepted) {
		if (second + 0 <= now - WINDOW_SECONDS) {
			minute_count -= accepted[second]
			delete accepted[second]
		}
	}
	if (accepted[now] < SECOND_LIMIT && minute_count < MINUTE_LIMIT) {
		summary()
		printf "%s\n", $0
		fflush()
		accepted[now]++
		minute_count++
	} else {
		if (!dropped)
			first_drop = now
		last_drop = now
		dropped++
	}
}

END { summary() }
