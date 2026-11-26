#!/usr/bin/env python3
"""HUP rollback error aggregation through the real daemon completion publisher.

Use the DNS readiness fixture and inject failed primitive *results* in its private
reload module copy. The real primitives still run, so each case can recover and
perform a subsequent successful HUP. This tests collection/publication, not OS
failure mechanics; production modules on disk are never instrumented.
"""
import importlib.util
import json
import pathlib
import signal
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('dns_ready', HERE / 'dns-ready.py')
dns = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dns)

# Actual rollback order: restore files, then reverse the three attempted actions.
ORDER = ['rollback_current', 'rollback_dnsmasq', 'rollback_dnsmasq_hup', 'rollback_nft']


def instrument(f):
    path = f.modules / 'reload.uc'
    source = path.read_text()

    def replace_once(old, new):
        nonlocal source
        assert source.count(old) == 1, ('fixture anchor changed', old)
        source = source.replace(old, new)

    def fault(name):
        return f"fs.access(`${{run_dir(daemon)}}/inject-{name}`, 'r')"

    # Force a deterministic three-action transaction while failure injection is
    # armed. All three real actions execute; the final result triggers rollback.
    anchor = '\tlet publication = publish_stage(daemon, stage, current, previous);'
    replace_once(anchor, "\tif (" + fault('forward') + ")\n"
                 "\t\tactions = [ 'nft_replace', 'restart_chinadns', 'dnsmasq_restart' ];\n" + anchor)
    anchor = '\t\tlet result = execute_action(daemon, action, artifacts, components);'
    replace_once(anchor, anchor + "\n\t\tif (action == 'dnsmasq_restart' && " + fault('forward') + ")\n"
                 "\t\t\tresult = { ok: false, detail: 'injected-forward' };")

    anchor = '\tlet restore_error = restore_current(daemon, previous, current, had_current);'
    replace_once(anchor, anchor + '\n\tif (' + fault('rollback_current') + ")\n"
                 "\t\trestore_error = 'injected-rollback_current';")
    for name, anchor, variable in [
        ('rollback_nft', '\t\t\tlet r = apply.nft_load(daemon.ctx, `${current}/${C.ARTIFACT_FILES.nft}`);', 'r'),
        ('rollback_dnsmasq_hup', '\t\t\t\tlet hup = apply.dnsmasq_hup(daemon.ctx);', 'hup'),
        ('rollback_dnsmasq', '\t\t\tlet r = apply.dnsmasq_install(daemon.ctx, old_artifacts.dnsmasq);', 'r'),
    ]:
        indent = anchor[:len(anchor) - len(anchor.lstrip())]
        replace_once(anchor, anchor + '\n' + indent + 'if (' + fault(name) + ')\n' + indent +
                     f"\t{variable} = {{ ok: false, detail: 'injected-{name}' }};")
    path.write_text(source)


def scenario(base, names):
    f = dns.ReloadFixture(base, '-'.join(names))
    instrument(f)
    with f.daemon() as proc:
        f.wait_running()
        before = f.state()
        old_hashes = before['render_hash']
        old_files = {p.name: p.read_bytes() for p in (f.run / 'current').iterdir() if p.is_file()}
        applied_before = len(f.events('RELOAD_APPLIED'))
        prior_at = before.get('last_reload', {}).get('at', 0)
        event_offset = len(f.events())
        for name in ['forward', *names]:
            (f.run / ('inject-' + name)).touch()
        f.set_mode('bypass_cn')
        proc.send_signal(signal.SIGHUP)
        dns.wait_for(lambda: f.state().get('last_reload', {}).get('at', 0) > prior_at,
                     label='rollback failure completion')
        state = f.state()
        last = state['last_reload']
        expected_names = [name for name in ORDER if name in names]
        expected_error = '; '.join(['dnsmasq_restart: injected-forward'] +
                                   [f'{name}: injected-{name}' for name in expected_names])
        dns.check(last['ok'] is False and last['error'] == expected_error,
                  'rollback reasons follow original error in execution order', json.dumps(last))
        dns.check(last['target_mode'] == 'bypass_cn' and last['target_node'] == before['node_id'],
                  'failed completion identifies attempted target', json.dumps(last))
        events = f.events()[event_offset:]
        rb_events = [e for e in events if e.get('args', {}).get('step', '').startswith('reload:rollback_')]
        dns.check([e['args']['step'] for e in rb_events] == ['reload:' + n for n in expected_names],
                  'independent rollback events retained without short circuit', json.dumps(rb_events))
        dns.check(all(e['code'] == 'START_FAILED' and e['args']['detail'] == 'injected-' + name
                      for e, name in zip(rb_events, expected_names)),
                  'independent events retain primitive reasons')
        terminal = [e for e in events if e.get('args', {}).get('step') == 'reload:actions']
        dns.check(len(terminal) == 1 and terminal[0]['args']['detail'] == expected_error,
                  'terminal action event agrees with published error', json.dumps(terminal))
        dns.check(len(f.events('RELOAD_APPLIED')) == applied_before,
                  'failed transaction emits no success event')
        dns.check(state['render_hash'] == old_hashes and state['mode'] == before['mode'] and
                  state['node_id'] == before['node_id'] and
                  all((f.run / 'current' / name).read_bytes() == data for name, data in old_files.items()),
                  'result injection leaves restored artifacts and applied metadata intact')

        for name in ['forward', *names]:
            (f.run / ('inject-' + name)).unlink()
        proc.send_signal(signal.SIGHUP)
        dns.wait_for(lambda: f.state().get('last_reload', {}).get('at', 0) > last['at'],
                     label='subsequent successful HUP completion')
        recovered = f.state()
        dns.check(recovered['last_reload']['ok'] is True and recovered['last_reload']['error'] is None and
                  recovered['mode'] == 'bypass_cn',
                  'subsequent successful HUP clears all rollback errors', json.dumps(recovered['last_reload']))
        dns.check(len(f.events('RELOAD_APPLIED')) == applied_before + 1,
                  'subsequent success emits exactly one applied event')


def main():
    with tempfile.TemporaryDirectory(prefix='reload-rollback-errors-') as tmp:
        base = pathlib.Path(tmp)
        for name in ORDER:
            scenario(base, [name])
        scenario(base, ORDER)
    print(f'rollback-errors: {dns.passed} passed, 0 failed', flush=True)


if __name__ == '__main__':
    main()
