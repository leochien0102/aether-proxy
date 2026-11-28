'use strict';
/* Real-Chromium width gate for the three long-value inputs (T16.126).
 * Same theme/version/hash evidence harness as T16.122 (see its header for env):
 *   APP_ROOT=<worktree> WWW_ROOT=<root-rockchip/www> THEME_ROOT=<theme dir>
 *   THEME_VERSION=<pkg version> OUTPUT_DIR=<evidence dir> NODE_PATH=<playwright>
 *   node --test tests/luci/t16.126-width-gate.js
 * Run the same file with T16126_BASELINE=1 and a pre-change APP_ROOT to record
 * the "before" numbers; baseline skips only the widening assertions.
 * Session RPC is simulated; no device, no apply, no external subscription.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { matrix, output, sha256, appRoot } = require('./t16.122-input-actions-gate');

const baseline = process.env.T16126_BASELINE === '1';
const UUID = '11111111-1111-4111-8111-111111111111';
const PUBKEY = 'A'.repeat(43);
/* 60 characters: longer than the theme's 400px cap can ever show, short enough
 * for the widest row a 1280px modal can offer (the input may not leave its field). */
const LONG_URL = 'https://subs.example.invalid/sub?token=' + '0123456789abcdef'.repeat(2).slice(0, 21);
const nodes = [
 {'.name':'wg',label:'original-label',protocol:'wireguard',address:'192.0.2.9',port:'443',local_address:['192.0.2.10/32'],source:'manual',secret_key:'fictional-secret'},
 {'.name':'vl',label:'vless',protocol:'vless',uuid:UUID,security:'reality',reality_pbk:PUBKEY,source:'manual'},
 {'.name':'sub','.type':'sub',user_agent:'fixture-global'},
 {'.name':'s1','.type':'subscription',name:'fixture-subscription',url:'https://example.invalid/sub',user_agent:'fixture-override'},
 {'.name':'stats','.type':'stats',heatmap_enabled:'1'}
];
const modal = h => h.page.locator('#modal_overlay .modal.cbi-modal');
const field = (h, name) => h.page.locator(`#modal_overlay [data-name="${name}"]`);

async function edit(h, id, name, value) {
 await h.page.locator(`tr[data-sid="${id}"] .cbi-button-edit`).click();
 await field(h, name).locator('input').first().waitFor({state:'visible'});
 await h.page.waitForFunction(({name,value}) => {
  const input = document.querySelector(`#modal_overlay [data-name="${name}"] input`);
  return input && input.value === value;
 }, {name,value});
}
async function cancel(h) { await modal(h).locator('.button-row > button').first().click();
 await h.page.waitForFunction(() => {
  const overlay = document.querySelector('#modal_overlay'), dialog = overlay?.querySelector('.modal');
  if (document.body.classList.contains('modal-overlay-active'))
   return false;
  if (!dialog) return true;
  const style = getComputedStyle(dialog), opacity = getComputedStyle(overlay).opacity;
  const rect = dialog.getBoundingClientRect();
  return style.display === 'none' || style.visibility === 'hidden' || Number(style.opacity) === 0 ||
   Number(opacity) === 0 || !rect.width || !rect.height;
 }, null, {timeout: 5000});
}

/* Theme inputs animate width (transition: all .25s); measure the target, not the tween.
 * The grid host that anchors the action buttons follows the animated width one
 * frame behind, so wait until the input, its host and its buttons all stand still. */
async function settle(locator) {
 await locator.evaluate(async el => {
  if (!el.style.width)
   return;
  const target = parseFloat(el.style.width);
  const host = el.parentElement;
  const snap = () => [parseFloat(getComputedStyle(el).width), host.getBoundingClientRect().width,
   ...[...host.querySelectorAll('button')].map(button => button.getBoundingClientRect().x)];
  let previous = [];
  for (let i = 0; i < 240; i++) {
   const now = snap();
   const stable = previous.length && previous.every((value, index) => Math.abs(value - now[index]) < 0.5);
   if (Math.abs(now[0] - target) < 1 && stable)
    return;
   previous = now;
   await new Promise(done => requestAnimationFrame(done));
  }
 });
}

/* Everything the acceptance talks about, measured in the live browser. */
async function measure(locator) {
 return locator.evaluate(el => {
  const style = getComputedStyle(el), rect = el.getBoundingClientRect();
  const row = el.closest('.cbi-value-field'), host = el.parentElement;
  const hostRect = host.getBoundingClientRect(), rowRect = row.getBoundingClientRect();
  const mirror = document.createElement('span');
  mirror.style.cssText = 'position:fixed;left:-10000px;top:0;white-space:pre;font:' + style.font +
   ';letter-spacing:' + style.letterSpacing;
  mirror.textContent = '\u2022'.repeat(el.value.length);
  document.body.append(mirror);
  const maskedWidth = mirror.getBoundingClientRect().width;
  mirror.remove();
  const contentRight = rect.right - (parseFloat(style.paddingRight) || 0) - (parseFloat(style.borderRightWidth) || 0);
  const actions = [...host.querySelectorAll('button[data-ap-action]')].map(button => {
   const box = button.getBoundingClientRect();
   const hit = document.elementFromPoint(box.x + box.width / 2, box.y + box.height / 2);
   return { action: button.dataset.apAction, rect: box.toJSON(), label: button.getAttribute('aria-label'),
    hit: hit === button || button.contains(hit), painted: !!button.getClientRects().length &&
     getComputedStyle(button).display !== 'none' };
  });
  return {
   type: el.type, length: el.value.length, clientWidth: el.clientWidth, scrollWidth: el.scrollWidth,
   offsetWidth: el.offsetWidth, computedWidth: style.width, maxWidth: style.maxWidth,
   paddingLeft: style.paddingLeft, paddingRight: style.paddingRight, fontSize: style.fontSize,
   inlineWidth: el.style.width, inlineMaxWidth: el.style.maxWidth, maskedWidth, contentRight,
   rect: rect.toJSON(), hostWidth: hostRect.width, rowWidth: rowRect.width,
   actions,
   doc: { scrollWidth: document.documentElement.scrollWidth, clientWidth: document.documentElement.clientWidth },
   body: { scrollWidth: document.body.scrollWidth, clientWidth: document.body.clientWidth }
  };
 });
}

function fits(record, name, data) {
 if (baseline) {
  assert.equal(data.inlineWidth, '', `${name}: baseline must not carry an inline width`);
  return;
 }
 assert.match(data.inlineWidth, /^\d+(\.\d+)?px$/, `${name}: decorator must set a px width`);
 assert.equal(data.inlineMaxWidth, 'none', `${name}: theme max-width cap must be lifted`);
 if (record.width >= 1280) {
  assert.ok(data.scrollWidth <= data.clientWidth,
   `${name}: ${record.width}px scrollWidth ${data.scrollWidth} > clientWidth ${data.clientWidth}`);
  assert.ok(data.maskedWidth <= data.clientWidth + 0.5,
   `${name}: ${record.width}px masked text ${data.maskedWidth} > clientWidth ${data.clientWidth}`);
 }
 assert.ok(data.actions.length >= 1, `${name}: actions missing`);
 for (const action of data.actions) {
  assert.ok(action.painted, `${name}: ${action.action} not painted`);
  assert.ok(action.rect.x >= data.rect.x - 1 && action.rect.x + action.rect.width <= data.rect.x + data.rect.width + 1,
   `${name}: ${action.action} leaves the input box horizontally`);
  assert.ok(action.rect.y >= data.rect.y - 1 && action.rect.y + action.rect.height <= data.rect.y + data.rect.height + 1,
   `${name}: ${action.action} leaves the input box vertically`);
  assert.equal(action.hit, true, `${name}: ${action.action} not hit-testable`);
  assert.ok(action.rect.x + 0.5 >= data.contentRight,
   `${name}: ${action.action} covers the text area (${action.rect.x} < ${data.contentRight})`);
 }
 for (let i = 0; i < data.actions.length; i++)
  for (let j = i + 1; j < data.actions.length; j++) {
   const a = data.actions[i].rect, b = data.actions[j].rect;
   assert.ok(a.x + a.width <= b.x + 0.5 || b.x + b.width <= a.x + 0.5,
    `${name}: actions ${data.actions[i].action}/${data.actions[j].action} overlap`);
  }
}

function unchanged(name, data) {
 assert.equal(data.inlineWidth, '', `${name}: other fields must keep the theme width`);
 assert.equal(data.inlineMaxWidth, '', `${name}: other fields must keep the theme max-width`);
}

async function overflow(record, h) {
 const doc = await h.page.evaluate(() => ({
  scrollWidth: document.documentElement.scrollWidth, clientWidth: document.documentElement.clientWidth,
  bodyScrollWidth: document.body.scrollWidth, bodyClientWidth: document.body.clientWidth
 }));
 record.pageOverflow = doc;
 if (record.width <= 360) {
  assert.ok(doc.scrollWidth <= doc.clientWidth, `page scrolls horizontally at ${record.width}px`);
  const m = await modal(h).evaluate(el => ({
   scrollWidth: el.scrollWidth, clientWidth: el.clientWidth, rect: el.getBoundingClientRect().toJSON()
  }));
  record.modal = m;
  /* Argon 2.4.3's own modal overflows by 2px at 360px before T16.126 (measured
   * 362/360 at 0b4afb70); page scroll is what must stay clean, and every widened
   * input must stay inside the modal box. */
  assert.ok(m.scrollWidth <= m.clientWidth + 2, `modal scrolls horizontally at ${record.width}px`);
  for (const key of ['uuid','reality_pbk','url']) {
   const data = record[key];
   if (!data) continue;
   assert.ok(data.rect.x >= m.rect.x && data.rect.right <= m.rect.right + 0.5,
    `${key} leaves the modal at ${record.width}px`);
  }
 }
}

test('T16.126 wide inputs: long values fit, actions stay inside, no narrow overflow', async () => {
 await matrix('t16126-width', {}, async (h, record) => {
  record.identity = { gateSHA256: sha256(__filename), baseline,
   source: Object.fromEntries(['aether-proxy/common.js','aether-proxy/subscriptions-block.js','view/aether-proxy/nodes.js']
    .map(file => [file, sha256(path.join(appRoot, 'luci-app-aether-proxy/htdocs/luci-static/resources', file))])) };

  await edit(h, 'wg', 'address', '192.0.2.9');
  record.other = {
   address: await measure(field(h, 'address').locator('input')),
   port: await measure(field(h, 'port').locator('input')),
   label: await measure(field(h, 'label').locator('input'))
  };
  await cancel(h);

  await edit(h, 'vl', 'uuid', UUID);
  const uuidInput = field(h, 'uuid').locator('input');
  await uuidInput.focus();
  await settle(uuidInput);
  record.uuid = await measure(uuidInput);
  const pbkInput = field(h, 'reality_pbk').locator('input');
  await pbkInput.focus();
  await settle(pbkInput);
  record.reality_pbk = await measure(pbkInput);
  record.sni = await measure(field(h, 'sni').locator('input'));
  record.reality_sid = await measure(field(h, 'reality_sid').locator('input'));
  fits(record, 'uuid', record.uuid);
  fits(record, 'reality_pbk', record.reality_pbk);
  for (const [name, data] of Object.entries({ sni: record.sni, reality_sid: record.reality_sid,
   label: record.other.label, address: record.other.address, port: record.other.port }))
   unchanged(name, data);
  await field(h, 'uuid').scrollIntoViewIfNeeded();
  await h.page.screenshot({path: path.join(output, `${record.id}-node-modal.png`)});
  await overflow(record, h);
  await cancel(h);

  await edit(h, 's1', 'url', 'https://example.invalid/sub');
  const input = field(h, 'url').locator('input');
  await input.fill(LONG_URL);
  assert.equal(await input.inputValue(), LONG_URL);
  await input.focus();
  await settle(input);
  record.url = await measure(input);
  fits(record, 'subscription url', record.url);
  assert.equal(record.url.length, LONG_URL.length);
  unchanged('subscription name', await measure(field(h, 'name').locator('input')));
  await overflow(record, h);
  await h.page.screenshot({path: path.join(output, `${record.id}-subscription-modal.png`)});
  await cancel(h);
  assert.equal(h.writes(), 0, 'measuring must not write configuration');
 }, 'nodes', nodes);
});
