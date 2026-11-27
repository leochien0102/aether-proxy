'use strict';
/* Shared assembly contract; Chromium gate covers real SDK/DOM/theme geometry. */
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { loadModule } = require('./loader');
const commonFile = path.resolve(__dirname,
 '../../luci-app-aether-proxy/htdocs/luci-static/resources/aether-proxy/common.js');
test('T16.123 shared field assembly preserves SDK identity and uses the cloned section id', () => {
 const document={activeElement:null};
 const observed=[];
 const oldObserver=globalThis.MutationObserver;
 globalThis.MutationObserver=class {
  constructor(callback) { this.callback=callback; }
  observe(input,options) { observed.push({input,options,callback:this.callback}); }
 };
 try {
  const Common=loadModule(commonFile,{
   baseclass:{extend(prototype){
    function Common() {}
    Object.assign(Common.prototype,prototype);
    return Common;
   }},rpc:{declare:()=>()=>{}},ui:{},uci:{}
  },{window:{},document});
  assert.equal(Common.input_action,undefined,'LuCI constructor has no static input_action');
  const ap=new Common();
  const buttons=[];
  ap.input_action=(input,icon,label,click,inset=0)=>{
   const button={input,icon,label,click,inset,style:{setProperty(name,value,priority){this[name]=[value,priority];}},
    setIcon(name,text){this.icon=name;this.label=text;}};
   input.parentElement.members.add(button); buttons.push(button); return button;
  };
  const rendered=[];
  const selectors=[];
  const validated=[];
  const write=()=>{};
  const option={password:true,write,validate:()=>true,renderWidget(id,index,value){
   const listeners={};
   const host={members:new Set(),addEventListener(type,fn){listeners['host:'+type]=fn;},contains(el){return this.members.has(el);}};
   const input={value,type:'text',readOnly:false,disabled:false,parentElement:host,
    nextElementSibling:{remove(){input.externalRemoved=true;}},
    addEventListener(type,fn){listeners[type]=fn;},
    dispatchEvent(event){listeners[event.type]?.(event);},
    focus(){document.activeElement=input;listeners['host:focusin']?.();}};
   host.members.add(input);
   const widget={querySelector:selector=>{selectors.push(selector);return input;}};
   rendered.push({id,index,widget,input,listeners}); return widget;
  },triggerValidation(id){validated.push(id);}};
  assert.equal(ap.field_actions(option,{show:'Show field',hide:'Hide field',clear:'Clear field'}),option);
  // GridSection copies own methods to a new option; it does not bind the parent option.
  const clone={...option,password:true};
  assert.equal(clone.renderWidget,option.renderWidget,'clone keeps the same closure');
  const widget=clone.renderWidget('node-one',2,'Fictional value');
  const {input,listeners}=rendered[0];
  const [eye,clear]=buttons;
  assert.equal(widget,rendered[0].widget,'retain actual SDK widget');
  assert.equal(option.write,write,'retain custom writer');
  assert.equal(input.type,'password'); assert.equal(input.externalRemoved,true);
  assert.equal(clear.inset,1.75);
  assert.equal(clear.hidden,true); assert.equal(clear.disabled,true); assert.equal(clear.tabIndex,-1);
  assert.deepEqual(clear.style.display,['none','important']);
  input.focus(); assert.equal(clear.hidden,false);
  eye.click(); assert.equal(input.type,'text'); assert.equal(input.value,'Fictional value');
  assert.equal(eye.label,'Hide field');
  document.activeElement=clear; listeners['host:focusout']({relatedTarget:clear});
  assert.equal(clear.hidden,false,'focus retained on own action');
  clear.click(); assert.equal(input.value,''); assert.equal(document.activeElement,input);
  assert.deepEqual(validated,['node-one'],'validate current cloned section, not main');
  assert.equal(clear.hidden,true);
  input.value='Fictional value'; input.focus(); input.readOnly=true; observed[0].callback();
  assert.equal(clear.hidden,true);
  input.readOnly=false; input.disabled=true; observed[0].callback(); assert.equal(clear.hidden,true);
  input.disabled=false; input.focus(); listeners['host:focusout']({relatedTarget:null});
  assert.equal(clear.hidden,true,'blur hides clear');
  clone.renderWidget('node-two',3,'Second fictional value');
  assert.equal(rendered[1].input.type,'password','reopened widget resets mask');
  assert.equal(rendered[1].input.value,'Second fictional value');
  buttons[2].click(); assert.equal(rendered[1].input.type,'text');
  assert.equal(input.type,'text','second reveal does not toggle first widget');
  const plain=Object.assign(Object.create(option),{password:false});
  plain.renderWidget('plain',0,'Fictional user');
  assert.equal(buttons.length,5,'plain field gets clear only');
  assert.equal(buttons[4].inset,0);
  // A list caller supplies the add-input selector, not an assembled wrapper.
  const listRenderer={password:false,renderWidget(id,index,value){
   return {querySelector(selector){
    assert.equal(selector,'.add-item > input');
    return rendered[2].input;
   }};
  },triggerValidation(id){validated.push(id);}};
  ap.field_actions(listRenderer,{clear:'Clear new item'},'.add-item > input');
  listRenderer.renderWidget('list',0,'');
  assert.deepEqual(selectors,['input','input','input']);
  assert.equal(buttons.length,6,'selected list add input gets one clear action');
 } finally {
  if (oldObserver===undefined) delete globalThis.MutationObserver;
  else globalThis.MutationObserver=oldObserver;
 }
});

test('T16.123 modal double renders SDK-like hosts and exercises cloned field actions', async () => {
 const previous={E:globalThis.E,tr:globalThis._,format:String.prototype.format,observer:globalThis.MutationObserver};
 try {
  const { harness }=require('./required-modal');
  globalThis._=text=>text;
  String.prototype.format=function(...args){let i=0;return this.replace(/%s/g,()=>String(args[i++]));};
  const h=await harness('node',{
   protocol:'vless',address:'203.0.113.10',port:'443',security:'reality',sni:'example.invalid',
   uuid:'Fictional UUID',reality_pbk:'A'.repeat(43)
  });
  const uuid=h.option('uuid'), key=h.option('reality_pbk');
  assert.notEqual(uuid.map,h.view.nodeMap,'modal owns its map, not the parent table');
  assert.equal(uuid.renderWidget,h.grid.children.find(option=>option.option==='uuid').renderWidget);
  assert.equal(uuid.input.type,'password');
  assert.equal(key.input.type,'password');
  const actions=uuid.input.parentElement.querySelectorAll('button');
  assert.equal(actions.length,2,'replace SDK reveal with exactly one eye and one clear');
  const [eye,clear]=actions;
  uuid.input.focus();
  assert.equal(clear.hidden,false);
  eye.click();
  assert.equal(uuid.input.type,'text');
  assert.equal(key.input.type,'password','other cloned field stays masked');
  const validated=[];
  const validate=uuid.triggerValidation;
  uuid.triggerValidation=function(id){validated.push([this,id]);return validate.call(this,id);};
  clear.click();
  assert.equal(uuid.input.value,'');
  assert.deepEqual(validated,[[uuid,'row']],'clear validates this cloned section');
  assert.equal(clear.hidden,true);
  assert.deepEqual(h.calls,[],'render/reveal/clear do not write UCI');
  await h.openModal();
  assert.equal(h.option('uuid').input.type,'password','reopening creates a fresh masked input');
  assert.equal(h.option('uuid').input.value,'Fictional UUID','unsaved draft is discarded');
 } finally {
  globalThis.E=previous.E; globalThis._=previous.tr;
  if (previous.format===undefined) delete String.prototype.format;
  else String.prototype.format=previous.format;
  if (previous.observer===undefined) delete globalThis.MutationObserver;
  else globalThis.MutationObserver=previous.observer;
 }
});
