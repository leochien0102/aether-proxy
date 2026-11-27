'use strict';
/* Real SDK/browser coverage. Uses the T16.122 theme/version/hash evidence harness.
 * Run with the same required environment as t16.122-input-actions-gate.js.
 * Repeat with THEME_NAME/THEME_ROOT/THEME_VERSION/THEME_CONTROL for a second theme.
 * RPC is simulated; no apply, installation, external subscription or device traffic.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const { matrix: runMatrix, pageHarness, chromium, tr, sha256 } = require('./t16.122-input-actions-gate');
const matrix = (name, initial, exercise, ...args) => runMatrix(name, initial, async (h,record,...rest) => {
 record.coverageGateSHA256=sha256(__filename);
 return exercise(h,record,...rest);
},...args);
const nodes = [
 {'.name':'wg',label:'original-label',protocol:'wireguard',address:'192.0.2.9',port:'443',local_address:['192.0.2.10/32'],source:'manual',secret_key:'fictional-secret'},
 {'.name':'vl',label:'vless',protocol:'vless',uuid:'11111111-1111-4111-8111-111111111111',security:'reality',reality_pbk:'A'.repeat(43),source:'manual'},
 {'.name':'hy',label:'hysteria',protocol:'hysteria',hysteria_auth:'fictional-auth',source:'manual'},
 {'.name':'http',label:'http',protocol:'http',username:'fictional-user',password:'fictional-password',source:'manual'},
 {'.name':'sub','.type':'sub',user_agent:'fixture-global'},
 {'.name':'s1','.type':'subscription',name:'fixture-subscription',url:'https://example.invalid/sub',user_agent:'fixture-override'},
 {'.name':'stats','.type':'stats',heatmap_enabled:'1'}
];
const modal = h => h.page.locator('#modal_overlay .modal.cbi-modal');
async function edit(h, id, field = 'label') {
 await h.page.locator(`tr[data-sid="${id}"] .cbi-button-edit`).click();
 await modal(h).locator(`[data-name="${field}"] input`).first().waitFor({state:'visible'});
 // Wait for modal load, not only for its initial empty render.
 await h.page.waitForFunction(({id,field,nodes}) => document.querySelector(`#modal_overlay [data-name="${field}"] input`)?.value === nodes.find(n=>n['.name']===id)[field], {id,field,nodes});
}
async function cancel(h) {
 const writes=h.writes();
 await modal(h).locator('.button-row > button').first().click();
 // SDK hideModal only removes modal-overlay-active. Argon retains a display:flex
 // dialog inside an opacity:0 overlay shifted -10000px, so Playwright "hidden"
 // is not its closure contract. Prove both visual absence and lack of hit cover.
 try {
  const handle=await h.page.waitForFunction(() => {
   const overlay=document.querySelector('#modal_overlay'), dialog=overlay?.querySelector('.modal');
   const active=document.body.classList.contains('modal-overlay-active');
   const rect=dialog?.getBoundingClientRect();
   const inViewport=!!rect && rect.width>0 && rect.height>0 && rect.right>0 && rect.bottom>0 && rect.left<innerWidth && rect.top<innerHeight;
   let suppressed=!dialog;
   const ancestors=[];
   for (let el=dialog; el; el=el.parentElement) {
    const s=getComputedStyle(el);
    ancestors.push({tag:el.tagName,id:el.id,display:s.display,visibility:s.visibility,opacity:s.opacity});
    suppressed ||= s.display==='none' || s.visibility==='hidden' || s.visibility==='collapse' || Number(s.opacity)===0;
   }
   const hits=[];
   // Sample the viewport and the clipped dialog, not its offscreen center alone.
   const regions=[{left:0,top:0,right:innerWidth,bottom:innerHeight}];
   if (inViewport) regions.push({left:Math.max(0,rect.left),top:Math.max(0,rect.top),right:Math.min(innerWidth,rect.right),bottom:Math.min(innerHeight,rect.bottom)});
   for (const region of regions) for (const x of [.1,.5,.9]) for (const y of [.1,.5,.9]) {
    const point={x:region.left+(region.right-region.left)*x,y:region.top+(region.bottom-region.top)*y};
    const hit=document.elementFromPoint(point.x,point.y);
    if (hit && overlay?.contains(hit)) hits.push({...point,tag:hit.tagName,id:hit.id});
   }
   const state={active,inViewport,suppressed,dialog:rect?.toJSON(),overlay:overlay?.getBoundingClientRect().toJSON(),ancestors,hits};
   window.__t16125ModalClosure=state;
   return !active && (suppressed || !inViewport) && hits.length===0 ? state : false;
  });
  (h.modalClosures ||= []).push(await handle.jsonValue());
  await handle.dispose();
 } catch (error) {
  const state=await h.page.evaluate(()=>window.__t16125ModalClosure);
  throw new Error(`modal did not close after Cancel: ${error.message}; ${JSON.stringify(state)}`);
 }
 // Actual non-forced background click must work after the transition. A class
 // change or transparent but pointer-blocking overlay alone cannot pass.
 const outside=h.page.locator('#outside');
 await outside.evaluate(el=>{el.dataset.cancelProbe='0';el.addEventListener('click',()=>{el.dataset.cancelProbe=String(Number(el.dataset.cancelProbe)+1);},{once:true});});
 await outside.click();
 assert.equal(await outside.getAttribute('data-cancel-probe'),'1','closed modal must release background pointer interaction');
 assert.equal(await h.page.evaluate(()=>document.body.classList.contains('modal-overlay-active')),false);
 assert.equal(h.writes(),writes,'Cancel must not save');
}
const row = (h, field) => modal(h).locator(`[data-name="${field}"]`);
async function clear(h, frame, input, value = 'fictional-draft') {
 const buttons = frame.getByRole('button',{name:/clear|清空|清除/i,includeHidden:true});
 assert.equal(await buttons.count(),1,'exactly one clear control, including hidden duplicates');
 await input.fill(''); await input.focus();
 assert.equal(await buttons.isVisible(),false,'empty/placeholder must not paint');
 await input.fill(value); await h.page.locator('#outside').focus();
 assert.equal(await buttons.isVisible(),false,'blurred draft must not paint');
 await input.focus(); assert.equal(await buttons.isVisible(),true);
 const writes = h.writes();
 await buttons.click();
 assert.equal(await input.inputValue(),'');
 assert(await input.evaluate(el=>document.activeElement===el),'clear returns focus');
 assert.equal(await buttons.isVisible(),false,'cleared action must disappear');
 assert.equal(h.writes(),writes,'clear must not save');
 const state = await buttons.evaluate(el=>({display:getComputedStyle(el).display,tab:el.tabIndex,disabled:el.disabled,rects:el.getClientRects().length}));
 assert.equal(state.display,'none'); assert.equal(state.tab,-1); assert.equal(state.disabled,true); assert.equal(state.rects,0);
}
async function password(h, frame, record) {
 const input = frame.locator('input').first();
 assert.equal(await input.getAttribute('type'),'password');
 await input.fill('fictional-secret'); await input.focus();
 const clearButton = frame.getByRole('button',{name:/clear|清空|清除/i});
 const eye = frame.locator('button[data-ap-action="eye"]');
 assert(await eye.getAttribute('aria-label'),'eye must have an accessible label');
 assert.equal(await eye.count(),1,'replace, do not duplicate SDK reveal');
 // A compact theme/control must not be enlarged by the action button.
 await input.evaluate(el=>{el.style.setProperty('height','24px','important');el.style.setProperty('min-height','0','important');});
 await input.scrollIntoViewIfNeeded();
 // Allow the style change and its ResizeObserver delivery to finish. This is
 // a fixed rendering boundary, not a retry that accepts a transient pass.
 await h.page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve))));
 const a = await clearButton.boundingBox(), b = await eye.boundingBox(), f = await input.boundingBox();
 const field = await frame.getAttribute('data-name');
 const layout = await input.evaluate(el=>{
  const host=el.parentElement, inputStyle=getComputedStyle(el), hostStyle=getComputedStyle(host);
  return {host:host.getBoundingClientRect().toJSON(),inputHeight:inputStyle.height,inputPadding:inputStyle.padding,
   inputBoxSizing:inputStyle.boxSizing,inputAlignSelf:inputStyle.alignSelf,
   rows:hostStyle.gridTemplateRows,alignItems:hostStyle.alignItems,
   actionHeight:hostStyle.getPropertyValue('--ap-input-action-height'),
   actions:Array.from(host.querySelectorAll('button')).map(button=>{
    const s=getComputedStyle(button);
    return {action:button.dataset.apAction,height:s.height,maxHeight:s.maxHeight,alignSelf:s.alignSelf,gridArea:s.gridArea};
   })};
 });
 const diagnostic=JSON.stringify({field,clear:a,eye:b,input:f,layout});
 assert(a && b && f,`missing compact hit boxes: ${diagnostic}`);
 const overlap = Math.max(0,Math.min(a.x+a.width,b.x+b.width)-Math.max(a.x,b.x))*Math.max(0,Math.min(a.y+a.height,b.y+b.height)-Math.max(a.y,b.y));
 (record.compactBoxes ||= []).push({field,a,b,f,overlap,layout});
 assert.equal(overlap,0,`compact actions overlap: ${diagnostic}`);
 for (const [name,box] of [['clear',a],['eye',b]]) {
  assert(box.y>=f.y-1 && box.y+box.height<=f.y+f.height+1,`${name} action exceeds compact input height: ${diagnostic}`);
  assert(box.x>=f.x-1 && box.x+box.width<=f.x+f.width+1,`${name} action exceeds input width: ${diagnostic}`);
  assert(box.width>=24 && box.height>=23,`${name} compact action still needs a usable target: ${diagnostic}`);
 }
 const click = async box => {
  const point = {x:box.x+box.width/2,y:box.y+box.height/2};
  await h.page.mouse.click(point.x,point.y);
 };
 await click(b); assert.equal(await input.getAttribute('type'),'text'); assert.equal(await input.inputValue(),'fictional-secret');
 await click(b); assert.equal(await input.getAttribute('type'),'password');
 await click(a); assert.equal(await input.inputValue(),''); assert(await input.evaluate(el=>document.activeElement===el));
 assert.deepEqual(await eye.boundingBox(),b,'empty value must not move eye');
}

test('T16.125 quota: pointer and keyboard clear do not commit before leaving', async () => {
 await matrix('t16125-quota',{},async h => {
  const group=h.page.locator('.ap-quota-control'), select=group.locator('select'), input=group.locator('input');
  await select.waitFor();
  await h.page.waitForFunction(()=>document.querySelector('.ap-quota-control select')?.value==='100');
  await select.selectOption('custom');
  // Do not call the generic helper: its outside-focus step would commit quota.
  await input.fill('321'); await input.focus();
  const action=group.getByRole('button',{name:tr('Clear input'),exact:true});
  await action.click();
  assert.equal(await input.inputValue(),''); assert(await input.isVisible());
  assert(await input.evaluate(el=>el===document.activeElement));
  await input.fill('321'); await input.focus(); await h.page.keyboard.press('Tab');
  assert(await action.evaluate(el=>el===document.activeElement),'Tab stays in quota editor');
  assert(await input.isVisible());
  await h.page.keyboard.press('Enter'); assert.equal(await input.inputValue(),'');
  await h.page.locator('#outside').click();
  assert.equal(await select.inputValue(),'100'); assert.equal(await input.isVisible(),false);
  assert.equal(h.writes(),0);
 },'overview',nodes);
});
test('T16.125 node modal, SDK passwords, UUID/REALITY and cancel', async () => {
 await matrix('t16125-modal',{},async (h,record) => {
  await edit(h,'wg');
  await clear(h,row(h,'label'),row(h,'label').locator('input'));
  await clear(h,row(h,'address'),row(h,'address').locator('input'),'192.0.2.20');
  await password(h,row(h,'secret_key'),record);
  await password(h,row(h,'preshared_key'),record);
  await cancel(h); await edit(h,'wg');
  assert.equal(await row(h,'label').locator('input').inputValue(),'original-label');
  assert.equal(await row(h,'secret_key').locator('input').inputValue(),'fictional-secret');
  assert.equal(await row(h,'secret_key').locator('input').getAttribute('type'),'password');
  await cancel(h); await edit(h,'http'); await password(h,row(h,'password'),record);
  await cancel(h); await edit(h,'hy'); await password(h,row(h,'hysteria_auth'),record);
  await cancel(h); await edit(h,'vl');
  await password(h,row(h,'uuid'),record); await password(h,row(h,'reality_pbk'),record);
  assert.equal(await row(h,'reality_pqv').getByRole('button',{name:/clear|清空|清除/i,includeHidden:true}).count(),0,'long editor excluded');
  assert.equal(h.writes(),0);
 },'nodes',nodes);
});
test('T16.125 plain list: clear draft, + add, Delete removes only added entry', async () => {
 await matrix('t16125-list',{},async (h,record) => {
  await edit(h,'wg');
  const frame=row(h,'local_address'), input=frame.locator('.add-item > input[type=text]');
  const values=()=>frame.locator('.item > input[type=hidden]').evaluateAll(els=>els.map(el=>el.value));
  const before=await values();
  await clear(h,frame,input,'192.0.2.11/32'); assert.deepEqual(await values(),before);
  await input.fill('192.0.2.12/32'); await input.focus(); await input.scrollIntoViewIfNeeded();
  const plus=frame.locator('.cbi-button-add'), action=frame.locator('button[data-ap-action=clear]');
  assert(await plus.evaluate(el=>el.previousElementSibling?.matches('input[type=text]')),'SDK + must keep its input sibling');
  const a=await action.boundingBox(), p=await plus.boundingBox(), f=await input.boundingBox();
  assert(a && p && f);
  const overlap=Math.max(0,Math.min(a.x+a.width,p.x+p.width)-Math.max(a.x,p.x))*Math.max(0,Math.min(a.y+a.height,p.y+p.height)-Math.max(a.y,p.y));
  record.listBoxes={clear:a,plus:p,input:f,overlap};
  assert.equal(overlap,0,'clear and + hit boxes must not intersect');
  assert(a.x>=f.x-1 && a.x+a.width<=f.x+f.width+1,'clear stays inside input');
  assert(p.x>=f.x+f.width-1,'+ stays outside input');
  assert(p.x+p.width<=record.width,'+ must not overflow the viewport');
  const point={x:p.x+p.width/2,y:p.y+p.height/2};
  assert(await plus.evaluate((el,point)=>{const hit=document.elementFromPoint(point.x,point.y);return hit===el || el.contains(hit);},point),'native + center must receive pointer');
  // Keep the ordinary non-forced click too: actionability must pass on mobile.
  await plus.click();
  assert.deepEqual(await values(),[...before,'192.0.2.12/32']);
  await frame.locator('.item').last().press('Delete'); assert.deepEqual(await values(),before);
  await cancel(h); await edit(h,'wg'); assert.deepEqual(await values(),before);
  assert.equal(h.writes(),0);
 },'nodes',nodes);
});
test('T16.125 candidate combobox clears only creation draft', async () => {
 await matrix('t16125-candidates',{},async h => {
  for (const field of ['china_dns','direct_dns']) {
   const frame=h.row(field), dropdown=frame.locator('.add-item .cbi-dropdown');
   const values=()=>frame.locator('.item > input[type=hidden]').evaluateAll(els=>els.map(el=>el.value));
   const before=await values();
   await dropdown.click();
   const input=dropdown.locator('ul:not(.preview) .create-item-input');
   await input.fill('192.0.2.53'); await input.focus();
   const button=dropdown.locator('ul:not(.preview)').getByRole('button',{name:tr('Clear input'),exact:true});
   assert.equal(await button.count(),1); await button.click();
   assert.equal(await input.inputValue(),''); assert(await input.evaluate(el=>el===document.activeElement));
   assert(await dropdown.evaluate(el=>el.hasAttribute('open')),'clear must not close/select dropdown');
   assert.deepEqual(await values(),before);
   await input.fill('192.0.2.53'); await input.press('Enter');
   assert.deepEqual(await values(),[...before,'192.0.2.53']);
   await h.page.locator('#outside').click();
   await frame.locator('.item').last().press('Delete'); assert.deepEqual(await values(),before);
   assert.equal(await input.isVisible(),false,'closed dropdown must not expose custom draft');
  }
  assert.equal(h.writes(),0);
 },'rules');
});
test('T16.125 composite trust DNS: each creation input is independent of selected value', async () => {
 await matrix('t16125-trust',{},async h => {
  const frame=h.row('trust_dns'), dropdowns=frame.locator('.cbi-dropdown');
  assert.equal(await dropdowns.count(),2);
  for (let i=0;i<2;i++) {
   const dropdown=dropdowns.nth(i), selected=await dropdown.evaluate(el=>el.value);
   const protocols=await frame.locator('select').evaluateAll(els=>els.map(el=>el.value));
   await dropdown.click();
   const input=dropdown.locator('ul:not(.preview) .create-item-input');
   await input.fill('192.0.2.53'); await input.focus();
   const action=dropdown.locator('ul:not(.preview)').getByRole('button',{name:tr('Clear input'),exact:true});
   assert.equal(await action.count(),1); await action.click();
   assert.equal(await input.inputValue(),''); assert(await input.evaluate(el=>el===document.activeElement));
   assert.equal(await dropdown.evaluate(el=>el.value),selected,'clear draft must not clear selected DNS');
   assert.deepEqual(await frame.locator('select').evaluateAll(els=>els.map(el=>el.value)),protocols);
   await h.page.locator('#outside').click(); assert.equal(await input.isVisible(),false);
  }
  await clear(h,h.row('dns_probe_domain'),h.input('dns_probe_domain'),'example.invalid');
  await h.reset(); assert.equal(await h.input('dns_probe_domain').inputValue(),''); assert.equal(h.writes(),0);
 },'rules');
});
test('T16.125 custom UA, subscription password and inheritance', async () => {
 await matrix('t16125-ua',{},async (h,record) => {
  for (const inModal of [false,true]) {
   if (inModal) await edit(h,'s1','name');
   const frame=(inModal?modal(h):h.page.locator('#view')).locator('[data-name=user_agent]').filter({has:h.page.locator('select')}).first();
   const select=frame.locator('select'), input=frame.locator('input[type=text]');
   assert.equal(await select.inputValue(),'@custom');
   await clear(h,frame,input,'custom/7');
   await select.selectOption(''); assert.equal(await input.isVisible(),false);
   await select.selectOption('@custom'); assert.equal(await input.inputValue(),'');
   if (!inModal) await input.fill('pending-common-UA');
   else {
    await select.selectOption(''); assert((await select.locator('option:checked').innerText()).includes('pending-common-UA'));
    await clear(h,row(h,'name'),row(h,'name').locator('input'));
    await password(h,row(h,'url'),record); await cancel(h); await edit(h,'s1','name');
    assert.equal(await row(h,'url').locator('input').inputValue(),'https://example.invalid/sub');
    assert.equal(await row(h,'url').locator('input').getAttribute('type'),'password');
   }
  }
  assert.equal(h.writes(),0);
 },'nodes',nodes);
});
test('T16.125 updates: copy, clear and native + have independent slots', async () => {
 await matrix('t16125-updates',{},async (h,record) => {
  for (const field of ['data_hour','data_minute']) await clear(h,h.row(field),h.input(field),'12');
  const frame=h.row('channel_urls'), input=frame.locator('.add-item > input');
  await input.fill('https://example.invalid/channel/'); await input.focus();
  const copy=frame.getByRole('button',{name:tr('Copy channel URL'),exact:true});
  const action=frame.getByRole('button',{name:tr('Clear input'),exact:true});
  const a=await action.boundingBox(), b=await copy.boundingBox(), f=await input.boundingBox(), plus=await frame.locator('.cbi-button-add').boundingBox();
  record.channelBoxes={a,b,f,plus}; assert(a && b && f && plus);
  assert(a.x+a.width<=b.x+1 && b.x+b.width<=f.x+f.width+1 && plus.x>=f.x+f.width-1);
  await action.click(); assert.equal(await input.inputValue(),'');
  assert.equal(await frame.locator('.item').count(),0);
  await input.fill('https://example.invalid/channel/'); await frame.locator('.cbi-button-add').click();
  assert.equal(await frame.locator('.item').count(),1);
  await h.reset(); assert.equal(await frame.locator('.item').count(),0); assert.equal(h.writes(),0);
 },'updates');
});
test('T16.125 advanced: ordinary fields, list and readonly exclusion', async () => {
 await matrix('t16125-advanced',{},async h => {
  assert.equal(await h.row('extra_ports').getByRole('button',{name:/clear|清空|清除/i,includeHidden:true}).count(),0,'readonly field excluded');
  for (const field of ['proxy_username','proxy_password']) await clear(h,h.row(field),h.input(field));
  await h.page.locator('.cbi-tabmenu a').filter({hasText:tr('Boot and health checks')}).click();
  for (const field of ['boot_wait_timeout','url','expect_code','timeout','fail_threshold','recover_threshold','node_timeout','node_concurrency']) {
   await clear(h,h.row(field),h.input(field),field==='url'?'https://example.invalid/':'12');
  }
  const frame=h.row('boot_check_targets'); await clear(h,frame,frame.locator('.add-item > input'),'192.0.2.53:53');
  await h.reset(); assert.equal(await h.input('proxy_username').inputValue(),''); assert.equal(h.writes(),0);
 });
});
test('T16.125 access: name, plain IP and candidate MAC drafts', async () => {
 await matrix('t16125-access',{},async h => {
  await h.page.locator('button.cbi-button-add').click();
  await modal(h).locator('[data-name=name] input').waitFor({state:'visible'});
  await clear(h,row(h,'name'),row(h,'name').locator('input'));
  const ip=row(h,'ip'); await clear(h,ip,ip.locator('.add-item > input'),'192.0.2.2');
  const mac=row(h,'mac'), dropdown=mac.locator('.add-item .cbi-dropdown');
  await dropdown.click(); const input=dropdown.locator('ul:not(.preview) .create-item-input');
  await input.fill('02:00:00:00:00:02'); await input.focus();
  const button=dropdown.locator('ul:not(.preview)').getByRole('button',{name:tr('Clear input'),exact:true});
  await button.click(); assert.equal(await input.inputValue(),''); assert.equal(await mac.locator('.item').count(),0);
  assert(await input.evaluate(el=>el===document.activeElement));
  // A real modal blocks pointer clicks on the background sentinel. Leave the
  // dropdown through its own modal heading, without forcing a background click.
  await modal(h).locator('h4').first().click(); await cancel(h); assert.equal(h.writes(),0);
 },'access');
});
// This enumerates every rendered text widget, including inactive tab/protocol fields.
// It deliberately does not whitelist individual fields, so new fields cannot silently escape coverage.
async function completeCoverage(h, root) {
 const fields = await root.locator('input:not([type=hidden]):not([type=checkbox]):not([type=radio])').evaluateAll(inputs => inputs
  .filter(input=>!input.closest('ul.preview') && !input.closest('[data-name=lan_ifaces]') && !input.readOnly && !input.disabled)
  .map(input=>({field:input.closest('[data-name]')?.getAttribute('data-name') || input.getAttribute('aria-label') || input.id,
   clear:input.parentElement.querySelectorAll('button[data-ap-action=clear]').length,
   eye:input.parentElement.querySelectorAll('button[data-ap-action=eye]').length,
   password:input.classList.contains('cbi-input-password')})));
 assert(fields.length>0,'coverage must not pass on an empty page');
 for (const field of fields) {
  assert.equal(field.clear,1,`${field.field}: exactly one clear action`);
  if (field.password) assert.equal(field.eye,1,`${field.field}: exactly one password eye`);
 }
 return fields;
}
for (const view of ['nodes','access','rules','advanced','updates']) {
 test(`T16.125 complete text-widget inventory: ${view}`, async () => {
  await matrix(`t16125-inventory-${view}`,{},async (h,record) => {
   // Access has only selectors in its empty main table; text fields live in its modal.
   record.fields=view==='access' ? [] : await completeCoverage(h,h.page.locator('#view'));
   if (view==='nodes') {
    await edit(h,'wg'); record.nodeFields=await completeCoverage(h,modal(h));
    await cancel(h);
    await h.page.getByRole('button',{name:tr('Add node'),exact:true}).click();
    const share=modal(h).locator('[data-name=_share]');
    await share.locator('input').waitFor({state:'visible'});
    await clear(h,share,share.locator('input'),'vless://fictional-share-link');
    await cancel(h);
   }
   if (view==='access') {
    await h.page.locator('button.cbi-button-add').click();
    await modal(h).locator('[data-name=name] input').waitFor({state:'visible'});
    record.hostFields=await completeCoverage(h,modal(h));
    await cancel(h);
   }
   assert.equal(h.writes(),0);
  },view,nodes);
 });
}
test('T16.125 scope: common module alone does not decorate arbitrary inputs', async () => {
 const browser=await chromium.launch();
 try {
  const h=await pageHarness(browser,'light',360,{},'logs');
  try {
   await h.open();
   assert.equal(await h.page.getByRole('button',{name:tr('Clear input'),includeHidden:true}).count(),0);
   await h.page.evaluate(()=>{const input=document.createElement('input');input.id='scope-sentinel';document.querySelector('#view').append(input);});
   await h.page.locator('#scope-sentinel').fill('not-an-application-field'); await h.page.locator('#scope-sentinel').focus();
   assert.equal(await h.page.getByRole('button',{name:tr('Clear input'),includeHidden:true}).count(),0,'no document injection');
   assert.deepEqual(h.unexpected,[]); assert.equal(h.writes(),0);
  } finally { await h.context.close(); }
 } finally { await browser.close(); }
});
