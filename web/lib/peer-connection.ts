import {keyFrom,seal,unseal,toBase64,fromBase64} from './sealed';
import {PeerMailbox,PeerSession} from './peer-mailbox';
import {saveSession} from './local-store';
import {gatherCandidates} from './ice-gathering';
export class BrowserPeer {
 private pc:RTCPeerConnection|null=null;private dc:RTCDataChannel|null=null;private poll:ReturnType<typeof setInterval>|undefined;private incoming=Promise.resolve();private outgoing=Promise.resolve();private seq=0;private received=0;private pieces:string[]=[];private pendingID=0;private size=0;private config='';private generation=0;private approved=false;
 constructor(private mailbox:PeerMailbox,private changed:()=>void,private problem:(message:string)=>void){}
 get online(){return this.dc?.readyState==='open'&&this.approved;}
 async start(){this.close();const config:any=await (await fetch('/peer-config.json',{cache:'no-store'})).json();if(!config.signalingOrigin)throw Error('Configure the Cloudflare signaling Worker before pairing.');const endpoint=new URL(config.signalingOrigin);if(endpoint.protocol!=='https:'||!endpoint.hostname.endsWith('.workers.dev')||endpoint.port||endpoint.pathname!=='/'||endpoint.username||endpoint.password||endpoint.search||endpoint.hash)throw Error('Configure the Cloudflare signaling Worker before pairing.');this.config=endpoint.origin;
  const s=this.mailbox.session;if(s.token)await this.signal('/v1/rooms/'+s.id,'DELETE',s.token).catch(()=>{});const room=await this.signal('/v1/rooms','POST','',{id:s.id});s.token=room.token;s.pair=room.pair;await saveSession(s);
  // ICE credentials are obtained through an authenticated signaling request.
  const initial=await this.signal('/v1/rooms/'+s.id+'/answer','GET',s.token);
  const generation=this.generation;const pc=new RTCPeerConnection({iceServers:initial.iceServers||config.iceServers});this.pc=pc;this.seq=0;this.received=0;this.pieces=[];
  const dc=pc.createDataChannel('slowclaw-v1',{ordered:true});this.dc=dc;
  dc.onopen=()=>this.changed();dc.onclose=()=>this.changed();dc.onerror=()=>this.problem('Phone disconnected. Browser drafts are kept. Reconnect to sync.');
  dc.onmessage=e=>{this.incoming=this.incoming.then(()=>{if(this.generation!==generation)return;return this.receive(String(e.data));}).catch(()=>{if(this.generation!==generation)return;this.close();this.problem('Peer message was invalid. Drafts are kept. Scan a fresh code.');});};
  pc.onconnectionstatechange=()=>{this.changed();if(['failed','disconnected'].includes(pc.connectionState))this.problem('Phone offline. Drafts are saved in this browser; reconnect to sync.');};
  await pc.setLocalDescription(await pc.createOffer());await gatherCandidates(pc);if(this.pc!==pc)throw Error('Pairing ended.');
  const key=await keyFrom(s.key),sealed=toBase64(await seal(key,new TextEncoder().encode(JSON.stringify(pc.localDescription)),s.id+'/signal/offer'));
  await this.signal('/v1/rooms/'+s.id+'/offer','PUT',s.token,{sealed});
  let checking=false;this.poll=setInterval(()=>{if(checking)return;checking=true;void (async()=>{try{const answer=await this.signal('/v1/rooms/'+s.id+'/answer','GET',s.token);if(!answer.sealed)return;clearInterval(this.poll);const raw=await unseal(key,fromBase64(answer.sealed),s.id+'/signal/answer');const desc=JSON.parse(new TextDecoder().decode(raw));if(desc.type!=='answer'||typeof desc.sdp!=='string')throw Error();if(this.pc===pc)await pc.setRemoteDescription(desc);}catch(e){clearInterval(this.poll);this.problem((e as Error).message);}finally{checking=false;}})();},1200);
 }
 private async signal(path:string,method:string,token:string,body?:unknown){const r=await fetch(this.config+path,{method,cache:'no-store',headers:{...(token?{Authorization:'Bearer '+token}:{}),...(body?{'Content-Type':'application/json'}:{})},body:body?JSON.stringify(body):undefined});const value:any=await r.json();if(!r.ok)throw Error(value.error||'Pairing unavailable.');return value;}
 private async receive(raw:string){if(raw.length>18000)throw Error();const frame=JSON.parse(raw);if(!Number.isSafeInteger(frame.seq)||frame.seq!==this.received+1||!Number.isInteger(frame.part)||frame.part!==this.pieces.length||typeof frame.data!=='string'||frame.data.length>14000||typeof frame.last!=='boolean')throw Error();if(this.pendingID&&this.pendingID!==frame.seq)throw Error();this.pendingID=frame.seq;this.size+=frame.data.length;if(this.size>5000000)throw Error();this.pieces.push(frame.data);if(!frame.last)return;const encrypted=fromBase64(this.pieces.join(''));this.pieces=[];this.size=0;this.pendingID=0;this.received=frame.seq;
  const s=this.mailbox.session,key=await keyFrom(s.key),bytes=await unseal(key,encrypted,s.id+'/rpc/phone/'+frame.seq),request=JSON.parse(new TextDecoder().decode(bytes));let response:unknown;
  try{if(typeof request.path!=='string'||typeof request.method!=='string'||typeof request.authorization!=='string'||typeof request.body!=='string'||request.id!==frame.seq)throw Error('Invalid request.');const body=await this.mailbox.request(request.path,request.method,fromBase64(request.body),request.authorization);response={id:request.id,body:toBase64(body)};if(request.path==='/pair')this.approved=true;this.changed();if(request.path==='/pair')void this.signal('/v1/rooms/'+s.id,'DELETE',s.token).catch(()=>{});}catch(e){response={id:request.id,error:(e as Error).message};}
  await this.send(response);
 }
 private send(value:unknown){const task=this.outgoing.then(async()=>{const dc=this.dc;if(!dc||dc.readyState!=='open')throw Error('Phone offline.');const seq=++this.seq,s=this.mailbox.session,key=await keyFrom(s.key);const encoded=toBase64(await seal(key,new TextEncoder().encode(JSON.stringify(value)),s.id+'/rpc/browser/'+seq));let part=0;
   for(let offset=0;offset<encoded.length;offset+=14000){const deadline=Date.now()+30000;while(dc.bufferedAmount>512000){if(dc.readyState!=='open'||Date.now()>deadline)throw Error('Phone disconnected.');await new Promise(r=>setTimeout(r,20));}if(dc.readyState!=='open')throw Error('Phone disconnected.');dc.send(JSON.stringify({seq,part:part++,data:encoded.slice(offset,offset+14000),last:offset+14000>=encoded.length}));}
  });this.outgoing=task.catch(()=>{});return task;}
 close(){this.generation++;this.approved=false;clearInterval(this.poll);this.dc?.close();this.pc?.close();this.dc=null;this.pc=null;}
}
