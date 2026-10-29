import {PeerMailbox,PeerSession} from './peer-mailbox';
import {configuredCloud,cloudClient} from './cloud';
import {savePrivateRecord} from './local-store';
import {random} from './protocol';
import {keyFrom,seal,unseal,toBase64,fromBase64} from './sealed';
export async function signInThroughPhone(box:PeerMailbox,s:PeerSession,stillPaired:()=>boolean){
 const config=await configuredCloud(),id=random(),key=await keyFrom(s.key),context=s.id+'/note/'+id,expires=Math.floor(Date.now()/1000)+120;
 const payload={kind:'cloud_login',nonce:id,config,expires};
 await box.request('/note','POST',new TextEncoder().encode(JSON.stringify({id,sealed:toBase64(await seal(key,new TextEncoder().encode(JSON.stringify(payload)),context))})));
 for(let i=0;i<60;i++){
  if(!stillPaired())throw Error('Phone connection ended. Your cloud account was not changed.');
  const row=box.edits.find(x=>x.id===id);
  if(row?.result){
   const value=JSON.parse(new TextDecoder().decode(await unseal(key,fromBase64(row.result),context+'/result')));
   if(value.error)throw Error(value.error);
   if(row.status!=='saved'||value.nonce!==id||Date.now()/1000>expires||value.expires_at<Date.now()/1000||typeof value.access_token!=='string'||typeof value.refresh_token!=='string')throw Error('Cloud login expired. Try again with your phone connected.');
   const client=cloudClient(config),result=await client.auth.setSession({access_token:value.access_token,refresh_token:value.refresh_token});
   if(result.error)throw result.error;
   await savePrivateRecord('cloud/config',config);
   await box.request('/note/'+id,'DELETE',new Uint8Array());
   return;
  }
  await new Promise(resolve=>setTimeout(resolve,2000));
 }
 throw Error('Keep the updated SlowClaw app open, then retry cloud sign-in.');
}
