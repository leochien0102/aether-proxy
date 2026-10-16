'use strict';
'require baseclass';

/* Pure update-page decisions and messages, per docs/10 "更新页".
 * Asset availability comes from the CLI; never infer it from a version or arch.
 */
const PACKAGES = [ 'xray-core', 'aether-proxy', 'luci-app-aether-proxy', 'luci-i18n-aether-proxy-zh-cn' ];
function restarts(name) {
	return name != 'xray-core';
}
function relative(at, now) {
	if (at == null)
		return _('Not checked yet');
	const seconds = Math.max(0, Math.floor(now - at));
	if (seconds < 60)
		return _('%s seconds ago').format(seconds);
	if (seconds < 3600)
		return _('%s minutes ago').format(Math.floor(seconds / 60));
	if (seconds < 86400)
		return _('%s hours ago').format(Math.floor(seconds / 3600));
	return _('%s days ago').format(Math.floor(seconds / 86400));
}
function failure(r) {
	const messages = {
		UPDATE_FETCH_FAILED: _('Cannot reach the release channel'),
		MANIFEST_BAD_SIGNATURE: _('Signature verification failed'),
		CONFIG_INVALID: _('No usable channel URL'),
		BUSY: _('Another update job is running'),
		JOB_LOST: _('Job process exited unexpectedly'),
		UPDATE_VERIFY_FAILED: _('Verification failed'),
		NO_SPACE: _('Not enough space'),
		ARCH_UNSUPPORTED: _('Unavailable on this device')
	};
	return (messages[r.code] ?? r.code ?? _('Unknown')) + (r.detail ? ': ' + r.detail : '');
}
return baseclass.extend({
	validate_url: function(value) {
		return /^https?:\/\/[^\/?#\s]+[^\s]*$/.test(value) || _('Enter an HTTP or HTTPS URL without whitespace');
	},
	table: function(status, busy, now) {
		const updates = status.updates_available;
		return {
			error: status.ok === false ? failure(status) : null,
			checked: relative(updates?.checked, now), url: updates?.url ?? '–',
			can_check: !busy,
			rows: PACKAGES.map(name => {
				const p = updates?.packages?.[name];
				let text;
				if (!updates)
					text = _('Not checked');
				else if (!p)
					text = _('Not in channel');
				else if (p.asset == null)
					text = _('Unavailable on this device') + ' (' + updates.arch + ')';
				else if (p.installed == null)
					text = _('Not installed');
				else
					text = p.newer ? _('Update available') : _('Up to date');
				return {
					name, installed: p ? (p.installed ?? _('Not installed')) : '–',
					available: p?.available ?? '–', previous: p?.previous ?? '–', status: text,
					install: !!p && p.asset != null && p.installed == null,
					update: !!p && p.asset != null && p.installed != null && p.newer === true,
					rollback: !!p && p.previous != null && p.installed != null && p.previous != p.installed,
					disabled: !!busy,
					rollback_label: _('Roll back to %s').format(p?.previous ?? '–'),
					confirmation: p ? this.confirmation(name, p.installed, p.previous) : ''
				};
			})
		};
	},
	confirmation: function(name, installed, previous) {
		return _('Install %s, replacing the current %s?').format(previous, installed) +
			(restarts(name) ? ' ' + _('The service will restart.') : '');
	},
	components: function(status) {
		return [ 'xray', 'chinadns-ng' ].map(name => ({
			name, version: status.components?.[name]?.version ?? _('Unknown'),
			path: status.components?.[name]?.path ?? '–',
			note: name == 'chinadns-ng' ?
				_('Not in the release channel; install or update from feeds on the Software page.') +
				(status.updates_available ? ' (' + status.updates_available.arch + ')' : '') : ''
		}));
	},
	job_result: function(kind, name, job) {
		// Job transport errors have no result; completed CLI failures do.
		const r = job.result ?? { ...job, code: job.code ?? job.error };
		if (kind == 'update_check') {
			if (r.ok === false || job.state == 'failed')
				return failure(r);
			const count = Object.values(r.packages ?? {}).filter(p => p.newer === true).length;
			return _('Check complete: %s packages have updates').format(count);
		}
		if (r.rolled_back)
			return _('Post-install check failed; rolled back to %s').format(r.from);
		if (!r.ok)
			return failure(r);
		const text = r.from == null ? _('%s installed: %s').format(name, r.to) :
			_('%s updated from %s to %s').format(name, r.from, r.to);
		return text + (restarts(name) ? ' ' + _('Page files may have changed; please refresh your browser.') : '');
	}
});
