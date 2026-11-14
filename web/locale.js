// Language preference applies to the public landing pages only.
(() => {
  const key='funtidesk-site-language';
  const isEnglish=/^\/en\/?$/.test(location.pathname);
  const isRoot=location.pathname==='/'||location.pathname==='/index.html';
  if(!isEnglish&&!isRoot)return;
  const query=new URLSearchParams(location.search);
  const explicit=query.get('lang');
  const valid=value=>value==='ru'||value==='en';
  let saved=null;
  try{saved=localStorage.getItem(key);if(valid(explicit))localStorage.setItem(key,explicit);}catch{}
  const browser=(navigator.languages?.[0]||navigator.language||'ru').toLowerCase();
  const preferred=valid(explicit)?explicit:valid(saved)?saved:(browser.startsWith('ru')?'ru':'en');
  // A direct /en/ link stays English. On the root, honour an explicit choice first.
  if((isRoot&&preferred==='en')||(isEnglish&&explicit==='ru')){
    location.replace((preferred==='en'?'/en/':'/')+location.search+location.hash);
  }
  document.addEventListener('DOMContentLoaded',()=>{
    document.querySelectorAll('[data-language]').forEach(link=>{
      const language=link.dataset.language;
      if(language===(isEnglish?'en':'ru'))link.setAttribute('aria-current','page');
      const targetQuery=new URLSearchParams(location.search);targetQuery.set('lang',language);
      link.href=(language==='en'?'/en/':'/')+'?'+targetQuery.toString()+location.hash;
      link.addEventListener('click',()=>{try{localStorage.setItem(key,language);}catch{}});
    });
  },{once:true});
})();
