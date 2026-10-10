// Opt-in deployment check: pnpm exec node tests/signaling-live.mjs https://...workers.dev
// Uses only synthetic signaling; the room is deleted even after a failed check.
import assert from 'node:assert/strict';
import {randomBytes} from 'node:crypto';
const origin=new URL(process.argv[2]||'');
assert.equal(origin.protocol,'https:');assert(origin.hostname.endsWith('.workers.dev'));
assert.equal(origin.pathname,'/');assert(!origin.search&&!origin.hash&&!origin.username&&!origin.password&&!origin.port);
const id=randomBytes(32).toString('hex'),base=origin.origin+'/v1/rooms';
async function call(path='',method='GET',token='',body,site='https://slowclaw.social'){
 const res=await fetch(base+path,{method,headers:{Origin:site,...(token?{Authorization:'Bearer '+token}:{}),...(body?{'Content-Type':'application/json'}:{})},body:body?JSON.stringify(body):undefined,signal:AbortSignal.timeout(20000)});
 return {status:res.status,body:await res.json()};
}
assert.equal((await call('','POST','',{id},'https://example.com')).status,403);
const created=await call('','POST','',{id});assert.equal(created.status,200);
const room=created.body,path='/'+id;
try{
 assert.equal((await call(path+'/offer')).status,401);
 assert.equal((await call(path+'/offer','PUT',room.pair,{sealed:'x'.repeat(80)})).status,403);
 assert.equal((await call(path+'/offer','PUT',room.token,{sealed:'x'.repeat(80)})).status,200);
 assert.equal((await call(path+'/offer','PUT',room.token,{sealed:'y'.repeat(80)})).status,409);
 assert.equal((await call(path+'/offer','GET',room.pair)).body.sealed,'x'.repeat(80));
 assert.equal((await call(path+'/answer','PUT',room.pair,{sealed:'z'.repeat(80)})).status,200);
 assert.equal((await call(path+'/answer','GET',room.token)).body.sealed,'z'.repeat(80));
 assert.equal((await call(path+'/snapshot','PUT',room.token,{sealed:'synthetic'})).status,404);
}finally{assert.equal((await call(path,'DELETE',room.token)).status,200);}
assert.equal((await call(path+'/offer','GET',room.pair)).status,410);
console.log('PASS live signaling: origin/capability isolation, immutable offer/answer, no journal route, deleted room');
