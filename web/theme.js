// Website theme only. The remote OS/video scene keeps its own appearance.
(() => {
  const key='funtidesk-sites-theme';
  const modes=['light','dark','system'];
  const media=window.matchMedia('(prefers-color-scheme: dark)');
  let preference='light',systemDark=media.matches;
  try{const saved=localStorage.getItem(key);if(modes.includes(saved))preference=saved;}catch{}
  const palettes={light:{text:'#102249',link:'#0F5AD6',accent:'#1267EF',bg:'#F4F1EC'},dark:{text:'#EEEAE3',link:'#7DB2FF',accent:'#2A73F0',bg:'#14130F'}};
  const bound=new WeakSet();
  function resolved(){return preference==='system'?(systemDark?'dark':'light'):preference;}
  function bindControls(){document.querySelectorAll('[data-theme-select]').forEach(select=>{select.value=preference;if(bound.has(select))return;bound.add(select);select.addEventListener('change',()=>set(select.value));});}
  function apply(){const theme=resolved();document.documentElement.dataset.theme=theme;document.documentElement.dataset.themePreference=preference;const meta=document.querySelector('meta[name="theme-color"]');if(meta)meta.content=palettes[theme].bg;bindControls();window.dispatchEvent(new CustomEvent('funtidesk-themechange',{detail:{preference,theme}}));}
  function set(value){if(!modes.includes(value))return;preference=value;if(value==='system')systemDark=media.matches;try{localStorage.setItem(key,value);}catch{}apply();}
  window.FuntiTheme={set,bindControls,preference:()=>preference,resolved,colors:()=>palettes[resolved()]};
  // Use the event's value: a retained MediaQueryList can lag during a scheme change.
  function systemThemeChanged(event){systemDark=event.matches;if(preference==='system')apply();}
  if(media.addEventListener)media.addEventListener('change',systemThemeChanged);else if(media.addListener)media.addListener(systemThemeChanged);
  apply();document.addEventListener('DOMContentLoaded',bindControls,{once:true});
})();
