import english from './translations.js';
const reverse=new Map(Object.entries(english).map(([ru,en])=>[en,ru]));
const valid=value=>value==='ru'||value==='en';
const key='funtidesk-site-language';
function initial(){
  if(typeof window==='undefined')return 'ru';
  const explicit=new URLSearchParams(location.search).get('lang');if(valid(explicit))return explicit;
  try{const saved=localStorage.getItem(key);if(valid(saved))return saved;}catch{}
  return (navigator.languages?.[0]||navigator.language||'ru').toLowerCase().startsWith('ru')?'ru':'en';
}
export let language=initial();
export function t(message,values={}){
  const source=reverse.get(message)||message;
  const translated=language==='en'?(english[source]||source):source;
  return translated.replace(/\{(\w+)\}/g,(whole,name)=>Object.hasOwn(values,name)?String(values[name]):whole);
}
let records=[];
export function initLanguage(){
  const walk=document.createTreeWalker(document.documentElement,NodeFilter.SHOW_TEXT);
  while(walk.nextNode()){
    const node=walk.currentNode;if(['SCRIPT','STYLE'].includes(node.parentElement?.tagName))continue;
    const value=node.data.trim();if(Object.hasOwn(english,value))records.push({node,value,prefix:node.data.match(/^\s*/)[0],suffix:node.data.match(/\s*$/)[0]});
  }
  for(const node of document.querySelectorAll('*'))for(const attr of ['aria-label','title','placeholder']){
    const value=node.getAttribute(attr);if(value&&Object.hasOwn(english,value))records.push({node,attr,value});
  }
  for(const select of document.querySelectorAll('[data-console-language]'))select.addEventListener('change',event=>setLanguage(event.target.value));
  apply();
}
function apply(){
  document.documentElement.lang=language;
  for(const record of records){
    const {node,value,attr,prefix,suffix}=record;if(!node.isConnected)continue;
    const current=attr?node.getAttribute(attr):node.data.trim();
    // Do not overwrite statuses or data that replaced the initial static content.
    if(current!==value&&current!==english[value])continue;
    if(attr)node.setAttribute(attr,t(value));else node.data=prefix+t(value)+suffix;
  }
  for(const select of document.querySelectorAll('[data-console-language]'))select.value=language;
}
export function setLanguage(value){
  if(!valid(value))return;language=value;
  if(typeof window==='undefined')return;
  try{localStorage.setItem(key,language);}catch{}
  const url=new URL(location.href);url.searchParams.set('lang',language);history.replaceState(null,'',url.pathname+url.search+url.hash);
  apply();document.dispatchEvent(new CustomEvent('funtidesk-languagechange'));
}
