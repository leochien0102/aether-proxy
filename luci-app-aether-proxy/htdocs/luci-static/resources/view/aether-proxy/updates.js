'use strict';
'require view';

return view.extend({
	render: function() {
		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Updates')),
			E('p', {}, _('This page has not been implemented yet.'))
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null
});
