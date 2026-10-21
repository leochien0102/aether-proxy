# Limit each child's output before procd/logd (docs/09 "child process logs").
BEGIN {
	SECOND_LIMIT = 20
	MINUTE_LIMIT = 120
	WINDOW_SECONDS = 60
}

function summary() {
	if (!dropped)
		return
	# Summaries sit outside the quota so a saturated minute cannot hide the loss (docs/09).
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
	# Rolling 60-second window (docs/09). A clock that went back (NTP correction, manual
	# change) restarts the counts: clamping to the last time would admit only one second's
	# quota until the clock caught up, silencing the child for as long as the jump.
	if (now < previous) {
		for (second in accepted)
			delete accepted[second]
		minute_count = 0
	}
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
