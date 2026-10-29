import {admin,body,Problem,rpc,serve,string} from '../_shared/http.ts';
import {phoneProof} from '../_shared/phone-proof.ts';
// Login requires possession of the phone's Nostr secret, a fresh payload-bound proof,
// and a single-use database receipt. No email is sent and no secret key leaves the phone.
Deno.serve(req=>serve(req,async req=>{
 const input=await body(req.clone(),8000),nonce=string(input.nonce,64);
 if(!/^[a-f0-9]{64}$/.test(nonce))throw new Problem('INVALID_NONCE');
 const url=Deno.env.get('SUPABASE_URL')!+'/functions/v1/cloud-login';
 const proof=await phoneProof(req.headers.get('Authorization'),url,new Uint8Array(await req.arrayBuffer()));
 const db=admin();
 await rpc(db,'cloud_phone_claim',{p_proof:proof.id,p_pubkey:proof.pubkey,p_created:proof.created_at});
 const email=await rpc<string>(db,'cloud_phone_email',{p_pubkey:proof.pubkey});
 let uid=await rpc<string|null>(db,'cloud_phone_user',{p_pubkey:proof.pubkey});
 if(!uid){
  const created=await db.auth.admin.createUser({email,email_confirm:true,app_metadata:{slowclaw_pubkey:proof.pubkey}});
  uid=created.data.user?.id||await rpc<string|null>(db,'cloud_phone_user',{p_pubkey:proof.pubkey});
  if(!uid)throw new Problem('PHONE_ACCOUNT_UNAVAILABLE',503);
 }
 const owner=await db.auth.admin.getUserById(uid);
 if(owner.error||!owner.data.user?.email)throw new Problem('PHONE_ACCOUNT_UNAVAILABLE',503);
 const link=await db.auth.admin.generateLink({type:'magiclink',email:owner.data.user.email});
 if(link.error||!link.data.properties?.hashed_token||link.data.user.id!==uid)throw new Problem('PHONE_LOGIN_UNAVAILABLE',503);
 const auth=await admin().auth.verifyOtp({token_hash:link.data.properties.hashed_token,type:'email'});
 if(auth.error||!auth.data.session||auth.data.user?.id!==uid)throw new Problem('PHONE_LOGIN_UNAVAILABLE',503);
 const s=auth.data.session;
 return {nonce,access_token:s.access_token,refresh_token:s.refresh_token,expires_in:s.expires_in,user:{id:uid},expires_at:Date.now()/1000+120};
}));
