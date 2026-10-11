const $=(s,r=document)=>r.querySelector(s);const $$=(s,r=document)=>[...r.querySelectorAll(s)];

const motion=$('#motion-lab');const playMotion=()=>{motion?.classList.remove('playing');void motion?.offsetWidth;motion?.classList.add('playing')};
$('#animate-link')?.addEventListener('click',()=>{motion?.scrollIntoView({behavior:'smooth',block:'center'});setTimeout(playMotion,350)});
$('#replay-motion')?.addEventListener('click',playMotion);motion?.addEventListener('click',e=>{if(!e.target.closest('button'))playMotion()});
$$('.letter-cloud span').forEach((el,i)=>el.style.setProperty('--i',i+1));

const leftPanel=$('#scene-panel-left');const requestCopy=$('#request-copy');const requestNote=$('#request-note');const familyLog=$('#family-log');
const scenes={
 help:{title:'Нужна помощь с компьютером?',body:'Кому отправить',button:'Попросить помощи ↗',event:'Демо готово. Мама уже добавлена в семью; папу можно добавить по коду.'},
 family:{title:'Добавить близкого в семью',body:'Код сопряжения',button:'Показать код ↗',event:'Семейный доступ использует разовое сопряжение по шестизначному коду.'},
 call:{title:'Позвонить домой',body:'Кому позвонить',button:'Позвонить ↗',event:'На звонок нужно ответить. Автоответ по паролю не используется по умолчанию.'}
};
let activeScene='help';
function renderScene(scene){activeScene=scene;$$('.demo-tab').forEach(b=>b.classList.toggle('active',b.dataset.scene===scene));const cfg=scenes[scene];if(!leftPanel)return;leftPanel.innerHTML=`<h3>${cfg.title}</h3><label>${cfg.body}<select id="scene-select"><option>${scene==='family'?'482 731':'Вы · помощник'}</option></select></label><button class="button full" id="scene-action">${cfg.button}</button>`;$('#scene-action')?.addEventListener('click',runScene);if(requestCopy)requestCopy.textContent='Запросов помощи пока нет';if(requestNote)requestNote.textContent='Выберите действие на компьютере слева.';if(familyLog)familyLog.textContent=cfg.event}
function runScene(){if(activeScene==='help'){requestCopy.textContent='Маме нужна помощь';requestNote.textContent='Компьютер близкого готов к подключению.';familyLog.textContent='Получен запрос помощи → можно открыть управление, файлы или терминал.'}else if(activeScene==='family'){requestCopy.textContent='Код сопряжения: 482 731';requestNote.textContent='Код действует ограниченное время и используется один раз.';familyLog.textContent='Демо сопряжения: после обмена ключами устройства становятся доверенными членами семьи.'}else{requestCopy.textContent='Входящий звонок от Мамы';requestNote.textContent='Ответить · Отклонить';familyLog.textContent='Демо звонка: голос начинается после ответа. Двустороннее видео пока не рекламируется как полностью проверенное.'}}
$$('.demo-tab').forEach(b=>b.addEventListener('click',()=>renderScene(b.dataset.scene)));
$('#ask-help')?.addEventListener('click',()=>{requestCopy.textContent='Маме нужна помощь';requestNote.textContent='Компьютер близкого готов к подключению.';familyLog.textContent='Получен запрос помощи → можно открыть управление, файлы или терминал.'});
$$('.quick-actions button').forEach(b=>b.addEventListener('click',()=>{familyLog.textContent=`Открываем: ${b.dataset.action}. Это локальная симуляция интерфейса.`}));
$('#reset-family')?.addEventListener('click',()=>renderScene('help'));

const proto=$('#prototype-body');$('#toggle-prototype')?.addEventListener('click',e=>{proto?.classList.toggle('collapsed');e.currentTarget.textContent=proto?.classList.contains('collapsed')?'Развернуть прототип □':'Свернуть прототип —'});

let activeDevice='Домашний ПК';let activeRoute='P2P';const deviceName=$('#session-device-name'),deviceOs=$('#session-device-os'),routeChip=$('#route-chip'),screenCopy=$('#screen-copy'),sessionLog=$('#session-log');
const deviceMeta={
 'Домашний ПК':['Windows','управление'],
 'Ноутбук':['Windows','управление'],
 'iPhone':['iOS','только просмотр'],
 'Android':['Android','управление с разрешением']
};
$$('.prototype-device').forEach(b=>b.addEventListener('click',()=>{activeDevice=b.dataset.device;$$('.prototype-device').forEach(x=>x.classList.toggle('selected',x===b));deviceName.textContent=activeDevice;deviceOs.textContent=deviceMeta[activeDevice][0];screenCopy.textContent='Ожидает подключения';sessionLog.textContent=`Выбрано устройство: ${activeDevice}. Режим: ${deviceMeta[activeDevice][1]}.`}));
function setRoute(route){activeRoute=route;$$('.scenario').forEach(b=>b.classList.toggle('active',b.dataset.route===route));routeChip.textContent=route==='Смена сети'?'AUTO':route.toUpperCase();routeChip.classList.toggle('chip-green',route!=='Relay');routeChip.classList.toggle('chip-amber',route==='Relay');sessionLog.textContent=route==='P2P'?'Сценарий: прямое P2P соединение.':route==='Relay'?'Сценарий: резервный маршрут через Relay.':'Сценарий: сеть изменилась → клиент обновляет маршрут и выбирает доступный транспорт.'}
$$('.scenario').forEach(b=>b.addEventListener('click',()=>setRoute(b.dataset.route)));
$('#connect-demo')?.addEventListener('click',()=>{screenCopy.textContent=`${activeDevice} · соединено`;sessionLog.textContent=`Сессия открыта. ${activeDevice}; транспорт: ${activeRoute}. Это симуляция, реальное соединение браузер не устанавливает.`});

$$('.family-device').forEach(b=>b.addEventListener('click',()=>{$$('.family-device').forEach(x=>x.classList.toggle('selected',x===b));familyLog.textContent=`Выбрано устройство: ${b.querySelector('strong')?.textContent}.`}));
