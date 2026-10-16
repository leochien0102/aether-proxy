'use strict';
const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');
const assert = require('node:assert/strict');
const { loadModule, parsePo } = require('../luci/loader');
const root = path.resolve(__dirname, '../..');
const res = path.join(root, 'luci-app-aether-proxy/htdocs/luci-static/resources');
const po = parsePo(fs.readFileSync(path.join(root, 'luci-app-aether-proxy/po/zh_Hans/aether-proxy.po'), 'utf8'));
globalThis._ = s => po[s] || s;
const model = loadModule(path.join(res, 'aether-proxy/model/subscriptions.js'), { baseclass: { extend: x => x } }, {});
let passed = 0;
function check(name, fn) { fn(); passed++; console.log('PASS  ' + name); }
const t = fs.mkdtempSync(path.join(root, 'tests/sub-status/tmp.'));
try {
 const conf = path.join(t, 'etc/config');
 const state = path.join(t, 'etc/aether-proxy/state');
 const run = path.join(t, 'run');
 fs.mkdirSync(conf, { recursive: true }); fs.mkdirSync(state, { recursive: true }); fs.mkdirSync(run);
 fs.writeFileSync(path.join(conf, 'aetherproxy'), "config global 'main'\n option enabled '0'\nconfig subscription 's_00000001'\n option url 'https://fiction.example/subscribe?token=FAKE'\n option enabled '0'\n");
 const file = path.join(state, 'sub.json');
 const events = path.join(run, 'events.jsonl');
 const eventText = '{"existing":"sentinel"}\n';
 fs.writeFileSync(events, eventText);
 function status(extra = []) {
  const r = cp.spawnSync(path.join(root, 'tests/host/ucode'), ['-S', path.join(root, 'aether-proxy/src/aether-proxy'), '--', 'sub', 'status', '--json', '--confdir', conf, '--sys-root', t, '--run-dir', run, ...extra], { encoding: 'utf8' });
  assert.equal(r.status, 0, r.stdout + r.stderr); assert.equal(r.stderr, ''); return JSON.parse(r.stdout);
 }
 check('1. status filters deleted subscriptions and preserves configured disabled record exactly', () => {
  const record = { last_attempt: 123, last_ok: 122, nodes: 9, skipped: { malformed: 2 }, error: 'SUB_FETCH_FAILED', extra: ['unchanged'] };
  fs.writeFileSync(file, JSON.stringify({ s_00000001: record, s_00000002: { nodes: 99 } }));
  const before = fs.readFileSync(file, 'utf8'); const mtime = fs.statSync(file).mtimeMs;
  assert.deepEqual(status(), { ok: true, subs: { s_00000001: record } });
  assert.equal(fs.readFileSync(file, 'utf8'), before); assert.equal(fs.statSync(file).mtimeMs, mtime);
 });
 check('2. missing and corrupt status return empty without adding events or creating state', () => {
  fs.unlinkSync(file);
  assert.deepEqual(status(), { ok: true, subs: {} }); assert.equal(fs.existsSync(file), false);
  for (const bad of ['{broken', '[]', 'null', '123']) {
   fs.writeFileSync(file, bad);
   assert.deepEqual(status(), { ok: true, subs: {} }); assert.equal(fs.readFileSync(file, 'utf8'), bad);
  }
  assert.equal(fs.readFileSync(events, 'utf8'), eventText);
 });
 check('3. sub_status forwards via shared 10s timeout, empty args and read ACL', () => {
  const plugin = fs.readFileSync(path.join(root, 'luci-app-aether-proxy/root/usr/share/rpcd/ucode/aetherproxy.uc'), 'utf8');
  assert.match(plugin, /sub_status: \{\s*call: function\(req\) \{\s*return call_cli\(\[ 'sub', 'status' \], DEFAULT_TIMEOUT_SECS\);\s*\},\s*args: \{\}/);
  assert.match(plugin, /DEFAULT_TIMEOUT_SECS = 10/);
  const acl = JSON.parse(fs.readFileSync(path.join(root, 'luci-app-aether-proxy/root/usr/share/rpcd/acl.d/luci-app-aether-proxy.json')));
  assert.ok(acl['luci-app-aether-proxy'].read.ubus.aetherproxy.includes('sub_status'));
  assert.ok(!acl['luci-app-aether-proxy'].write.ubus.aetherproxy.includes('sub_status'));
 });
 function row(s, record, now = 200000) { return model.build([{ '.name': 's_00000001', ...s }], { ok: true, subs: record ? { s_00000001: record } : {} }, now, false).rows[0]; }
 check('4. list defaults, URL redaction and manual interval', () => {
  const r = row({ url: 'https://example.com/api/v1/client/subscribe?token=SECRET', interval_hours: '0' });
  assert.equal(r.name, 's_00000001'); assert.equal(r.address, 'https://example.com/…');
  assert.doesNotMatch(JSON.stringify(r), /token|SECRET/); assert.equal(r.interval, '仅手动');
  for (const url of ['broken', 'https://', 'https://bad host/path', 'javascript:alert(1)']) assert.equal(row({url}).address, '…');
  // userinfo (user:password@) must never reach the list either
  const withAuth = row({ url: 'https://alice:HUNTER2@example.com/sub?token=SECRET' });
  assert.equal(withAuth.address, 'https://example.com/…'); assert.doesNotMatch(JSON.stringify(withAuth), /alice|HUNTER2|SECRET/);
  assert.equal(row({name: 'Test', enabled: '0', fetch_via: 'proxy'}).name, 'Test');
  assert.equal(row({enabled: '0'}).enabled, '禁用');
  assert.equal(model.build([], {}, 0, true).can_update, false);
  assert.equal(model.build([{'.name': 's_a'}], {}, 0, true).rows[0].can_update, false);
 });
 check('5. results cover all errors, skip reasons, unknowns and relative time', () => {
  assert.equal(row({}).result.text, '尚未更新');
  assert.equal(row({}, {nodes: 12, error: null}).result.text, '成功，12 个节点');
  const errors = {SUB_FETCH_FAILED:'下载失败',SUB_DECODE_FAILED:'解码失败',SUB_FORMAT_UNSUPPORTED:'格式不支持',SUB_NO_VALID_NODES:'没有可用节点',SUB_APPLY_INVALID:'应用后配置无效',SUB_PROXY_UNAVAILABLE:'代理不可用',SUB_SHRANK:'节点数骤减',UNKNOWN:'UNKNOWN'};
  for (const [error, text] of Object.entries(errors)) assert.equal(row({}, {error}).result.text, text);
  const reasons = {malformed:'格式错误',unsupported_scheme:'不支持的协议',unsupported_transport:'不支持的传输',unsupported_security:'不支持的安全层',ss_plugin:'带插件的 SS',vmess_alterid:'VMess alterId 非 0',new_reason:'new_reason'};
  const skipped = Object.fromEntries(Object.keys(reasons).map(k => [k, 2]));
  const text = row({}, {skipped}).result.skipped;
  assert.ok(text.startsWith('跳过 14 个：'));
  for (const reason of Object.values(reasons)) assert.ok(text.includes(reason + ' 2'), text);
  for (const [delta, text] of [[5,'5 秒前'],[120,'2 分钟前'],[7200,'2 小时前'],[172800,'2 天前']]) assert.equal(row({}, {last_attempt:200000-delta}).result.time, text);
 });
 check('6. job summaries include all five counts per subscription and failure code', () => {
  const lines = model.job_result({result:{subs:{s_a:{ok:true,added:1,updated:2,stale:3,revived:4,removed:5},s_b:{ok:false,code:'SUB_FETCH_FAILED'}}}}, {s_a:'Alpha',s_b:'Beta'});
  assert.deepEqual(lines, ['Alpha: 新增 1 / 更新 2 / 失效 3 / 恢复 4 / 移除 5', 'Beta: SUB_FETCH_FAILED']);
 });
 check('7. generated IDs use four lower-case hex bytes and retry collisions', () => {
  const seq = [[0,1,171,255],[255,16,0,128]]; let calls=0;
  const id = model.new_id(['s_0001abff'], () => new Uint8Array(seq[calls++]));
  assert.equal(id,'s_ff100080'); assert.equal(calls,2); assert.match(id,/^s_[0-9a-f]{8}$/);
 });
 check('8. delete plan removes only owned nodes, retains current as manual and counts accurately', () => {
  const nodes = [{'.name':'current',source:'A'},{'.name':'a1',source:'A'},{'.name':'a2',source:'A'},{'.name':'b',source:'B'},{'.name':'m',source:'manual'}];
  const p = model.delete_plan('A', nodes, 'current');
  assert.deepEqual(p.remove,['a1','a2']); assert.deepEqual(p.manual,['current']);
  assert.equal(p.confirm,'删除此订阅并一并删除 2 个节点？1 个当前节点将保留并改为手动。');
  assert.deepEqual(model.delete_plan('A',nodes,'b').remove,['current','a1','a2']);
 });
 check('9. GridSection uses named add, password URL, confirmed destructive delete, job updates and translated text', () => {
  const source = fs.readFileSync(path.join(res,'view/aether-proxy/subscriptions.js'),'utf8');
  assert.match(source,/m\.section\(form\.GridSection, 'subscription'\)/);
  assert.match(source,/renderSectionAdd = function\(\) \{ return E\(\[\]\); \}/);
  assert.match(source,/model\.new_id/); assert.match(source,/crypto\.getRandomValues/);
  assert.match(source,/uci\.add\('aetherproxy', 'subscription', id\)/);
  assert.match(source,/renderMoreOptionsModal\(id\)/);
  assert.match(source,/'url', _\('Subscription URL'\)\).*o\.password = true/);
  assert.match(source,/cbi-button-remove/); assert.match(source,/if \(!confirm\(plan.confirm\)\) return/);
  assert.match(source,/ap\.run_job\('sub_update', ids\)/);
  assert.match(source,/uci\.set\('aetherproxy', node, 'source', 'manual'\)/);
  assert.match(source,/uci\.set\('aetherproxy', node, 'stale', '0'\)/);
  assert.doesNotMatch(source,/rpc\.declare|cbi-button-reset/);
  for (const f of ['view/aether-proxy/subscriptions.js','aether-proxy/model/subscriptions.js']) {
   const text=fs.readFileSync(path.join(res,f),'utf8');
   for (const m of text.matchAll(/_\('([^']+)'\)/g)) assert.ok(po[m[1]], 'translation missing: '+m[1]);
   assert.equal(cp.spawnSync('node',['--check',path.join(res,f)]).status,0);
  }
 });
 console.log(`${passed} passed, 0 failed`);
} finally { fs.rmSync(t, { recursive:true, force:true }); }
