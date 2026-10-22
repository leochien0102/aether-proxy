'use strict';

/* T10.37: load the merged view and its real subscription block with the same
 * injected UCI, form and RPC dependencies. Tests may inspect either controller,
 * but integration renders always go through the shipped nodes view. */
const path = require('node:path');
const { loadModule } = require('./loader');
const RES = path.resolve(__dirname, '../../luci-app-aether-proxy/htdocs/luci-static/resources');
function loadNodesPage(modules, env) {
	const dependencies = { ...modules, baseclass: { extend: props => props } };
	for (const name of ['nodes', 'subscriptions']) {
		const key = 'aether-proxy.model.' + name;
		dependencies[key] ??= loadModule(path.join(RES, 'aether-proxy/model', name + '.js'),
			{ baseclass: dependencies.baseclass }, {});
	}
	const subscriptions = loadModule(path.join(RES, 'aether-proxy/subscriptions-block.js'), dependencies, env);
	const view = loadModule(path.join(RES, 'view/aether-proxy/nodes.js'), {
		...dependencies, 'aether-proxy.subscriptions-block': subscriptions
	}, env);
	return { view, subscriptions };
}
module.exports = { loadNodesPage };
