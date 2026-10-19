import { discoverConnections } from './analysis.mjs';
import { reflectWithPi } from './pi.mjs';

export async function processOne(store, {reflect=reflectWithPi}={}) {
  const job=store.claim();
  if(!job)return false;
  try {
    if(job.kind==='discover-connections') {
      const matches=discoverConnections(store.passages());
      store.finish(job,{examined:store.passages().length,candidates:matches.length},matches);
    } else if(job.kind==='reflect') {
      const found=store.passages(job.payload.source_ids);
      if(found.length!==job.payload.source_ids.length) throw new Error('Some source IDs were not found');
      const output=await reflect(found);
      store.finish(job,{generated:true},[{
        kind:'pi-reflection',title:'Proposed reflection (Pi)',explanation:output,source_ids:found.map(p=>p.id)
      }]);
    } else throw new Error('Unsupported job');
  } catch(error) { store.fail(job,error.message||'Job failed'); }
  return true;
}

export function startWorker(store,{intervalMs=5000,reflect}={}) {
  let busy=false,closed=false;
  async function tick(){
    if(closed||busy) return;
    busy=true;
    try {store.scheduleTick();await processOne(store,{reflect});}
    finally {busy=false;}
  }
  const interval=setInterval(()=>{void tick();},intervalMs);
  void tick();
  return {async stop(){closed=true;clearInterval(interval);while(busy)await new Promise(r=>setTimeout(r,10));},tick};
}
