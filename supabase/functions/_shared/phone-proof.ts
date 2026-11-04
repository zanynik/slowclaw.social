import {schnorr} from 'npm:@noble/curves@2.4.0/secp256k1.js';
import {Problem} from './http.ts';
const hex=(b:ArrayBuffer)=>Array.from(new Uint8Array(b),x=>x.toString(16).padStart(2,'0')).join('');
const hash=async(b:Uint8Array)=>hex(await crypto.subtle.digest('SHA-256',Uint8Array.from(b)));
const bytes=(s:string)=>Uint8Array.from(s.match(/../g)!,x=>parseInt(x,16));
export async function phoneProof(header:string|null,url:string,body:Uint8Array,now=Date.now()/1000){
 try{
  if(!header?.startsWith('Nostr ')||header.length>8000)throw Error();
  const e=JSON.parse(atob(header.slice(6)));
  if(e.kind!==27235||e.content!==''||!Number.isInteger(e.created_at)||Math.abs(e.created_at-now)>60||!/^[a-f0-9]{64}$/.test(e.pubkey)||!/^[a-f0-9]{64}$/.test(e.id)||!Array.isArray(e.tags)||!/^([a-f0-9]{128})$/.test(e.sig))throw Error();
  const tag=(n:string)=>{const t=e.tags.filter((t:unknown)=>Array.isArray(t)&&t[0]===n);if(t.length!==1||t[0].length!==2)throw Error();return t[0][1];};
  if(tag('u')!==url||tag('method')!=='POST'||tag('payload')!==await hash(body))throw Error();
  const id=await hash(new TextEncoder().encode(JSON.stringify([0,e.pubkey,e.created_at,e.kind,e.tags,e.content])));
  if(id!==e.id||!schnorr.verify(bytes(e.sig),bytes(id),bytes(e.pubkey)))throw Error();
  return {id,pubkey:e.pubkey as string,created_at:e.created_at as number};
 }catch{throw new Problem('PHONE_PROOF_INVALID',401);}
}
