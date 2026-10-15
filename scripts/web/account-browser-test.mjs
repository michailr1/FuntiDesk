import assert from 'node:assert/strict';
import {mkdtemp, readFile, writeFile, rm, mkdir, access} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join, extname} from 'node:path';
import {spawn} from 'node:child_process';
import {createInterface} from 'node:readline';
import {createServer} from 'node:net';
import {randomBytes,generateKeyPairSync,sign,createHash} from 'node:crypto';
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
import {once} from 'node:events';
const require=createRequire(import.meta.url);
const {chromium}=require('playwright');
const root=fileURLToPath(new URL('../../',import.meta.url));
const binary=process.env.FUNTI_ACCOUNT_BINARY||join(root,'account/target/debug/funtidesk-account');
await access(binary);
const dir=await mkdtemp(join(tmpdir(),'funtidesk-web-check-'));
const reserve=createServer();await new Promise(r=>reserve.listen(0,'127.0.0.1',r));const backendPort=reserve.address().port;await new Promise(r=>reserve.close(r));
const fixture=spawn('python3',[fileURLToPath(new URL('./account-test-fixture.py',import.meta.url)),String(backendPort),join(dir,'registry.sock'),join(dir,'account.sqlite3')],{stdio:['ignore','pipe','inherit']});
const lines=createInterface({input:fixture.stdout});
const ready=JSON.parse(await new Promise(r=>lines.once('line',r)));
const base='http://127.0.0.1:'+ready.proxy_port;
await writeFile(join(dir,'account.key'),randomBytes(32).toString('hex'),{mode:0o600});
await writeFile(join(dir,'witness.key'),randomBytes(32).toString('hex'),{mode:0o600});
const witnessSocket=createServer();await new Promise(r=>witnessSocket.listen(0,'127.0.0.1',r));const witnessPort=witnessSocket.address().port;await new Promise(r=>witnessSocket.close(r));
const serviceEnv={...process.env,FUNTI_ACCOUNT_LISTEN:'127.0.0.1:'+backendPort,FUNTI_ACCOUNT_DATABASE:join(dir,'account.sqlite3'),FUNTI_ACCOUNT_KEY_FILE:join(dir,'account.key'),FUNTI_ACCOUNT_SMTP_HOST:'127.0.0.1',FUNTI_ACCOUNT_SMTP_PORT:String(ready.smtp_port),FUNTI_ACCOUNT_REGISTRY_SOCKET:join(dir,'registry.sock'),FUNTI_ACCOUNT_WITNESS_KEY_FILE:join(dir,'witness.key'),FUNTI_ACCOUNT_WITNESS_NAMESPACE:randomBytes(32).toString('hex'),FUNTI_ACCOUNT_WITNESS_URL:'http://127.0.0.1:'+witnessPort+'/v1/witness',FUNTI_WITNESS_LISTEN:'127.0.0.1:'+witnessPort,FUNTI_WITNESS_DIRECTORY:join(dir,'witness')};
const start=args=>spawn(binary,args,{env:serviceEnv,stdio:['ignore','ignore','inherit']});
async function run(args){const child=start(args);const [code]=await once(child,'exit');assert.equal(code,0,'CLI '+args[0]+' failed');}
let browser,service,witness;
async function request(path,body,headers={}){const response=await fetch(base+path,{method:body===undefined?'GET':'POST',headers:{...headers,...(body===undefined?{}:{'content-type':'application/json'})},body:body===undefined?undefined:JSON.stringify(body)});assert.ok(response.ok,'API '+path+' HTTP '+response.status);return response.status===204?null:response.json();}
const sleep=ms=>new Promise(r=>setTimeout(r,ms));
async function inbox(address,previous=0){for(let i=0;i<100;i++){const all=await request('/test/inbox');const matching=all.filter(m=>m.to.includes(address));if(matching.length>previous)return matching.at(-1).code;await sleep(50)}throw Error('Test SMTP timeout');}
const apiPath='/api/account/v1';
function key(){const pair=generateKeyPairSync('ed25519');return {...pair,pk:pair.publicKey.export({type:'spki',format:'der'}).subarray(-32).toString('base64')};}
function canonical(value){if(Array.isArray(value))return value.map(canonical);if(value&&typeof value==='object')return Object.fromEntries(Object.keys(value).sort().map(k=>[k,canonical(value[k])]));return value;}
function proof(n,pair){const message=n.action==='bind'?['funtidesk-account-v1','bind',n.account_id,n.funti_id,n.pk,n.nonce,n.expires_at]:['funtidesk-account-v1',n.action,n.account_id,n.device_id,n.funti_id,n.pk,n.payload_hash,n.nonce,n.expires_at];return sign(null,Buffer.from(message.join('\n')),pair.privateKey).toString('base64');}
try{
  await run(['witness-init']);witness=start(['witness']);
  for(let i=0;i<100;i++){try{assert.equal((await fetch(serviceEnv.FUNTI_ACCOUNT_WITNESS_URL)).status,405);break}catch{await sleep(50);if(i===99)throw Error('Witness startup timeout')}}
  await run(['initialize']);service=start([]);
  for(let i=0;i<100;i++){try{assert.equal((await fetch(base+'/health')).status,200);break}catch{await sleep(50);if(i===99)throw Error('Service startup timeout')}}
  const address='family@example.invalid';
  const native={'x-funti-client':'native'};
  const boot=await request(apiPath+'/auth/bootstrap',undefined,native);native['x-funti-login']=boot.login_context;
  const challenge=await request(apiPath+'/auth/request',{email:address},native);
  const nativeSession=await request(apiPath+'/auth/verify',{challenge_id:challenge.challenge_id,code:await inbox(address)},native);
  delete native['x-funti-login'];native.authorization='Bearer '+nativeSession.token;
  const first=key(),second=key(),member=key();
  await request('/test/keys',{'900001':first.pk,'900002':second.pk});
  async function bind(id,name,pair){const n=await request(apiPath+'/devices/bind/nonce',{funti_id:id,pk:pair.pk},native);const bound=await request(apiPath+'/devices/bind',{nonce:n.nonce,signature:proof(n,pair),name,version:'1.5.0-ft.test'},native);return bound.device_id;}
  const firstId=await bind('900001','Домашний компьютер',first);const secondId=await bind('900002','Ноутбук',second);
  async function signed(id,action,payload,pair){const payload_hash=createHash('sha256').update(JSON.stringify(canonical(payload))).digest('hex');const n=await request(apiPath+'/devices/'+id+'/'+action+'/nonce',{payload_hash},native);return request(apiPath+'/devices/'+id+'/'+action,{nonce:n.nonce,signature:proof(n,pair),payload},native);}
  const hostile='<img src=x onerror="window.pwned=1">';
  await signed(firstId,'family',{name:'Домашний компьютер',version:'1.5.0-ft.test',members:[{id:'900003',name:hostile,pk:member.pk}]},first);
  await request('/test/advance-minute',{});
  browser=await chromium.launch({executablePath:'/usr/bin/chromium',headless:true,args:['--no-sandbox']});
  const context=await browser.newContext();const page=await context.newPage();const errors=[];page.on('pageerror',e=>errors.push(e.message));
  const removeIds=[];let loseRemove=true;let bootstrapDown=false;let partial=false;
  await context.route('**/*',async route=>{
    const req=route.request();const url=new URL(req.url());assert.equal(url.origin,'https://desk.funti.cc','Unexpected browser destination');
    if(url.pathname.startsWith(apiPath)){
      assert.ok(!req.headers()['authorization']&&!req.headers()['x-funti-client'],'Browser must use cookie');
      if(req.method()==='POST'){assert.equal(req.headers().origin,'https://desk.funti.cc');assert.ok(req.headers()['x-funti-csrf']);}
      if(bootstrapDown){await route.fulfill({status:503,contentType:'application/json',body:'{"error":"service_unavailable"}'});return;}
      const response=await route.fetch({url:base+url.pathname,headers:{...req.headers(),host:'desk.funti.cc'}});

      if(url.pathname.endsWith('/family/remove')){
        const body=req.postDataJSON();assert.match(body.request_id,/^[0-9a-f]{64}$/);assert.equal(body.target_pk,member.pk);removeIds.push(body.request_id);
        if(loseRemove){loseRemove=false;await route.abort('failed');return;}
      }
      if(partial&&url.pathname.endsWith('/family/removals')){const body=await response.json();body.has_more=true;await route.fulfill({response,json:body});return;}
      await route.fulfill({response});return;
    }
    const path=url.pathname.endsWith('/')?url.pathname+'index.html':url.pathname;
    const content=await readFile(root+'/web'+path);
    await route.fulfill({status:200,contentType:({'.html':'text/html','.js':'application/javascript','.css':'text/css','.svg':'image/svg+xml'})[extname(path)],body:content});
  });
  await page.goto('https://desk.funti.cc/account/');await page.locator('#send-code:enabled').waitFor();
  await page.locator('#email').fill(address);await page.locator('#send-code').click();await page.locator('#code-form:not([hidden])').waitFor();
  const sentCode=await inbox(address,1);await page.locator('#code').fill(sentCode==='000000'?'000001':'000000');await page.locator('#code-form button[type=submit]').click();await page.locator('#message[data-kind=error]').waitFor();
  assert.match(await page.locator('#message').textContent(),/Код неверный/);
  await page.locator('#resend-code').click();await page.locator('#message[data-kind=error]').waitFor();assert.match(await page.locator('#message').textContent(),/Слишком много запросов/);await request('/test/advance-minute',{});await page.locator('#resend-code:enabled').click();await page.locator('#code-form button[type=submit]:enabled').waitFor();
  await page.locator('#code').fill(await inbox(address,2));await page.locator('#code-form button[type=submit]').click();await page.locator('#account:not([hidden])').waitFor();
  await page.getByText(hostile,{exact:true}).waitFor();assert.equal(await page.locator('#family img').count(),0);assert.equal(await page.evaluate(()=>window.pwned),undefined);
  assert.equal(await page.locator('#devices .row').count(),2);
  if(process.env.FUNTI_WEB_SCREENSHOTS){await mkdir(process.env.FUNTI_WEB_SCREENSHOTS,{recursive:true});await page.screenshot({path:join(process.env.FUNTI_WEB_SCREENSHOTS,'account-desktop.png'),fullPage:true});}
  await page.setViewportSize({width:375,height:812});assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=window.innerWidth),'Mobile account overflows');
  if(process.env.FUNTI_WEB_SCREENSHOTS)await page.screenshot({path:join(process.env.FUNTI_WEB_SCREENSHOTS,'account-mobile.png'),fullPage:true});
  await page.setViewportSize({width:1280,height:900});
  const cookies=await context.cookies('https://desk.funti.cc');const session=cookies.find(c=>c.name==='__Host-funti-account');assert.ok(session?.httpOnly&&session?.secure&&session?.sameSite==='Strict');
  assert.equal(await page.evaluate(()=>localStorage.length+sessionStorage.length),0);
  await page.reload();await page.getByText(hostile,{exact:true}).waitFor();
  page.on('dialog',dialog=>dialog.accept());
  await page.locator('#favorite-id').fill('333333333');await page.locator('#favorite-name').fill(hostile);
  await page.locator('#favorite-form button').click();await page.locator('#favorites .row-name').getByText(hostile,{exact:true}).waitFor();
  assert.equal(await page.locator('#favorites img').count(),0);
  let library=await request(apiPath+'/library',undefined,native);assert.equal(library.favorites.length,1);
  await request(apiPath+'/library/favorites',{revision:library.revision,favorites:[]},native);
  await page.locator('#favorites button:enabled').click();await page.locator('#message[data-kind=error]').waitFor();
  assert.match(await page.locator('#message').textContent(),/другом устройстве/);
  library=await request(apiPath+'/library',undefined,native);assert.equal(library.favorites.length,0);
  await page.locator('#refresh:enabled').click();await page.locator('#favorites .empty').waitFor();
  const historyEvent={history_epoch:0,entry:{event_id:randomBytes(32).toString('hex'),source_device_id:firstId,funti_id:'333333333',name:hostile,connected_at:Math.floor(Date.now()/1000)}};
  await request(apiPath+'/library/history',historyEvent,native);await request(apiPath+'/library/history',historyEvent,native);
  await page.locator('#refresh:enabled').click();await page.locator('#history .row-name').getByText(hostile,{exact:true}).waitFor();
  assert.equal(await page.locator('#history .row').count(),1);assert.equal(await page.locator('#history img').count(),0);
  await page.locator('#clear-history:enabled').click();await page.locator('#history .empty').waitFor();
  const staleHistory=await fetch(base+apiPath+'/library/history',{method:'POST',headers:{...native,'content-type':'application/json'},body:JSON.stringify(historyEvent)});
  assert.equal(staleHistory.status,409);assert.equal((await request(apiPath+'/library',undefined,native)).history.length,0);

  await page.locator('#family .row button').click();await page.locator('#message[data-kind=error]').waitFor();
  await page.locator('#family .row button:enabled').click();await page.getByText('Подтверждено: 0 из 2 показанных компьютеров',{exact:true}).waitFor();
  assert.equal(removeIds.length,2);assert.equal(removeIds[0],removeIds[1]);
  const queued=await request(apiPath+'/family/removals',undefined,native);assert.equal(queued.deliveries.length,2);const event=queued.deliveries[0].event_id;
  await signed(firstId,'ack',{events:[event]},first);await page.locator('#refresh').click();await page.getByText('Подтверждено: 1 из 2 показанных компьютеров',{exact:true}).waitFor();
  await signed(secondId,'ack',{events:[event]},second);partial=true;await page.locator('#refresh').click();await page.getByText('Показана последняя часть журнала удалений.',{exact:true}).waitFor();
  await page.locator('#logout-all').click();await page.locator('#send-code:enabled').waitFor();assert.equal(await page.locator('#devices .row').count(),0);assert.equal(await page.locator('#account-email').textContent(),'');
  const invalidNative=await fetch(base+apiPath+'/session',{headers:native});assert.equal(invalidNative.status,401);
  await page.locator('#email').fill('another@example.invalid');await page.locator('#send-code').click();await page.locator('#code-form:not([hidden])').waitFor();await page.locator('#code').fill(await inbox('another@example.invalid'));await page.locator('#code-form button[type=submit]').click();await page.locator('#account:not([hidden])').waitFor();await page.locator('#logout:enabled').click();await page.locator('#send-code:enabled').waitFor();
  bootstrapDown=true;await page.reload();await page.locator('#retry-login:not([hidden])').waitFor();assert.equal(await page.locator('#send-code').isDisabled(),true);
  bootstrapDown=false;await page.locator('#retry-login').click();await page.locator('#send-code:enabled').waitFor();
  assert.deepEqual(errors,[]);
  console.log('ACCOUNT_BROWSER_API_OK: independent encrypted state, login, invalid/resend code, HttpOnly cookie restore, safe text, no storage, idempotent retry, pending/ack/partial deliveries, logout/all, outage retry');
}finally{
  await browser?.close();
  for(const child of [service,witness,fixture].filter(Boolean)){if(child.exitCode===null){const ended=once(child,'exit');child.kill();await ended;}}
  await rm(dir,{recursive:true,force:true});
}
