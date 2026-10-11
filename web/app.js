const $=(s,r=document)=>r.querySelector(s);const $$=(s,r=document)=>[...r.querySelectorAll(s)];

// Keep the site demo structurally aligned with the current M3 client:
// the transport indicator belongs to RemoteToolbar, not to a separate title/status bar.
const sessionChip=$('#session-chip');const sessionToolbar=$('.session-toolbar');
if(sessionChip&&sessionToolbar){
  sessionToolbar.appendChild(sessionChip);
  Object.assign(sessionChip.style,{marginLeft:'2px',border:'1px solid rgba(255,255,255,.08)',background:'#242430',borderRadius:'999px',padding:'6px 9px',color:'rgba(242,242,247,.72)',fontSize:'12px',display:'inline-flex',alignItems:'center',whiteSpace:'nowrap'});
}
const peerNotes=$$('.fd-peer small');if(peerNotes[2])peerNotes[2].textContent='последнее подключение';

let transport='auto';
$$('[data-transport]').forEach((button)=>{
  button.addEventListener('click',()=>{
    transport=button.dataset.transport;
    $$('[data-transport]').forEach((x)=>x.classList.toggle('active',x===button));
  });
});

$('#demo-connect')?.addEventListener('click',()=>{
  const field=$('#remote-id');
  const id=(field?.value||'').trim();
  if(!id){field?.focus();field?.setAttribute('placeholder','Введите ID устройства');return;}
  const mode=transport==='relay'?'Relay':'Auto';const button=$('#demo-connect');const old=button.textContent;
  button.textContent=`${mode} · подключение…`;setTimeout(()=>{button.textContent=old},1100);
});

$('#refresh-otp')?.addEventListener('click',()=>{
  const alphabet='ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
  let value='';for(let i=0;i<6;i++)value+=alphabet[Math.floor(Math.random()*alphabet.length)];
  const target=$('#otp-value');if(target)target.textContent=value;
});

let relayExample=false;
$('#toggle-session-route')?.addEventListener('click',()=>{
  relayExample=!relayExample;
  const chip=$('#session-chip');const text=chip?.querySelector('span');const dot=chip?.querySelector('i');const info=$('#session-info');const button=$('#toggle-session-route');
  if(text)text.textContent=relayExample?'Relay':'P2P';if(dot)dot.style.background=relayExample?'#f5a623':'#34c77b';
  if(info)info.innerHTML=relayExample?'<b>Relay</b><br/>Сессия идёт через релейный сервер. Это штатный fallback, когда прямой маршрут недоступен.':'<b>P2P</b><br/>Прямое защищённое соединение. Клиент показывает транспорт по реальному состоянию сессии.';
  if(button)button.textContent=relayExample?'Показать P2P ↻':'Показать Relay ↻';
});

const conceptCopy={
  family:'Семейный доступ: доверенное устройство появляется по понятному имени; разрешения задаются отдельно. В текущем M3-интерфейсе этот экран ещё не выдаётся за готовый.',
  help:'Запрос помощи: близкий отправляет явный запрос, а помощник видит, кто просит помощь и к какому устройству предлагается подключиться.',
  call:'Звонок: отдельное явное действие. Входящий вызов требует ответа; скрытый автоответ здесь не подразумевается.'
};
$$('[data-concept]').forEach((button)=>button.addEventListener('click',()=>{const output=$('#concept-output');if(output)output.innerHTML=`<strong>Сценарий:</strong> ${conceptCopy[button.dataset.concept]||''}`;output?.scrollIntoView({behavior:'smooth',block:'nearest'});}));