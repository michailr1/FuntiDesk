import assert from 'node:assert/strict';
import {readFile,mkdir} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {build} from 'esbuild';
import {chromium} from 'playwright';
import sodium from 'libsodium-wrappers';
import {ready, SERVER_KEY, wire, rendezvous, encode, decode, splitKeys, encrypt, decrypt, passwordProof} from '../src/protocol.js';
await ready;
const root=fileURLToPath(new URL('../',import.meta.url)),server=sodium.crypto_sign_keypair(),peer=sodium.crypto_sign_keypair(),box=sodium.crypto_box_keypair();
const pin=sodium.to_base64(server.publicKey,sodium.base64_variants.ORIGINAL),id='123456789';
const {hbb}=await import('../src/schema.generated.js');
const signedPeer=sodium.crypto_sign(encode(hbb.IdPk,{id,pk:peer.publicKey}),server.privateKey);
const signedId=sodium.crypto_sign(encode(hbb.IdPk,{id,pk:box.publicKey,kx_version:1}),peer.privateKey);
const vector=JSON.parse(await readFile(new URL('./fixtures/file-zstd.json',import.meta.url)))[1];
const html=await readFile(new URL('../../web/connect/index.html',import.meta.url));
const bundle=await build({stdin:{contents:"import {Files} from './src/files.js';import {FilePanel} from './src/files-ui.js';window.files=new Files();window.makePanel=owner=>{window.owner=owner;window.panel=new FilePanel(()=>window.owner);};",resolveDir:root},bundle:true,write:false,format:'esm',target:'chrome120',plugins:[{name:'test-pin',setup(b){b.onLoad({filter:/\/protocol\.js$/},async a=>({contents:(await readFile(a.path,'utf8')).replace(SERVER_KEY,pin),loader:'js'}));}}]});
const browser=await chromium.launch({executablePath:process.env.CHROMIUM_PATH||'/usr/bin/chromium',args:['--no-sandbox']});
try{for(const scenario of ['valid','wrong-password','wrong-key','revoked']){
 const page=await browser.newPage();const errors=[];let proofSent=false,cancelled=false,received=[],send,job,hold=false,writes=0,uiMode=false;
 const listing=()=>uiMode ? [{name:'zebra.txt',entry_type:4,size:20},{name:'Folder10',entry_type:0},{name:'data.txt',entry_type:4,size:4096},{name:'Folder2',entry_type:0},{name:'Photos',entry_type:0},{name:'Report10.txt',entry_type:4,size:10},{name:'Report2.txt',entry_type:4,size:2},{name:'big.zip',entry_type:4,size:60*1024*1024}] : [{name:'data.txt',entry_type:4,size:4096}];
 page.on('pageerror',e=>errors.push(e.message));
 await page.route('https://desk.funti.cc/**',async r=>{
  const url=new URL(r.request().url());
  if(url.pathname==='/connect/session.js')return r.fulfill({contentType:'application/javascript',body:Buffer.from(bundle.outputFiles[0].contents)});
  if(url.pathname==='/'||url.pathname==='/connect/')return r.fulfill({contentType:'text/html',body:html});
  const file=fileURLToPath(new URL('../../web'+url.pathname,import.meta.url));
  return r.fulfill({contentType:url.pathname.endsWith('.css')?'text/css':'image/svg+xml',body:await readFile(file)});
 });
 await page.routeWebSocket('wss://desk.funti.cc/ws/rendezvous',ws=>ws.onMessage(bytes=>{const m=decode(rendezvous,Buffer.from(bytes));assert.equal(m.punch_hole_request.conn_type,1);ws.send(Buffer.from(encode(rendezvous,{relay_response:{uuid:'files',pk:signedPeer,relay_server:'attacker.invalid:1'}})));}));
 await page.routeWebSocket('wss://desk.funti.cc/ws/relay',ws=>{
  let state=0,keys,rx=0,tx=0;send=m=>ws.send(Buffer.from(encrypt(encode(wire,m),++tx,keys[1])));
  ws.onMessage(async bytes=>{bytes=Buffer.from(bytes);
   if(state===0){assert.equal(decode(rendezvous,bytes).request_relay.conn_type,1);state=1;ws.send(Buffer.from(encode(wire,{signed_id:{id:signedId}})));return;}
   if(state===1){const p=decode(wire,bytes).public_key;const secret=sodium.crypto_box_open_easy(p.symmetric_value,new Uint8Array(24),p.asymmetric_value,box.privateKey);keys=splitKeys(secret,p.asymmetric_value,box.publicKey,1);state=2;send({hash:{salt:'salt',challenge:'challenge'}});return;}
   const m=decode(wire,decrypt(bytes,++rx,keys[0]));
   if(m.login_request){proofSent=true;assert.ok(m.login_request.file_transfer);assert.equal(m.login_request.username,id);assert.deepEqual(m.login_request.password,await passwordProof(scenario==='wrong-password'?'bad':'password','salt','challenge'));
    send({login_response:scenario==='wrong-password'?{error:'Wrong password'}:{peer_info:{username:'fixture',platform:'Windows'}}});if(scenario!=='wrong-password')send({file_response:{dir:{path:'C:\\Family',entries:listing()}}});return;}
   if(m.file_action?.read_dir){const path=m.file_action.read_dir.path||'C:\\Family';send({file_response:{dir:{path,entries:path==='C:\\Family'?listing():[]}}});return;}
   if(m.file_action?.send){job=m.file_action.send.id;if(scenario==='revoked'){send({misc:{permission_info:{permission:4,enabled:false}}});return;}
    send({file_response:{dir:{id:job,path:'C:\\Family\\data.txt',entries:[{entry_type:4,size:4096}]}}});send({file_response:{digest:{id:job,file_size:4096}}});return;}
   if(m.file_action?.send_confirm){if(hold)return;send({file_response:{block:{id:job,data:Buffer.from(vector.hex,'hex'),compressed:true}}});send({file_response:{done:{id:job,file_num:1}}});return;}
   if(m.file_action?.receive){writes++;job=m.file_action.receive.id;received=[];assert.equal(m.file_action.receive.files[0].name,'photo.jpg');return;}
   if(m.file_response?.digest){send({file_action:{send_confirm:{id:job,offset_blk:0}}});return;}
   if(m.file_response?.block){received.push(...m.file_response.block.data);return;}
   if(m.file_response?.done){assert.deepEqual(received,[1,2,3,4]);send({file_response:{done:{id:job,file_num:0}}});return;}
   if(m.file_action?.cancel){cancelled=true;send({file_response:{done:{id:m.file_action.cancel.id}}});}
  });
 });
 await page.goto('https://desk.funti.cc/');await page.waitForFunction(()=>window.files);
 const expected=scenario==='wrong-key'?new Uint8Array(32):peer.publicKey;
 const failure=await page.evaluate(async({id,key,password})=>{try{await files.connect(id,password,Uint8Array.from(key));return null}catch(e){return e.message}}, {id,key:[...expected],password:scenario==='wrong-password'?'bad':'password'});
 if(scenario==='wrong-key'||scenario==='wrong-password'){
  assert.equal(failure,scenario==='wrong-key'?'invalid_identity':'files_denied');assert.equal(proofSent,scenario!=='wrong-key');
  assert.ok(await page.evaluate(()=>files.closed&&files.keys.every(k=>k.every(n=>n===0))));
 }else{
  assert.equal(failure,null);await page.waitForFunction(()=>!files.listing);await page.evaluate(()=>files.list());await page.waitForFunction(()=>files.entries?.length===1);
  await page.evaluate(()=>files.download(files.entries[0]));
  if(scenario==='revoked'){await page.waitForFunction(()=>files.closed);assert.equal(await page.evaluate(()=>files.error),'files_denied');assert.equal(await page.evaluate(()=>files.blob),null);}
  else{
   await page.waitForFunction(()=>files.blob);assert.equal(await page.evaluate(async()=>new Uint8Array(await files.blob.arrayBuffer()).every(n=>n===65)),true);
   await page.evaluate(()=>files.upload(new File([Uint8Array.of(1,2,3,4)],'photo.jpg')));await page.waitForFunction(()=>!files.job&&files.result?.type==='upload');
   await page.evaluate(()=>{files.download(files.entries[0]);files.cancel();});await page.waitForTimeout(50);assert.equal(await page.evaluate(()=>files.blob),null);assert.ok(cancelled);
   await page.evaluate(()=>files.close());
   uiMode=true;
   await page.evaluate(({id,key})=>makePanel({connected:true,filesAllowed:true,id,peerKey:Uint8Array.from(key)}),{id,key:[...peer.publicKey]});
   await page.locator('#files-open').click();await page.locator('#files-password').fill('password');await page.locator('#files-login-button').click();
   await page.locator('#files-list button').first().waitFor();
   assert.deepEqual(await page.locator('#files-list .files-name').allTextContents(),['Folder2','Folder10','Photos','big.zip','data.txt','Report2.txt','Report10.txt','zebra.txt']);
   assert.deepEqual(await page.locator('#files-list .files-group').allTextContents(),['Папки','Файлы']);
   assert.equal(await page.locator('#files-upload').isVisible(),false);assert.equal(await page.locator('#files-location').getAttribute('open'),null);
   await page.locator('#files-search').fill('REPORT');assert.deepEqual(await page.locator('#files-list .files-name').allTextContents(),['Report2.txt','Report10.txt']);
   await page.locator('#files-search').fill('missing');await page.getByText('Ничего не найдено в этой папке',{exact:true}).waitFor();
   await page.locator('#files-search').fill('');await page.locator('#files-sort').selectOption('size');
   assert.deepEqual((await page.locator('#files-list .files-name').allTextContents()).slice(0,5),['Folder2','Folder10','Photos','big.zip','data.txt']);
   await page.locator('#files-sort').selectOption('name');
   assert.equal(await page.getByRole('button',{name:'Скачать big.zip: больше 50 МБ',exact:true}).isDisabled(),true);
   await page.getByRole('button',{name:'Открыть папку Folder2',exact:true}).click();await page.getByText('Папка пуста',{exact:true}).waitFor();
   assert.equal(await page.locator('#files-breadcrumbs [aria-current]').textContent(),'Folder2');await page.locator('#files-up').click();await page.getByRole('button',{name:'Скачать data.txt',exact:true}).waitFor();
   await page.setViewportSize({width:390,height:700});
   if(process.env.FUNTI_WEB_SCREENSHOTS)await page.screenshot({path:process.env.FUNTI_WEB_SCREENSHOTS+'/files-browse-phone.png'});
   await page.locator('#files-location summary').click();assert.equal(await page.locator('#files-path').isVisible(),true);
   await page.locator('#files-path').fill('C:\\Family');await page.locator('#files-folder-go').click();await page.waitForFunction(()=>!panel.client.listing);
   assert.equal(await page.locator('#files-path').isVisible(),false);
   await page.getByRole('button',{name:'Скачать data.txt',exact:true}).click();await page.locator('#files-save').waitFor({state:'visible'});
   const download=page.waitForEvent('download');await page.locator('#files-save').click();const saved=await download;
   assert.equal(saved.suggestedFilename(),'data.txt');assert.deepEqual(await readFile(await saved.path()),Buffer.alloc(4096,65));
   const chooser=page.waitForEvent('filechooser');await page.locator('#files-choose').click();await (await chooser).setFiles({name:'photo.jpg',mimeType:'image/jpeg',buffer:Buffer.from([1,2,3,4])});
   assert.equal(await page.locator('#files-save').isVisible(),false);assert.equal(await page.locator('#files-upload').isVisible(),true);assert.equal(await page.locator('#files-choose').isVisible(),false);
   assert.equal(await page.locator('#files-name').isVisible(),false);await page.locator('#files-rename summary').click();assert.equal(await page.locator('#files-name').inputValue(),'photo.jpg');
   await page.locator('#files-rename summary').click();await page.locator('#files-send').click();
   await page.waitForFunction(()=>panel.client.result?.type==='upload'&&!panel.client.listing);assert.equal(await page.locator('#files-status').textContent(),'Файл передан на компьютер.');
   const before=writes;await page.locator('#files-pick').setInputFiles({name:'data.txt',mimeType:'text/plain',buffer:Buffer.of(9)});await page.locator('#files-send').click();
   assert.match(await page.locator('#files-status').textContent(),/уже есть/);assert.equal(writes,before);await page.locator('#files-unpick').click();assert.equal(await page.locator('#files-upload').isVisible(),false);assert.equal(await page.locator('#files-pick').inputValue(),'');
   hold=true;await page.getByRole('button',{name:'Скачать data.txt',exact:true}).click();await page.locator('#files-cancel').waitFor({state:'visible'});await page.locator('#files-cancel').click();
   assert.equal(await page.evaluate(()=>panel.client.blob),null);hold=false;
   await page.evaluate(()=>document.body.classList.add('phone-session'));
   for(const viewport of [{width:320,height:700},{width:844,height:390},{width:390,height:700}]){await page.setViewportSize(viewport);assert.ok(await page.locator('#files-dialog').evaluate(d=>d.getBoundingClientRect().width<=innerWidth&&d.scrollWidth<=d.clientWidth));
    assert.ok(await page.locator('#files-scroll').evaluate(d=>d.clientHeight>=64));
    assert.ok(await page.locator('#files-choose').evaluate(b=>b.getBoundingClientRect().bottom<=innerHeight&&b.getBoundingClientRect().height>=44));
    if(process.env.FUNTI_WEB_SCREENSHOTS)await page.screenshot({path:process.env.FUNTI_WEB_SCREENSHOTS+'/files-'+viewport.width+'.png'});}
   if(process.env.FUNTI_WEB_SCREENSHOTS){await mkdir(process.env.FUNTI_WEB_SCREENSHOTS,{recursive:true});await page.screenshot({path:process.env.FUNTI_WEB_SCREENSHOTS+'/files-phone.png'});}
   await page.evaluate(()=>{window.revoked=0;const original=URL.revokeObjectURL.bind(URL);URL.revokeObjectURL=url=>{revoked++;original(url)};});
   await page.getByRole('button',{name:'Скачать data.txt',exact:true}).click();await page.locator('#files-save').waitFor({state:'visible'});await page.locator('#files-close').click();
   assert.equal(await page.evaluate(()=>revoked),1);assert.equal(await page.locator('#files-password').inputValue(),'');assert.equal(await page.locator('#files-dialog').evaluate(d=>d.open),false);assert.equal(await page.locator('#files-search').inputValue(),'');assert.equal(await page.locator('#files-pick').inputValue(),'');
   await page.evaluate(()=>{owner.filesAllowed=false;panel.sync()});assert.equal(await page.locator('#files-open').isVisible(),false);
   console.log('FILES_UI_OK native download+upload+conflict+cancel+phone-layout+URL cleanup+rights');
  }
 }
 assert.deepEqual(errors,[]);console.log('ENCRYPTED_FILES_OK '+scenario);await page.close();
}}finally{await browser.close()}
