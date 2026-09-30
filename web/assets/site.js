document.querySelectorAll('[data-year]').forEach(el=>el.textContent=new Date().getFullYear());

const $=(s,p=document)=>p.querySelector(s), $$=(s,p=document)=>[...p.querySelectorAll(s)];

const glow=$('.cursorGlow');
if(glow) addEventListener('pointermove',e=>{glow.style.left=e.clientX+'px';glow.style.top=e.clientY+'px'});

const io=new IntersectionObserver(entries=>entries.forEach(e=>{if(e.isIntersecting)e.target.classList.add('visible')}),{threshold:.12});
$$('.reveal').forEach(el=>io.observe(el));

$$('[data-count]').forEach(el=>{
  const target=+el.dataset.count;
  let started=false;
  const obs=new IntersectionObserver(es=>es.forEach(e=>{
    if(e.isIntersecting&&!started){started=true;let n=0;const t=setInterval(()=>{n+=Math.max(1,Math.ceil((target-n)/7));if(n>=target){n=target;clearInterval(t)}el.textContent=n},45)}
  }),{threshold:.5});obs.observe(el)
});

$$('.tiltCard').forEach(card=>{
  card.addEventListener('pointermove',e=>{
    const r=card.getBoundingClientRect(),x=(e.clientX-r.left)/r.width-.5,y=(e.clientY-r.top)/r.height-.5;
    card.style.transform=`perspective(800px) rotateX(${-y*8}deg) rotateY(${x*10}deg) translateZ(4px)`;
  });
  card.addEventListener('pointerleave',()=>card.style.transform='');
});

$$('.magnetic').forEach(el=>{
  el.addEventListener('pointermove',e=>{const r=el.getBoundingClientRect();el.style.transform=`translate(${(e.clientX-r.left-r.width/2)*.08}px,${(e.clientY-r.top-r.height/2)*.08}px)`});
  el.addEventListener('pointerleave',()=>el.style.transform='');
});

const stage=$('#networkStage'), demo=$('#demoPulse');
if(stage&&demo){
  demo.addEventListener('click',()=>{
    stage.classList.remove('stageBurst'); void stage.offsetWidth; stage.classList.add('stageBurst');
    $$('.wordmarkMorph span').forEach(s=>{s.style.setProperty('--rx',(Math.random()*70-35)+'px');s.style.setProperty('--ry',(-20-Math.random()*45)+'px');s.style.setProperty('--rr',(Math.random()*18-9)+'deg')});
    setTimeout(()=>stage.classList.remove('stageBurst'),1000);
  });
}

const lab=$('.lab'), latency=$('#latency'), routeText=$('#routeText');
const modes={p2p:{latency:24,text:'Прямой P2P'},relay:{latency:48,text:'Через Relay'},blocked:{latency:83,text:'Relay · обход сложной сети'}};
$$('.modeBtn').forEach(btn=>btn.addEventListener('click',()=>{
  $$('.modeBtn').forEach(x=>x.classList.remove('active'));btn.classList.add('active');
  lab.classList.remove('relayMode','blockedMode');
  if(btn.dataset.mode==='relay')lab.classList.add('relayMode');
  if(btn.dataset.mode==='blocked')lab.classList.add('blockedMode');
  const cfg=modes[btn.dataset.mode];routeText.textContent=cfg.text;
  const from=+latency.textContent,to=cfg.latency,start=performance.now(),dur=350;
  const tick=t=>{const k=Math.min(1,(t-start)/dur);latency.textContent=Math.round(from+(to-from)*k);if(k<1)requestAnimationFrame(tick)};requestAnimationFrame(tick);
}));

const canvas=$('#starfield');
if(canvas){
 const ctx=canvas.getContext('2d');let w,h,dpr,pts=[];
 const resize=()=>{dpr=Math.min(devicePixelRatio||1,2);w=canvas.clientWidth;h=canvas.clientHeight;canvas.width=w*dpr;canvas.height=h*dpr;ctx.setTransform(dpr,0,0,dpr,0,0);pts=Array.from({length:Math.min(110,Math.floor(w/12))},()=>({x:Math.random()*w,y:Math.random()*h,v:.08+Math.random()*.18,r:.5+Math.random()*1.5}))};resize();addEventListener('resize',resize);
 const draw=()=>{ctx.clearRect(0,0,w,h);for(const p of pts){p.y-=p.v;if(p.y<0)p.y=h;ctx.beginPath();ctx.fillStyle='rgba(100,190,255,'+(0.18+p.r*.12)+')';ctx.arc(p.x,p.y,p.r,0,Math.PI*2);ctx.fill()}requestAnimationFrame(draw)};draw();
}

const cat=$('#funtiCat');
if(cat){cat.addEventListener('click',()=>{const b=$('.catBubble',cat);b.textContent=['маршрут вижу 👀','P2P свободен ✓','Relay наготове ⚡','мяу-туннель стабилен 😼'][Math.floor(Math.random()*4)];b.style.opacity=1;b.style.transform='none';setTimeout(()=>{b.style.opacity=''},1500)})}

addEventListener('scroll',()=>{
 const y=scrollY;
 if(stage&&innerWidth>900) stage.style.transform=`translateY(${Math.min(34,y*.035)}px) rotateX(${Math.min(3,y*.002)}deg)`;
},{passive:true});