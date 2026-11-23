#!/usr/bin/env python3
"""Offline regression: real Git ranges + production selector/detect, no CI dispatch.

Only stdlib is required. Read the workflow's relevant YAML blocks by indentation
and fail closed if their structure changes, rather than testing a mapping copy.
"""
import fnmatch
import os
from pathlib import Path
import re
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = (ROOT / '.github/workflows/build.yml').read_text()
SELECTOR = ROOT / 'tools/ci/changed-components.sh'
ALL = {'aether-proxy', 'luci-app-aether-proxy', 'aether-xray',
       'chinadns-ng', 'aether-dns'}


def block(text, name, indent):
    """Get exactly one named YAML mapping block, without a YAML dependency."""
    pattern = rf'^{" " * indent}{re.escape(name)}:\n((?:^ {{%d,}}[^\n]*\n|^\n)*)' % (indent + 1)
    matches = re.findall(pattern, text, re.MULTILINE)
    if len(matches) != 1:
        raise AssertionError(f'expected one {name!r} block at indent {indent}')
    return matches[0]


ON = block(WORKFLOW, 'on', 0)
DETECT = block(block(WORKFLOW, 'jobs', 0), 'detect', 2)
def detect_run(workflow):
    detect = block(block(workflow, 'jobs', 0), 'detect', 2)
    # A literal block has a "|" value, unlike the mapping blocks above.
    match = re.search(r'^        run: \|\n((?:^          .*\n|^\n)+)', detect, re.MULTILINE)
    if match is None:
        raise AssertionError('detect must expose its shell run block')
    return textwrap.dedent(match[1])


RUN = detect_run(WORKFLOW)
ENV = block(DETECT, 'env', 8)
ENV_BINDINGS = dict(re.findall(r'^          (\w+): (.+)$', ENV, re.MULTILINE))
SMOKE = block(block(WORKFLOW, 'jobs', 0), 'smoke', 2)


class BuildScope(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='build-scope-')
        self.addCleanup(self.tmp.cleanup)
        self.repo = Path(self.tmp.name)
        self.git('init', '-q')
        self.git('config', 'user.name', 'Build scope test')
        self.git('config', 'user.email', 'scope@example.invalid')
        script = self.repo / 'tools/ci/changed-components.sh'
        script.parent.mkdir(parents=True)
        script.write_bytes(SELECTOR.read_bytes())
        self.base = self.commit()

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.repo, text=True).strip()

    def commit(self, paths=()):
        for path in paths:
            target = self.repo / path
            target.parent.mkdir(parents=True, exist_ok=True)
            with target.open('a') as stream:
                # Distinct payloads prevent Git rename detection from folding two
                # independently added package files into one destination path.
                stream.write(f'\n# changed {path}\n')
        self.git('add', '.')
        self.git('commit', '-qm', 'fixture')
        return self.git('rev-parse', 'HEAD')

    def packages(self, output, expected):
        words = output.split()
        self.assertEqual(set(words), expected)
        self.assertEqual(len(words), len(set(words)), 'duplicate packages')
        return set(words)

    def select(self, base, head):
        return subprocess.check_output(
            ['sh', str(SELECTOR), base, head], cwd=self.repo, text=True)

    def detect(self, event, base, head, explicit='', run=RUN):
        # Resolve the workflow's actual env bindings against a fake event. A wrong
        # PR binding (e.g. github.sha, the merge ref) is not silently corrected.
        context = {
            'inputs.components': explicit,
            'github.event.before': base,
            'github.sha': self.base,  # deliberately not the PR head
            'github.event.pull_request.base.sha': base,
            'github.event.pull_request.head.sha': head,
        }
        if event == 'push':
            context['github.sha'] = head
        env = dict(os.environ, GITHUB_EVENT_NAME=event)
        for name, binding in ENV_BINDINGS.items():
            match = re.fullmatch(r'\$\{\{ (.+) \}\}', binding)
            self.assertIsNotNone(match, f'unsupported env binding: {binding}')
            env[name] = context[match[1]]
        output = self.repo / 'github-output'
        output.write_text('')
        env['GITHUB_OUTPUT'] = str(output)
        subprocess.run(['bash', '-c', run], cwd=self.repo, env=env,
                       check=True, capture_output=True, text=True)
        lines = output.read_text().splitlines()
        self.assertEqual(len(lines), 1)
        self.assertTrue(lines[0].startswith('packages='))
        return lines[0].removeprefix('packages=')

    def paths(self, event):
        paths = block(block(ON, event, 2), 'paths', 4)
        patterns = re.findall(r"^      - '([^']+)'$", paths, re.MULTILINE)
        self.assertTrue(patterns)
        return patterns

    def smoke(self, packages):
        # Freeze the existing job dependency and token-safe predicate: this test
        # asserts scheduling eligibility, not remote package-build success.
        self.assertIn('    needs: [detect, packages]\n', SMOKE)
        self.assertIn("    if: contains(format(' {0} ', needs.detect.outputs.packages), ' aether-proxy ')\n", SMOKE)
        return ' aether-proxy ' in f" {' '.join(sorted(packages))} "

    def test_automatic_scope_paths_and_smoke(self):
        cases = [
            ('backend', ['aether-proxy/src/service.uc'], ALL),
            ('luci', ['luci-app-aether-proxy/htdocs/view.js'], ALL),
            ('workflow', ['.github/workflows/build.yml'], ALL),
            ('ci-tool', ['tools/ci/helper.sh'], ALL),
            ('nested-ci-tool', ['tools/ci/nested/helper.sh'], ALL),
            ('smoke', ['tests/ci/smoke.sh'], ALL),
            ('smoke-host', ['tests/ci/smoke-host.py'], ALL),
            ('sample', ['tests/fixtures/sample/nested/input.json'], ALL),
            ('docs', ['docs/guide.md', 'README.md'], set()),
            ('xray', ['aether-xray/Makefile'], {'aether-xray'}),
            ('chinadns', ['chinadns-ng/Makefile'], {'chinadns-ng'}),
            ('dns', ['aether-dns/Makefile'], {'aether-dns'}),
            ('mixed-independent', ['aether-xray/Makefile', 'aether-dns/Makefile',
                                   'docs/guide.md'], {'aether-xray', 'aether-dns'}),
            ('mixed-full', ['aether-proxy/Makefile', 'luci-app-aether-proxy/Makefile',
                            'tools/ci/nested/helper.sh', 'aether-xray/Makefile'], ALL),
        ]
        for name, paths, expected in cases:
            with self.subTest(case=name):
                base = self.git('rev-parse', 'HEAD')
                head = self.commit(paths)
                self.packages(self.select(base, head), expected)
                for event in ('push', 'pull_request'):
                    selected = self.packages(self.detect(event, base, head), expected)
                    triggered = any(fnmatch.fnmatchcase(path, pattern)
                                    for path in paths for pattern in self.paths(event))
                    self.assertEqual(triggered, bool(expected), (name, event))
                    self.assertEqual(triggered and self.smoke(selected), expected == ALL)

    def test_real_range_not_head_only_or_pr_default(self):
        # More than one commit; unrelated base history must not leak into scope.
        base = self.commit(['aether-proxy/old.uc'])
        self.commit(['aether-xray/Makefile'])
        head = self.commit(['aether-dns/Makefile'])
        expected = {'aether-xray', 'aether-dns'}
        self.packages(self.select(base, head), expected)
        for event in ('push', 'pull_request'):
            self.packages(self.detect(event, base, head), expected)

    def test_diverged_pr_uses_merge_base_not_target_tip(self):
        ancestor = self.base
        self.git('checkout', '-qb', 'target')
        target = self.commit(['aether-proxy/Makefile'])
        self.git('checkout', '-qb', 'pr', ancestor)
        head = self.commit(['chinadns-ng/Makefile'])
        self.assertEqual(self.git('merge-base', target, head), ancestor)

        # Execute the previous production detect on this exact fixture as a
        # regression witness, not a hand-written approximation of old behavior.
        previous = subprocess.check_output(
            ['git', 'show', 'da306116:.github/workflows/build.yml'],
            cwd=ROOT, text=True)
        old_selected = self.packages(
            self.detect('pull_request', target, head, run=detect_run(previous)), ALL)
        self.assertTrue(self.smoke(old_selected))

        selected = self.packages(self.detect('pull_request', target, head), {'chinadns-ng'})
        self.assertFalse(self.smoke(selected))
        # Push retains endpoint semantics, even with these divergent endpoints.
        self.packages(self.detect('push', target, head), ALL)

    def test_pr_merge_base_failure_is_fatal(self):
        # Existing objects but unrelated roots: merge-base exits 1. Never let the
        # selector's diff fallback quietly reduce this to the HEAD-only change.
        self.git('checkout', '-q', '--orphan', 'unrelated')
        self.git('rm', '-rf', '.')
        head = self.commit(['chinadns-ng/Makefile'])
        with self.assertRaises(subprocess.CalledProcessError) as error:
            self.detect('pull_request', self.base, head)
        self.assertIn('::error::Unable to determine PR merge-base', error.exception.stderr)
        self.assertEqual((self.repo / 'github-output').read_text(), '')
        # Missing objects fail explicitly too, rather than running the selector.
        with self.assertRaises(subprocess.CalledProcessError) as error:
            self.detect('pull_request', 'f' * 40, head)
        self.assertIn('::error::Unable to determine PR merge-base', error.exception.stderr)
        self.assertEqual((self.repo / 'github-output').read_text(), '')

    def test_explicit_inputs_and_empty_defaults(self):
        head = self.commit(['aether-proxy/Makefile'])
        for event in ('workflow_dispatch', 'workflow_call'):
            for explicit in ('aether-xray', 'chinadns-ng', 'aether-dns',
                             'luci-app-aether-proxy', 'aether-proxy',
                             'aether-dns aether-xray'):
                with self.subTest(event=event, explicit=explicit):
                    # Preserve exact input, including order; never auto-expand.
                    self.assertEqual(self.detect(event, self.base, head, explicit), explicit)
            self.packages(self.detect(event, self.base, head), ALL)
            declaration = block(block(ON, event, 2), 'inputs', 4)
            components = block(declaration, 'components', 6)
            self.assertIn("        default: ''\n", components)
            self.assertIn('        required: false\n', components)

    def test_zero_before_existing_fallback(self):
        head = self.commit(['aether-dns/Makefile'])
        self.packages(self.select('0' * 40, head), {'aether-dns'})


if __name__ == '__main__':
    unittest.main(verbosity=2)
