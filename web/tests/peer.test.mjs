import 'fake-indexeddb/auto';
import {createRequire} from 'node:module';
import {mkdtempSync,rmSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import assert from 'node:assert/strict';
import {schnorr} from '@noble/curves/secp256k1.js';
const req=createRequire(import.meta.url),wr=createRequire(req.resolve('wrangler/package.json')),{build}=wr('esbuild');
const dir=mkdtempSync(join(tmpdir(),'slowclaw-peer-'));
const origin='https://slowclaw.social',id='1'.repeat(64),pair='2'.repeat(64),key='3'.repeat(64),secret=new Uint8Array(32);secret[31]=1;
const encode=s=>new TextEncoder().encode(s),hex=b=>Buffer.from(b).toString('hex');
const hash=async bytes=>hex(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)));
async function sign(path,method,body,identity=secret){const pubkey=hex(schnorr.getPublicKey(identity)),created_at=Math.floor(Date.now()/1000),tags=[['u',origin+'/api/session/'+id+path],['method',method],['payload',await hash(body)],['nonce',crypto.randomUUID()]],eventId=await hash(encode(JSON.stringify([0,pubkey,created_at,27235,tags,''])));return 'Nostr '+Buffer.from(JSON.stringify({id:eventId,pubkey,created_at,kind:27235,tags,content:'',sig:hex(schnorr.sign(Buffer.from(eventId,'hex'),identity))})).toString('base64');}
try{
 await build({stdin:{contents:"export {PeerMailbox} from './lib/peer-mailbox'; export {BrowserPeer} from './lib/peer-connection'; export {keyFrom,seal,unseal,toBase64,fromBase64} from './lib/sealed'; export {localStore,saveSession,restoreSession,clearWorkspace} from './lib/local-store';",resolveDir:process.cwd()},bundle:true,format:'esm',platform:'node',outfile:join(dir,'peer.mjs')});
 const {PeerMailbox,BrowserPeer,keyFrom,seal,unseal,toBase64,fromBase64,localStore,saveSession,restoreSession,clearWorkspace}=await import(join(dir,'peer.mjs'));
 const session={id,key,pair,token:'4'.repeat(64),expires:0},box=new PeerMailbox(session,origin);
 const call=async(path,method='GET',value,phone=false)=>{const bytes=value instanceof Uint8Array?value:encode(value===undefined?'':JSON.stringify(value));return box.request(path,method,bytes,phone?await sign(path,method,bytes):undefined);};
 await saveSession(session);assert.deepEqual(await restoreSession(),session);assert(!JSON.stringify(await localStore.get('session')).includes(key));assert.equal((await localStore.get('wrapping-key')).extractable,false);
 await assert.rejects(call('/note','POST',{id:'a'.repeat(64),sealed:'x'.repeat(80)}),/Approve/);
 const pairBody=encode(JSON.stringify({pair})),proof=await sign('/pair','POST',pairBody);await box.request('/pair','POST',pairBody,proof);await assert.rejects(box.request('/pair','POST',pairBody,proof),/already used/);
 const edit='a'.repeat(64);await call('/note','POST',{id:edit,sealed:'x'.repeat(80)});await call('/note','POST',{id:edit,sealed:'x'.repeat(80)});assert.equal(box.edits.length,1);
 await assert.rejects(call('/note','POST',{id:edit,sealed:'y'.repeat(80)}),/conflict/);await assert.rejects(call('/note/'+edit,'DELETE'),/not saved/);
 const other=new Uint8Array(32);other[31]=2;await assert.rejects(box.request('','GET',new Uint8Array(),await sign('','GET',new Uint8Array(),other)),/not paired/);
 await call('/note/'+edit,'POST',{status:'saved',result:'sealed-receipt'},true);await call('/note/'+edit,'POST',{status:'conflict',result:'changed'},true);assert.equal(box.edits[0].status,'saved');
 const restored=new PeerMailbox(await restoreSession(),origin);await restored.restore();assert.equal(restored.edits[0].result,'sealed-receipt');await call('/note/'+edit,'DELETE');assert.equal(box.edits.length,0);
 await call('/snapshot','PUT',{sealed:'encrypted-snapshot'},true);assert.equal(box.snapshot,'encrypted-snapshot');
 const transfer='b'.repeat(64),file=new Uint8Array(2_100_028).fill(7);await call('/upload','POST',{id:transfer,meta:'sealed-meta',bytes:file.length});await call('/file/'+transfer,'PUT',file);
 assert.deepEqual(await call('/file/'+transfer+'?offset=32768&length=32768','GET',undefined,true),file.slice(32768,65536));await assert.rejects(call('/file/'+transfer+'?offset=0&length=999999','GET',undefined,true),/range/);
 await call('/file/'+transfer,'POST',undefined,true);assert.equal(await localStore.get(id+'/file/'+transfer),undefined);
 const wire=new BrowserPeer(box,()=>{},()=>{}),frames=[];wire.dc={readyState:'open',bufferedAmount:0,send:frame=>frames.push(JSON.parse(frame))};
 const raw=encode(JSON.stringify({id:1,path:'',method:'GET',body:'',authorization:await sign('','GET',new Uint8Array())}));const cryptoKey=await keyFrom(key),sealedWire=toBase64(await seal(cryptoKey,raw,id+'/rpc/phone/1'));let part=0;
 for(let offset=0;offset<sealedWire.length;offset+=14000)await wire.receive(JSON.stringify({seq:1,part:part++,data:sealedWire.slice(offset,offset+14000),last:offset+14000>=sealedWire.length}));
 const answer=JSON.parse(new TextDecoder().decode(await unseal(cryptoKey,fromBase64(frames.map(f=>f.data).join('')),id+'/rpc/browser/1')));assert.equal(answer.id,1);assert.equal(JSON.parse(Buffer.from(answer.body,'base64').toString()).paired,true);
 await assert.rejects(wire.receive(JSON.stringify({seq:1,part:0,data:sealedWire,last:true})),undefined,'replayed data-channel frames rejected');
 await localStore.set('slowclaw.web.drafts.'+id,'encrypted-draft');await call('','DELETE',undefined,true);assert.equal(await localStore.get('slowclaw.web.drafts.'+id),'encrypted-draft');await box.clear();assert.equal(await localStore.get(id+'/mailbox'),undefined);
 await clearWorkspace(id);await localStore.set('slowclaw.web.drafts.'+id,'late-draft');await localStore.set(id+'/mailbox',{snapshot:'late-snapshot'});await saveSession(session);assert.equal(await restoreSession(),null);assert.equal(await localStore.get('slowclaw.web.drafts.'+id),undefined);assert.equal(await localStore.get(id+'/mailbox'),undefined);
 console.log('PASS: IndexedDB recovery, key wrapping, signed pairing/replay, identity isolation, idempotent queues, immutable receipts, chunked imports and draft preservation');
}finally{rmSync(dir,{recursive:true,force:true});}
