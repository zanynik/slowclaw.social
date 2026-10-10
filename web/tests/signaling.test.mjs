import {createRequire} from 'node:module';
import {mkdtempSync,rmSync} from 'node:fs';
import {join} from 'node:path';
import {tmpdir} from 'node:os';
import assert from 'node:assert/strict';
const req=createRequire(import.meta.url),wr=createRequire(req.resolve('wrangler/package.json')),{build}=wr('esbuild'),{Miniflare}=wr('miniflare');
const dir=mkdtempSync(join(tmpdir(),'slowclaw-signal-'));let mf;
try{
 await build({entryPoints:['signaling/worker.ts'],bundle:true,format:'esm',platform:'browser',external:['cloudflare:workers'],outfile:join(dir,'worker.mjs')});
 mf=new Miniflare({modules:true,modulesRoot:dir,rootPath:dir,scriptPath:join(dir,'worker.mjs'),compatibilityDate:'2026-05-15',durableObjects:{PAIRING:{className:'PairingRooms'}},bindings:{ALLOWED_ORIGINS:'https://slowclaw.social'}});
 const call=(path,method='GET',token='',body,origin='https://slowclaw.social')=>mf.dispatchFetch('https://signaling.example.com/v1/rooms'+path,{method,headers:{Origin:origin,...(token?{Authorization:'Bearer '+token}:{}),...(body?{'Content-Type':'application/json'}:{})},body:body?JSON.stringify(body):undefined});
 assert.equal((await call('','POST','',{id:'1'.repeat(64)},'https://example.com')).status,403);
 let response=await call('','POST','',{id:'1'.repeat(64)});assert.equal(response.status,200);const room=await response.json();
 assert.equal((await call('/'+room.id+'/offer')).status,401);
 assert.equal((await call('/'+room.id+'/offer','PUT',room.pair,{sealed:'x'.repeat(80)})).status,403);
 assert.equal((await call('/'+room.id+'/offer','PUT',room.token,{sealed:'x'.repeat(80)})).status,200);
 assert.equal((await call('/'+room.id+'/offer','PUT',room.token,{sealed:'y'.repeat(80)})).status,409);
 assert.equal((await (await call('/'+room.id+'/offer','GET',room.pair)).json()).sealed,'x'.repeat(80));
 assert.equal((await call('/'+room.id+'/answer','PUT',room.pair,{sealed:'z'.repeat(80)})).status,200);
 assert.equal((await call('/'+room.id+'/snapshot','PUT',room.token,{sealed:'journal-content'})).status,404);
 assert.equal((await call('/'+room.id+'/answer','PUT',room.pair,{sealed:'z'.repeat(100001)})).status,413);
 assert.equal((await call('/'+room.id,'DELETE',room.pair)).status,404);
 assert.equal((await call('/'+room.id,'DELETE',room.token)).status,200);assert.equal((await call('/'+room.id+'/offer','GET',room.pair)).status,410);
 console.log('PASS: real Worker signaling, origin/capability isolation, immutable SDP, bounded payloads, no journal endpoints and deletion');
}finally{await mf?.dispose();rmSync(dir,{recursive:true,force:true});}
