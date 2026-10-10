'use client';
import {useEffect,useRef,useState} from 'react';
import {Button} from './ui/button';
import {JournalOperation} from './journal-notepad';
import {JournalEntry} from '@/lib/journal-draft';
import {Candidate,UnitGroup,unitModel} from '@/lib/journal-units';
import {keyFrom,seal,unseal,toBase64,fromBase64} from '@/lib/sealed';
type Session={id:string;key:string};
type Pending={id:string;sealed:string;kind:'read'|'units';key:string;revision:string};
const random=()=>Array.from(crypto.getRandomValues(new Uint8Array(32)),x=>x.toString(16).padStart(2,'0')).join('');
export function JournalThoughts({session,index,recent,groups,revisions,operations,enabled,api}:{session:Session;index:JournalEntry[];recent:JournalEntry[];groups:UnitGroup[];revisions:Record<string,string>;operations:JournalOperation[];enabled:boolean;api:(s:any,path?:string,options?:RequestInit)=>Promise<any>}){
 const [running,setRunning]=useState(false),[status,setStatus]=useState(''),[problem,setProblem]=useState(''),[ready,setReady]=useState(false);
 const job=useRef<Pending|null>(null),worker=useRef<Worker|null>(null),working=useRef(false),alive=useRef(true),active=useRef(false),done=useRef<Record<string,string>>({}),blocked=useRef(new Set<string>());
 const storage='slowclaw.web.units.'+session.id;
 useEffect(()=>{alive.current=true;void(async()=>{try{const saved=sessionStorage.getItem(storage);if(saved){const key=await keyFrom(session.key);job.current=JSON.parse(new TextDecoder().decode(await unseal(key,fromBase64(saved),session.id+'/units-pending')));}}catch{setProblem('The previous organizing request could not be restored.');}finally{if(alive.current)setReady(true);}})();return()=>{alive.current=false;active.current=false;worker.current?.terminate();};},[session.id]);
 async function queue(payload:any,kind:Pending['kind'],key:string,revision:string){
  const bytes=new TextEncoder().encode(JSON.stringify(payload));
  if(bytes.length>950000)throw Error('This journal has too many separate thoughts to sync in one pass. Its original text is kept.');
  const id=random(),secret=await keyFrom(session.key),sealed=toBase64(await seal(secret,bytes,session.id+'/note/'+id));
  const pending={id,sealed,kind,key,revision};
  const stored=toBase64(await seal(secret,new TextEncoder().encode(JSON.stringify(pending)),session.id+'/units-pending'));
  if(!alive.current)return;sessionStorage.setItem(storage,stored);job.current=pending;
 }
 async function organize(entry:JournalEntry){
  if(!entry.revision||typeof entry.text!=='string')throw Error('This journal has no current source text.');
  setStatus('Preparing '+(entry.title||'journal')+'…');
  const units=await new Promise<Candidate[]>((resolve,reject)=>{
   const w=worker.current??new Worker(new URL('../lib/journal-units.worker.ts',import.meta.url),{type:'module'});worker.current=w;
   w.onmessage=e=>{if(e.data.status){setStatus(e.data.status);return;}if(e.data.error)reject(Error(e.data.error));else resolve(e.data.units);};
   w.onerror=()=>{w.terminate();worker.current=null;reject(Error('The local model could not start. Please retry in a current desktop browser.'));};
   w.postMessage({text:entry.text});
  });
  if(alive.current)await queue({kind:'units',key:entry.id,base:entry.revision,model:unitModel,units},'units',entry.id,entry.revision);
 }
 async function tick(){
  if(!ready||!enabled||working.current)return;working.current=true;
  let attempted:JournalEntry|undefined;
  try{
   const pending=job.current;
   if(pending){
    const receipt=operations.find(o=>o.id===pending.id);
    if(receipt&&receipt.status!=='queued'&&receipt.result){
     const key=await keyFrom(session.key),result=JSON.parse(new TextDecoder().decode(await unseal(key,fromBase64(receipt.result),session.id+'/note/'+pending.id+'/result')));
     if(receipt.status==='rejected'){blocked.current.add(pending.key+'@'+pending.revision);throw Error(result.error||'The phone could not accept this journal.');}
     if(pending.kind==='read'&&receipt.status==='loaded'){
      // Clear only after the next encrypted operation has been persisted.
      attempted=result.entry;await organize(result.entry);
     }else if(pending.kind==='units'&&receipt.status==='saved'&&result.key===pending.key&&result.revision===pending.revision){
      done.current[pending.key]=pending.revision;job.current=null;sessionStorage.removeItem(storage);setStatus('Saved on phone.');
     }else throw Error('Unexpected phone receipt.');
     await api(session,'/note/'+pending.id,{method:'DELETE'});
    }else{
     await api(session,'/note',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id:pending.id,sealed:pending.sealed})});setStatus('Waiting for phone…');
    }
   }else if(active.current){
    const entry=index.find(e=>e.revision&&revisions[e.id]!==e.revision&&done.current[e.id]!==e.revision&&!blocked.current.has(e.id+'@'+e.revision));
    if(!entry){active.current=false;setRunning(false);setStatus('Available thoughts are organized.');}
    else{const loaded=recent.find(e=>e.id===entry.id&&e.revision===entry.revision);if(loaded){attempted=loaded;await organize(loaded);}else await queue({kind:'read',key:entry.id},'read',entry.id,entry.revision!);}
   }
  }catch(e){if(attempted?.revision){blocked.current.add(attempted.id+'@'+attempted.revision);const pending=job.current;if(pending?.kind==='read')blocked.current.add(pending.key+'@'+pending.revision);}
   setProblem((e as Error).message);active.current=false;setRunning(false);
   const pending=job.current;if(pending&&blocked.current.has(pending.key+'@'+pending.revision)){await api(session,'/note/'+pending.id,{method:'DELETE'}).catch(()=>{});job.current=null;sessionStorage.removeItem(storage);}
  }finally{working.current=false;}
 }
 useEffect(()=>{const timer=setInterval(()=>void tick(),1500);return()=>clearInterval(timer);},[ready,enabled,operations,index,recent,revisions]);
 function start(){setProblem('');active.current=true;setRunning(true);}
 function pause(){active.current=false;setRunning(false);setStatus('Paused. The current journal will finish and sync.');}
 return <section className="thought-workspace"><div className="thought-heading"><div><h2>Your thoughts</h2><p className="quiet">Related passages, gathered from your journals.</p></div><Button disabled={!enabled||!ready} onClick={running?pause:start}>{running?'Pause':'Organize thoughts'}</Button></div>{!enabled&&<p>Update SlowClaw from TestFlight, then reconnect to organize your thoughts.</p>}{status&&<p role="status" className="quiet">{status}</p>}{problem&&<div role="alert" className="error"><p>{problem}</p>{!running&&<Button variant="ghost" onClick={()=>{blocked.current.clear();start();}}>Retry skipped journals</Button>}</div>}<p className="caption">Processing stays in this browser. The model downloads once; keep this page and SlowClaw open to sync. Groups are saved on your phone.</p>{groups.length===0?<div className="empty"><h2>See what connects your thoughts.</h2><p>Choose Organize thoughts to gather related journal passages here.</p></div>:<div className="thought-groups">{groups.map(group=><details key={group.id} className="thought-group"><summary><span>{group.title}</span><small>{group.units.length} thought{group.units.length===1?'':'s'}</small></summary>{group.units.map(unit=><article key={unit.id}><p className="entry-body">{unit.text}</p><small className="quiet">{index.find(e=>e.id===unit.sourceKey)?.title||'Journal'}</small></article>)}</details>)}</div>}</section>;
}
