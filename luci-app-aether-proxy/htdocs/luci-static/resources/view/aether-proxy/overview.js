'use strict';
'require view';
'require rpc';

var callVersion = rpc.declare({
	object: 'aetherproxy',
	method: 'version'
});

return view.extend({
	load: function() {
		return callVersion();
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
