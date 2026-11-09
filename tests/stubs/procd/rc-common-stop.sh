# T15.10 fixture: stop sequence supplied verbatim by docs/tasks/m15.md.
# SDK rc.common SHA256: 143c915143c351bd96c5e8007d56e191b78975fd75a32709acd42243d68d230d
# This models rc.common dispatch, not the procd daemon or firmware library internals.
# Deliberately no set -e / hook short circuit: kill and callback still run on failure.
stop() {
	procd_lock
	stop_service "$@"
	procd_kill "$(basename ${basescript:-$initscript})" "$1"
	if eval "type service_stopped" 2>/dev/null >/dev/null; then
		service_stopped
	fi
}
