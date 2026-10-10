import { schnorr } from '@noble/curves/secp256k1.js';
export const origin = 'https://slowclaw-web.zanynik.chatgpt.site';
export const maxFile = 50 * 1024 * 1024 + 28;
export const hex = (b: Uint8Array) => Array.from(b,x=>x.toString(16).padStart(2,'0')).join('');
export const digest = async (b: string | Uint8Array) => hex(new Uint8Array(await crypto.subtle.digest('SHA-256', typeof b==='string'?new TextEncoder().encode(b):Uint8Array.from(b))));
export const random = () => hex(crypto.getRandomValues(new Uint8Array(32)));
export function fail(status: number, message: string): never { throw Object.assign(new Error(message),{status}); }
export function validID(s: string) { return /^[a-f0-9]{64}$/.test(s); }
export async function verifyPhone(header: string|null, url: string, method: string, body: Uint8Array, now = Date.now()/1000) {
 try {
  if(!header?.startsWith('Nostr ') || header.length>8000) throw Error();
  const e=JSON.parse(atob(header.slice(6)));
  if(e.kind!==27235 || e.content!=='' || !Number.isInteger(e.created_at) || Math.abs(e.created_at-now)>60 || !validID(e.pubkey) || !validID(e.id) || !Array.isArray(e.tags)) throw Error();
  const tag=(n:string)=>{const t=e.tags.filter((t:unknown)=>Array.isArray(t)&&t[0]===n);if(t.length!==1||t[0].length!==2)throw Error();return t[0][1];};
  if(tag('u')!==url || tag('method')!==method || tag('payload')!==await digest(body)) throw Error();
  const id=await digest(JSON.stringify([0,e.pubkey,e.created_at,e.kind,e.tags,e.content]));
  if(id!==e.id || !schnorr.verify(Uint8Array.from(e.sig.match(/../g), (s:string)=>parseInt(s,16)),Uint8Array.from(id.match(/../g)!,s=>parseInt(s,16)),Uint8Array.from(e.pubkey.match(/../g), (s:string)=>parseInt(s,16))))throw Error();
  return {id:e.id as string,pubkey:e.pubkey as string};
 }catch { return fail(401,'Phone authorization expired or is invalid. Try again.'); }
}
