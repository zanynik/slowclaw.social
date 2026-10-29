// Browser profile is the security boundary. Only encrypted content is persisted;
// the non-extractable wrapping key is local and never uploaded.
let opening:Promise<IDBDatabase>|undefined;
function database(){return opening??=new Promise<IDBDatabase>((resolve,reject)=>{const r=indexedDB.open('slowclaw-local',1);r.onupgradeneeded=()=>r.result.createObjectStore('records');r.onsuccess=()=>resolve(r.result);r.onerror=()=>{opening=undefined;reject(Error('Browser storage is unavailable. Export unsynced text before closing.'));};});}
async function run<T>(mode:IDBTransactionMode,action:(s:IDBObjectStore)=>IDBRequest<T>):Promise<T>{const db=await database();return new Promise((resolve,reject)=>{const tx=db.transaction('records',mode),r=action(tx.objectStore('records'));let value:T;r.onsuccess=()=>value=r.result;tx.oncomplete=()=>resolve(value);tx.onabort=tx.onerror=()=>reject(Error('Browser storage could not save your draft. Export it before closing.'));});}
export const localStore={get:(key:string)=>run<any>('readonly',s=>s.get(key)),set:(key:string,value:unknown)=>run('readwrite',s=>endedKey(key)?s.get(key):s.put(value,key)),remove:(key:string)=>run('readwrite',s=>s.delete(key))};
let wrapping:Promise<CryptoKey>|undefined;
function wrapKey(){return wrapping??=(async()=>{const stored=await localStore.get('wrapping-key');if(stored)return stored as CryptoKey;const key=await crypto.subtle.generateKey({name:'AES-GCM',length:256},false,['encrypt','decrypt']);await localStore.set('wrapping-key',key);return key;})();}
export async function saveSession(value:unknown){const id=(value as {id?:string})?.id;if(id&&endedWorkspaces.has(id))return;const key=await wrapKey(),iv=crypto.getRandomValues(new Uint8Array(12));const bytes=new TextEncoder().encode(JSON.stringify(value));const sealed=await crypto.subtle.encrypt({name:'AES-GCM',iv,additionalData:new TextEncoder().encode('slowclaw/local-session/v1')},key,bytes);if(!id||!endedWorkspaces.has(id))await localStore.set('session',{iv,sealed});}
export async function restoreSession(){const value=await localStore.get('session');if(!value)return null;const key=await wrapKey();return JSON.parse(new TextDecoder().decode(await crypto.subtle.decrypt({name:'AES-GCM',iv:value.iv,additionalData:new TextEncoder().encode('slowclaw/local-session/v1')},key,value.sealed)));}
// Cloud auth and drafts have separate authenticated contexts from phone pairing.
export async function savePrivateRecord(name:string,value:unknown){const key=await wrapKey(),iv=crypto.getRandomValues(new Uint8Array(12));const sealed=await crypto.subtle.encrypt({name:'AES-GCM',iv,additionalData:new TextEncoder().encode(name)},key,new TextEncoder().encode(JSON.stringify(value)));await localStore.set(name,{iv,sealed});}
export async function loadPrivateRecord<T>(name:string):Promise<T|null>{const value=await localStore.get(name);if(!value)return null;return JSON.parse(new TextDecoder().decode(await crypto.subtle.decrypt({name:'AES-GCM',iv:value.iv,additionalData:new TextEncoder().encode(name)},await wrapKey(),value.sealed)));}
// Block late asynchronous autosaves before deleting a workspace atomically.
const endedWorkspaces=new Set<string>();
function endedKey(key:string){return [...endedWorkspaces].some(id=>key.startsWith(id+'/')||key==='slowclaw.web.drafts.'+id||key==='slowclaw.web.units.'+id);}
export async function clearWorkspace(id:string){
 endedWorkspaces.add(id);
 const db=await database();
 await new Promise<void>((resolve,reject)=>{
  const tx=db.transaction('records','readwrite'),s=tx.objectStore('records'),cursor=s.openCursor();
  cursor.onsuccess=()=>{const row=cursor.result;if(!row)return;const key=String(row.key);if(key==='session'||key.startsWith(id+'/')||key==='slowclaw.web.drafts.'+id||key==='slowclaw.web.units.'+id)row.delete();row.continue();};
  tx.oncomplete=()=>resolve();tx.onabort=tx.onerror=()=>reject(Error('Browser workspace could not be cleared. Retry logout.'));
 });
}
