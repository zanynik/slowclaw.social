import { env } from 'cloudflare:workers';
import { digest, random, validID, verifyPhone, fail, origin, maxFile } from './protocol';
type Session={id:string;browser_hash:string;pair_hash:string;pubkey:string|null;created:number;expires:number;closed:number;revision:string|null;updated:number|null};
const db=()=>{if(!env.DB)fail(503,'Session storage is unavailable.');return env.DB!;};
const bucket=()=>{if(!env.BUCKET)fail(503,'Transfer storage is unavailable.');return env.BUCKET!;};
const now=()=>Math.floor(Date.now()/1000);
const json=(value:unknown,status=200)=>Response.json(value,{status,headers:{'Cache-Control':'no-store','Referrer-Policy':'no-referrer'}});
async function remove(id:string){
 await db().prepare('UPDATE sessions SET closed=1 WHERE id=?').bind(id).run();
 let cursor:string|undefined;
 do {const page=await bucket().list({prefix:id+'/',cursor,limit:100});if(page.objects.length)await bucket().delete(page.objects.map(o=>o.key));cursor=page.truncated?page.cursor:undefined;}while(cursor);
 await db().batch([db().prepare('DELETE FROM journal_edits WHERE session=?').bind(id),db().prepare('DELETE FROM transfers WHERE session=?').bind(id),db().prepare('DELETE FROM proofs WHERE session=?').bind(id),db().prepare('DELETE FROM sessions WHERE id=?').bind(id)]);
}
async function cleanup(){
 const expired=await db().prepare('SELECT id FROM sessions WHERE expires<=? OR closed=1 LIMIT 5').bind(now()).all<{id:string}>();
 for(const s of expired.results)await remove(s.id);
}
async function body(req:Request,limit:number){
 const reader=req.body?.getReader();if(!reader)return new Uint8Array();
 const chunks:Uint8Array[]=[];let n=0;
 for(;;){const {value,done}=await reader.read();if(done)break;n+=value.length;if(n>limit){await reader.cancel();fail(413,'This request is too large.');}chunks.push(value);}
 const out=new Uint8Array(n);let offset=0;for(const c of chunks){out.set(c,offset);offset+=c.length;}return out;
}
function parse(bytes:Uint8Array):any{try{return JSON.parse(new TextDecoder().decode(bytes));}catch{fail(400,'Invalid request.');}}
async function session(id:string){if(!validID(id))fail(404,'Session not found.');const s=await db().prepare('SELECT id,browser_hash,pair_hash,pubkey,created,expires,closed,updated,substr(snapshot,1,16) AS revision FROM sessions WHERE id=?').bind(id).first<Session>();if(!s||s.closed||s.expires<=now())fail(410,'Session ended. Scan a new code to reconnect.');return s;}
async function browser(req:Request,s:Session){
 // Browser capabilities are session-scoped, random and never placed in URLs.
 if(req.headers.get('Origin') && req.headers.get('Origin')!==new URL(req.url).origin)fail(403,'Use the paired browser.');
 const token=req.headers.get('Authorization')?.replace(/^Bearer /,'')||'';
 if(!validID(token)||await digest(token)!==s.browser_hash)fail(401,'Scan a new code to reconnect.');
}
async function phone(req:Request,s:Session,bytes:Uint8Array,pair=false){
 const url=origin+new URL(req.url).pathname+new URL(req.url).search;
 const proof=await verifyPhone(req.headers.get('Authorization'),url,req.method,bytes);
 if(!pair&&proof.pubkey!==s.pubkey)fail(403,'This phone is not paired.');
 let inserted;
 try {inserted=await db().prepare('INSERT INTO proofs(id,session) SELECT ?,? WHERE EXISTS(SELECT 1 FROM sessions WHERE id=? AND closed=0 AND expires>?)').bind(proof.id,s.id,s.id,now()).run();}catch{fail(409,'Request already used. Retry with a new authorization.');}
 if(!inserted.meta.changes)fail(410,'Session ended during authorization.');
 return proof.pubkey;
}
export async function handle(req:Request,parts:string[]){
 try {
  await cleanup();
  if(parts.length===0&&req.method==='POST'){
   if(req.headers.get('Origin')!==new URL(req.url).origin)fail(403,'Open SlowClaw Web to start a session.');
   // Bound anonymous abandoned sessions. No IP, identity or browser fingerprint is stored.
   const count=await db().prepare('SELECT COUNT(*) AS n FROM sessions WHERE pubkey IS NULL').first<{n:number}>();
   if((count?.n||0)>=500)fail(429,'Pairing is busy. Please retry in a few minutes.');
   const id=random(),token=random(),pair=random(),created=now();
   await db().prepare('INSERT INTO sessions(id,browser_hash,pair_hash,created,expires) VALUES(?,?,?,?,?)').bind(id,await digest(token),await digest(pair),created,created+300).run();
   return json({id,token,pair,expires:created+300});
  }
  const [id,action,transferID]=parts;const s=await session(id);
  if(action==='pair'&&req.method==='POST'){
   const bytes=await body(req,4096),data=parse(bytes);const pubkey=await phone(req,s,bytes,true);
   if(s.pubkey||typeof data.pair!=='string'||await digest(data.pair)!==s.pair_hash)fail(409,'Code was used or is invalid. Scan a new code.');
   const updated=await db().prepare('UPDATE sessions SET pubkey=?,pair_hash=?,expires=? WHERE id=? AND pubkey IS NULL AND closed=0 AND expires>?').bind(pubkey,'',now()+86400,id,now()).run();
   if(!updated.meta.changes)fail(409,'Code already used.');return json({expires:now()+86400});
  }
  const isPhone=req.headers.get('Authorization')?.startsWith('Nostr ');
  const bytes=isPhone?await body(req,4*1024*1024):new Uint8Array();
  if(isPhone)await phone(req,s,bytes);else await browser(req,s);
  if(req.method==='DELETE'&&!action){await remove(id);return json({ended:true});}
  if(!action&&req.method==='GET'){
   const rows=await db().prepare('SELECT id,meta,bytes,status,created FROM transfers WHERE session=? ORDER BY created').bind(id).all();
   let snapshot:string|undefined;
   if(!isPhone&&s.revision&&new URL(req.url).searchParams.get('after')!==s.revision){
    const stored=await db().prepare('SELECT snapshot FROM sessions WHERE id=? AND closed=0 AND expires>?').bind(id,now()).first<{snapshot:string}>();
    snapshot=stored?.snapshot;
   }
   const edits=await db().prepare('SELECT id,sealed,status,result FROM journal_edits WHERE session=? ORDER BY created,rowid').bind(id).all();
   return json({edits:edits.results,paired:!!s.pubkey,pubkey:s.pubkey,expires:s.expires,updated:s.updated,revision:s.revision,transfers:rows.results,snapshot});
  }
  if(!s.pubkey)fail(409,'Approve this session on your phone first.');
  if(action==='note'&&!transferID&&req.method==='POST'&&!isPhone){
   const data=parse(await body(req,1500000));
   if(!validID(data.id)||typeof data.sealed!=='string'||data.sealed.length<40||data.sealed.length>1400000)fail(400,'Invalid journal operation.');
   await db().prepare(`INSERT INTO journal_edits(id,session,sealed,created) SELECT ?,?,?,? WHERE EXISTS(SELECT 1 FROM sessions WHERE id=? AND closed=0 AND expires>?) AND (SELECT COUNT(*) FROM journal_edits WHERE session=?)<500 AND (SELECT COALESCE(SUM(length(sealed)+COALESCE(length(result),0)),0) FROM journal_edits WHERE session=?)+?<=12000000 ON CONFLICT(id) DO NOTHING`).bind(data.id,id,data.sealed,now(),id,now(),id,id,data.sealed.length).run();
   const row=await db().prepare('SELECT session,sealed FROM journal_edits WHERE id=?').bind(data.id).first<{session:string;sealed:string}>();
   if(!row)fail(409,'Journal queue is full. Wait for your phone to sync.');
   if(row.session!==id||row.sealed!==data.sealed)fail(409,'Journal operation identity conflict.');
   return json({queued:true});
  }
  if(action==='note'&&validID(transferID||'')){
   const row=await db().prepare('SELECT status FROM journal_edits WHERE id=? AND session=?').bind(transferID,id).first<{status:string}>();
   if(!row)fail(404,'Journal operation not found.');
   if(req.method==='POST'&&isPhone){
    const data=parse(bytes);
    if(!['saved','conflict','loaded','rejected'].includes(data.status)||typeof data.result!=='string'||data.result.length>1400000)fail(400,'Invalid journal receipt.');
    await db().prepare("UPDATE journal_edits SET status=?,result=?,sealed='' WHERE id=? AND session=? AND status='queued'").bind(data.status,data.result,transferID,id).run();return json({received:true});
   }
   if(req.method==='DELETE'&&!isPhone){
    await db().prepare("DELETE FROM journal_edits WHERE id=? AND session=? AND status!='queued'").bind(transferID,id).run();return json({removed:true});
   }
  }
  if(action==='snapshot'&&req.method==='PUT'&&isPhone){
   const data=parse(bytes);if(typeof data.sealed!=='string'||data.sealed.length>1700000)fail(413,'Recent data is too large.');
   await db().prepare('UPDATE sessions SET snapshot=?,updated=? WHERE id=? AND closed=0').bind(data.sealed,now(),id).run();return json({saved:true});
  }
  if(action==='upload'&&req.method==='POST'&&!isPhone){
   const data=parse(await body(req,10000));
   if(!validID(data.id)||typeof data.meta!=='string'||data.meta.length>8000||!Number.isInteger(data.bytes)||data.bytes<29||data.bytes>maxFile)fail(400,'Upload must be a journal or audio file up to 50 MB.');
   await db().prepare(`INSERT INTO transfers(id,session,meta,bytes,status,created) SELECT ?,?,?,?,'pending',? WHERE EXISTS(SELECT 1 FROM sessions WHERE id=? AND closed=0 AND expires>?) AND (SELECT COALESCE(SUM(bytes),0) FROM transfers WHERE session=? AND status!='saved')+?<=262144000 AND (SELECT COUNT(*) FROM transfers WHERE session=?)<500 ON CONFLICT(id) DO NOTHING`).bind(data.id,id,data.meta,data.bytes,now(),id,now(),id,data.bytes,id).run();
   const row=await db().prepare('SELECT session,meta,bytes FROM transfers WHERE id=?').bind(data.id).first<{session:string;meta:string;bytes:number}>();
   if(!row)fail(409,'The transfer queue is full. Keep your phone open to receive files, then retry.');
   if(row.session!==id||row.meta!==data.meta||row.bytes!==data.bytes)fail(409,'Upload identity conflict.');
   return json({id:data.id});
  }
  if(action==='file'&&validID(transferID||'')){
   const row=await db().prepare('SELECT * FROM transfers WHERE id=? AND session=?').bind(transferID,id).first<{bytes:number;status:string}>();
   if(!row)fail(404,'Transfer not found.');const key=id+'/'+transferID;
   if(req.method==='DELETE'&&!isPhone){
    const deleted=await db().prepare("DELETE FROM transfers WHERE id=? AND session=? AND status='pending'").bind(transferID,id).run();
    if(!deleted.meta.changes)fail(409,'This file has already been sent. Wait for your phone to receive it.');
    await bucket().delete(key);return json({removed:true});
   }
   if(req.method==='PUT'&&!isPhone){
    if(row.status==='saved')return json({saved:true});
    if(Number(req.headers.get('Content-Length'))!==row.bytes)fail(400,'Upload size changed. Retry the file.');
    // Stream ciphertext; Workers never buffer an entire audio file.
    const stored=await bucket().put(key,req.body,{httpMetadata:{contentType:'application/octet-stream'}});
    if(!stored||stored.size!==row.bytes){await bucket().delete(key);fail(400,'Incomplete upload. Retry the file.');}
    const live=await db().prepare('SELECT id FROM sessions WHERE id=? AND closed=0 AND expires>?').bind(id,now()).first();
    if(!live){await bucket().delete(key);fail(410,'Session ended during upload.');}
    await db().prepare("UPDATE transfers SET status='ready' WHERE id=? AND session=? AND status!='saved'").bind(transferID,id).run();
    const current=await db().prepare('SELECT status FROM transfers WHERE id=?').bind(transferID).first<{status:string}>();
    if(!current||current.status==='saved')await bucket().delete(key);
    return json({waitingForPhone:true});
   }
   if(req.method==='GET'&&isPhone&&row.status==='ready'){
    const blob=await bucket().get(key);if(!blob)fail(503,'File is not ready. Retry shortly.');
    return new Response(blob.body,{headers:{'Content-Type':'application/octet-stream','Cache-Control':'no-store','Content-Length':String(blob.size)}});
   }
   if(req.method==='POST'&&isPhone){
    if(row.status!=='ready'&&row.status!=='saved')fail(409,'File has not finished uploading.');
    await db().prepare("UPDATE transfers SET status='saved' WHERE id=? AND session=?").bind(transferID,id).run();await bucket().delete(key);return json({saved:true});
   }
  }
  fail(404,'Action not found.');
 }catch(e){const error=e as Error&{status?:number};if(!error.status)console.error('Session storage operation failed');return json({error:error.status?error.message:'Sync is unavailable. Your original files are unchanged. Please retry.'},error.status||503);}
}
