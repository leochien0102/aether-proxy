'use strict';
'require view';
'require aether-proxy.common as ap';

return view.extend({
	load: function() {
		return ap.call('version');
	},

	render: function(res) {
		var text = (res && res.version)
			? 'aether-proxy ' + res.version
			: _('Unable to read the version.');

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('aether-proxy')),
			E('p', {}, text)
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
