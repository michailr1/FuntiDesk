import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';
import { chromium } from 'playwright';
import sodium from 'libsodium-wrappers';
import { ready, SERVER_KEY, wire, rendezvous, encode, decode, splitKeys, encrypt, decrypt, passwordProof } from '../src/protocol.js';
import { hbb } from '../src/schema.generated.js';
await ready;
const root=fileURLToPath(new URL('../../',import.meta.url));
const server=sodium.crypto_sign_keypair();const signer=sodium.crypto_sign_keypair();const box=sodium.crypto_box_keypair();
const fixtureKey=sodium.to_base64(server.publicKey,sodium.base64_variants.ORIGINAL);
// Only the test bundle uses the fixture trust anchor. The shipped bundle keeps the real pinned key.
const fixtureBundle=await build({entryPoints:[path.join(root,'web-client/src/main.js')],bundle:true,write:false,format:'esm',target:'chrome120',plugins:[{
  name:'fixture-trust-anchor',setup(builder){builder.onLoad({filter:/\/protocol\.js$/},async args=>({contents:(await readFile(args.path,'utf8')).replace(SERVER_KEY,fixtureKey),loader:'js'}));}
}]});
const bundle=Buffer.from(fixtureBundle.outputFiles[0].contents);
const policy=(await readFile(path.join(root,'infra/funtidesk-account/Caddyfile.web-client.fragment'),'utf8')).match(/Content-Security-Policy "([^"]+)"/)[1];
const frame=await readFile(new URL('./fixtures/red-vp9.frame',import.meta.url));
const id='123456789';const password='482951';
const signedPeer=sodium.crypto_sign(encode(hbb.IdPk,{id,pk:signer.publicKey}),server.privateKey);
const signedId=sodium.crypto_sign(encode(hbb.IdPk,{id,pk:box.publicKey,kx_version:1}),signer.privateKey);
const browser=await chromium.launch({executablePath:process.env.CHROMIUM_PATH||'/usr/bin/chromium',headless:true,args:['--no-sandbox']});
try {
  for(const scenario of ['valid','phone','wrong-password','wrong-key']) {
    const phone=scenario==='phone';
    const context=await browser.newContext(phone?{viewport:{width:390,height:844},isMobile:true,hasTouch:true}:{});const page=await context.newPage();const errors=[];const input=[];const publicKeys=[];
    const systemDialogs=[];let allowAction=false;page.on('dialog',dialog=>{systemDialogs.push(dialog.type());return allowAction?dialog.accept():dialog.dismiss();});
    if(phone)await page.addInitScript(()=>{
      window.wakeRequests=0;window.wakeReleases=0;
      Object.defineProperty(navigator,'wakeLock',{value:{request:async()=>{
        window.wakeRequests++;if(window.denyWakeLock)throw new DOMException('Denied','NotAllowedError');
        const lock=new EventTarget();lock.release=async()=>{window.wakeReleases++;lock.dispatchEvent(new Event('release'));};window.currentWake=lock;return lock;
      }}});
    });
    page.on('pageerror',e=>errors.push(e.message));
    page.on('console',m=>{if(m.type()==='error'&&m.text().includes('Content Security Policy'))errors.push(m.text());});
    await page.route('https://desk.funti.cc/**',async route=>{
      const url=new URL(route.request().url());
      if(url.pathname==='/connect/session.js')return route.fulfill({contentType:'application/javascript',body:bundle});
      const filename=path.join(root,'web',url.pathname.endsWith('/')?url.pathname+'index.html':url.pathname);
      const type=({'.html':'text/html','.js':'application/javascript','.css':'text/css','.svg':'image/svg+xml','.png':'image/png','.webmanifest':'application/manifest+json'})[path.extname(filename)];
      await route.fulfill({contentType:type,body:await readFile(filename),headers:type==='text/html'?{'Content-Security-Policy':policy}:{}});
    });
    await page.routeWebSocket('wss://desk.funti.cc/ws/rendezvous',ws=>ws.onMessage(bytes=>{
      const request=decode(rendezvous,Buffer.from(bytes));assert.equal(request.punch_hole_request.id,id);
      assert.equal(request.punch_hole_request.licence_key,fixtureKey);
      const signed=hostPeer.slice();if(scenario==='wrong-key')signed[0]^=1;
      ws.send(Buffer.from(encode(rendezvous,{relay_response:{uuid:'fixture',pk:signed,relay_server:'attacker.invalid:1234',version:'1.5.0'}})));
    }));
    let relay;let send;let sendCount=0;let receiveCount=0;let keys;let connectionCount=0;const logins=[];let hostPassword=password;let hostSalt='salt';let hostPeer=signedPeer;let hostIdentity=signedId;let viewOnly=false;
    await page.routeWebSocket('wss://desk.funti.cc/ws/relay',ws=>{
      relay=ws;let state=0;sendCount=0;receiveCount=0;const challenge='challenge-'+(++connectionCount);
      send=(value)=>ws.send(Buffer.from(encrypt(encode(wire,value),++sendCount,keys[1])));
      ws.onMessage(async bytes=>{
        bytes=Buffer.from(bytes);
        if(state===0){const request=decode(rendezvous,bytes);assert.equal(request.request_relay.secure,true);state=1;ws.send(Buffer.from(encode(wire,{signed_id:{id:hostIdentity}})));return;}
        if(state===1){
          const value=decode(wire,bytes).public_key;publicKeys.push(value);assert.equal(value.kx_version,1);
          const secret=sodium.crypto_box_open_easy(value.symmetric_value,new Uint8Array(24),value.asymmetric_value,box.privateKey);
          keys=splitKeys(secret,value.asymmetric_value,box.publicKey,1);state=2;send({hash:{salt:hostSalt,challenge}});return;
        }
        const value=decode(wire,decrypt(bytes,++receiveCount,keys[0]));
        if(value.login_request){
          assert.equal(value.login_request.username,id);assert.equal(value.login_request.option.disable_clipboard,2);
          logins.push(value.login_request);const correct=await passwordProof(hostPassword,hostSalt,challenge);
          if(!sodium.memcmp(correct,value.login_request.password)){send({login_response:{error:'Wrong Password'}});return;}
          send({login_response:{peer_info:{hostname:'Fixture',platform:'Windows',current_display:0,displays:[{width:32,height:32,x:0,y:0}]}}});
          if(viewOnly)send({misc:{permission_info:{permission:0,enabled:false}}});
          send({video_frame:{vp9s:{frames:[{key:true,pts:0,data:frame}]}}});
        }
        if(value.mouse_event||value.key_event||value.misc?.switch_display||value.misc?.option)input.push(value);
      });
    });
    await page.goto('https://desk.funti.cc/connect/');
    await page.locator('#peer-id').fill(id);await page.locator('#password').fill(scenario==='wrong-password'?'incorrect':password);
    await page.locator('#connect').click();
    if(scenario==='valid'||phone) {
      await page.waitForFunction(()=>document.querySelector('#screen').width===32);
      assert.deepEqual(await page.evaluate(()=>Array.from(document.querySelector('#screen').getContext('2d').getImageData(16,16,1,1).data).map((v,i)=>i===0?v>200:i===3?v===255:v<50)),[true,true,true,true]);
      if(phone){
        await page.locator('body.phone-session').waitFor();await page.locator('#phone-menu').waitFor();
        await page.locator('#phone-help-sheet[open]').waitFor();assert.equal(input.length,0);
        await page.getByRole('button',{name:'Понятно',exact:true}).click();
        assert.equal(await page.evaluate(()=>window.wakeRequests),1);
        await page.locator('#phone-cursor').waitFor();
        send({cursor_position:{x:8,y:10}});
        await page.waitForFunction(()=>{const c=document.querySelector('#screen').getBoundingClientRect(),p=document.querySelector('#phone-cursor').getBoundingClientRect();return Math.abs(p.x-c.x-c.width/4)<1&&Math.abs(p.y-c.y-c.height*10/32)<1;});

        const cdp=await context.newCDPSession(page);
        const touch=async(type,points)=>{await cdp.send('Input.dispatchTouchEvent',{type,touchPoints:points.map(([x,y],id)=>({id,x,y}))});};
        await touch('touchStart',[[180,400]]);await touch('touchEnd',[]);
        await touch('touchStart',[[160,400],[220,400]]);await touch('touchEnd',[]);
        await touch('touchStart',[[160,400],[220,400]]);await touch('touchMove',[[160,450],[220,450]]);await touch('touchEnd',[]);
        await page.waitForTimeout(50);
        assert.ok(input.some(v=>v.mouse_event?.mask===9));assert.ok(input.some(v=>v.mouse_event?.mask===17));assert.ok(input.some(v=>v.mouse_event?.mask===3));
        await page.waitForTimeout(350);
        await touch('touchStart',[[180,400]]);await touch('touchEnd',[]);
        await touch('touchStart',[[180,400]]);await touch('touchMove',[[250,400]]);await touch('touchEnd',[]);
        await page.waitForTimeout(50);
        const drag=input.filter(v=>v.mouse_event).map(v=>v.mouse_event.mask||0);
        const held=drag.slice(drag.lastIndexOf(9));
        assert.ok(held[0]===9&&held.at(-1)===10&&held.slice(1,-1).includes(0),'double tap drag must move with its button down, then release it');
        await touch('touchStart',[[160,400],[220,400]]);await touch('touchMove',[[140,400],[240,400]]);await touch('touchEnd',[]);
        const enlarged=await page.locator('#screen').boundingBox();assert.ok(enlarged.width>390);
        await touch('touchStart',[[160,400],[220,400]]);await touch('touchMove',[[190,420],[250,420]]);await touch('touchEnd',[]);
        const panned=await page.locator('#screen').boundingBox();assert.ok(panned.x>enlarged.x);
        const pointer=await page.locator('#phone-cursor').boundingBox(),lastMove=input.filter(v=>v.mouse_event&&!(v.mouse_event.mask||0)).at(-1).mouse_event;
        assert.ok(Math.abs(pointer.x-panned.x-lastMove.x*panned.width/32)<1,'visible cursor must follow the actual touchpad target after zoom and pan');
        await page.locator('#phone-menu').click();await page.locator('#phone-keyboard').click();
        const keyboard=await page.locator('#phone-keys').boundingBox();assert.ok(keyboard.height<80,'normal typing must not show a second keyboard');
        assert.equal(await page.locator('#phone-key-buttons').isVisible(),false,'special keys belong in the menu on demand');
        const field=await page.locator('#phone-text').boundingBox();assert.ok(field.width>=150&&field.height>=40,'typing field must be visible');
        assert.equal(await page.locator('#phone-text').evaluate(e=>e===document.activeElement),true);
        await page.evaluate(()=>{Object.defineProperties(visualViewport,{height:{value:420,configurable:true},offsetTop:{value:30,configurable:true}});visualViewport.dispatchEvent(new Event('resize'));});
        const stageWithKeyboard=await page.locator('#remote-stage').boundingBox(),keysWithKeyboard=await page.locator('#phone-keys').boundingBox();
        assert.equal(stageWithKeyboard.y,30);assert.ok(stageWithKeyboard.y+stageWithKeyboard.height<=keysWithKeyboard.y+1);assert.ok(keysWithKeyboard.y+keysWithKeyboard.height<=451);
        if(process.env.FUNTI_PHONE_SCREENSHOT)await page.screenshot({path:process.env.FUNTI_PHONE_SCREENSHOT});
        await page.evaluate(()=>{delete visualViewport.height;delete visualViewport.offsetTop;visualViewport.dispatchEvent(new Event('resize'));});
        await page.locator('#phone-text').fill('Привет');await page.locator('#phone-text').dispatchEvent('input');
        await page.locator('#phone-text').evaluate(e=>{
          e.value='Готово';e.dispatchEvent(new InputEvent('input',{bubbles:true,isComposing:true,inputType:'insertCompositionText'}));
          e.dispatchEvent(new InputEvent('beforeinput',{bubbles:true,cancelable:true,isComposing:true,inputType:'deleteContentBackward'}));
          e.dispatchEvent(new CompositionEvent('compositionend',{bubbles:true}));e.dispatchEvent(new InputEvent('input',{bubbles:true}));
          e.dispatchEvent(new KeyboardEvent('keydown',{key:'Unidentified',bubbles:true}));
          e.dispatchEvent(new InputEvent('beforeinput',{bubbles:true,cancelable:true,inputType:'insertLineBreak'}));
        });

        await page.locator('#phone-menu').click();await page.locator('#phone-special-keys summary').click();
        const contrast=await page.locator('[data-key=F2]').evaluate(button=>{
          const style=getComputedStyle(button),luminance=color=>color.match(/[\d.]+/g).slice(0,3).map(Number).map(n=>{n/=255;return n<=.04045?n/12.92:((n+.055)/1.055)**2.4}).reduce((sum,n,i)=>sum+n*[.2126,.7152,.0722][i],0);
          const a=luminance(style.color),b=luminance(style.backgroundColor);return (Math.max(a,b)+.05)/(Math.min(a,b)+.05);
        });assert.ok(contrast>=4.5,'special-key labels must contrast with their background');
        assert.equal(await page.locator('#phone-text').evaluate(e=>e===document.activeElement),true,'menu and extra keys must retain native keyboard focus');
        await page.locator('[data-key=Control]').click();await page.locator('[data-key=F1]').click();
        await page.locator('[data-key=F2]').click();await page.locator('#phone-text').press('Backspace');
        await page.waitForTimeout(50);
        assert.equal(input.filter(v=>v.key_event?.seq==='Привет').length,1);
        assert.equal(input.filter(v=>v.key_event?.seq==='Готово').length,1);
        assert.equal(input.filter(v=>v.key_event?.control_key===hbb.ControlKey.Return&&v.key_event.down).length,1);
        assert.equal(input.filter(v=>v.key_event?.control_key===hbb.ControlKey.Backspace&&v.key_event.down).length,1,'composition edits must not delete remote text');

        assert.ok(input.some(v=>v.key_event?.control_key===hbb.ControlKey.F1&&v.key_event.modifiers?.includes(hbb.ControlKey.Control)));
        assert.ok(input.some(v=>v.key_event?.control_key===hbb.ControlKey.F2&&!v.key_event.modifiers?.length));
        await page.locator('[data-key=Control]').click();await page.locator('[data-key=Control]').click();
        await page.locator('[data-key=F3]').click();await page.locator('[data-key=F4]').click();await page.waitForTimeout(50);
        assert.ok(input.some(v=>v.key_event?.control_key===hbb.ControlKey.F4&&v.key_event.modifiers?.includes(hbb.ControlKey.Control)));
        await page.locator('[data-key=Control]').click();
        await page.locator('#phone-menu').click();await page.locator('#phone-keys-close').click();assert.equal(await page.locator('#phone-text').isVisible(),false);await page.locator('#phone-menu').click();
        await page.locator('#phone-cad').click();await page.waitForTimeout(20);
        assert.equal(input.filter(v=>v.key_event?.control_key===hbb.ControlKey.CtrlAltDel).length,0);
        allowAction=true;await page.locator('#phone-cad').click();await page.waitForTimeout(50);
        assert.equal(input.filter(v=>v.key_event?.control_key===hbb.ControlKey.CtrlAltDel).length,1);
        await page.locator('#phone-quality').selectOption('2');
        await page.locator('#phone-monitor').selectOption('0');await page.waitForTimeout(50);
        assert.ok(input.some(v=>v.misc?.option?.image_quality===2));assert.ok(input.some(v=>v.misc?.switch_display));
        await page.locator('#phone-fit').click();await page.locator('#phone-mode').selectOption('touch');await page.locator('#phone-menu').click();
        const direct=await page.locator('#screen').boundingBox();
        await page.touchscreen.tap(direct.x+direct.width/4,direct.y+direct.height/4);await page.waitForTimeout(30);
        const click=input.filter(v=>v.mouse_event?.mask===9).at(-1);assert.equal(click.mouse_event.x,8);assert.equal(click.mouse_event.y,8);
        const rightBefore=input.filter(v=>v.mouse_event?.mask===17).length;
        await touch('touchStart',[[180,400]]);await page.waitForTimeout(600);await touch('touchEnd',[]);await page.waitForTimeout(30);
        assert.equal(input.filter(v=>v.mouse_event?.mask===17).length,rightBefore+1);
        const menuBefore=await page.locator('#phone-menu').boundingBox();
        await touch('touchStart',[[menuBefore.x+24,menuBefore.y+24]]);await touch('touchMove',[[300,200]]);await touch('touchEnd',[]);
        assert.ok((await page.locator('#phone-menu').boundingBox()).x>100);assert.equal(await page.locator('#phone-panel').isVisible(),false);
        await page.locator('#phone-menu').click();await page.setViewportSize({width:844,height:390});
        await page.waitForTimeout(50);const landscape=await page.locator('#screen').boundingBox();
        assert.ok(landscape.width<=844&&landscape.height<=390);
        assert.equal(await page.locator('link[rel=manifest]').getAttribute('href'),'/connect/app.webmanifest');
        const app=JSON.parse(await readFile(path.join(root,'web/connect/app.webmanifest'),'utf8'));
        assert.equal(app.display,'standalone');assert.equal(app.start_url,'/connect/');
        assert.equal(await page.locator('link[rel=apple-touch-icon]').getAttribute('href'),'/connect/apple-touch-icon.png');
        const icon=await readFile(path.join(root,'web/connect/apple-touch-icon.png'));
        assert.deepEqual([...icon.subarray(0,8)],[137,80,78,71,13,10,26,10]);
        assert.equal(icon.readUInt32BE(16),180);assert.equal(icon.readUInt32BE(20),180);
        await page.evaluate(async()=>{window.denyWakeLock=true;await window.currentWake.release();document.dispatchEvent(new Event('visibilitychange'));});
        await page.waitForTimeout(50);assert.equal(await page.evaluate(()=>window.wakeRequests),2);await page.locator('body.phone-session').waitFor();
      }else{
        await page.locator('#screen').click();await page.keyboard.press('a');
        await page.waitForTimeout(100);assert.ok(input.some(v=>v.mouse_event));assert.ok(input.some(v=>v.key_event?.chr===97));
      }
      send({misc:{permission_info:{permission:0,enabled:false}}});await page.locator(phone?'#phone-state':'#status').getByText('Компьютер разрешил только просмотр.',{exact:true}).waitFor();
      if(phone)assert.equal(await page.locator('#phone-cursor').isVisible(),false,'no control marker in view-only mode');
      else assert.equal(await page.locator('#phone-cursor').isVisible(),false,'desktop input remains unchanged');
      const before=input.length;
      if(phone){
        await page.locator('#phone-keyboard').click();await page.locator('#phone-menu').click();await page.locator('[data-key=F2]').click();await page.locator('#phone-text').fill('Нельзя');await page.locator('#phone-menu').click();
        await page.locator('#phone-keys-close').click();
        const r=await page.locator('#screen').boundingBox();await page.touchscreen.tap(r.x+r.width/2,r.y+r.height/2);
        await page.locator('#phone-menu').click();
      }else await page.keyboard.press('b');
      await page.waitForTimeout(50);assert.equal(input.length,before);
      await page.locator(phone?'#phone-end':'#disconnect').click();await page.locator('#connect:enabled').waitFor();
      if(phone){
        assert.equal(await page.evaluate(()=>window.wakeReleases),1);assert.equal(await page.locator('#phone-text').inputValue(),'');
        await page.locator('#password').fill(password);await page.locator('#connect').click();await page.locator('body.phone-session').waitFor();
        assert.equal(await page.locator('#phone-help-sheet').isVisible(),false,'reconnect must not reopen the first-session hint');
        await page.locator('#phone-menu').click();await page.locator('#phone-help').click();await page.locator('#phone-help-sheet[open]').waitFor();
        await page.getByRole('button',{name:'Понятно',exact:true}).click();
        await page.locator('#phone-menu').click();await page.locator('#phone-end').click();await page.locator('#connect:enabled').waitFor();
        await page.clock.install();
        const visibility=async hidden=>page.evaluate(hidden=>{Object.defineProperty(document,'hidden',{value:hidden,configurable:true});document.dispatchEvent(new Event('visibilitychange'));},hidden);
        const started=async()=>{await page.locator('body.phone-session').waitFor();await page.waitForFunction(()=>document.querySelector('#screen').getContext('2d').getImageData(16,16,1,1).data[0]>200);};
        const login=async()=>{await page.locator('#password').fill(password);await page.locator('#connect').click();await started();};
        const disconnect=async()=>{await visibility(true);relay.close();await page.locator('#status').getByText(/Восстановим/).waitFor();};
        await login();const initial=logins.at(-1),initialCount=connectionCount;
        await disconnect();await page.clock.setSystemTime(Date.now()+60_000);viewOnly=true;await visibility(false);await started();
        assert.equal(connectionCount,initialCount+1);assert.equal(await page.locator('#password').inputValue(),'');
        const restored=logins.at(-1);assert.equal(restored.my_id,initial.my_id);assert.equal(restored.session_id,initial.session_id);assert.notDeepEqual(restored.password,initial.password,'each recovery needs a fresh challenge proof');
        const inputBefore=input.length;await page.touchscreen.tap(180,180);await page.waitForTimeout(30);assert.equal(input.length,inputBefore,'restored connection must use current host permissions');
        // One return gets one attempt; a second transport failure cannot spin.
        relay.close();await page.locator('#connect:enabled').waitFor();await page.waitForTimeout(50);assert.equal(connectionCount,initialCount+1);
        viewOnly=false;await login();await disconnect();const expiredCount=connectionCount;
        await page.clock.setSystemTime(Date.now()+360_000);await visibility(false);await page.locator('#connect:enabled').waitFor();
        assert.equal(connectionCount,expiredCount,'a suspended expiry timer must not extend the five-minute window');
        await login();await disconnect();hostSalt='new-salt';const changedSalt=logins.length;await visibility(false);await page.locator('#connect:enabled').waitFor();assert.equal(logins.length,changedSalt,'changed salt must stop before sending cached credentials');hostSalt='salt';
        await login();await disconnect();const changedKey=logins.length;const nextSigner=sodium.crypto_sign_keypair();
        hostPeer=sodium.crypto_sign(encode(hbb.IdPk,{id,pk:nextSigner.publicKey}),server.privateKey);hostIdentity=sodium.crypto_sign(encode(hbb.IdPk,{id,pk:box.publicKey,kx_version:1}),nextSigner.privateKey);
        await visibility(false);await page.locator('#connect:enabled').waitFor();assert.equal(logins.length,changedKey,'a different verified host key must not receive the cached password proof');hostPeer=signedPeer;hostIdentity=signedId;
        await login();await disconnect();hostPassword='changed-password';const rejected=connectionCount;await visibility(false);await page.locator('#connect:enabled').waitFor();await page.waitForTimeout(50);assert.equal(connectionCount,rejected+1,'host rejection must stop automatic retries');hostPassword=password;
        await login();await visibility(true);await page.locator('#phone-menu').click();await page.locator('#phone-end').click();const ended=connectionCount;await visibility(false);await page.waitForTimeout(30);assert.equal(connectionCount,ended,'End must erase recovery');
        await login();await visibility(true);const malformedCount=connectionCount;relay.send(Buffer.from([1,2,3]));await page.locator('#connect:enabled').waitFor();await visibility(false);await page.waitForTimeout(30);assert.equal(connectionCount,malformedCount,'invalid encrypted data must not trigger recovery');
        await login();await visibility(true);const closedByHost=connectionCount;send({misc:{close_reason:'Closed manually by the peer'}});await page.locator('#connect:enabled').waitFor();await visibility(false);await page.waitForTimeout(30);assert.equal(connectionCount,closedByHost,'host termination must not trigger recovery');
        await login();const reloadCount=connectionCount;await page.reload();await page.locator('#connect:enabled').waitFor();await page.waitForTimeout(30);assert.equal(connectionCount,reloadCount,'reload must not recover credentials');
        assert.equal(await page.locator('#peer-id').getAttribute('autocomplete'),'username');assert.equal(await page.locator('#password').getAttribute('autocomplete'),'current-password');
      }
    } else {
      await page.locator('#connect:enabled').waitFor();
      assert.equal(publicKeys.length,scenario==='wrong-key'?0:1);
      assert.equal(input.length,0);
    }
    assert.equal(await page.locator('#password').inputValue(),'');
    assert.equal(await page.evaluate(()=>localStorage.length+sessionStorage.length),0);
    assert.equal(systemDialogs.filter(type=>type==='alert').length,0,'gesture hints must never use a system alert');
    assert.deepEqual(errors,[]);
    await context.close();
  }
  console.log('BROWSER_PROTOCOL_OK: encrypted VP9 session, desktop regression, mobile cursor, native keyboard and optional menu keys/viewport, IME/Enter, touch/pinch/drag, text/modifiers, display/quality, confirmed SAS, orientation, optional Wake Lock, bounded recovery/expiry/key/salt/rejection/reload, view-only, disconnect, no storage');
} finally { await browser.close(); }
