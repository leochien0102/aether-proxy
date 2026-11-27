'use strict';
/* Fixture contract only: real common helpers with the unit DOM, no browser
 * geometry claims. Protect old page doubles from silently replacing helpers
 * with no-ops when the application adds a shared entry point. */
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadModule } = require('./loader');
const { modalElement: E, modalDocument } = require('./modal-dom');
const RES = path.resolve(__dirname,'../../luci-app-aether-proxy/htdocs/luci-static/resources');
function fixture() {
 globalThis.E=E;
 globalThis._=text=>text;
 modalDocument.activeElement=null;
 const call=async()=>({ok:true});
 const ap={call};
 loadModule(path.join(RES,'view/aether-proxy/logs.js'), {
  view:{extend:object=>object},uci:{},dom:{},'aether-proxy.common':ap,'aether-proxy.model.logs':{}
 },{window:{},document:modalDocument});
 return {ap,call};
}
test('T16.125 fixture loader retains RPC stubs and supplies the complete real action helper group',()=>{
 const {ap,call}=fixture();
 assert.equal(ap.call,call,'loading shared UI helpers must not replace fixture RPC behavior');
 for(const method of ['input_action','field_actions','text_actions','clear_input'])
  assert.equal(typeof ap[method],'function',method);
 const input=E('input',{type:'text',value:'draft'}), host=E('span',{},[input]);
 let validations=0;
 const action=ap.clear_input(input,null,()=>validations++);
 assert.equal(host.querySelectorAll('button').length,1);
 assert.equal(ap.clear_input(input),action,'real per-input duplicate guard');
 assert.equal(action.hidden,true);
 input.focus(); assert.equal(action.hidden,false);
 action.attrs.click();
 assert.equal(input.value,''); assert.equal(modalDocument.activeElement,input);
 assert.equal(validations,1); assert.equal(action.hidden,true); assert.equal(action.disabled,true);
 assert.equal(action.tabIndex,-1);
 assert.equal(input.resizeObservers.length,1,'one size observer per input');
});
test('T16.125 fixture DOM supports shared field selection, SDK password replacement and readonly exclusion',()=>{
 const {ap}=fixture();
 class Value {
  constructor(password=false) {this.password=password;this.map={};this.validations=0;}
  renderWidget() {
   this.input=E('input',{type:'text',class:this.password?'cbi-input-password':'cbi-input-text',value:'original'});
   return E('div',{},[this.input,...(this.password?[E('button',{class:'cbi-button cbi-button-neutral'},'Reveal')]:[])]);
  }
  triggerValidation(){this.validations++;}
 }
 class DynamicList extends Value {}
 class ListValue extends Value {}
 class TextValue extends Value {}
 const ordinary=new Value(), secret=new Value(true), readonly=new Value(), select=new ListValue(), long=new TextValue();
 readonly.readonly=true;
 const section={children:[ordinary,secret,readonly,select,long]};
 const form={Value,DynamicList,ListValue,TextValue};
 ap.text_actions(section,form); ap.text_actions(section,form);
 assert.equal(select.apFieldActions,undefined); assert.equal(long.apFieldActions,undefined);
 const plain=ordinary.renderWidget('row'), password=secret.renderWidget('row'), locked=readonly.renderWidget('row');
 assert.equal(plain.querySelectorAll('button').length,1);
 assert.equal(locked.querySelectorAll('button').length,0);
 assert.equal(password.querySelectorAll('button').length,2,'SDK reveal replaced, no duplicate eye');
 assert.equal(secret.input.type,'password');
 assert.equal(secret.input.resizeObservers.length,1,'eye and clear share the same observer');
 secret.input.focus();
 password.querySelector('button[data-ap-action="clear"]').attrs.click();
 assert.equal(secret.input.value,''); assert.equal(secret.validations,1);
 assert.equal(secret.input.type,'password');
 assert.equal(ordinary.input.value,'original','clear only this field');
});
test('fixture event attributes and DOM dispatch deliver original and added handlers exactly once',()=>{
 const calls=[];
 const node=E('select',{change:event=>{
  assert.equal(event.target,node); assert.equal(event.currentTarget,node);
  calls.push('attribute');
 }});
 node.addEventListener('change',event=>{
  assert.equal(event.target,node); calls.push('first');
 });
 node.addEventListener('change',()=>calls.push('second'));
 assert.equal(typeof node.attrs.change,'function','preserve legacy fixture trigger');
 node.attrs.change();
 assert.deepEqual(calls,['attribute','first','second']);
 calls.length=0;
 node.dispatchEvent(new Event('change'));
 assert.deepEqual(calls,['attribute','first','second']);
 calls.length=0;
 node.emit('change');
 assert.deepEqual(calls,['attribute','first','second']);
 const parent=E('div',{},[node]);
 parent.addEventListener('change',()=>calls.push('parent'));
 calls.length=0;
 node.dispatchEvent(new Event('change',{bubbles:true}));
 assert.deepEqual(calls,['attribute','first','second','parent']);
});
