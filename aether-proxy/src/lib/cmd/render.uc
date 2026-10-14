'use strict';

// `aether-proxy render <xray|nft|chinadns|dnsmasq>`: prints one artifact to stdout (docs/10).

import * as C from 'aetherproxy.const';
import * as pipeline from 'aetherproxy.pipeline';

const USAGE = 'Usage: aether-proxy render <xray|nft|chinadns|dnsmasq> [--json]';

export function run(args) {
	let p = pipeline.parse_args(args);

	// TODO(design): docs/10 has no event code for usage errors; the JSON uses "USAGE".
	if (p.error || length(p.positional) != 1 || C.ARTIFACT_FILES[p.positional[0]] == null) {
		let detail = p.error ?? (length(p.positional) ? `unknown artifact '${join(' ', p.positional)}'` : 'artifact name missing');
		let json = !!(p.opts?.json || index(args, '--json') >= 0);

		return pipeline.finish({ json }, { ok: false, code: 'USAGE', detail, errors: [] }, 2, `${detail}\n${USAGE}`);
	}

	let name = p.positional[0];
	let res = pipeline.build(p.opts);

	if (!res.ok)
		return pipeline.finish(p.opts, { ok: false, code: res.code, detail: res.detail, errors: res.errors }, res.exit, pipeline.describe_errors(res));

	if (p.opts.json) {
		print(sprintf('%.J', { ok: true, name, file: C.ARTIFACT_FILES[name], content: res.artifacts[name] }), '\n');
		return 0;
	}

	// Artifacts end with exactly one newline already.
	print(res.artifacts[name]);
	return 0;
};
