# Merge repeated child messages, then limit output before procd/logd (docs/09 "child process logs").
BEGIN {
	SECOND_LIMIT = 20
	MINUTE_LIMIT = 120
	WINDOW_SECONDS = 60
	REPEAT_SECONDS = 10
	REPEAT_LIMIT = 32
	DNS_TIMESTAMP = "^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] " \
		"[0-9][0-9]:[0-9][0-9]:[0-9][0-9]"
	XRAY_TIMESTAMP = "^[0-9][0-9][0-9][0-9]/[0-9][0-9]/[0-9][0-9] " \
		"[0-9][0-9]:[0-9][0-9]:[0-9][0-9]([.][0-9]+)?"
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

# Forwarded text (docs/09): drop every ESC[...m, then a leading timestamp and the whitespace
# after it. Lines without a recognized timestamp only lose the colour codes. The result is
# also the deduplication key.
# chinadns-ng's level letter (W/I/E) stays at the start ("W [Upstream.zig..."), docs/09.
# Spell out digit classes rather than intervals or awk extensions for firmware BusyBox awk.
function message_key(line, message) {
	message = line
	gsub(/\033\[[0-9;]*m/, "", message)
	if (sub(DNS_TIMESTAMP, "", message) || sub(XRAY_TIMESTAMP, "", message))
		sub(/^[ \t]+/, "", message)
	return message
}

function repeat_summary(    i, message) {
	# Stable first-seen order avoids depending on awk's associative-array iteration order.
	for (i = 1; i <= tracked; i++) {
		message = messages[i]
		if (repeats[message])
			printf "aether-proxy: %s repeated %d more times: %s\n", \
				name, repeats[message], substr(message, 1, 160)
	}
	# Like rate-limit summaries, repetition summaries sit outside the output quota.
	fflush()
}

function clear_repeats(    i) {
	for (i = 1; i <= tracked; i++) {
		delete repeats[messages[i]]
		delete messages[i]
	}
	tracked = 0
	window_active = 0
}

# Free the earliest tracked slot whose repeat count is 0 (docs/09 "跟踪位满时让位"); later
# entries shift down so the table stays in first-seen order. Returns 0 when every slot repeats.
function make_room(    i, j) {
	for (i = 1; i <= tracked; i++) {
		if (repeats[messages[i]])
			continue
		delete repeats[messages[i]]
		for (j = i; j < tracked; j++)
			messages[j] = messages[j + 1]
		delete messages[tracked]
		tracked--
		return 1
	}
	return 0
}

function duplicate(message) {
	if (message in repeats) {
		repeats[message]++
		return 1
	}
	if (tracked >= REPEAT_LIMIT)
		make_room()
	if (tracked < REPEAT_LIMIT) {
		messages[++tracked] = message
		# Tracked even if the rate limit then drops this first line (docs/09):
		# retries cannot take more quota, and the summary still carries the message.
		repeats[message] = 0
	}
	return 0
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
		# Discard the old deduplication window too: backward time starts afresh (docs/09).
		clear_repeats()
	}
	previous = now
	if (window_active && now - repeat_start >= REPEAT_SECONDS) {
		repeat_summary()
		clear_repeats()
	}
	if (!window_active) {
		repeat_start = now
		window_active = 1
	}
	# Duplicates never reach the quota accounting, including its dropped-line counter.
	forwarded = message_key($0)
	if (duplicate(forwarded))
		next
	for (second in accepted) {
		if (second + 0 <= now - WINDOW_SECONDS) {
			minute_count -= accepted[second]
			delete accepted[second]
		}
	}
	if (accepted[now] < SECOND_LIMIT && minute_count < MINUTE_LIMIT) {
		summary()
		printf "%s\n", forwarded
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

END {
	summary()
	repeat_summary()
}
