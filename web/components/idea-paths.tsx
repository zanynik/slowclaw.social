'use client';
import {useEffect,useRef,useState} from 'react';
import {Button} from './ui/button';
import {JournalEntry} from '@/lib/journal-draft';
import {JournalOperation} from './journal-notepad';
import {buildIdeaPaths,EmbeddedIdea,IdeaPath,ideaModelVersion,journalChunks,latestJournals,normalizeIdea,EmbeddingBackend,embeddingBackend} from '@/lib/idea-paths';
import {localStore} from '@/lib/local-store';
import {keyFrom,seal,unseal,toBase64,fromBase64} from '@/lib/sealed';
type Session={id:string;key:string};
type API=(s:any,path?:string,options?:RequestInit)=>Promise<any>;
type Cache={model:string;backend?:EmbeddingBackend;signature:string;entries:JournalEntry[];ideas:EmbeddedIdea[]};
const emptyCache=():Cache=>({model:ideaModelVersion,signature:'',entries:[],ideas:[]});
const encode=(v:unknown)=>new TextEncoder().encode(JSON.stringify(v));
export function IdeaPaths({session,index,recent,operations,api,sample=false,onPaths}:{session?:Session;index:JournalEntry[];recent:JournalEntry[];operations:JournalOperation[];api?:API;sample?:boolean;onPaths?:(paths:IdeaPath[])=>void}){
 const [ready,setReady]=useState(false),[busy,setBusy]=useState(false),[status,setStatus]=useState(''),[error,setError]=useState(''),[paths,setPaths]=useState<IdeaPath[]>([]),[savedSignature,setSavedSignature]=useState('');
 const cache=useRef(emptyCache()),worker=useRef<Worker|null>(null),generation=useRef(0),receipts=useRef(operations),running=useRef(false),cancelWorker=useRef<(()=>void)|null>(null);
 receipts.current=operations;
 const latest=latestJournals(index),signature=latest.map(e=>e.id+'@'+e.revision).join('|');
 const storage=session?.id+'/idea-paths';
 async function store(value:Cache){if(session&&storage){const key=await keyFrom(session.key);await localStore.set(storage,toBase64(await seal(key,encode(value),session.id+'/idea-paths')));}cache.current=value;}
 useEffect(()=>{let alive=true;void(async()=>{try{if(session&&storage){const raw=await localStore.get(storage);if(raw){const key=await keyFrom(session.key),value:Cache=JSON.parse(new TextDecoder().decode(await unseal(key,fromBase64(raw),session.id+'/idea-paths')));if(value.model===ideaModelVersion&&value.ideas.length<=60){value.ideas.forEach(i=>normalizeIdea(i.vector));if(alive){cache.current=value;setPaths(buildIdeaPaths(value.ideas));onPaths?.(buildIdeaPaths(value.ideas));setSavedSignature(value.signature);}}}}}catch{if(alive)setError('Previous Idea Paths could not be restored. Your journals are kept.');}finally{if(alive)setReady(true);}})();return()=>{alive=false;generation.current++;cancelWorker.current?.();worker.current?.terminate();worker.current=null;};},[session?.id]);
 async function read(entry:JournalEntry,run:number){
  const available=recent.find(e=>e.id===entry.id&&e.revision===entry.revision&&typeof e.text==='string')||cache.current.entries.find(e=>e.id===entry.id&&e.revision===entry.revision);
  if(available)return available;
  if(!session||!api)throw Error('Keep your phone connected to load the latest journals.');
  const record=session.id+'/idea-path-read/'+entry.id;
  const stored=await localStore.get(record);let pending:{id:string;sealed:string};
  if(stored){const key=await keyFrom(session.key);pending=JSON.parse(new TextDecoder().decode(await unseal(key,fromBase64(stored),record)));}
  else {const id=Array.from(crypto.getRandomValues(new Uint8Array(32)),x=>x.toString(16).padStart(2,'0')).join(''),key=await keyFrom(session.key);pending={id,sealed:toBase64(await seal(key,encode({kind:'read',key:entry.id}),session.id+'/note/'+id))};await localStore.set(record,toBase64(await seal(key,encode(pending),record)));}
  await api(session,'/note',{method:'POST',body:JSON.stringify(pending)});
  const deadline=Date.now()+60000;
  while(run===generation.current){
   const receipt=receipts.current.find(r=>r.id===pending.id&&r.status!=='queued'&&r.result);
   if(receipt){const key=await keyFrom(session.key),result=JSON.parse(new TextDecoder().decode(await unseal(key,fromBase64(receipt.result!),session.id+'/note/'+pending.id+'/result')));
    if(receipt.status!=='loaded'){await api(session,'/note/'+pending.id,{method:'DELETE'});await localStore.remove(record);throw Error(result.error||'The phone could not load this journal.');}
    const loaded=result.entry as JournalEntry;if(loaded.id!==entry.id||typeof loaded.text!=='string'||!loaded.revision)throw Error('Invalid journal receipt.');
    await store({...cache.current,entries:[...cache.current.entries.filter(e=>e.id!==entry.id),loaded].slice(-3)});
    await api(session,'/note/'+pending.id,{method:'DELETE'});await localStore.remove(record);
    if(loaded.revision!==entry.revision)throw Error('A journal changed on your phone. Refresh, then build again.');return loaded;
   }
   if(Date.now()>deadline)throw Error('Waiting for your phone. Keep SlowClaw open, reconnect, then retry.');
   await new Promise(resolve=>setTimeout(resolve,250));
  }throw Error('Paused.');
 }
 async function build(){if(running.current)return;running.current=true;setBusy(true);setError('');const run=++generation.current;
  try{
   const entries:JournalEntry[]=[];for(const entry of latest){if(run!==generation.current)return;setStatus('Loading '+(entry.title||'journal')+'…');entries.push(await read(entry,run));}
   const all=entries.flatMap(journalChunks),chunks=entries.flatMap(e=>journalChunks(e).slice(0,20));
   if(!chunks.length){setStatus('These journals have no text yet.');setPaths([]);return;}
   const backend=await embeddingBackend();if(run!==generation.current)return;
   const ideas=chunks.map(c=>{const old=cache.current.backend===backend?cache.current.ideas.find(i=>i.id===c.id&&i.text===c.text):undefined;return old?{...c,vector:old.vector}:undefined;});
   const missing=chunks.filter((_,i)=>!ideas[i]);
   if(missing.length){const vectors=await new Promise<number[][]>((resolve,reject)=>{
    cancelWorker.current=()=>reject(Error('Paused.'));
    const w=new Worker(new URL('../lib/idea-paths.worker.ts',import.meta.url),{type:'module'});worker.current=w;
    w.onmessage=e=>{if(run!==generation.current){reject(Error('Paused.'));return;}if(e.data.status)setStatus(e.data.status);else if(e.data.error)reject(Error(e.data.error));else resolve(e.data.vectors);};
    w.onerror=()=>reject(Error('The embedding worker could not start. Check your connection and retry in a current desktop browser.'));
    w.postMessage({texts:missing.map(c=>c.text),backend});
   });let n=0;chunks.forEach((c,i)=>{if(!ideas[i])ideas[i]={...c,vector:normalizeIdea(vectors[n++])};});}
   if(run!==generation.current)return;
   const embedded=ideas as EmbeddedIdea[];await store({model:ideaModelVersion,backend,signature,entries,ideas:embedded});
   if(run!==generation.current)return;setPaths(buildIdeaPaths(embedded));onPaths?.(buildIdeaPaths(embedded));setSavedSignature(signature);setStatus(`${entries.length} journal${entries.length===1?'':'s'} · ${chunks.length} passages${all.length>chunks.length?' · first 20 passages per journal':''} · ${sample?'computed locally':'saved in this browser'}`);
  }catch(e){if(run===generation.current)setError((e as Error).message);}finally{if(run===generation.current){worker.current?.terminate();worker.current=null;cancelWorker.current=null;running.current=false;setBusy(false);}}
 }
 function pause(){generation.current++;cancelWorker.current?.();cancelWorker.current=null;worker.current?.terminate();worker.current=null;running.current=false;setBusy(false);setStatus('Paused. Previously saved paths are kept.');}
 return <section className="thought-workspace"><div className="thought-heading"><div><h2>Idea Paths</h2><p className="quiet">Little chains of thought from your three latest journals.</p></div><Button disabled={!ready||!latest.length} onClick={busy?pause:()=>void build()}>{busy?'Pause':paths.length?'Refresh paths':'Build idea paths'}</Button></div>
 {sample&&<p className="sample-note">A sample workspace with invented journals. Connect your phone to explore your own.</p>}
 <p className="caption">Five lines at a time. Exact excerpts, grouped by meaning and ordered with the Idea Path prototype. EmbeddingGemma 2 runs on this device; its model downloads on first use.</p>
 {status&&<p role="status" className="quiet">{status}</p>}{error&&<p role="alert" className="error">{error}</p>}{savedSignature&&signature!==savedSignature&&<p className="quiet">Your latest journals have changed. Refresh paths when you’re ready.</p>}
 {!paths.length&&!busy&&<div className="empty"><h2>Follow an idea a little further.</h2><p>{latest.length?'Build paths to notice what connects these journals.':'Keep SlowClaw open to bring your latest journals here.'}</p></div>}
 <div className="idea-path-grid">{paths.map((path,i)=><article className="idea-path-card" key={path.ideas.map(p=>p.id).join('|')}><header><span className="eyebrow">{path.ideas.length>1?'IDEA PATH '+(i+1):'A THOUGHT TO KEEP'}</span><small>{path.ideas.length} passage{path.ideas.length===1?'':'s'}</small></header><ol>{path.ideas.map(idea=><li key={idea.id}><p>{idea.text}</p><small>{idea.title}{idea.date?' · '+new Date(idea.date).toLocaleDateString():''}</small></li>)}</ol>{path.ideas.length>2&&<details className="idea-path-score"><summary>How this chain was ordered</summary><p>Relatedness {path.similarity.toFixed(3)} · step alignment {path.alignment.toFixed(3)}. The earliest and latest passages anchor each chain. Similarity suggests a connection; it does not establish cause or chronology.</p></details>}</article>)}</div>
 </section>;
}
