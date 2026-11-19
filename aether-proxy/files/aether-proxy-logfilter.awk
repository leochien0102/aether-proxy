# Merge repeated child messages, then limit output before procd/logd (docs/09 "child process logs").
BEGIN {
	now = SESSION_START = previous = systime()
	STARTUP_SECONDS = 5
	SECOND_LIMIT = 20
	MINUTE_LIMIT = 120
	WINDOW_SECONDS = 60
	REPEAT_SECONDS = 10
	REPEAT_LIMIT = 32
	DNS_TIMESTAMP = "^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] " \
		"[0-9][0-9]:[0-9][0-9]:[0-9][0-9]"
	XRAY_TIMESTAMP = "^[0-9][0-9][0-9][0-9]/[0-9][0-9]/[0-9][0-9] " \
		"[0-9][0-9]:[0-9][0-9]:[0-9][0-9]([.][0-9]+)?"
	if (stats != "") {
		# A failed awk redirection is fatal. Let a shell consume the JSON before trying
		# to write it, so stats I/O errors cannot close the child's log FIFO (SIGPIPE).
		stats_writer = "set -- " shell_quote(stats) "; IFS= read -r line && " \
			"{ [ ! -L \"$1\" ] && { [ ! -e \"$1\" ] || [ -f \"$1\" ]; } && " \
			"{ umask 077; printf '%s\\n' \"$line\" > \"$1\"; }; }"
		for (i = 1; i < 32; i++)
			json_control[sprintf("%c", i)] = sprintf("\\u%04x", i)
		stats_name = json_string(name)
		write_stats()
	}
}

function shell_quote(value,    quote) {
	quote = sprintf("%c", 39)
	gsub(quote, quote "\"" quote "\"" quote, value)
	return quote value quote
}

function json_string(value,    i, c, out) {
	out = "\""
	for (i = 1; i <= length(value); i++) {
		c = substr(value, i, 1)
		out = out (c in json_control ? json_control[c] : (c == "\"" || c == "\\" ? "\\" c : c))
	}
	return out "\""
}

function write_stats() {
	if (stats == "")
		return
	printf "{\"name\":%s,\"accepted\":%d,\"dropped\":%d,\"first_drop\":%s,\"last_drop\":%s," \
		"\"second_limit\":%d,\"minute_limit\":%d}\n", \
		stats_name, total_accepted, total_dropped, total_dropped ? session_first_drop : "null", \
		total_dropped ? last_drop : "null", SECOND_LIMIT, MINUTE_LIMIT | stats_writer
	if (close(stats_writer) != 0)
		stats = ""
	last_stats_write = now
	last_stats_accepted = total_accepted
}

function summary() {
	# Summaries sit outside the quota so a saturated minute cannot hide the loss (docs/09).
	printf "aether-proxy: %s output rate limited, dropped %d lines between %s and %s, first: %s\n", \
		name, dropped, strftime("%H:%M:%S", first_drop), strftime("%H:%M:%S", last_drop), first_message
	fflush()
	write_stats()
}

function finish_drops() {
	# The first drop was already reported. Summarize the complete streak only if it grew.
	if (dropped > 1)
		summary()
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

function repeat_summary(    i, message, emitted) {
	# Stable first-seen order avoids depending on awk's associative-array iteration order.
	for (i = 1; i <= tracked; i++) {
		message = messages[i]
		if (repeats[message]) {
			printf "aether-proxy: %s repeated %d more times: %s\n", \
				name, repeats[message], substr(message, 1, 160)
			emitted = 1
		}
	}
	# Like rate-limit summaries, repetition summaries sit outside the output quota.
	fflush()
	if (emitted)
		write_stats()
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
		if (!seen_line) {
			SESSION_START = previous = (test_start == "" ? now : test_start + 0)
			last_stats_write = now
		}
		sub(/^[0-9]+ /, "")
	}
	# Rolling 60-second window (docs/09). A clock that went back (NTP correction, manual
	# change) restarts the counts: clamping to the last time would admit only one second's
	# quota until the clock caught up, silencing the child for as long as the jump.
	if (now < previous) {
		# Move the origin along with the clock; a rollback never renews startup grace.
		SESSION_START -= previous - now
		last_stats_write -= previous - now
		for (second in accepted)
			delete accepted[second]
		minute_count = 0
		# Discard the old deduplication window too: backward time starts afresh (docs/09).
		clear_repeats()
	}
	seen_line = 1
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
	if (minute_count < MINUTE_LIMIT && (now - SESSION_START < STARTUP_SECONDS || accepted[now] < SECOND_LIMIT)) {
		finish_drops()
		printf "%s\n", forwarded
		fflush()
		accepted[now]++
		minute_count++
		total_accepted++
		if (total_accepted == 1 || now - last_stats_write >= 5 || total_accepted - last_stats_accepted >= 50)
			write_stats()
		next
	}
	if (!dropped) {
		first_drop = now
		first_message = substr(forwarded, 1, 160)
	}
	if (!total_dropped)
		session_first_drop = now
	last_drop = now
	total_dropped++
	if (++dropped == 1)
		summary()
	else
		write_stats()
}

END {
	finish_drops()
	repeat_summary()
	write_stats()
}
