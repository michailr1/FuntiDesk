import assert from 'node:assert/strict';
import {readFile, mkdir} from 'node:fs/promises';
import {createServer} from 'node:http';
import {createHash} from 'node:crypto';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {chromium} from 'playwright';

const root=fileURLToPath(new URL('../../web/',import.meta.url));
const html=await readFile(path.join(root,'index.html'),'utf8');
const urls=[...html.matchAll(/(?:href|src)="(\/[^"?]+\.(?:css|js))(?:\?v=([^"&]+))?"/g)];
for(const [,name,version] of urls){
  const data=await readFile(path.join(root,name));
  assert.equal(version,createHash('sha256').update(data).digest('hex').slice(0,12),'asset version '+name);
}
// Real HTTP cache: seed old unversioned CSS/JS, then navigate to the new document.
// A fresh-context-only check missed this regression on the owner's browser.
const server=createServer(async(req,res)=>{
  try{
    const url=new URL(req.url,'http://localhost');
    if(url.pathname==='/warm'){
      res.setHeader('Content-Type','text/html');res.setHeader('Cache-Control','no-store');
      return res.end('<!doctype html>'+urls.map(([,name])=>name.endsWith('.css')?`<link rel="stylesheet" href="${name}">`:`<script src="${name}"></script>`).join(''));
    }
    const name=url.pathname==='/'?'index.html':decodeURIComponent(url.pathname.slice(1));
    if(name.split('/').includes('..'))throw Error('invalid path');
    const ext=path.extname(name);
    res.setHeader('Content-Type',({'.html':'text/html','.css':'text/css','.js':'application/javascript','.svg':'image/svg+xml','.jpg':'image/jpeg'})[ext]||'application/octet-stream');
    res.setHeader('Cache-Control',ext==='.html'?'no-store':'public,max-age=86400');
    if(!url.search&&ext==='.css')return res.end(':root{--stale-style:1}');
    if(!url.search&&ext==='.js')return res.end('window.staleScript=true');
    res.end(await readFile(path.join(root,name)));
  }catch{res.writeHead(404);res.end();}
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const base='http://127.0.0.1:'+server.address().port;
const browser=await chromium.launch({executablePath:process.env.CHROMIUM_PATH||'/usr/bin/chromium',headless:true,args:['--no-sandbox']});
try{
  for(const width of [320,390,768,1440]){
    const context=await browser.newContext({viewport:{width,height:900},colorScheme:'light'});
    try{
      const page=await context.newPage();await page.goto(base+'/warm');
      const errors=[];page.on('pageerror',e=>errors.push(e.message));await page.goto(base);
      assert.equal(await page.evaluate(()=>window.staleScript),undefined);
      assert.equal(await page.evaluate(()=>getComputedStyle(document.documentElement).getPropertyValue('--stale-style')),'');
      for(const theme of ['dark','light']){
        await page.getByLabel('Тема сайта',{exact:true}).selectOption(theme);
        assert.equal(await page.locator('html').getAttribute('data-theme'),theme);
        assert.equal(await page.evaluate(()=>getComputedStyle(document.body).backgroundColor),theme==='light'?'rgb(244, 241, 236)':'rgb(20, 19, 15)');
        assert.ok(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),'overflow '+width);
      }
      await page.emulateMedia({colorScheme:'dark'});
      await page.waitForFunction(()=>matchMedia('(prefers-color-scheme: dark)').matches);
      await page.getByLabel('Тема сайта',{exact:true}).selectOption('system');
      await page.waitForFunction(()=>document.documentElement.dataset.theme==='dark');
      await page.emulateMedia({colorScheme:'light'});
      await page.waitForFunction(()=>document.documentElement.dataset.theme==='light');
      assert.equal(await page.locator('#demo,input,dialog').count(),0);
      assert.equal(await page.getByText('К содержимому',{exact:true}).count(),0);
      assert.equal(await page.locator('.account-link svg').evaluate(v=>v.getBoundingClientRect().width),24);
      await page.locator('#hero-form').click();
      const canvas=page.locator('#letters');
      assert.ok(await canvas.evaluate(c=>c.getContext('2d').getImageData(0,0,c.width,c.height).data.some(v=>v!==0)),'blank letters');
      const before=await canvas.evaluate(c=>c.toDataURL());
      await page.locator('#hero-network').click();
      await page.waitForFunction(old=>document.querySelector('#letters').toDataURL()!==old,before);
      await page.locator('#motion').click();assert.equal(await page.locator('#motion').getAttribute('aria-pressed'),'true');
      await page.locator('#motion').click();assert.equal(await page.locator('#motion').getAttribute('aria-pressed'),'false');
      await page.locator('#hero-form').click();
      if(process.env.FUNTI_WEB_SCREENSHOTS){await mkdir(process.env.FUNTI_WEB_SCREENSHOTS,{recursive:true});await page.screenshot({path:path.join(process.env.FUNTI_WEB_SCREENSHOTS,'landing-'+width+'.png'),fullPage:true});}
      const anchors=await page.locator('a[href^="#"]').evaluateAll(a=>a.map(v=>v.hash.slice(1)));
      for(const id of anchors)assert.equal(await page.locator(`[id="${id}"]`).count(),1,'anchor '+id);
      await page.getByLabel('Тема сайта',{exact:true}).selectOption('dark');await page.reload();
      assert.equal(await page.locator('html').getAttribute('data-theme'),'dark');
      assert.deepEqual(errors,[]);
      console.log('LANDING_OK width='+width+' warmed cache, visual themes, animation, navigation');
    }finally{await context.close();}
  }
}finally{await browser.close();await new Promise(resolve=>server.close(resolve));}
