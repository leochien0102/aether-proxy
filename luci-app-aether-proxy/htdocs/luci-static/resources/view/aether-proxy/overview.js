'use strict';
'require view';
'require rpc';

var callStatus = rpc.declare({
	object: 'aetherproxy',
	method: 'status'
});

return view.extend({
	load: function() {
		return callStatus();
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
