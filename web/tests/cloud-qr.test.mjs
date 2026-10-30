import {createRequire} from 'node:module';
import {mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
const require=createRequire(import.meta.url),wr=createRequire(require.resolve('wrangler/package.json')),{build}=wr('esbuild');
const dir=mkdtempSync(join(tmpdir(),'slowclaw-qr-'));
try{
 await build({entryPoints:['lib/cloud-qr.ts','lib/sealed.ts'],outdir:dir,format:'esm',platform:'node',bundle:true});
 const {startCloudQR,pollCloudQR}=await import(pathToFileURL(join(dir,'cloud-qr.js')));
 const {keyFrom,seal,toBase64}=await import(pathToFileURL(join(dir,'sealed.js')));
 const config={url:'https://project.supabase.co',publishableKey:'sb_publishable_test'};
 let payload=null,acks=0,sessions=0;const session={nonce:'',expires_at:Date.now()/1000+120,access_token:'slowclaw_test_access',refresh_token:'slowclaw_test_refresh'};
 globalThis.fetch=async(_url,options)=>{const v=JSON.parse(options.body);if(v.action==='start')return Response.json({expires:Date.now()/1000+120});if(v.action==='ack'){acks++;return Response.json({ok:true});}return Response.json({payload});};
 const qr=await startCloudQR(config);assert.ok(!qr.code.includes(qr.secret));assert.notEqual(qr.key,qr.secret);session.nonce=qr.id;
 const client={auth:{setSession:async v=>{sessions++;assert.equal(v.access_token,session.access_token);return {error:null};}}};
 assert.equal(await pollCloudQR(config,qr,client,()=>true),false);
 payload=toBase64(await seal(await keyFrom(qr.key),new TextEncoder().encode(JSON.stringify(session)),'cloud-qr/'+qr.id));
 assert.equal(await pollCloudQR(config,qr,client,()=>false),false);assert.equal(sessions,0);
 assert.equal(await pollCloudQR(config,qr,client,()=>true),true);assert.equal(sessions,1);assert.equal(acks,1);
 await assert.rejects(()=>pollCloudQR(config,{...qr,id:'0'.repeat(64)},client,()=>true));
 await assert.rejects(()=>pollCloudQR(config,{...qr,expires:0},client,()=>true));assert.equal(sessions,1);
 console.log('PASS: cloud QR uses separate poll capability, authenticated encryption, expiry and cancellation');
}finally{rmSync(dir,{recursive:true,force:true});}
