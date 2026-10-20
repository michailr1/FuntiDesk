import test from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {fileBlock, fileName, fileSize, BLOCK, LIMIT} from '../src/file-codec.js';
import {Files} from '../src/files.js';
import {displayEntries,displaySize} from '../src/files-ui.js';
const frames=JSON.parse(await readFile(new URL('./fixtures/file-zstd.json',import.meta.url)));
const decode = hex => fileBlock(Uint8Array.from(Buffer.from(hex,'hex')),true);
function client(t){const sent=[];const f=new Files();f.connected=true;f.path='C:\\Users\\Family';f.socket={send:m=>sent.push(m),drain:async()=>{}};t.after(()=>f.close());return {f,sent};}
async function pumped(f){for(let i=0;i<100&&!f.job?.awaitingDone;i++)await new Promise(r=>setTimeout(r,1));assert.equal(f.job?.awaitingDone,true);}
test('native libzstd vectors, including empty and full-sized blocks',()=>{for(const v of frames)assert.deepEqual(decode(v.hex),new Uint8Array(v.length).fill(65));});
test('rejects oversized frame window/content, concatenation, truncation and mismatched content size',()=>{
 const v=frames[1].hex;
 assert.throws(()=>decode(v+v));assert.throws(()=>decode(v.slice(0,-2)));
 for(const h of ['28b52ffda001000200010000','28b52ffd00ff010000','28b52ffd2122010000'])assert.throws(()=>decode(h));
 const bytes=Buffer.from(v,'hex');bytes[5]=0;bytes[6]=31;assert.throws(()=>fileBlock(bytes,true));
 assert.throws(()=>fileBlock(new Uint8Array(BLOCK+1),false));
});
test('safe upload names and explicit file-size bounds',()=>{
 for(const n of ['../a','..','C:abc','a/b','a\\b','nul.txt','COM1','foo.','x\0y'])assert.throws(()=>fileName(n));
 assert.equal(fileName('Фото 2026.jpg'),'Фото 2026.jpg');assert.equal(fileSize(LIMIT),LIMIT);
 for(const n of [-1,LIMIT+1,Infinity,NaN,1.5])assert.throws(()=>fileSize(n));
});
test('upload waits for native digest confirmation and final acknowledgement',async t=>{
 const {f,sent}=client(t),data=new Uint8Array(BLOCK+7).fill(73);f.upload(new File([data],'photo.jpg'));
 assert.equal(sent.length,2);assert.equal(f.job.bytes,0);const id=f.job.id;
 f.handle({file_action:{send_confirm:{id,offset_blk:0}}});await pumped(f);
 const blocks=sent.filter(m=>m.file_response?.block).map(m=>m.file_response.block.data);
 assert.deepEqual(Buffer.concat(blocks),Buffer.from(data));assert.ok(f.job,'outgoing bytes are not a success ACK');
 f.handle({file_response:{done:{id,file_num:0}}});assert.equal(f.job,null);assert.equal(f.result.type,'upload');
});
test('zero-byte upload explicitly creates a file before done',async t=>{
 const {f,sent}=client(t);f.upload(new File([],'empty.txt'));const id=f.job.id;
 f.handle({file_action:{send_confirm:{id,offset_blk:0}}});await pumped(f);
 assert.equal(sent.find(m=>m.file_response?.block).file_response.block.data.length,0);
 f.handle({file_response:{done:{id}}});assert.equal(f.result.type,'upload');
});
test('conflict cannot silently overwrite an existing file',t=>{
 const {f,sent}=client(t);f.upload(new File(['new'],'same.txt'));const id=f.job.id;
 f.handle({file_response:{digest:{id,is_upload:true,file_size:3}}});assert.equal(f.error,'file_exists');assert.equal(f.job,null);
 assert.equal(sent.filter(m=>m.file_response?.block).length,0);assert.equal(sent.at(-1).file_action.cancel.id,id);
});
test('download combines raw/zstd bytes and waits for exact length and done',async t=>{
 const {f}=client(t);f.download({entry_type:4,name:'data.txt',size:4097});const id=f.job.id;
 f.handle({file_response:{dir:{id,entries:[{entry_type:4,size:4097}]}}});
 f.handle({file_response:{digest:{id,file_size:4097}}});
 f.handle({file_response:{block:{id,data:Uint8Array.of(66)}}});
 f.handle({file_response:{block:{id,data:Uint8Array.from(Buffer.from(frames[1].hex,'hex')),compressed:true}}});
 assert.equal(f.blob,null);f.handle({file_response:{done:{id,file_num:1}}});
 assert.deepEqual(new Uint8Array(await f.blob.arrayBuffer()),Uint8Array.from([66,...new Uint8Array(4096).fill(65)]));
});
test('rejects unsolicited data, changed size and premature done',t=>{
 const {f}=client(t);f.download({entry_type:4,name:'data.txt',size:10});const id=f.job.id;
 assert.throws(()=>f.handle({file_response:{block:{id,data:Uint8Array.of(1)}}}));
 assert.throws(()=>f.handle({file_response:{dir:{id,entries:[{entry_type:4,size:11}]}}}));
 assert.throws(()=>f.handle({file_response:{done:{id}}}));assert.equal(f.blob,null);
});
test('cancel discards late frames and does not affect a new job',t=>{
 const {f,sent}=client(t);f.download({entry_type:4,name:'a.txt',size:1});const id=f.job.id;f.cancel();
 assert.equal(sent.at(-1).file_action.cancel.id,id);f.download({entry_type:4,name:'b.txt',size:2});
 f.handle({file_response:{block:{id,data:Uint8Array.of(1)}}});assert.equal(f.job.bytes,0);assert.equal(f.blob,null);
});
test('file permission denial remains separate from keyboard/view-only',()=>{
 const f=new Files();f.permission({misc:{permission_info:{permission:0,enabled:false}}});
 assert.throws(()=>f.permission({misc:{permission_info:{permission:4,enabled:false}}}),/files_denied/);f.close();
});

test('cancellation while waiting for send capacity cannot send late file bytes',async t=>{
 const {f,sent}=client(t);let resume;f.socket.drain=()=>new Promise(r=>resume=r);
 f.upload(new File(['private payload'],'a.txt'));const id=f.job.id;
 f.handle({file_action:{send_confirm:{id,offset_blk:0}}});f.cancel();resume();await new Promise(r=>setTimeout(r,10));
 assert.equal(sent.filter(m=>m.file_response?.block||m.file_response?.done).length,0);
});

test('file display keeps folders first, uses natural names and does not mutate native order',()=>{
 const entries=[{name:'File10.txt',entry_type:4,size:10},{name:'Folder10',entry_type:0},{name:'file2.txt',entry_type:4,size:2},{name:'Folder2',entry_type:0},{name:'C:',entry_type:3},{name:'shortcut',entry_type:2}];
 const original=structuredClone(entries),names=(query,sort)=>displayEntries(entries,query,sort).map(e=>e.name);
 assert.deepEqual(names('','name'),['C:','Folder2','Folder10','shortcut','file2.txt','File10.txt']);
 assert.deepEqual(names('','reverse'),['shortcut','Folder10','Folder2','C:','File10.txt','file2.txt']);
 assert.deepEqual(names('','size'),['C:','Folder2','Folder10','shortcut','File10.txt','file2.txt']);
 assert.deepEqual(names(' FILE','name'),['file2.txt','File10.txt']);assert.deepEqual(names('missing','name'),[]);
 assert.deepEqual(entries,original);
});
test('human file sizes include zero and unknown, with the same binary units as the transport limit',()=>{
 assert.equal(displaySize(0),'0 Б');assert.equal(displaySize(1024),'1 КБ');assert.equal(displaySize(50*1024*1024),'50 МБ');assert.equal(displaySize(-1),'Размер неизвестен');
 assert.deepEqual(displayEntries([{name:'older',entry_type:4,modified_time:1},{name:'folder',entry_type:0},{name:'new',entry_type:4,modified_time:10}], '', 'date').map(e=>e.name),['folder','new','older']);
});
