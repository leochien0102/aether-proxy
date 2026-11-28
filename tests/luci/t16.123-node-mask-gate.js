'use strict';
/* Real LuCI GridSection modals, real local Proton2025 CSS, fictional session RPC.
 * Same environment as t16.122-input-actions-gate.js; no device or network access.
 * node --test tests/luci/t16.123-node-mask-gate.js
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { matrix: runMatrix, absent, tr, output, sha256 } = require('./t16.122-input-actions-gate');
function matrix(name, initial, exercise, view, nodes) {
 return runMatrix(name,initial,async (h,record,...args) => {
  record.nodeGateSHA256=sha256(__filename);
  await exercise(h,record,...args);
 },view,nodes);
}
const original = {
 '.name':'n_fixture', label:'Fictional node', source:'manual', protocol:'vless',
 address:'203.0.113.10', port:'443', security:'reality', sni:'example.invalid',
 uuid:'A1234567-89AB-4CDE-8F01-23456789ABCD', reality_pbk:'A'.repeat(43)
};
const fields = [
 ['uuid','Show UUID','Hide UUID','Clear UUID'],
 ['reality_pbk','Show REALITY public key','Hide REALITY public key','Clear REALITY public key']
];
function modalHarness(h) {
 const modal = h.page.locator('#modal_overlay > .modal.cbi-modal');
 const row = field => modal.locator(`[data-name="${field}"]`);
 const input = field => row(field).locator('input').first();
 const button = (field,label) => row(field).getByRole('button',{name:tr(label),exact:true,includeHidden:true});
 return {...h,modal,row,input,button};
}
async function edit(h, id = original['.name']) {
 await h.page.locator(`tr[data-sid="${id}"] .cbi-button-edit`).click();
 await h.input('uuid').waitFor({state:'visible'});
}
async function cancel(h) {
 await h.modal.locator('.button-row > button').first().click();
 await h.modal.waitFor({state:'hidden'});
}
async function saveModal(h) {
 await h.modal.locator('.button-row > .cbi-button-positive').click();
 await h.modal.waitFor({state:'hidden'});
}
async function masked(h, expected) {
 for (const [field,show] of fields) {
  assert.equal(await h.input(field).getAttribute('type'),'password',`${field}: default mask`);
  assert.equal(await h.input(field).inputValue(),expected[field],`${field}: exact value`);
  assert.equal(await h.button(field,show).count(),1,`${field}: accessible show action`);
 }
}
async function pointer(h, button) {
 await button.scrollIntoViewIfNeeded();
 const box = await button.boundingBox();
 assert.ok(box,'button hit box missing');
 const point = {x:box.x+box.width/2,y:box.y+box.height/2};
 assert.equal(await button.evaluate((el,p)=>{
  const hit=document.elementFromPoint(p.x,p.y); return el===hit || el.contains(hit);
 },point),true,'real pointer must hit intended button');
 await h.page.mouse.click(point.x,point.y);
 return point;
}
/* Proton2025 animates input width and margin (`transition: all .25s`), so a
 * width-only change settles later than the modal. Wait until the input has
 * reached its inline target and two consecutive frames have identical boxes
 * before measuring, so the layout assertions see the resting layout. */
async function stable(h) {
 await h.page.waitForFunction(() => {
  const dialog=document.querySelector('#modal_overlay > .modal.cbi-modal');
  if (!dialog || getComputedStyle(dialog).display==='none') return false;
  const input=dialog.querySelector('[data-name="uuid"] input');
  if (!input) return false;
  const target=parseFloat(input.style.width);
  if (!target) return false;
  const settled=Math.abs(input.getBoundingClientRect().width-target)<1 &&
   parseFloat(getComputedStyle(input).marginRight)<0.5;
  const sig=[...dialog.querySelectorAll('[data-name="uuid"] input, [data-name="uuid"] button')]
   .map(el=>{const r=el.getBoundingClientRect(); return [r.x,r.y,r.width,r.height].join(',');})
   .join('|');
  const same=sig===window.__t16123Signature;
  window.__t16123Signature=sig;
  return settled && same;
 },null,{timeout:5000});
}
test('T16.123 visibility: node modal final rendering and keyboard actions', async () => {
 await matrix('node-visibility',{},async (base,record,id) => {
  const h = modalHarness(base);
  await edit(h);
  await masked(h,original);
  for (const [field,, ,clearLabel] of fields) {
   const input=h.input(field), clear=h.button(field,clearLabel);
   await h.page.locator('#outside').focus();
   await absent(h,field,clearLabel,record,'nonempty blurred',false);
   await input.fill('');
   await absent(h,field,clearLabel,record,'empty');
   await input.evaluate(el=>{el.placeholder='Fictional display-only hint';});
   await absent(h,field,clearLabel,record,'placeholder only');
   await input.fill(original[field]); await input.fill('');
   await absent(h,field,clearLabel,record,'typed then erased');
   await input.fill(original[field]);
   assert.equal(await clear.isVisible(),true,'focused nonempty clear visible');
   let reached=false;
   for (let i=0;i<2;i++) {
    await h.page.keyboard.press('Tab');
    if (await clear.evaluate(el=>el===document.activeElement)) { reached=true; break; }
   }
   assert.ok(reached,'natural Tab reaches this field clear');
   assert.equal(await clear.isVisible(),true,'Tab keeps clear visible');
   const writes=h.writes();
   await h.page.keyboard.press('Enter');
   assert.equal(await input.inputValue(),'');
   assert.equal(await input.evaluate(el=>el===document.activeElement),true,'clear restores focus');
   assert.equal(h.writes(),writes,'clear must not save');
   await absent(h,field,clearLabel,record,'button cleared');
   for (const attr of ['readonly','disabled']) {
    await input.fill(original[field]);
    await input.evaluate((el,a)=>el.setAttribute(a,''),attr);
    await h.page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(resolve)));
    await absent(h,field,clearLabel,record,attr,false);
    await input.evaluate((el,a)=>el.removeAttribute(a),attr);
   }
   await input.fill(original[field]);
  }
  await cancel(h); await edit(h); await masked(h,original);
  record.cancelRestoresExactValues=true;
  await h.page.screenshot({path:path.join(output,`${id}-reopened.png`),fullPage:true});
 },'nodes',[original]);
});
test('T16.123 layout: independent reveals, smaller glyph and zero button overlap', async () => {
 await matrix('node-layout',{},async (base,record,id) => {
  const h=modalHarness(base);
  await edit(h); await masked(h,original);
  await stable(h);
  const r6root=process.env.R6_ROOT;
  assert.ok(r6root,'R6_ROOT is required to measure the formal r6 clear SVG');
  const r6source=fs.readFileSync(path.join(r6root,'luci-app-aether-proxy/htdocs/luci-static/resources/aether-proxy/common.js'),'utf8');
  // Evaluate the actual r6 input_action, not a copied size constant or SVG path.
  const baseline = await h.page.evaluate(async source => {
   const common=await L.require('aether-proxy.common');
   const start=source.indexOf('input_action: function(');
   const end=source.indexOf('\n\t/* Shared with the module-level TIMEOUTS',start);
   if (start<0 || end<0) throw new Error('Cannot locate formal r6 input_action');
   const declaration=source.slice(start,end).trim().replace(/,$/,'');
   const action=new Function(`return ({${declaration}}).input_action`)();
   const host=document.createElement('div'), input=document.createElement('input');
   host.append(input);
   document.querySelector('#modal_overlay .cbi-modal [data-name="uuid"] .cbi-value-field').append(host);
   const button=action.call(common,input,'clear','Fictional baseline',()=>{});
   const svg=button.querySelector('svg').getBoundingClientRect();
   const target=button.getBoundingClientRect();
   host.remove(); return {svg:{width:svg.width,height:svg.height},target:{width:target.width,height:target.height}};
  },r6source);
  record.r6Glyph=baseline;
  record.boxes=[];
  for (const [field,show,hide,clearLabel] of fields) {
   const other=field==='uuid'?'reality_pbk':'uuid';
   const input=h.input(field), clear=h.button(field,clearLabel), eye=h.button(field,show);
   await input.focus(); await input.scrollIntoViewIfNeeded();
   const a=await clear.boundingBox(), b=await eye.boundingBox(), f=await input.boundingBox();
   assert.ok(a && b && f,'missing field action boxes');
   const intersection=Math.max(0,Math.min(a.x+a.width,b.x+b.width)-Math.max(a.x,b.x))*
    Math.max(0,Math.min(a.y+a.height,b.y+b.height)-Math.max(a.y,b.y));
   const item={field,clear:a,eye:b,input:f,intersection}; record.boxes.push(item);
   await h.page.screenshot({path:path.join(output,`${id}-${field}-focused.png`),fullPage:true});
   assert.equal(intersection,0,'button hit boxes must not overlap');
   assert.ok(a.x>=f.x && a.x+a.width<=b.x && b.x+b.width<=f.x+f.width+1,'separate slots inside input');
   for (const box of [a,b]) {
    assert.ok(box.width>=24 && box.height>=24,'retain usable click target');
    assert.ok(box.y>=f.y-1 && box.y+box.height<=f.y+f.height+1,'button stays inside input height');
   }
   const glyph=await clear.locator('svg').boundingBox(); item.glyph=glyph;
   assert.ok(glyph.width<baseline.svg.width && glyph.height<baseline.svg.height,'clear SVG smaller than r6');
   assert.equal(a.width,baseline.target.width,'clear target width retained from r6');
   assert.equal(a.height,baseline.target.height,'clear target height retained from r6');
   const writes=h.writes();
   item.eyeClick=await pointer(h,eye);
   assert.equal(await input.getAttribute('type'),'text');
   assert.equal(await input.inputValue(),original[field],'reveal preserves exact value');
   assert.equal(await h.input(other).getAttribute('type'),'password','other field remains masked');
   await pointer(h,h.button(field,hide));
   assert.equal(await input.getAttribute('type'),'password');
   assert.equal(await input.inputValue(),original[field]);
   item.clearClick=await pointer(h,clear);
   assert.equal(await input.inputValue(),'');
   assert.equal(await h.input(other).inputValue(),original[other],'clear affects this field only');
   assert.equal(await input.evaluate(el=>el===document.activeElement),true);
   assert.equal(h.writes(),writes,'pointer actions do not save');
   item.emptyEye=await h.button(field,show).boundingBox();
   assert.deepEqual(item.emptyEye,b,'empty field eye does not move');
   await input.fill(original[field]);
  }
  await cancel(h); await edit(h); await masked(h,original);
 },'nodes',[original]);
});
test('T16.123 lifecycle: create, cancel, exact save/reopen and original validation', async () => {
 await matrix('node-lifecycle',{},async (base,record) => {
  const h=modalHarness(base);
  await edit(h); await masked(h,original);
  await saveModal(h); await edit(h); await masked(h,original);
  assert.equal(h.values.n_fixture.uuid,original.uuid,'unchanged UUID bytes');
  assert.equal(h.values.n_fixture.reality_pbk,original.reality_pbk,'unchanged public key bytes');
  for (const [field] of fields) {
   await h.input(field).fill(field==='uuid'?'!'.repeat(31):'invalid!');
   await h.input(field).blur();
   const writes=h.writes();
   await h.modal.locator('.button-row > .cbi-button-positive').click();
   await h.page.waitForFunction(()=>{
    const el=document.querySelector('#modal_overlay > .cbi-modal .button-row > .cbi-button-positive');
    return el && !el.disabled && !el.classList.contains('spinning');
   },null,{timeout:8000});
   assert.equal(await h.modal.isVisible(),true,'invalid edit keeps modal open');
   assert.equal(h.writes(),writes,'invalid edit cannot save');
   assert.ok(await h.row(field).locator('.cbi-input-invalid').count(),'original validator marks invalid field');
   await h.input(field).fill(original[field]);
  }
  const changed={uuid:'Fictional edited UUID',reality_pbk:'B'.repeat(43)};
  for (const [field] of fields) await h.input(field).fill(changed[field]);
  await saveModal(h); await edit(h); await masked(h,changed); await cancel(h);
  await h.page.getByRole('button',{name:tr('Add node'),exact:true}).click();
  await h.modal.waitFor({state:'visible'});
  await h.row('protocol').locator('select').selectOption('vless');
  await h.input('uuid').waitFor({state:'visible'});
  assert.equal(await h.input('uuid').getAttribute('type'),'password','new node masked');
  assert.equal(await h.input('uuid').inputValue(),'','new node starts empty');
  await h.input('uuid').fill('discarded fictional draft');
  await cancel(h);
  // Inspect actual LuCI UCI cache as well as RPC fixtures: Cancel must remove the new section.
  assert.equal(await h.page.evaluate(async()=>{
   const uci=await L.require('uci'); return uci.sections('aetherproxy','node').length;
  }),1,'cancel new node removes unsaved section');
  await h.page.getByRole('button',{name:tr('Add node'),exact:true}).click();
  await h.modal.waitFor({state:'visible'});
  await h.row('protocol').locator('select').selectOption('vless');
  await h.input('uuid').waitFor({state:'visible'});
  await h.row('security').locator('select').selectOption('reality');
  await masked(h,{uuid:'',reality_pbk:''});
  for (const [field,value] of Object.entries({address:'198.51.100.2',port:'443',sni:'example.invalid',...changed}))
   await h.input(field).fill(value);
  await saveModal(h);
  const created=Object.values(h.values).find(node=>node['.type']==='node' && node['.name']!=='n_fixture');
  assert.ok(created,'new node saved through real modal');
  await edit(h,created['.name']); await masked(h,changed); await cancel(h);
  await h.open(); await edit(h); await masked(h,changed);
  await h.row('protocol').locator('select').selectOption('vmess');
  assert.equal(await h.input('uuid').getAttribute('type'),'password','VMess UUID is also masked');
  await h.button('uuid','Show UUID').click();
  assert.equal(await h.input('uuid').inputValue(),changed.uuid,'VMess reveal preserves UUID');
  await saveModal(h); await edit(h); await masked(h,changed);
  assert.equal(h.values.n_fixture.protocol,'vmess','VMess save/reopen through native modal');
  record.lifecycle={unchanged:true,invalidRejected:true,modifiedSaved:true,newCancelled:true,newSaved:true,reloaded:true,vmess:true};
 },'nodes',[original]);
});
