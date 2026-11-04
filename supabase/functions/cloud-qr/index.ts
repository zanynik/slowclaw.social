import {admin,body,Problem,rpc,serve,string,user} from '../_shared/http.ts';
Deno.serve(req=>serve(req,async req=>{
 const input=await body(req,24000),action=string(input.action,16),id=string(input.id,64),db=admin();
 if(!/^[a-f0-9]{64}$/.test(id)||!['start','poll','complete','ack'].includes(action))throw new Problem('INVALID_QR_REQUEST');
 let secret='',payload='';
 if(action==='complete'){await user(req,db);payload=string(input.payload,20000);if(!/^[A-Za-z0-9+/=]+$/.test(payload))throw new Problem('INVALID_QR_REQUEST');}
 else {secret=string(input.secret,64);if(!/^[a-f0-9]{64}$/.test(secret))throw new Problem('INVALID_QR_REQUEST');}
 const ip=req.headers.get('x-forwarded-for')?.split(',')[0]?.trim()||'unknown';
 const address=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',new TextEncoder().encode(ip))),x=>x.toString(16).padStart(2,'0')).join('');
 return rpc(db,'cloud_qr',{p_action:action,p_id:id,p_secret:secret,p_payload:payload,p_address:address});
}));
