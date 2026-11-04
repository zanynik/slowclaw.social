import {admin,body,Problem,rpc,serve,string} from '../_shared/http.ts';
import {phoneProof} from '../_shared/phone-proof.ts';

// Every call carries a fresh NIP-98 proof from the phone's Nostr key (bound to this URL
// and the exact request body) and is recorded once, so a proof cannot be replayed.
//
//   {action:"link", access_token}  ties the key to the account that access_token belongs to.
//   {action:"login", nonce}        returns a new session for the key's account (creating a
//                                  key-only account the first time). The phone uses this to
//                                  sign in without a password and to hand a browser its own
//                                  session through the cloud-qr relay. No secret leaves the phone.
Deno.serve(req=>serve(req,async req=>{
 const raw=new Uint8Array(await req.clone().arrayBuffer());
 const input=await body(req,8000);
 const action=input.action===undefined?'login':string(input.action,8);
 const url=Deno.env.get('SUPABASE_URL')!+'/functions/v1/cloud-login';
 const proof=await phoneProof(req.headers.get('Authorization'),url,raw);
 const db=admin();
 await rpc(db,'cloud_phone_claim',{p_proof:proof.id,p_pubkey:proof.pubkey,p_created:proof.created_at});

 if(action==='link'){
  const token=string(input.access_token,8000);
  const {data,error}=await db.auth.getUser(token);
  if(error||!data.user)throw new Problem('SIGN_IN_REQUIRED',401);
  await rpc(db,'cloud_nostr_link',{p_pubkey:proof.pubkey,p_user:data.user.id});
  return {linked:true,user:{id:data.user.id}};
 }
 if(action!=='login')throw new Problem('INVALID_INPUT');

 const nonce=string(input.nonce,64);
 if(!/^[a-f0-9]{64}$/.test(nonce))throw new Problem('INVALID_NONCE');
 let uid=await rpc<string|null>(db,'cloud_nostr_user',{p_pubkey:proof.pubkey});
 if(!uid){
  const email=await rpc<string>(db,'cloud_phone_email',{p_pubkey:proof.pubkey});
  const created=await db.auth.admin.createUser({email,email_confirm:true,app_metadata:{slowclaw_pubkey:proof.pubkey}});
  uid=created.data.user?.id||await rpc<string|null>(db,'cloud_nostr_user',{p_pubkey:proof.pubkey});
  if(!uid)throw new Problem('PHONE_ACCOUNT_UNAVAILABLE',503);
  await rpc(db,'cloud_nostr_link',{p_pubkey:proof.pubkey,p_user:uid});
 }
 const owner=await db.auth.admin.getUserById(uid);
 if(owner.error||!owner.data.user?.email)throw new Problem('PHONE_ACCOUNT_UNAVAILABLE',503);
 const link=await db.auth.admin.generateLink({type:'magiclink',email:owner.data.user.email});
 if(link.error||!link.data.properties?.hashed_token||link.data.user.id!==uid)throw new Problem('PHONE_LOGIN_UNAVAILABLE',503);
 const auth=await admin().auth.verifyOtp({token_hash:link.data.properties.hashed_token,type:'email'});
 if(auth.error||!auth.data.session||auth.data.user?.id!==uid)throw new Problem('PHONE_LOGIN_UNAVAILABLE',503);
 const s=auth.data.session;
 return {nonce,access_token:s.access_token,refresh_token:s.refresh_token,expires_in:s.expires_in,
  user:{id:uid,email:owner.data.user.email},expires_at:Date.now()/1000+120};
}));
