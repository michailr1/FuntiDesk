const support=document.querySelector('#support-widget');
const trigger=support.querySelector('summary');
function closeSupport(){support.open=false;trigger.focus();}
support.querySelector('.support-close').addEventListener('click',closeSupport);
support.addEventListener('keydown',event=>{
  if(event.key==='Escape'&&support.open){event.preventDefault();closeSupport();}
});
document.addEventListener('pointerdown',event=>{
  if(support.open&&!support.contains(event.target))support.open=false;
});
