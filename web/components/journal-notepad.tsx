'use client';
import {useEffect,useRef,useState} from 'react';
import {Button} from './ui/button';
import {keyFrom,seal,unseal,toBase64,fromBase64} from '@/lib/sealed';
import {applyJournalReceipt,Draft,Pending,JournalEntry} from '@/lib/journal-draft';
type Session={id:string;key:string};
export type JournalOperation={id:string;sealed:string;status:string;result?:string};
type API=(s:any,path?:string,options?:RequestInit)=>Promise<any>;
const random=()=>Array.from(crypto.getRandomValues(new Uint8Array(32)),x=>x.toString(16).padStart(2,'0')).join('');
const encode=(v:unknown)=>new TextEncoder().encode(JSON.stringify(v));
export function JournalNotepad({session,index,recent,operations,api,enabled}:{session:Session;index:JournalEntry[];recent:JournalEntry[];operations:JournalOperation[];api:API;enabled:boolean}){
 const [drafts,setDrafts]=useState<Record<string,Draft>>({}),[selected,setSelected]=useState(''),[query,setQuery]=useState(''),[ready,setReady]=useState(false),[problem,setProblem]=useState('');
 const state=useRef<Record<string,Draft>>({}),active=useRef(''),working=useRef(false),alive=useRef(true),persistence=useRef(Promise.resolve());
 const storage='slowclaw.web.drafts.'+session.id;
 function update(next:Record<string,Draft>){state.current=next;setDrafts(next);}
 function select(id:string){active.current=id;setSelected(id);}
 function persist(){const value={drafts:state.current,selected:active.current};persistence.current=persistence.current.catch(()=>{}).then(async()=>{const key=await keyFrom(session.key),sealed=await seal(key,encode(value),session.id+'/drafts');if(alive.current)sessionStorage.setItem(storage,toBase64(sealed));});return persistence.current;}
 useEffect(()=>{alive.current=true;void (async()=>{try{const stored=sessionStorage.getItem(storage);if(stored){const key=await keyFrom(session.key),value=JSON.parse(new TextDecoder().decode(await unseal(key,fromBase64(stored),session.id+'/drafts')));if(alive.current){update(value.drafts);select(value.selected);}}}catch{setProblem('Could not restore the encrypted browser draft.');}finally{if(alive.current)setReady(true);}})();return()=>{alive.current=false;};},[session.id]);
 useEffect(()=>{const warn=(e:BeforeUnloadEvent)=>{if(Object.values(state.current).some(d=>d.dirty||d.pending)){e.preventDefault();e.returnValue='';}};window.addEventListener('beforeunload',warn);return()=>window.removeEventListener('beforeunload',warn);},[]);
 async function send(d:Draft,kind:'read'|'write'){
  const id=random(),key=await keyFrom(session.key),payload=kind==='read'?{kind,key:d.id}:{kind,key:d.id,base:d.base,title:d.title,text:d.text};
  const pending:Pending={id,sealed:toBase64(await seal(key,encode(payload),session.id+'/note/'+id)),kind,title:d.title,text:d.text};
  // Persist the exact operation before networking so a lost response retries
  // one operation instead of creating another note or applying twice.
  update({...state.current,[d.id]:{...state.current[d.id],pending,status:kind==='read'?'Loading from phone…':'Saving…'}});await persist();
 }
 async function tick(){if(working.current||!ready||!enabled)return;working.current=true;try{
  for(const original of Object.values(state.current)){
   let d=state.current[original.id];if(d.conflict||d.status.startsWith('Unavailable'))continue;
   if(!d.pending&&d.dirty){if(encode({title:d.title,text:d.text}).length>999000){throw Error('This note is over the 1 MB editor limit.');}await send(d,'write');d=state.current[d.id];}
   if(!d.pending)continue;
   const pending=d.pending,receipt=operations.find(o=>o.id===pending.id);
   if(receipt&&receipt.status!=='queued'&&receipt.result){
    const key=await keyFrom(session.key),result=JSON.parse(new TextDecoder().decode(await unseal(key,fromBase64(receipt.result),session.id+'/note/'+pending.id+'/result')));
    d=state.current[d.id];const next=applyJournalReceipt(d,pending,receipt.status,result);
    update({...state.current,[d.id]:next});await persist();await api(session,'/note/'+pending.id,{method:'DELETE'});
   }else {
    await api(session,'/note',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({id:pending.id,sealed:pending.sealed})});
    const latest=state.current[d.id];update({...state.current,[d.id]:{...latest,status:pending.kind==='read'?'Loading from phone…':'Waiting for phone'}});
   }
  }
  setProblem('');
 }catch(e){setProblem((e as Error).message+' Your browser draft is kept; saving will retry.');}finally{working.current=false;}}
 useEffect(()=>{const timer=setInterval(()=>void tick(),1000);return()=>clearInterval(timer);},[ready,enabled,operations]);
 function newEntry(copy?:Draft){const id='journal_web_'+random();update({...state.current,[id]:{id,title:copy?.title||'',text:copy?.text||'',base:null,dirty:!!copy,status:copy?'Unsaved changes':'Start writing'}});select(id);void persist().catch(e=>setProblem(e.message));}
 async function open(entry:JournalEntry){if(state.current[entry.id]){select(entry.id);const d=state.current[entry.id];if(!d.dirty&&!d.pending&&!d.conflict&&entry.revision&&d.base!==entry.revision){try{await send(d,'read');}catch(e){setProblem((e as Error).message);}}return;}const loaded=recent.find(e=>e.id===entry.id&&e.revision);const d:Draft={id:entry.id,title:loaded?.title||entry.title||'',text:loaded?.text||'',base:loaded?.revision||null,dirty:false,status:loaded?'Saved on phone':'Loading from phone…'};update({...state.current,[entry.id]:d});select(entry.id);try{if(!loaded)await send(d,'read');else await persist();}catch(e){setProblem((e as Error).message);}}
 function change(field:'title'|'text',value:string){const d=state.current[active.current];if(!d)return;update({...state.current,[d.id]:{...d,[field]:value,dirty:true,status:d.pending?'Waiting for phone':'Unsaved changes'}});void persist().catch(e=>setProblem('Browser draft could not be saved: '+e.message));}
 useEffect(()=>{if(!ready)return;const d=state.current[active.current];if(!d||d.dirty||d.pending||d.conflict)return;const remote=recent.find(e=>e.id===d.id&&e.revision);if(remote&&remote.revision!==d.base){update({...state.current,[d.id]:{...d,title:remote.title||'',text:remote.text||'',base:remote.revision!,status:'Saved on phone'}});void persist().catch(e=>setProblem(e.message));}},[recent,ready]);
 const draft=drafts[selected];const entries=[...Object.values(drafts).filter(d=>!index.some(e=>e.id===d.id)).map(d=>({id:d.id,title:d.title||'New journal',kind:'JOURNAL',date:undefined})),...index].filter(e=>(e.title||'').toLowerCase().includes(query.toLowerCase()));
 return <section className="notepad"><aside className="note-sidebar"><Button onClick={()=>newEntry()} disabled={!ready||!enabled}>+ New entry</Button><input aria-label="Search journal titles" placeholder="Find an entry…" value={query} onChange={e=>setQuery(e.target.value)}/><div className="note-index">{entries.map(e=><button className={selected===e.id?'selected':''} key={e.id} disabled={!enabled||!ready} onClick={()=>void open(e)}><strong>{e.title||'Untitled'}</strong><small>{e.kind==='TRANSCRIPT'?'Transcript':e.date?new Date(e.date).toLocaleDateString():'Journal'}</small></button>)}</div></aside><div className="note-paper">{!enabled?<p>Update SlowClaw from TestFlight, then keep it open to enable the journal editor.</p>:!draft?<div className="note-welcome"><h2>A blank page, whenever you need it.</h2><p>Start a new journal or choose a note or transcript.</p><Button disabled={!ready} onClick={()=>newEntry()}>New entry</Button></div>:<><div className="note-save" role="status">{draft.status}</div><input className="note-title" aria-label="Journal title" placeholder="Untitled" value={draft.title} disabled={draft.pending?.kind==='read'} onChange={e=>change('title',Array.from(e.target.value.replace(/[\r\n]/g,'')).slice(0,240).join(''))}/><textarea key={selected} autoFocus className="note-text" aria-label="Journal text" placeholder="Start writing…" value={draft.text} disabled={draft.pending?.kind==='read'} onChange={e=>change('text',e.target.value)}/>{draft.conflict&&<div className="note-conflict"><p>Your phone has a newer version. Your browser text is kept above.</p><Button variant="outline" onClick={()=>{const e=draft.conflict!;update({...state.current,[draft.id]:{...draft,title:e.title||'',text:e.text||'',base:e.revision!,dirty:false,conflict:undefined,status:'Saved on phone'}});void persist();}}>Use phone version</Button><Button onClick={()=>{const original=draft;const e=draft.conflict!;update({...state.current,[draft.id]:{...draft,title:e.title||'',text:e.text||'',base:e.revision!,dirty:false,conflict:undefined,status:'Saved on phone'}});newEntry(original);}}>Save browser text as new entry</Button></div>}</>}{problem&&<p role="alert" className="error">{problem}</p>}<p className="note-caption">Autosaves as you write. Keep SlowClaw open on your iPhone to sync. No audio is downloaded.</p></div></section>;
}
