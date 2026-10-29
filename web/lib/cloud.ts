import {createClient,type SupabaseClient} from '@supabase/supabase-js';
import {loadPrivateRecord,localStore,savePrivateRecord} from './local-store';
export type CloudConfig={url:string;publishableKey:string};
export type CloudEntry={id:string;text:string;title:string;source:string;recorded_at:string;revision:number;content_hash:string;deleted_at:string|null;updated_at:string};
export type CloudArtifact={id:string;kind:string;title:string;body:{text?:string;status?:string;entry_ids?:string[];booklet?:string[];quote?:string;topics?:string[]};sources:{id:string;revision:number}[];state:string;stale:boolean;model:string};
export type CloudSettings={sync_enabled:boolean;ai_enabled:boolean;daily_enabled:boolean;provider:'openai'|'openrouter';daily_limit:number;daily_budget:number;monthly_budget:number};
export type CloudSnapshot={entries:CloudEntry[];hasMore:boolean;artifacts:CloudArtifact[];reads:{url:string;title:string;description:string;source:string;score:number;reason:string;read_at:string|null}[];jobs:{id:string;kind:string;entry_id:string;status:string;attempts:number;error_code:string|null}[];media:{id:string;entry_id:string;filename:string;status:string;bytes:number;sha256:string}[];usage:{reserved_usd:number;created_at:string}[]};
export type CloudWrite={id:string;text:string;title:string;source:string;recorded_at?:string;revision:number;deleted?:boolean};
export type PendingWrite=CloudWrite&{operation:string;conflict?:CloudEntry|null};
export const emptyCloud:CloudSnapshot={entries:[],hasMore:false,artifacts:[],reads:[],jobs:[],media:[],usage:[]};
export function validateCloudConfig(value:CloudConfig):CloudConfig {
  const u=new URL(value.url);
  if(u.protocol!=='https:'||!u.hostname.endsWith('.supabase.co')||u.username||u.password||u.port||!['','/'].includes(u.pathname)||u.search||u.hash)throw Error('Use your Supabase project HTTPS URL.');
  if(!/^sb_publishable_[A-Za-z0-9_-]+$/.test(value.publishableKey))throw Error('Use a publishable key, never a secret or service-role key.');
  return {url:u.origin,publishableKey:value.publishableKey};
}
export function cloudClient(config:CloudConfig):SupabaseClient {
  const safe=validateCloudConfig(config);
  return createClient(safe.url,safe.publishableKey,{auth:{detectSessionInUrl:true,flowType:'pkce',storage:{
    getItem:async key=>loadPrivateRecord<string>('cloud/auth/'+key),
    setItem:async(key,value)=>{await savePrivateRecord('cloud/auth/'+key,value);},
    removeItem:async key=>{await localStore.remove('cloud/auth/'+key);},
  }}});
}
export const message=(e:unknown)=>e instanceof Error?e.message:'Could not finish. Your local drafts are kept.';
export async function cloudAPI<T=any>(client:SupabaseClient,input:Record<string,unknown>,worker=false,accessToken?:string):Promise<T>{
  const {data,error}=await client.functions.invoke(worker?'cloud-worker':'cloud-api',{body:input,...(accessToken?{headers:{Authorization:'Bearer '+accessToken}}:{})});
  if(error){let code='Cloud request failed. Your local drafts are kept.';try{const context=(error as {context?:Response}).context;if(context){const b=await context.json() as {error?:string};code=b.error||code;}}catch{}throw Error(code);}
  if(data?.error)throw Error(data.error);return data as T;
}
export async function pendingWrites(uid:string):Promise<PendingWrite[]>{return await loadPrivateRecord<PendingWrite[]>('cloud/'+uid+'/outbox')||[];}
export async function withOutbox<T>(uid:string,run:()=>Promise<T>):Promise<T>{if(!navigator.locks)throw Error('Use a current browser with workspace locking.');return navigator.locks.request('slowclaw-cloud-'+uid,run);}
export async function queueWrite(uid:string,value:CloudWrite){return withOutbox(uid,async()=>{
  const rows=await pendingWrites(uid),old=rows.find(r=>r.id===value.id),revisions=await loadPrivateRecord<Record<string,number>>('cloud/'+uid+'/revisions')||{};
  const next={...value,revision:old?.revision??Math.max(value.revision,revisions[value.id]||0),operation:crypto.randomUUID()};
  await savePrivateRecord('cloud/'+uid+'/outbox',[...rows.filter(r=>r.id!==value.id),next]);
});}
export async function flushWrites(client:SupabaseClient,uid:string){return withOutbox(uid,async()=>{
  const rows=await pendingWrites(uid);let saved=0;
  for(const row of [...rows]){
    if(row.conflict!==undefined)continue;
    const {data}=await client.auth.getSession();if(!data.session||data.session.user.id!==uid)break;
    const result=await cloudAPI<{ok:boolean;entry?:CloudEntry;conflict?:CloudEntry|null}>(client,{action:'save',...row},false,data.session.access_token);
    const index=rows.findIndex(r=>r.operation===row.operation);if(index<0)continue;
    if(result.ok){const revisions=await loadPrivateRecord<Record<string,number>>('cloud/'+uid+'/revisions')||{};if(result.entry)revisions[row.id]=result.entry.revision;await savePrivateRecord('cloud/'+uid+'/revisions',revisions);rows.splice(index,1);saved++;}
    else rows[index]={...row,conflict:result.conflict??null};
    await savePrivateRecord('cloud/'+uid+'/outbox',rows);
  }return saved;
});}
export async function uploadAudio(client:SupabaseClient,entryId:string,file:File,onProgress:(text:string)=>void){
  if(file.size<1||file.size>50*1024*1024)throw Error('Audio files must be between 1 byte and 50 MB.');
  const allowed:Record<string,string>={m4a:'audio/mp4',mp3:'audio/mpeg',wav:'audio/wav',webm:'audio/webm',aac:'audio/aac',flac:'audio/flac'};
  const mime=allowed[file.name.split('.').pop()?.toLowerCase()||''];if(!mime)throw Error('Choose m4a, mp3, wav, webm, aac or flac audio.');
  onProgress('Checking audio…');const bytes=await file.arrayBuffer();const sha256=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),x=>x.toString(16).padStart(2,'0')).join('');
  const start=await cloudAPI(client,{action:'upload_start',entry_id:entryId,filename:file.name.slice(0,240),mime,bytes:file.size,sha256});
  if(start.complete){onProgress('Audio already uploaded.');return;}
  onProgress('Uploading audio…');const result=await client.storage.from('slowclaw-audio').uploadToSignedUrl(start.media.object_path,start.upload.token,file,{contentType:mime});
  if(result.error)onProgress('Checking whether the previous upload completed…');
  onProgress('Verifying uploaded audio…');const done=await cloudAPI(client,{action:'upload_finish',id:start.media.id});
  onProgress('Audio uploaded and verified. Transcripts come from the app.');
}

export async function configuredCloud():Promise<CloudConfig>{
 const stored=await loadPrivateRecord<CloudConfig>('cloud/config');if(stored)return validateCloudConfig(stored);
 let value:Partial<CloudConfig>={};try{value=await (await fetch('/cloud-config.json',{cache:'no-store'})).json() as CloudConfig;}catch{}
 if(!value?.url)value=await (await fetch('https://slowclaw-cloud-config.zanynik.workers.dev/',{cache:'no-store'})).json() as CloudConfig;
 return validateCloudConfig(value as CloudConfig);
}
