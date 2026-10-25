'use strict';
'require baseclass';

/* Pure update-page decisions and messages, per docs/10 "更新页".
 * Asset availability comes from the CLI; never infer it from a version or arch.
 * Undefined status means the initial read is pending (docs/10 "其余页面先出页面").
 * Manual rollback is Xray-only, per docs/10 "r13：取消三包手动回滚".
 * Grouped forward updates follow docs/10 "B17：更新页显示「一起更新」的结果".
 */
const PACKAGES = [ 'xray-core', 'aether-proxy', 'luci-app-aether-proxy', 'luci-i18n-aether-proxy-zh-cn' ];
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
function can_rollback(name, entry) {
	// Older service packages may not understand the current configuration.
	if (name != 'xray-core' || !entry)
		return false;
	return entry.previous != null && entry.installed != null && entry.previous != entry.installed;
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
	const reason = messages[r.code] ?? r.code ?? _('Unknown', 'aether-proxy');
	return r.detail ? _('%s: %s', 'aether-proxy').format(reason, r.detail) : reason;
}
function companion_result(r) {
	// The backend reports only the first failed companion's cause at the top level.
	// The refresh sentence names no package: the interface itself may have failed.
	// Keep backend order rather than object insertion order when assigning that cause.
	const pages = [
		{ name: 'luci-app-aether-proxy', label: _('Interface', 'aether-proxy') },
		{ name: 'luci-i18n-aether-proxy-zh-cn', label: _('Translation', 'aether-proxy') }
	];
	const installed = pages.filter(p => r.companions[p.name] == 'installed');
	const failed = pages.filter(p => r.companions[p.name] == 'failed');
	if (r.ok === false && !failed.length)
		return failure(r);
	const updated = r.from != r.to;
	const parts = [];
	if (updated)
		parts.push(r.from == null ? _('%s installed: %s', 'aether-proxy').format(r.package, r.to) :
			_('%s updated from %s to %s', 'aether-proxy').format(r.package, r.from, r.to));
	if (installed.length) {
		const labels = installed.map(p => p.label).reduce((a, b) => _('%s, %s', 'aether-proxy').format(a, b));
		parts.push((updated ? _('%s updated together', 'aether-proxy') : _('%s updated', 'aether-proxy'))
			.format(labels));
	}
	failed.forEach((p, i) => {
		const text = _('%s update failed', 'aether-proxy').format(p.label);
		parts.push(i == 0 ? _('%s: %s', 'aether-proxy').format(text, failure(r)) : text);
	});
	if (!parts.length)
		parts.push(_('Already up to date', 'aether-proxy'));
	const text = _('%s.', 'aether-proxy').format(
		parts.reduce((a, b) => _('%s; %s', 'aether-proxy').format(a, b)));
	return installed.length ? _('%s %s', 'aether-proxy').format(text,
		_('Please refresh the page.', 'aether-proxy')) : text;
}
function package_result(name, r) {
	if (r.rolled_back)
		return _('Post-install check failed; rolled back to %s', 'aether-proxy').format(r.from);
	if (r.companions)
		return companion_result(r);
	if (!r.ok)
		return failure(r);
	const text = r.from == null ? _('%s installed: %s', 'aether-proxy').format(name, r.to) :
		_('%s updated from %s to %s', 'aether-proxy').format(name, r.from, r.to);
	return text + (restarts(name) ?
		' ' + _('Page files may have changed; please refresh your browser.', 'aether-proxy') : '');
}
return baseclass.extend({
	job_progress: function(kind, name, previous, status) {
		if (kind == 'update_check')
			return _('Checking for updates…', 'aether-proxy');
		if (previous)
			return _('Rolling back %s…', 'aether-proxy').format(name);
		if (name != 'aether-proxy' && name != 'luci-app-aether-proxy')
			return _('Installing %s…', 'aether-proxy').format(name);
		const text = _('Updating %s and its interface…', 'aether-proxy').format('aether-proxy');
		return status?.updates_available?.packages?.['aether-proxy']?.newer === true ?
			_('%s %s', 'aether-proxy').format(text,
				_('The service will be briefly interrupted.', 'aether-proxy')) : text;
	},
	manual_install_note: function() {
		return _('To install another version: download the three packages for that version from the release page, '
			+ 'then upload and install them on the system Software page, or use opkg install. '
			+ 'Before downgrading, note that older versions may not recognize newer settings; '
			+ 'restore the default configuration first if necessary.', 'aether-proxy');
	},
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
					rollback: can_rollback(name, p),
					disabled: pending || !!busy,
					rollback_label: _('Roll back to %s', 'aether-proxy').format(p?.previous ?? '–'),
					confirmation_title: _('Roll back %s', 'aether-proxy').format(name),
					confirmation: name == 'xray-core' && p ? this.confirmation(name, p.installed, p.previous) : ''
				};
			})
		};
	},
	confirmation: function(name, installed, previous) {
		return _('Install %s, replacing the current %s?', 'aether-proxy').format(previous, installed);
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
	job_result: function(kind, name, job) {
		// Job transport errors have no result; completed CLI failures do.
		const r = job.result ?? { ...job, code: job.code ?? job.error };
		if (kind == 'update_check') {
			if (r.ok === false || job.state == 'failed')
				return failure(r);
			const count = Object.values(r.packages ?? {}).filter(p => p.newer === true).length;
			return _('Check complete: %s packages have updates', 'aether-proxy').format(count);
		}
		return package_result(name, r);
	}
});
