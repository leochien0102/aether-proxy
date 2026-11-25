'use strict';
'require baseclass';

const releases = /* @RELEASES@ */ [];
return baseclass.extend({
	releases: releases,
	url: function(version) {
		return typeof version == 'string' && version === version.trim() && /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)-r[1-9]\d*$/.test(version) ?
			'https://github.com/leochien0102/aether-proxy/releases/tag/v' + version : null;
	},
	render: function(installed) {
		const current = releases.find(r => r.version === installed);
		const versions = current ? [current, ...releases.filter(r => r !== current)] : releases;
		return E('div', { style: 'overflow-wrap:anywhere; min-width:0' }, [
			E('p', {}, [ _('Installed application version', 'aether-proxy'), ': ', installed ?? _('Unknown', 'aether-proxy') ]),
			E('p', {}, _('Bundled summaries are available offline. Release links require internet access.', 'aether-proxy')),
			...(!current ? [ E('p', {}, _('No bundled summary for the installed application version.', 'aether-proxy')) ] : []),
			...versions.map(r => E('details', { open: r === current || null }, [
				E('summary', {}, [r.version]),
				...(r.changes.length ? [ E('h4', {}, _('Main changes', 'aether-proxy')),
					E('ul', {}, r.changes.map(text => E('li', {}, [text]))) ] :
					[ E('p', {}, _('No bundled summary for this version.', 'aether-proxy')) ]),
				...(r.notes.length ? [ E('h4', {}, _('Upgrade notes', 'aether-proxy')),
					E('ul', {}, r.notes.map(text => E('li', {}, [text]))) ] : []),
				E('a', { href: this.url(r.version), target: '_blank', rel: 'noopener noreferrer' },
					_('Formal release (online)', 'aether-proxy'))
			]))
		]);
	}
});
