'use strict';
'require baseclass';

/* Pure update-page decisions and messages, per docs/10 "更新页".
 * Asset availability comes from the CLI; never infer it from a version or arch.
 * Undefined status means the initial read is pending (docs/10 "其余页面先出页面").
 * Grouped rollback messages follow docs/10 "更新页：回滚一起回滚".
 */
const PACKAGES = [ 'xray-core', 'aether-proxy', 'luci-app-aether-proxy', 'luci-i18n-aether-proxy-zh-cn' ];
const ROLLBACK_GROUP = PACKAGES.slice(1);
const PAGE_PACKAGES = ROLLBACK_GROUP.slice(1);
function rolls_back_together(name) {
	return name == 'aether-proxy' || name == 'luci-app-aether-proxy';
}
function grouped_confirmation(status) {
	const packages = status?.updates_available?.packages;
	return [ _('These three packages will be rolled back together to keep the page and backend at the same version:',
		'aether-proxy'), ...ROLLBACK_GROUP.map(name => {
		const p = packages?.[name];
		return p?.installed != null && p?.previous != null ?
			_('%s: %s → %s', 'aether-proxy').format(name, p.installed, p.previous) :
			_('%s: skip (not installed or no previous version available)', 'aether-proxy').format(name);
	}) ];
}
/* Keep whitespace out of msgids: po2lmo stores it but _() trims it, so a
   leading space never matches on the device (m10 X3). English needs a space
   before an ASCII parenthesis; the Chinese full-width one needs none. */
function arch_note(arch) {
	const note = _('(device architecture %s)', 'aether-proxy').format(arch);
	return (note.startsWith('(') ? ' ' : '') + note;
}
function restarts(name) {
	return name != 'xray-core';
}
function relative(at, now) {
	if (at == null)
		return _('Not checked yet', 'aether-proxy');
	const seconds = Math.max(0, Math.floor(now - at));
	if (seconds < 60)
		return _('%s seconds ago', 'aether-proxy').format(seconds);
	if (seconds < 3600)
		return _('%s minutes ago', 'aether-proxy').format(Math.floor(seconds / 60));
	if (seconds < 86400)
		return _('%s hours ago', 'aether-proxy').format(Math.floor(seconds / 3600));
	return _('%s days ago', 'aether-proxy').format(Math.floor(seconds / 86400));
}
function failure(r) {
	const messages = {
		UPDATE_FETCH_FAILED: _('Cannot reach the release channel', 'aether-proxy'),
		MANIFEST_BAD_SIGNATURE: _('Signature verification failed', 'aether-proxy'),
		CONFIG_INVALID: _('No usable channel URL', 'aether-proxy'),
		BUSY: _('Another update job is running', 'aether-proxy'),
		JOB_LOST: _('Job process exited unexpectedly', 'aether-proxy'),
		UPDATE_VERIFY_FAILED: _('Verification failed', 'aether-proxy'),
		NO_SPACE: _('Not enough space', 'aether-proxy'),
		ARCH_UNSUPPORTED: _('Unavailable on this device', 'aether-proxy')
	};
	return (messages[r.code] ?? r.code ?? _('Unknown', 'aether-proxy')) + (r.detail ? ': ' + r.detail : '');
}
function package_result(name, r) {
	if (r.rolled_back)
		return _('Post-install check failed; rolled back to %s', 'aether-proxy').format(r.from);
	if (!r.ok)
		return failure(r);
	const text = r.from == null ? _('%s installed: %s', 'aether-proxy').format(name, r.to) :
		_('%s updated from %s to %s', 'aether-proxy').format(name, r.from, r.to);
	return text + (restarts(name) ?
		' ' + _('Page files may have changed; please refresh your browser.', 'aether-proxy') : '');
}
function grouped_result(r) {
	const companions = r.companions ?? {};
	const states = Object.values(companions);
	// A companion is only attempted after backend verification has passed.
	const backend_ok = r.ok || states.some(state => state == 'rolled_back' || state == 'failed');
	const lines = [ backend_ok ?
		_('%s: rolled back to %s', 'aether-proxy').format('aether-proxy', r.to) :
		(r.rolled_back ? failure(r) + ' — ' : '') + package_result('aether-proxy', r) ];
	const labels = {
		rolled_back: _('Rolled back', 'aether-proxy'),
		skipped: _('Skipped', 'aether-proxy'),
		failed: _('Failed', 'aether-proxy')
	};
	for (const [name, state] of Object.entries(companions))
		lines.push(name + ': ' + (labels[state] ?? state));
	if (backend_ok && !r.ok)
		lines.push(failure(r));
	if (states.includes('failed'))
		lines.push(_('Backend rolled back; page files are still newer. Try rolling back again or reinstalling.',
			'aether-proxy'));
	// Without companions (the job itself could not be read) nothing is known about them.
	else if (!backend_ok && r.companions)
		lines.push(_('The two page packages were not changed.', 'aether-proxy'));
	return lines.join('\n');
}
return baseclass.extend({
	validate_url: function(value) {
		return /^https?:\/\/[^\/?#\s]+[^\s]*$/.test(value) ||
			_('Enter an HTTP or HTTPS URL without whitespace', 'aether-proxy');
	},
	table: function(status, busy, now) {
		const pending = status === undefined;
		const loading = _('Reading…', 'aether-proxy');
		const updates = status?.updates_available;
		return {
			error: status?.ok === false ? failure(status) : null,
			checked: pending ? loading : relative(updates?.checked, now), url: updates?.url ?? '–',
			can_check: !pending && !busy,
			rows: PACKAGES.map(name => {
				const p = updates?.packages?.[name];
				let text;
				if (pending)
					text = loading;
				else if (!updates)
					text = _('Not checked', 'aether-proxy');
				else if (!p)
					text = _('Not in channel', 'aether-proxy');
				else if (p.asset == null)
					text = _('Unavailable on this device', 'aether-proxy') + ' (' + updates.arch + ')';
				else if (p.installed == null)
					text = _('Not installed', 'aether-proxy');
				else
					text = p.newer ? _('Update available', 'aether-proxy') : _('Up to date', 'aether-proxy');
				return {
					name,
					installed: pending ? loading : (p ? (p.installed ?? _('Not installed', 'aether-proxy')) : '–'),
					available: pending ? loading : (p?.available ?? '–'),
					previous: pending ? loading : (p?.previous ?? '–'), status: text,
					install: !!p && p.asset != null && p.installed == null,
					update: !!p && p.asset != null && p.installed != null && p.newer === true,
					rollback: !!p && p.previous != null && p.installed != null && p.previous != p.installed,
					disabled: pending || !!busy,
					rollback_label: _('Roll back to %s', 'aether-proxy').format(p?.previous ?? '–'),
					confirmation_title: rolls_back_together(name) ? _('Roll back Aether Proxy', 'aether-proxy') :
						_('Roll back %s', 'aether-proxy').format(name),
					confirmation: rolls_back_together(name) ? grouped_confirmation(status) :
						(p ? this.confirmation(name, p.installed, p.previous) : '')
				};
			})
		};
	},
	confirmation: function(name, installed, previous) {
		return _('Install %s, replacing the current %s?', 'aether-proxy').format(previous, installed) +
			(restarts(name) ? ' ' + _('The service will restart.', 'aether-proxy') : '');
	},
	components: function(status) {
		const pending = status === undefined;
		const loading = _('Reading…', 'aether-proxy');
		return [ 'xray', 'chinadns-ng' ].map(name => ({
			name, version: pending ? loading : (status?.components?.[name]?.version ?? _('Unknown', 'aether-proxy')),
			path: pending ? loading : (status?.components?.[name]?.path ?? '–'),
			note: !pending && name == 'chinadns-ng' ?
				_('Not automatically updated through the release channel: '
					+ 'install or update from feeds on the Software page, '
					+ 'or download the chinadns-ng package%s from the release page and install it manually.',
					'aether-proxy')
					.format(status?.updates_available ? arch_note(status.updates_available.arch) : '') : ''
		}));
	},
	page_rolled_back: function(job) {
		return PAGE_PACKAGES.some(name => job.result?.companions?.[name] == 'rolled_back');
	},
	job_result: function(kind, name, job, previous) {
		// Job transport errors have no result; completed CLI failures do.
		const r = job.result ?? { ...job, code: job.code ?? job.error };
		if (kind == 'update_check') {
			if (r.ok === false || job.state == 'failed')
				return failure(r);
			const count = Object.values(r.packages ?? {}).filter(p => p.newer === true).length;
			return _('Check complete: %s packages have updates', 'aether-proxy').format(count);
		}
		if (previous && rolls_back_together(name))
			return grouped_result(r);
		return package_result(name, r);
	}
});
