'use strict';
/* Two independent real-Chromium gates. App source is selectable; assertions are not.
 * APP_ROOT=<worktree> WWW_ROOT=<root-rockchip/www> THEME_ROOT=<proton2025 static dir>
 * THEME_VERSION=1.4.5-r1 OUTPUT_DIR=<evidence dir> NODE_PATH=<playwright node_modules>
 * node --test [--test-name-pattern='visibility|layout'] tests/luci/t16.122-input-actions-gate.js
 * Local SDK modules and actual theme assets; session RPC only is simulated. No device/apply.
 */
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const { chromium } = require('playwright');
const { parsePo } = require('./loader');
const appRoot = path.resolve(process.env.APP_ROOT || path.join(__dirname, '../..'));
function required(name) { assert.ok(process.env[name], `${name} is required`); return process.env[name]; }
const www = path.resolve(required('WWW_ROOT'));
const theme = path.resolve(required('THEME_ROOT'));
const version = required('THEME_VERSION');
const output = path.resolve(required('OUTPUT_DIR'));
const control = path.resolve(process.env.THEME_CONTROL || path.join(www,'../usr/lib/opkg/info/luci-theme-proton2025.control'));
assert.equal(fs.readFileSync(control,'utf8').match(/^Version:\s*(.+)$/m)?.[1],version,'theme package version mismatch');
const app = path.join(appRoot, 'luci-app-aether-proxy');
const messages = parsePo(fs.readFileSync(path.join(app, 'po/zh_Hans/aether-proxy.po'), 'utf8'));
const tr = key => messages[key] || key;
const sha256 = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const git = (...args) => {
 const result = spawnSync('git', ['--no-optional-locks', '-C', appRoot, ...args], { encoding:'utf8' });
 assert.equal(result.status, 0, 'git metadata lookup failed'); return result.stdout.trim();
};
function shell(view, mode) {
 return `<!doctype html><html data-theme="${mode}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<link rel="stylesheet" href="/luci-static/proton2025/css/cascade.css">
<script src="/luci-static/resources/cbi.js"></script><script src="/luci-static/resources/luci.js"></script></head>
<body><div id="indicators"></div><main><div id="maincontent"><div id="view"></div></div></main><button id="outside" type="button">Outside field</button>
<script>const messages=${JSON.stringify(messages).replace(/</g, '\\u003c')};window._=key=>messages[key]||key;
window.L=new LuCI({scriptname:'/cgi-bin/luci',resource:'/luci-static/resources',base_url:'/luci-static/resources',media:'/luci-static/proton2025',ubuspath:'/ubus',sessionid:'00000000000000000000000000000000',nodespec:{satisfied:true,readonly:false}});
window.ready=L.require('view.aether-proxy.${view}');</script></body></html>`;
}
async function pageHarness(browser, mode, width, initial = {}, view = 'advanced') {
 const context = await browser.newContext({ viewport:{width,height:1000}, colorScheme:mode, serviceWorkers:'block' });
 const values = Object.fromEntries([['main','global',{lan_ifaces:['br-lan'],...initial}],['update','update',{}],['dns','dns',{}],['probe','probe',{}],['stats','stats',{}]]
  .map(([id,type,opts],i) => [id,{'.name':id,'.type':type,'.index':i,...opts}]));
 let writes = 0;
 const unexpected = [];
 const fixtures = {
  'session.access':()=>({access:true}), 'luci.getFeatures':()=>({}), 'luci.getInitList':()=>({}),
  'uci.get':({config})=>({values:config === 'aetherproxy' ? values : {}}), 'uci.changes':()=>({changes:{}}),
  'uci.set':({section,values:incoming})=>{ writes++; Object.assign(values[section],incoming); return {}; },
  'uci.delete':({section,options})=>{ writes++; for (const key of options || []) delete values[section][key]; return {}; },
  'aetherproxy.status':()=>({ok:true,explicit_lan:{interface:'lan',addresses:['192.0.2.1']}}),
  'network.get_proto_handlers':()=>({}), 'network.interface.dump':()=>({interface:[]}),
  'luci-rpc.getBoardJSON':()=>({}), 'luci-rpc.getHostHints':()=>({}),
  'luci-rpc.getNetworkDevices':()=>({'br-lan':{name:'br-lan',devtype:'bridge',up:true,ipaddrs:[{address:'192.0.2.1',netmask:'255.255.255.0'}]}})
 };
 await context.route('**/*', async route => {
  const request = route.request(), url = new URL(request.url());
  if (url.origin !== 'http://luci.test') { unexpected.push('external request'); return route.abort(); }
  if (url.pathname === '/') return route.fulfill({contentType:'text/html',body:shell(view,mode)});
  if (url.pathname === '/ubus') {
   const reply = call => {
    if (call.method === 'list') return {jsonrpc:'2.0',id:call.id,result:{}};
    const [,object,method,params] = call.params, key = object+'.'+method;
    if (!fixtures[key]) { unexpected.push(key); return {jsonrpc:'2.0',id:call.id,result:[3]}; }
    return {jsonrpc:'2.0',id:call.id,result:[0,fixtures[key](params || {})]};
   };
   const data = request.postDataJSON();
   return route.fulfill({json:Array.isArray(data) ? data.map(reply) : reply(data)});
  }
  if (url.pathname.startsWith('/luci-static/')) {
   const name = url.pathname.slice('/luci-static/'.length);
   const files = name.startsWith('proton2025/') ? [path.join(theme,name.slice('proton2025/'.length))] :
    [path.join(app,'htdocs/luci-static',name),path.join(www,'luci-static',name)];
   const file = files.find(file => fs.statSync(file,{throwIfNoEntry:false})?.isFile());
   if (file) return route.fulfill({path:file});
  }
  unexpected.push(url.pathname); return route.fulfill({status:404});
 });
 const page = await context.newPage();
 page.setDefaultTimeout(8000);
 page.on('pageerror', error => {
  if (!/invalid input value|Authentication requires both|共享用户名和密码/.test(error.message)) unexpected.push('SDK page error');
 });
 const row = field => page.locator(`[data-name="${field}"]`);
 const input = field => row(field).locator('input').first();
 const button = (field,label) => row(field).getByRole('button',{name:tr(label),exact:true,includeHidden:true});
 const tab = () => page.locator('.cbi-tabmenu a').filter({hasText:tr('LAN explicit proxy')}).click();
 const open = async () => { await page.goto('http://luci.test'); await page.evaluate(()=>window.ready.then(()=>null)); if (view === 'advanced') await tab(); };
 const reset = async () => { await page.locator('.cbi-button-reset').click(); if (view === 'advanced') await tab(); };
 const save = async () => { await page.locator('.cbi-button-save').click(); await page.waitForFunction(()=>!document.querySelector('.cbi-button-save').disabled); };
 return {context,page,values,row,input,button,tab,open,reset,save,writes:()=>writes,unexpected};
}
async function matrix(name, initial, exercise) {
 fs.mkdirSync(output,{recursive:true});
 const metadata = {theme:'proton2025',version,themeRoot:theme,control,controlSHA256:sha256(control),cssSHA256:sha256(path.join(theme,'css/cascade.css')),
  sourceSHA256:Object.fromEntries(['aether-proxy/common.js','view/aether-proxy/advanced.js','view/aether-proxy/updates.js'].map(file=>[file,sha256(path.join(app,'htdocs/luci-static/resources',file))])),
  gateSHA256:sha256(__filename),appRoot,commit:git('rev-parse','HEAD'),dirty:git('status','--porcelain'),scope:'real LuCI modules + actual theme CSS; simulated session RPC, no device',cases:[]};
 const browser = await chromium.launch();
 metadata.chromium = browser.version();
 const failures = [];
 try {
  for (const mode of ['dark','light']) for (const width of [1280,360]) {
   const id = `${name}-${mode}-${width}`, record = {id,mode,width};
   let h;
   try {
    h = await pageHarness(browser,mode,width,initial);
    await h.open();
    await exercise(h,record,id,browser);
    assert.deepEqual(h.unexpected,[],'unexpected requests/errors');
    record.result = 'PASS';
   } catch (error) {
    record.result = 'FAIL'; record.error = error.message; failures.push(`${id}: ${error.message}`);
   } finally {
    if (h) {
     try { await h.page.screenshot({path:path.join(output,`${id}-final.png`),fullPage:true}); }
     catch (error) { failures.push(`${id}: screenshot failed: ${error.message}`); }
     await h.context.close();
    }
    metadata.cases.push(record);
   }
  }
 } finally {
  await browser.close();
  fs.writeFileSync(path.join(output,`${name}.json`),JSON.stringify(metadata,null,2)+'\n');
 }
 assert.deepEqual(failures,[],`${name}: each matrix entry must pass`);
}
// Does not trust hidden alone: records final computed styles, geometry, hit testing and real Tab traversal.
async function absent(h, field, label, record, state, traverse = true) {
 const clear = h.button(field,label);
 const result = await clear.evaluate(button => {
  const style = getComputedStyle(button), rect = button.getBoundingClientRect();
  let hit = false;
  if (rect.width && rect.height) for (const [fx,fy] of [[.1,.1],[.5,.5],[.9,.9]]) {
   const target = document.elementFromPoint(rect.x+rect.width*fx,rect.y+rect.height*fy);
   hit ||= target === button || button.contains(target);
  }
  return {display:style.display,visibility:style.visibility,opacity:style.opacity,rect:rect.toJSON(),hit,tabIndex:button.tabIndex,disabled:button.disabled,
   painted:!!button.getClientRects().length && style.display !== 'none' && style.visibility !== 'hidden' && Number(style.opacity) !== 0};
 });
 (record.visibility ||= []).push({field,state,...result});
 assert.equal(result.painted,false,`${state}: clear is painted`);
 assert.equal(result.hit,false,`${state}: clear is hit-testable`);
 if (!traverse) return;
 // Tab from the empty input through this row: never directly focus the hidden button.
 await h.input(field).focus();
 for (let i=0;i<4;i++) {
  await h.page.keyboard.press('Tab');
  assert.equal(await clear.evaluate(button=>button === document.activeElement),false,`${state}: clear in Tab sequence`);
 }
 await h.page.locator('#outside').focus();
}
test('T16.122 visibility: final rendering, hit testing and keyboard focus', async () => {
 await matrix('visibility',{},async (h,record,id) => {
  for (const [field,label] of [['proxy_username','Clear username'],['proxy_password','Clear password']]) {
   const input = h.input(field), clear = h.button(field,label);
   await absent(h,field,label,record,'initial empty');
   await input.evaluate(el=>{el.placeholder='Display-only hint';});
   await absent(h,field,label,record,'placeholder only');
   await input.fill('fictional-draft'); await input.fill('');
   await absent(h,field,label,record,'typed then erased');
   await input.fill('fictional-draft'); await h.page.locator('#outside').focus();
   // Test loss of focus before absent() focuses the input again.
   await absent(h,field,label,record,'nonempty blurred',false);
   await input.focus(); assert.equal(await clear.isVisible(),true,'nonempty focused clear absent');
   // Password eye is first in DOM; Tab must keep the whole field active until clear.
   let reached = false;
   for (let i=0;i<2;i++) { await h.page.keyboard.press('Tab'); if (await clear.evaluate(el=>el===document.activeElement)) { reached=true; break; } }
   assert.ok(reached,'Tab from input must reach clear');
   assert.equal(await clear.isVisible(),true,'clear vanished while keyboard-focused');
   const writes = h.writes();
   await h.page.keyboard.press('Enter');
   assert.equal(await input.inputValue(),'');
   assert.equal(await input.evaluate(el=>el===document.activeElement),true,'clear must restore input focus');
   assert.equal(h.writes(),writes,'clear submitted data');
   await absent(h,field,label,record,'cleared');
   for (const attribute of ['readonly','disabled']) {
    await input.fill('fictional-draft'); await input.evaluate((el,attr)=>el.setAttribute(attr,''),attribute);
    await h.page.evaluate(()=>new Promise(resolve=>requestAnimationFrame(resolve)));
    await absent(h,field,label,record,attribute,false);
    await input.evaluate((el,attr)=>el.removeAttribute(attr),attribute);
   }
   await h.reset();
   await absent(h,field,label,record,'reset to empty');
  }
  await h.page.screenshot({path:path.join(output,`${id}-empty.png`),fullPage:true});
 });
});
test('T16.122 layout: zero button intersection and real coordinate clicks', async () => {
 await matrix('layout',{proxy_username:'fictional-user',proxy_password:'fictional-secret'},async (h,record,id,browser) => {
  const field = h.input('proxy_password');
  const clear = h.button('proxy_password','Clear password');
  const eye = () => h.row('proxy_password').getByRole('button',{name:new RegExp(`${tr('Show password')}|${tr('Hide password')}`)});
  await field.focus(); await field.scrollIntoViewIfNeeded();
  const a = await clear.boundingBox(), b = await eye().boundingBox(), f = await field.boundingBox();
  assert.ok(a && b && f,'missing hit boxes');
  const intersection = Math.max(0,Math.min(a.x+a.width,b.x+b.width)-Math.max(a.x,b.x))*Math.max(0,Math.min(a.y+a.height,b.y+b.height)-Math.max(a.y,b.y));
  record.boxes = {clear:a,eye:b,input:f,intersection};
  record.clicks = {eye:{x:b.x+b.width/2,y:b.y+b.height/2},clear:{x:a.x+a.width/2,y:a.y+a.height/2}};
  await h.page.screenshot({path:path.join(output,`${id}-focused.png`),fullPage:true});
  assert.equal(intersection,0,'clear and eye button hit boxes overlap');
  assert.ok(a.x+a.width<=b.x && b.x+b.width<=f.x+f.width+1 && a.x>=f.x,'slots must be separate, eye rightmost and inside input');
  for (const box of [a,b]) {
   assert.ok(box.width>=24 && box.height>=24,'insufficient click target');
   assert.ok(box.y>=f.y-1 && box.y+box.height<=f.y+f.height+1,'button outside input height');
  }
  const appearance = await clear.evaluate(el=>{const s=getComputedStyle(el);return {radius:s.borderRadius,shadow:s.boxShadow};});
  assert.equal(appearance.radius,'0px','clear has rounded frame');
  assert.equal(appearance.shadow,'none','clear has theme shadow');
  const before = await field.inputValue(), user = await h.input('proxy_username').inputValue(), writes = h.writes();
  const pointer = async (locator,point) => {
   assert.equal(await locator.evaluate((el,p)=>{const hit=document.elementFromPoint(p.x,p.y);return el===hit || el.contains(hit);},point),true,'coordinate misses intended button');
   await h.page.mouse.click(point.x,point.y);
  };
  assert.equal(await field.getAttribute('type'),'password');
  await pointer(eye(),record.clicks.eye);
  assert.equal(await field.getAttribute('type'),'text'); assert.equal(await field.inputValue(),before);
  await pointer(eye(),record.clicks.eye);
  assert.equal(await field.getAttribute('type'),'password'); assert.equal(await field.inputValue(),before);
  await pointer(clear,record.clicks.clear);
  assert.equal(await field.inputValue(),''); assert.equal(await h.input('proxy_username').inputValue(),user);
  assert.equal(await field.evaluate(el=>el===document.activeElement),true);
  assert.equal(h.writes(),writes,'pointer actions submitted data');
  const emptyEye = await eye().boundingBox(); record.emptyEye = emptyEye;
  assert.deepEqual(emptyEye,b,'eye moves when clear disappears');
  await h.reset(); assert.equal(await field.getAttribute('type'),'password'); assert.equal(await field.inputValue(),before);
  await field.fill('fictional-replacement'); await h.save(); await h.open();
  assert.equal(await field.inputValue(),'fictional-replacement','save/reopen regression');
  const updates = await pageHarness(browser,record.mode,record.width,{},'updates');
  try {
   await updates.open();
   const row = updates.row('channel_urls'), url = row.locator('.add-item > input');
   const copy = row.getByRole('button',{name:tr('Copy channel URL'),exact:true});
   await copy.focus(); await updates.page.keyboard.press('Enter');
   await row.getByRole('button',{name:tr('Copied'),exact:true}).waitFor();
   assert.equal(await url.inputValue(),'','default copy changed draft');
   await url.focus(); await updates.page.keyboard.press('Control+v');
   assert.equal(await url.inputValue(),await url.getAttribute('placeholder'),'default URL copy/paste');
   const u = await url.boundingBox(), c = await copy.boundingBox(), plus = await row.locator('.cbi-button-add').boundingBox();
   record.channelBoxes = {input:u,copy:c,plus};
   assert.ok(c.x>=u.x && c.x+c.width<=u.x+u.width+1 && plus.x>=u.x+u.width-1,'copy/native plus layout');
   assert.ok(plus.x+plus.width<=record.width,'channel controls overflow viewport');
   await url.fill(''); await updates.save();
   assert.equal(updates.values.update.channel_urls,undefined,'unmodified default was saved');
   assert.deepEqual(updates.unexpected,[],'unexpected update-page requests/errors');
   await updates.page.screenshot({path:path.join(output,`${id}-channel.png`),fullPage:true});
  } finally { await updates.context.close(); }
 });
});
