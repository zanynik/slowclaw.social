import test from 'node:test';
import assert from 'node:assert/strict';
import { Store } from '../src/store.mjs';
import { discoverConnections } from '../src/analysis.mjs';
import { processOne } from '../src/worker.mjs';
import { makeServer } from '../src/server.mjs';

const record=(id,body,revision=1)=>({id,source:`journal:${id}`,revision,occurred_at:'2026-01-01T12:00:00Z',body});
const p1=record('p1','Journaling reflection ideas meaningful notes useful patterns');
const p2=record('p2','Reflection journaling ideas meaningful projects and patterns');

test('revision-aware mirror is idempotent and never overwrites a conflict',()=>{
  const s=new Store(':memory:');
  assert.equal(s.importPassages([p1]).changed,1);
  assert.equal(s.importPassages([p1]).changed,0);
  assert.throws(()=>s.importPassages([{...p1,body:'edited without revision'}]),/conflict/);
  assert.throws(()=>s.importPassages([{...p1,revision:0}]),/Revision/);
  assert.equal(s.importPassages([{...p1,revision:2,body:'new text'}]).changed,1);
  assert.throws(()=>s.importPassages([p1]),/Stale/);
  assert.equal(s.passages()[0].body,'new text');s.close();
});

test('batch import is atomic even when second passage is invalid',()=>{
  const s=new Store(':memory:');
  assert.throws(()=>s.importPassages([p1,{...p2,revision:0}]),/Revision/);
  assert.equal(s.passages().length,0);s.close();
});

test('discovery yields cited, reviewable proposals and never changes journals',async()=>{
  const s=new Store(':memory:');s.importPassages([p1,p2]);
  assert.equal(discoverConnections(s.passages()).length,1);
  assert.equal(await processOne(s),true);
  const [proposal]=s.listProposals();
  assert.deepEqual(new Set(proposal.source_ids),new Set(['p1','p2']));
  assert.equal(proposal.status,'pending');
  assert.equal(s.decide(proposal.id,'accepted').status,'accepted');
  assert.throws(()=>s.decide(proposal.id,'rejected'),/already reviewed/);
  s.enqueue('discover-connections');
  await processOne(s);
  assert.equal(s.listProposals().length,1); // accepted suggestions do not resurface
  assert.equal(s.passages().length,2);
  assert.equal(s.listEvents().some(e=>e.name==='proposal.reviewed'),true);s.close();
});

test('reflect job needs explicit consent and does not silently use Pi',async()=>{
  const s=new Store(':memory:');s.importPassages([p1]);
  assert.throws(()=>s.enqueue('reflect',{source_ids:['p1']}),/explicit approval/);
  s.enqueue('reflect',{source_ids:['p1'],allow_model_provider:true});
  await processOne(s); // initial queued discovery
  await processOne(s,{reflect:async()=>`A proposal grounded in p1`});
  assert.equal(s.listProposals()[0].kind,'pi-reflection');
  assert.equal(s.listProposals()[0].status,'pending');s.close();
});

test('running jobs recover and fail after bounded retries',()=>{
  const s=new Store(':memory:');s.enqueue('discover-connections');s.claim();
  s.recoverJobs();assert.equal(s.listJobs()[0].status,'queued');
  s.claim();s.recoverJobs();assert.equal(s.listJobs()[0].status,'failed');s.close();
});

test('scheduler disabled by default and bounded to hourly minimum',()=>{
  const s=new Store(':memory:');
  assert.equal(s.scheduleTick(),false);
  assert.throws(()=>s.updateSchedule({enabled:true,interval_minutes:1}),/60/);
  s.updateSchedule({enabled:true,interval_minutes:60});
  assert.equal(s.scheduleTick(),true);
  assert.equal(s.scheduleTick(),false);s.close();
});

test('loopback HTTP API requires bearer token and rejects cross-origin writes',async()=>{
  const s=new Store(':memory:'),token='test-secret-token';
  const server=makeServer(s,token,{port:4317});
  await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
  const url=`http://127.0.0.1:${server.address().port}`;
  try{
    let r=await fetch(url+'/v1/passages');assert.equal(r.status,401);
    r=await fetch(url+'/v1/passages',{headers:{Authorization:`Bearer ${token}`}});assert.equal(r.status,200);
    r=await fetch(url+'/v1/passages',{method:'POST',headers:{Authorization:`Bearer ${token}`,Origin:'https://untrusted.example','Content-Type':'application/json'},body:JSON.stringify({passages:[p1]})});
    assert.equal(r.status,403);
    assert.equal(s.passages().length,0);
  }finally{await new Promise(resolve=>server.close(resolve));s.close()}
});
