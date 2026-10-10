import {DurableObject} from 'cloudflare:workers';
type Env={PAIRING:DurableObjectNamespace<PairingRooms>;ALLOWED_ORIGINS:string;TURN_URL?:string;TURN_SECRET?:string};
type Room={browser:string;phone:string;expires:number;offer?:string;answer?:string;requests:number};
const valid=(s:string)=>/^[a-f0-9]{64}$/.test(s);
const hex=(b:ArrayBuffer)=>Array.from(new Uint8Array(b),x=>x.toString(16).padStart(2,'0')).join('');
const hash=async(s:string)=>hex(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(s)));
async function bounded(req:Request,limit:number){const reader=req.body?.getReader();if(!reader)return '';let size=0;const chunks:Uint8Array[]=[];for(;;){const {value,done}=await reader.read();if(done)break;size+=value.length;if(size>limit){await reader.cancel();throw Error('Too large.');}chunks.push(value);}const out=new Uint8Array(size);let offset=0;for(const chunk of chunks){out.set(chunk,offset);offset+=chunk.length;}return new TextDecoder().decode(out);}
const random=()=>hex(crypto.getRandomValues(new Uint8Array(32)).buffer);
export class PairingRooms extends DurableObject<Env>{
 // No D1/R2/KV and no storage.put: SDP ciphertext lives in RAM for five minutes.
 private rooms=new Map<string,Room>();private creates=new Map<string,{count:number;expires:number}>();
 async fetch(req:Request){
  const now=Date.now();for(const [id,r] of this.rooms)if(r.expires<=now)this.rooms.delete(id);for(const [ip,r] of this.creates)if(r.expires<=now)this.creates.delete(ip);
  const allowed=this.env.ALLOWED_ORIGINS.split(','),origin=req.headers.get('Origin');
  const headers={'Content-Type':'application/json','Cache-Control':'no-store','Referrer-Policy':'no-referrer',...(origin&&allowed.includes(origin)?{'Access-Control-Allow-Origin':origin,'Vary':'Origin'}:{})};
  const json=(v:unknown,status=200)=>new Response(JSON.stringify(v),{status,headers});
  if(origin&&!allowed.includes(origin))return json({error:'Origin not allowed.'},403);
  if(req.method==='OPTIONS')return new Response(null,{headers:{...headers,'Access-Control-Allow-Methods':'GET,POST,PUT,DELETE,OPTIONS','Access-Control-Allow-Headers':'Authorization,Content-Type','Access-Control-Max-Age':'600'}});
  const url=new URL(req.url),parts=url.pathname.split('/').filter(Boolean);
  if(parts[0]!=='v1'||parts[1]!=='rooms'||parts.length>4)return json({error:'Not found.'},404);
  if(req.method==='POST'&&parts.length===2){
   if(!origin||!allowed.includes(origin))return json({error:'Open SlowClaw Web.'},403);
   const ip=await hash(req.headers.get('CF-Connecting-IP')||'local');const rate=this.creates.get(ip)||{count:0,expires:now+60000};if(rate.count>=10||this.rooms.size>=500)return json({error:'Pairing busy. Retry shortly.'},429);rate.count++;this.creates.set(ip,rate);
   if(Number(req.headers.get('Content-Length')||0)>1024)return json({error:'Too large.'},413);
   let body:string;try{body=await bounded(req,1024);}catch{return json({error:'Too large.'},413);}
   let id:string;try{id=JSON.parse(body).id;}catch{return json({error:'Invalid pairing.'},400);}if(!valid(id)||this.rooms.has(id))return json({error:'Code is active. Wait five minutes or use a fresh workspace.'},409);
   const token=random(),pair=random();this.rooms.set(id,{browser:await hash(token),phone:await hash(pair),expires:now+300000,requests:0});setTimeout(()=>this.rooms.delete(id),300000);return json({id,token,pair,expires:Math.floor(now/1000)+300});
  }
  const [, ,id,action]=parts,room=this.rooms.get(id);if(!room)return json({error:'Code expired. Scan a fresh one.'},410);
  const token=req.headers.get('Authorization')?.replace(/^Bearer /,'')||'';if(!valid(token))return json({error:'Unauthorized.'},401);const fingerprint=await hash(token),browser=fingerprint===room.browser,phone=fingerprint===room.phone;if(!browser&&!phone)return json({error:'Unauthorized.'},401);
  if(++room.requests>500)return json({error:'Pairing request limit reached.'},429);
  if(req.method==='DELETE'&&!action&&browser){this.rooms.delete(id);return json({ended:true});}
  if(!['offer','answer'].includes(action))return json({error:'Not found.'},404);
  if(req.method==='GET'&&((action==='offer'&&phone)||(action==='answer'&&browser))){const sealed=room[action as 'offer'|'answer'];const iceServers:unknown[]=[{urls:['stun:stun.l.google.com:19302']}];
   if(this.env.TURN_URL&&this.env.TURN_SECRET){const username=String(Math.floor(now/1000)+600)+':'+id;const key=await crypto.subtle.importKey('raw',new TextEncoder().encode(this.env.TURN_SECRET),{name:'HMAC',hash:'SHA-1'},false,['sign']);const signature=new Uint8Array(await crypto.subtle.sign('HMAC',key,new TextEncoder().encode(username)));iceServers.push({urls:[this.env.TURN_URL],username,credential:btoa(String.fromCharCode(...signature))});}
   return json({sealed:sealed||null,iceServers});
  }
  if(req.method==='PUT'&&((action==='offer'&&browser)||(action==='answer'&&phone))){if(Number(req.headers.get('Content-Length')||0)>100000)return json({error:'Too large.'},413);let raw:string;try{raw=await bounded(req,100000);}catch{return json({error:'Too large.'},413);}let sealed:string;try{sealed=JSON.parse(raw).sealed;}catch{return json({error:'Invalid signaling.'},400);}if(typeof sealed!=='string'||sealed.length<40||sealed.length>90000||!/^[A-Za-z0-9+/=]+$/.test(sealed))return json({error:'Invalid signaling.'},400);const prior=room[action as 'offer'|'answer'];if(prior&&prior!==sealed)return json({error:'Code already used.'},409);room[action as 'offer'|'answer']=sealed;return json({received:true});}
  return json({error:'Action not allowed.'},403);
 }
}
export default {fetch(req:Request,env:Env){return env.PAIRING.getByName('pairing').fetch(req);}};
