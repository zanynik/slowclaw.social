import {admin,body,checked,DB,failure,Problem,rpc,serve,user} from '../_shared/http.ts';
import {analysisArtifacts} from '../_shared/ai.ts';
import {dailyArtifacts,embeddings,generate,relatedGroups,Source} from '../_shared/ai.ts';
import {candidates} from '../_shared/reads.ts';

type Job={id:string;user_id:string;entry_id:string;kind:string;input_hash:string;payload:Record<string,any>;lease_token:string;attempts:number};
async function current(db:DB,j:Job){
  const live=checked(await db.from('cloud_jobs').select('status,lease_token').eq('id',j.id).single());
  const settings=checked(await db.from('cloud_settings').select('*').eq('user_id',j.user_id).single());
  if(live.status!=='running'||live.lease_token!==j.lease_token||!settings.sync_enabled||!settings.ai_enabled)throw new Problem('PROCESSING_DISABLED',409);
  return settings;
}
async function process(db:DB,j:Job){
  if(j.kind==='purge_media'){
    const media=checked(await db.from('cloud_media').select('id,object_path').eq('user_id',j.user_id).eq('entry_id',j.entry_id));
    if(media.length){checked(await db.storage.from('slowclaw-audio').remove(media.map(m=>m.object_path)));checked(await db.from('cloud_media').delete().eq('user_id',j.user_id).eq('entry_id',j.entry_id));}
    checked(await db.from('cloud_jobs').update({status:'completed',updated_at:new Date().toISOString()}).eq('id',j.id).eq('lease_token',j.lease_token));return;
  }
  const settings=await current(db,j);
  if(j.kind==='analyze'){
    const entry=checked(await db.from('cloud_entries').select('*').eq('user_id',j.user_id).eq('id',j.entry_id).single());
    if(entry.deleted_at||j.input_hash!==entry.id+':'+entry.revision)throw new Problem('SOURCE_CHANGED',409);
    if(entry.text.length>60000)throw new Problem('JOURNAL_TOO_LONG_SPLIT_REQUIRED',409);
    const {value,model}=await generate(db,j.user_id,settings.provider,'Return {summary:string, actions:[{text,quote}], moments:[{title,quote}], topics:string[], quotes:string[]}. Actions require an explicit intention supported by an exact quote. Quotes must be verbatim contiguous passages from the source. Up to 16 meaningful quotes, 8 actions, 4 moments. Preserve the author language.',{text:entry.text});
    const result=analysisArtifacts(value,entry.text);
    await current(db,j);
    await embeddings(db,j.user_id,result.units,settings.provider);
    await rpc(db,'cloud_commit_analysis',{p_job:j.id,p_lease:j.lease_token,p_revision:entry.revision,p_artifacts:result.artifacts,p_units:result.units,p_model:model});return;
  }
  if(j.kind==='transcribe')throw new Problem('APP_TRANSCRIPTION_ONLY',409);
  if(j.kind==='daily'){
    const entries=checked(await db.from('cloud_entries').select('id,revision,text,title,recorded_at').eq('user_id',j.user_id).is('deleted_at',null).order('updated_at',{ascending:false}).limit(30)) as Source[];
    const summaries=checked(await db.from('cloud_artifacts').select('body,sources').eq('user_id',j.user_id).eq('kind','summary').eq('stale',false).order('created_at',{ascending:false}).limit(60));
    const sources=entries.filter(e=>e.text.trim()&&!e.text.includes('transcribing…'));
    if(!sources.length)throw new Problem('JOURNALS_REQUIRED',409);
    const units=checked(await db.from('cloud_units').select('entry_id,quote,embedding,model').eq('user_id',j.user_id).in('entry_id',sources.map(s=>s.id)).limit(120));
    const material=sources.map(e=>({id:e.id,revision:e.revision,title:e.title,recorded_at:e.recorded_at,text:(summaries.find(a=>a.sources.some((s:any)=>s.id===e.id&&s.revision===e.revision))?.body.text||e.text).slice(0,2200)}));
    const readings=await candidates();
    const {value,model}=await generate(db,j.user_id,settings.provider,'Return {reflection:string, spaces:[{title,summary,status,entry_ids:string[]}], readings:[{url,score:number,reason:string}]}. Propose coherent Spaces across at least two journals, with current status and a chronological booklet order of entry_ids. Consider the semantically related exact passages as evidence. Rank up to 15 supplied articles by relevance to the author. URLs must come from candidates. Do not claim to have read full articles. Distinguish questions from decisions.',{journals:material,relatedPassages:relatedGroups(units),candidates:readings});
    const artifacts=dailyArtifacts(value,sources);
    if(Array.isArray(value.readings))for(const r of value.readings.slice(0,15)){
      const source=readings.find(x=>x.url===r.url);
      if(source&&typeof r.score==='number'&&Number.isFinite(r.score))artifacts.push({kind:'read',title:source.title.slice(0,240),body:{...source,score:Math.max(0,Math.min(1,r.score)),reason:typeof r.reason==='string'?r.reason.slice(0,700):''}});
    }
    await rpc(db,'cloud_commit_daily',{p_job:j.id,p_lease:j.lease_token,p_artifacts:artifacts,p_sources:sources.map(({id,revision})=>({id,revision})),p_model:model});
    return;
  }
  throw new Problem('UNSUPPORTED_JOB');
}

Deno.serve(req=>serve(req,async req=>{
  const db=admin(),cron=req.headers.get('x-slowclaw-cron');let uid:string|null=null;
  if(cron){if(!await rpc(db,'cloud_scheduler_authorized',{p_token:cron}))throw new Problem('UNAUTHORIZED',401);}
  else {uid=await user(req,db);await body(req,2000);}
  if(cron){
    const users=checked(await db.from('cloud_settings').select('user_id,daily_enabled').eq('sync_enabled',true).eq('ai_enabled',true).limit(200));
    for(const s of users)await rpc(db,'cloud_enqueue_missing',{p_user:s.user_id});
    const jobs=users.filter(s=>s.daily_enabled).map(s=>({user_id:s.user_id,kind:'daily',input_hash:new Date().toISOString().slice(0,10)}));
    if(jobs.length)checked(await db.from('cloud_jobs').upsert(jobs,{onConflict:'user_id,kind,input_hash',ignoreDuplicates:true}));
  }
  const job=await rpc<Job|null>(db,'cloud_claim_job',{p_user:uid});if(!job)return {processed:false};
  try{await process(db,job);return {processed:true,job_id:job.id};}
  catch(e){const p=failure(e);const blocked=['APP_TRANSCRIPTION_ONLY','OPENAI_KEY_REQUIRED','OPENROUTER_KEY_REQUIRED','BUDGET_LIMIT','PROCESSING_DISABLED','AUDIO_SPLIT_REQUIRED','JOURNAL_TOO_LONG_SPLIT_REQUIRED','JOURNALS_REQUIRED'].includes(p.error);
    checked(await db.from('cloud_jobs').update({status:p.error==='SOURCE_CHANGED'?'cancelled':blocked?'blocked':job.attempts>=4?'failed':'pending',error_code:p.error,available_at:new Date(Date.now()+Math.min(3600,60*2**job.attempts)*1000).toISOString(),lease_until:null,updated_at:new Date().toISOString()}).eq('id',job.id).eq('status','running').eq('lease_token',job.lease_token));
    return {processed:false,job_id:job.id,error:p.error};}
}));
