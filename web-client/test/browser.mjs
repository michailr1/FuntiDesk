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
const frame=await readFile(new URL('./fixtures/red-vp9.frame',import.meta.url));
const id='123456789';const password='482951';
const signedPeer=sodium.crypto_sign(encode(hbb.IdPk,{id,pk:signer.publicKey}),server.privateKey);
const signedId=sodium.crypto_sign(encode(hbb.IdPk,{id,pk:box.publicKey,kx_version:1}),signer.privateKey);
const browser=await chromium.launch({executablePath:process.env.CHROMIUM_PATH||'/usr/bin/chromium',headless:true,args:['--no-sandbox']});
try {
  for(const scenario of ['valid','wrong-password','wrong-key']) {
    const context=await browser.newContext();const page=await context.newPage();const errors=[];const input=[];const publicKeys=[];
    page.on('pageerror',e=>errors.push(e.message));
    await page.route('https://desk.funti.cc/**',async route=>{
      const url=new URL(route.request().url());
      if(url.pathname==='/connect/session.js')return route.fulfill({contentType:'application/javascript',body:bundle});
      const filename=path.join(root,'web',url.pathname.endsWith('/')?url.pathname+'index.html':url.pathname);
      const type=({'.html':'text/html','.js':'application/javascript','.css':'text/css','.svg':'image/svg+xml'})[path.extname(filename)];
      await route.fulfill({contentType:type,body:await readFile(filename)});
    });
    await page.routeWebSocket('wss://desk.funti.cc/ws/rendezvous',ws=>ws.onMessage(bytes=>{
      const request=decode(rendezvous,Buffer.from(bytes));assert.equal(request.punch_hole_request.id,id);
      assert.equal(request.punch_hole_request.licence_key,fixtureKey);
      const signed=signedPeer.slice();if(scenario==='wrong-key')signed[0]^=1;
      ws.send(Buffer.from(encode(rendezvous,{relay_response:{uuid:'fixture',pk:signed,relay_server:'attacker.invalid:1234',version:'1.5.0'}})));
    }));
    let relay;let send;let sendCount=0;let receiveCount=0;let keys;
    await page.routeWebSocket('wss://desk.funti.cc/ws/relay',ws=>{
      relay=ws;let state=0;
      send=(value)=>ws.send(Buffer.from(encrypt(encode(wire,value),++sendCount,keys[1])));
      ws.onMessage(async bytes=>{
        bytes=Buffer.from(bytes);
        if(state===0){const request=decode(rendezvous,bytes);assert.equal(request.request_relay.secure,true);state=1;ws.send(Buffer.from(encode(wire,{signed_id:{id:signedId}})));return;}
        if(state===1){
          const value=decode(wire,bytes).public_key;publicKeys.push(value);assert.equal(value.kx_version,1);
          const secret=sodium.crypto_box_open_easy(value.symmetric_value,new Uint8Array(24),value.asymmetric_value,box.privateKey);
          keys=splitKeys(secret,value.asymmetric_value,box.publicKey,1);state=2;send({hash:{salt:'salt',challenge:'challenge'}});return;
        }
        const value=decode(wire,decrypt(bytes,++receiveCount,keys[0]));
        if(value.login_request){
          assert.equal(value.login_request.username,id);assert.equal(value.login_request.option.disable_clipboard,2);
          const correct=await passwordProof(password,'salt','challenge');
          if(!sodium.memcmp(correct,value.login_request.password)){send({login_response:{error:'Wrong Password'}});return;}
          send({login_response:{peer_info:{hostname:'Fixture',platform:'Windows',current_display:0,displays:[{width:32,height:32,x:0,y:0}]}}});
          send({video_frame:{vp9s:{frames:[{key:true,pts:0,data:frame}]}}});
        }
        if(value.mouse_event||value.key_event)input.push(value);
      });
    });
    await page.goto('https://desk.funti.cc/connect/');
    await page.locator('#peer-id').fill(id);await page.locator('#password').fill(scenario==='wrong-password'?'incorrect':password);
    await page.locator('#connect').click();
    if(scenario==='valid') {
      await page.waitForFunction(()=>document.querySelector('#screen').width===32);
      assert.deepEqual(await page.evaluate(()=>Array.from(document.querySelector('#screen').getContext('2d').getImageData(16,16,1,1).data).map((v,i)=>i===0?v>200:i===3?v===255:v<50)),[true,true,true,true]);
      await page.locator('#screen').click();await page.keyboard.press('a');
      await page.waitForTimeout(100);assert.ok(input.some(v=>v.mouse_event));assert.ok(input.some(v=>v.key_event?.chr===97));
      send({misc:{permission_info:{permission:0,enabled:false}}});await page.locator('#status').getByText('Компьютер разрешил только просмотр.',{exact:true}).waitFor();
      const before=input.length;await page.keyboard.press('b');await page.waitForTimeout(50);assert.equal(input.length,before);
      await page.locator('#disconnect').click();await page.locator('#connect:enabled').waitFor();
    } else {
      await page.locator('#connect:enabled').waitFor();
      assert.equal(publicKeys.length,scenario==='wrong-key'?0:1);
      assert.equal(input.length,0);
    }
    assert.equal(await page.locator('#password').inputValue(),'');
    assert.equal(await page.evaluate(()=>localStorage.length+sessionStorage.length),0);
    assert.deepEqual(errors,[]);
    await context.close();
  }
  console.log('BROWSER_PROTOCOL_OK: real WebCodecs VP9 frame, encrypted v1 handshake, password rejection, key rejection, mouse/keyboard, view-only, disconnect, strict CSP, no storage');
} finally { await browser.close(); }
