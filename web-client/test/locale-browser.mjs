import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import {chromium} from 'playwright';
const root=fileURLToPath(new URL('../../web/',import.meta.url));
const browser=await chromium.launch({executablePath:'/usr/bin/chromium',args:['--no-sandbox']});
try{
 for(const width of [320,390,768,1440])for(const locale of ['ru-RU','en-US']){
  const context=await browser.newContext({locale,viewport:{width,height:900}});const page=await context.newPage();const errors=[];let sockets=0;
  page.on('pageerror',error=>errors.push(error.message));
  await page.route('https://desk.funti.cc/**',async route=>{
    const path=new URL(route.request().url()).pathname;
    const name=path==='/connect/'?'connect/index.html':path.slice(1);
    const contentType=name.endsWith('.js')?'application/javascript':name.endsWith('.css')?'text/css':name.endsWith('.html')?'text/html':'image/svg+xml';
    await route.fulfill({contentType,body:await readFile(root+name)});
  });
  await page.routeWebSocket(/.*/,()=>{sockets++;});
  await page.goto('https://desk.funti.cc/connect/');
  const language=locale.startsWith('ru')?'ru':'en';
  await page.waitForFunction(lang=>document.documentElement.lang===lang,language);
  await page.locator('#console-language').selectOption('en');
  assert.equal(await page.locator('h1').textContent(),'Connect to a computer');
  assert.equal(await page.getByLabel('Computer password',{exact:true}).count(),2);
  assert.equal(await page.locator('#files-dialog').evaluate(el=>/[А-Яа-яЁё]/.test(el.textContent)),false);
  assert.equal(await page.locator('#phone-ui').evaluate(el=>/[А-Яа-яЁё]/.test(el.textContent)),false);
  assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'English overflow '+width);
  await page.locator('#peer-id').fill('123456789');await page.locator('#password').fill('kept-only-in-form');
  await page.locator('#console-language').selectOption('ru');
  assert.equal(await page.locator('#password').inputValue(),'kept-only-in-form');
  assert.equal(await page.locator('#peer-id').inputValue(),'123456789');
  assert.equal(sockets,0,'language selection must not open network sessions');
  assert.equal(await page.evaluate(()=>JSON.stringify({...localStorage}).includes('kept-only-in-form')),false);
  await page.reload();assert.equal(await page.locator('#console-language').inputValue(),'ru');
  assert.deepEqual(errors,[]);console.log('CONSOLE_LOCALE_OK width='+width+' browser='+locale);await context.close();
 }
 const context=await browser.newContext({locale:'ru-RU'});
 await context.addInitScript(()=>{Object.defineProperty(window,'localStorage',{get(){throw new DOMException('Blocked','SecurityError')}})});
 const page=await context.newPage();await page.route('https://desk.funti.cc/**',async route=>{
  const path=new URL(route.request().url()).pathname;const name=path==='/connect/'?'connect/index.html':path.slice(1);
  await route.fulfill({contentType:name.endsWith('.js')?'application/javascript':name.endsWith('.css')?'text/css':'text/html',body:await readFile(root+name)});
 });
 await page.goto('https://desk.funti.cc/connect/?lang=en#123456789');
 await page.waitForFunction(()=>document.documentElement.lang==='en');
 assert.equal(await page.locator('#peer-id').inputValue(),'123456789');
 await page.locator('#console-language').selectOption('ru');await page.reload();
 assert.equal(await page.locator('html').getAttribute('lang'),'ru');await context.close();
 console.log('CONSOLE_LOCALE_OK explicit URL, blocked storage, ID fragment preserved');
}finally{await browser.close();}
