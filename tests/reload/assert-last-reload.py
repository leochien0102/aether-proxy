#!/usr/bin/env python3
"""T10.71: observe real daemon reload completion, not the earlier event/action edge."""
import json
import sys
import time
from pathlib import Path


def main():
    path, node, mode, wanted, baseline = sys.argv[1:]
    expected = wanted == 'true'
    floor = 0 if baseline == '<missing>' else float(baseline or '0')
    deadline = time.monotonic() + 10
    state = {}
    while time.monotonic() < deadline:
        state = json.loads(Path(path).read_text())
        result = state.get('last_reload', {})
        if result.get('at', 0) > floor:
            break
        time.sleep(0.05)
    result = state['last_reload']
    assert set(result) == {'at', 'target_node', 'target_mode', 'ok', 'error'}, result
    assert isinstance(result['at'], (float, int)) and result['at'] > floor, result
    assert result['target_node'] == (None if node == '-' else node), result
    assert result['target_mode'] == (None if mode == '-' else mode), result
    assert result['ok'] is expected, result
    if expected:
        assert result['error'] is None, result
    else:
        assert isinstance(result['error'], str) and result['error'], result
    # Completion must not replace runtime with a five-field result object.
    assert state['state'] in ('running', 'degraded', 'failsafe'), state
    assert state['node_id'] and state['mode'], state
    assert state['components']['xray']['version'], state
    assert state['render_hash'] and 'monitor' in state, state
    print(json.dumps(result, ensure_ascii=False))


if __name__ == '__main__':
    main()
