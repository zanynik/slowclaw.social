import {admin,body,checked,optional,Problem,rpc,serve,string,user} from '../_shared/http.ts';

Deno.serve(req=>serve(req,async req=>{
  const db=admin(),uid=await user(req,db),input=await body(req),action=string(input.action,40);
  if(action==='settings') {
    checked(await db.from('cloud_settings').upsert({user_id:uid},{onConflict:'user_id',ignoreDuplicates:true}));
    return {settings:checked(await db.from('cloud_settings').select('*').eq('user_id',uid).single())};
  }
  if(action==='configure') {
    const old=optional(await db.from('cloud_settings').select('*').eq('user_id',uid).maybeSingle());
    const patch:Record<string,unknown>={user_id:uid};
    for(const key of ['sync_enabled','ai_enabled','daily_enabled'])if(key in input){if(typeof input[key]!=='boolean')throw new Problem('INVALID_SETTING');patch[key]=input[key];}
    if('provider' in input){if(!['openai','openrouter'].includes(String(input.provider)))throw new Problem('INVALID_PROVIDER');patch.provider=input.provider;}
    for(const [key,max] of [['daily_limit',200],['daily_budget',20],['monthly_budget',200]] as const)if(key in input){const n=input[key];if(typeof n!=='number'||!Number.isFinite(n)||n<0||n>max||(key==='daily_limit'&&!Number.isInteger(n)))throw new Problem('INVALID_BUDGET');patch[key]=n;}
    const settings=checked(await db.from('cloud_settings').upsert({...old,...patch,updated_at:new Date().toISOString()}).select().single());
    if(!settings.sync_enabled||!settings.ai_enabled)checked(await db.from('cloud_jobs').update({status:'blocked',error_code:'PROCESSING_DISABLED'}).eq('user_id',uid).in('status',['pending','running'] ).neq('kind','purge_media'));
    return {settings};
  }
  if(action==='provider_key'){
    const provider=string(input.provider,20);if(!['openai','openrouter'].includes(provider))throw new Problem('INVALID_PROVIDER');
    await rpc(db,'cloud_provider_secret',{p_user:uid,p_provider:provider,p_value:input.remove===true?null:string(input.key,500),p_remove:input.remove===true});
    return {configured:input.remove!==true};
  }
  if(action==='snapshot'){
    const offset=Number(input.offset||0);if(!Number.isInteger(offset)||offset<0||offset>20000)throw new Problem('INVALID_OFFSET');
    const entries=checked(await db.from('cloud_entries').select('*').eq('user_id',uid).order('id').range(offset,offset+199));
    if(offset>0)return {entries,hasMore:entries.length===200};
    const [artifacts,reads,jobs,media,usage]=await Promise.all([
      db.from('cloud_artifacts').select('*').eq('user_id',uid).order('created_at',{ascending:false}).limit(300),
      db.from('cloud_reads').select('*').eq('user_id',uid).order('score',{ascending:false}).limit(100),
      db.from('cloud_jobs').select('id,kind,entry_id,status,attempts,error_code,created_at').eq('user_id',uid).order('created_at',{ascending:false}).limit(60),
      db.from('cloud_media').select('*').eq('user_id',uid).order('created_at',{ascending:false}).limit(1000),
      db.from('cloud_usage').select('reserved_usd,created_at').eq('user_id',uid).gte('created_at',new Date(Date.now()-32*86400000).toISOString()).limit(10000),
    ]);
    return {entries,hasMore:entries.length===200,artifacts:checked(artifacts),reads:checked(reads),jobs:checked(jobs),media:checked(media),usage:checked(usage)};
  }
  if(action==='save'){
    const revision=input.revision;if(!Number.isInteger(revision)||Number(revision)<0)throw new Problem('INVALID_REVISION');
    const recorded=input.recorded_at?new Date(String(input.recorded_at)):null;if(recorded&&!Number.isFinite(+recorded))throw new Problem('INVALID_DATE');
    return await rpc(db,'cloud_save_entry',{p_user:uid,p_id:string(input.id,200),p_text:string(input.text,1000000,true),p_title:string(input.title||'',240,true),p_source:string(input.source||'text',100),p_recorded:recorded?.toISOString()||null,p_revision:revision,p_deleted:input.deleted===true});
  }
  if(action==='upload_start'){
    const entry=checked(await db.from('cloud_entries').select('id,deleted_at').eq('user_id',uid).eq('id',string(input.entry_id,200)).single());
    const settings=checked(await db.from('cloud_settings').select('sync_enabled').eq('user_id',uid).single());if(!settings.sync_enabled||entry.deleted_at)throw new Problem('SYNC_DISABLED',409);
    const size=input.bytes, hash=string(input.sha256,64),mime=string(input.mime,100);
    if(!Number.isInteger(size)||Number(size)<1||Number(size)>52428800||!/^[a-f0-9]{64}$/.test(hash)||!['audio/mp4','audio/mpeg','audio/wav','audio/x-wav','audio/webm','audio/aac','audio/flac','application/octet-stream'].includes(mime))throw new Problem('INVALID_FILE');
    const existing=optional(await db.from('cloud_media').select('*').eq('user_id',uid).eq('entry_id',entry.id).eq('sha256',hash).maybeSingle());
    if(existing?.status==='uploaded')return {media:existing,complete:true};
    let media=existing;
    if(!media){
      const rows=checked(await db.from('cloud_media').select('bytes').eq('user_id',uid).limit(20000));
      if(rows.reduce((sum,r)=>sum+Number(r.bytes),0)+Number(size)>900*1024*1024)throw new Problem('AUDIO_QUOTA_REACHED',409);
      const id=crypto.randomUUID(),path=uid+'/'+id+'/'+hash;
      const result=await db.from('cloud_media').insert({user_id:uid,id,entry_id:entry.id,object_path:path,filename:string(input.filename,240),bytes:size,sha256:hash,mime}).select().single();
      if(result.error){media=checked(await db.from('cloud_media').select('*').eq('user_id',uid).eq('entry_id',entry.id).eq('sha256',hash).single());}else media=result.data;
    }
    const signed=checked(await db.storage.from('slowclaw-audio').createSignedUploadUrl(media.object_path));
    return {media,upload:signed};
  }
  if(action==='upload_finish'){
    const media=checked(await db.from('cloud_media').select('*').eq('user_id',uid).eq('id',string(input.id,100)).single());
    const entry=checked(await db.from('cloud_entries').select('*').eq('user_id',uid).eq('id',media.entry_id).single());
    const settings=checked(await db.from('cloud_settings').select('*').eq('user_id',uid).single());if(!settings.sync_enabled||entry.deleted_at)throw new Problem('SYNC_DISABLED',409);
    const blob=checked(await db.storage.from('slowclaw-audio').download(media.object_path));
    if(blob.size!==Number(media.bytes))throw new Problem('UPLOAD_SIZE_MISMATCH',409);
    const hash=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',await blob.arrayBuffer())),x=>x.toString(16).padStart(2,'0')).join('');
    if(hash!==media.sha256)throw new Problem('UPLOAD_HASH_MISMATCH',409);
    checked(await db.from('cloud_media').update({status:'uploaded'}).eq('user_id',uid).eq('id',media.id));
    if(settings.ai_enabled&&(!entry.text.trim()||entry.text.includes('transcribing…'))&&media.bytes<=25000000){
      checked(await db.from('cloud_jobs').upsert({user_id:uid,kind:'transcribe',entry_id:entry.id,input_hash:entry.id+':'+entry.revision+':'+media.sha256,payload:{media_id:media.id,revision:entry.revision}},{onConflict:'user_id,kind,input_hash',ignoreDuplicates:true}));
    }
    return {uploaded:true,transcriptionSupported:media.bytes<=25000000};
  }
  if(action==='audio_url'){
    const media=checked(await db.from('cloud_media').select('*').eq('user_id',uid).eq('id',string(input.id,100)).eq('status','uploaded').single());
    const entry=checked(await db.from('cloud_entries').select('deleted_at').eq('user_id',uid).eq('id',media.entry_id).single());if(entry.deleted_at)throw new Problem('ENTRY_DELETED',410);
    return checked(await db.storage.from('slowclaw-audio').createSignedUrl(media.object_path,60));
  }
  if(action==='enqueue'){
    const settings=checked(await db.from('cloud_settings').select('*').eq('user_id',uid).single());if(!settings.sync_enabled||!settings.ai_enabled)throw new Problem('PROCESSING_DISABLED',409);
    if(input.daily===true){if(!settings.daily_enabled)throw new Problem('DAILY_DISABLED',409);checked(await db.from('cloud_jobs').upsert({user_id:uid,kind:'daily',input_hash:new Date().toISOString().slice(0,10)},{onConflict:'user_id,kind,input_hash',ignoreDuplicates:true}));}
    await rpc(db,'cloud_enqueue_missing',{p_user:uid});
    if(input.retry===true)checked(await db.from('cloud_jobs').update({status:'pending',available_at:new Date().toISOString(),attempts:0,error_code:null}).eq('user_id',uid).in('status',['blocked','failed']));
    return {queued:true};
  }
  if(action==='artifact_state'){
    if(!['accepted','dismissed','completed','proposed'].includes(String(input.state)))throw new Problem('INVALID_STATE');
    const patch:Record<string,unknown>={state:input.state};if(input.title!==undefined)patch.title=string(input.title,240);
    const artifact=checked(await db.from('cloud_artifacts').select('id,stale').eq('user_id',uid).eq('id',string(input.id,100)).single());
    if(artifact.stale&&input.state==='accepted')throw new Problem('SOURCE_CHANGED',409);
    checked(await db.from('cloud_artifacts').update(patch).eq('user_id',uid).eq('id',artifact.id));return {saved:true};
  }
  if(action==='read') {checked(await db.from('cloud_reads').update({read_at:input.read===false?null:new Date().toISOString()}).eq('user_id',uid).eq('url',string(input.url,2048)));return {saved:true};}
  if(action==='search'){
    // Text search works without sending the query to a provider. Semantic units retain exact source links.
    const q=string(input.query,200).replace(/[,%()]/g,' ').trim();if(q.length<2)throw new Problem('QUERY_TOO_SHORT');
    return {entries:checked(await db.from('cloud_entries').select('*').eq('user_id',uid).is('deleted_at',null).ilike('text','%'+q+'%').limit(50))};
  }
  if(action==='source'){
    const id=string(input.id,200),revision=Number(input.revision);
    const current=optional(await db.from('cloud_entries').select('*').eq('user_id',uid).eq('id',id).is('deleted_at',null).maybeSingle());
    if(!current)throw new Problem('SOURCE_UNAVAILABLE',404);
    if(current.revision===revision)return {entry:current};
    const old=checked(await db.from('cloud_entry_history').select('*').eq('user_id',uid).eq('id',id).eq('revision',revision).single());
    return {entry:old};
  }
  if(action==='export'){
    const offset=Number(input.offset||0);if(!Number.isInteger(offset)||offset<0||offset>200000)throw new Problem('INVALID_OFFSET');
    const tables:Record<string,string>={entries:'cloud_entries',history:'cloud_entry_history',artifacts:'cloud_artifacts',media:'cloud_media',reads:'cloud_reads',units:'cloud_units',settings:'cloud_settings',usage:'cloud_usage'};
    const entity=String(input.entity||'entries'),table=tables[entity];if(!table)throw new Problem('INVALID_EXPORT_ENTITY');
    const order=entity==='history'?'id':entity==='units'?'entry_id':entity==='settings'?'user_id':entity==='reads'?'url':'id';
    let query=db.from(table).select('*').eq('user_id',uid).order(order);
    if(entity==='history')query=query.order('revision');if(entity==='units')query=query.order('ordinal');
    return {rows:checked(await query.range(offset,offset+199))};
  }
  throw new Problem('UNKNOWN_ACTION',404);
}));
