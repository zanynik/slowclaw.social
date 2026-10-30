import type {SupabaseClient} from '@supabase/supabase-js';
import type {CloudConfig} from './cloud';
import {random} from './protocol';
import {keyFrom,fromBase64,unseal} from './sealed';
export type CloudQR={id:string;key:string;secret:string;expires:number;code:string};
export async function qrRequest(c:CloudConfig,input:Record<string,unknown>){
 const r=await fetch(c.url+'/functions/v1/cloud-qr',{method:'POST',headers:{apikey:c.publishableKey,'Content-Type':'application/json'},body:JSON.stringify(input)});
 const v=await r.json() as {error?:string;expires?:number;payload?:string};if(!r.ok||v.error)throw Error('Cloud sign-in could not finish. Show a new code and try again.');return v;
}
export async function startCloudQR(c:CloudConfig):Promise<CloudQR>{const id=random(),key=random(),secret=random(),r=await qrRequest(c,{action:'start',id,secret}),expires=r.expires;
 if(typeof expires!=='number'||!Number.isFinite(expires)||expires<Date.now()/1000||expires>Date.now()/1000+125)throw Error('Invalid sign-in expiry.');
 return {id,key,secret,expires,code:JSON.stringify({type:'slowclaw-cloud',id,key,expires})};
}
export async function pollCloudQR(c:CloudConfig,q:CloudQR,client:SupabaseClient,active:()=>boolean){
 const r=await qrRequest(c,{action:'poll',id:q.id,secret:q.secret});if(!r.payload||!active())return false;
 const v=JSON.parse(new TextDecoder().decode(await unseal(await keyFrom(q.key),fromBase64(r.payload),'cloud-qr/'+q.id)));
 if(v.nonce!==q.id||v.expires_at<Date.now()/1000||q.expires<Date.now()/1000||typeof v.access_token!=='string'||typeof v.refresh_token!=='string')throw Error('Sign-in code expired. Show a new code.');
 if(!active())return false;const result=await client.auth.setSession({access_token:v.access_token,refresh_token:v.refresh_token});if(result.error)throw result.error;
 await qrRequest(c,{action:'ack',id:q.id,secret:q.secret}).catch(()=>{});return true;
}
