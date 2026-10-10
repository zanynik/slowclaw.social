import {localStore,saveSession} from './local-store';
import {validID,verifyPhone,maxFile} from './protocol';
export type PeerSession={id:string;token:string;pair:string;key:string;expires:number;pubkey?:string};
type Edit={id:string;sealed:string;status:string;result?:string};
type Transfer={id:string;meta:string;bytes:number;status:string};
export class PeerMailbox {
 edits:Edit[]=[];transfers:Transfer[]=[];snapshot='';updated=0;private proofs=new Map<string,number>();private serial=Promise.resolve();
 constructor(public session:PeerSession,private origin:string){}
 async restore(){const stored=await localStore.get(this.session.id+'/mailbox');if(stored){this.edits=stored.edits;this.transfers=stored.transfers;this.snapshot=stored.snapshot;this.updated=stored.updated;}}
 private persist(){return localStore.set(this.session.id+'/mailbox',{edits:this.edits,transfers:this.transfers,snapshot:this.snapshot,updated:this.updated});}
 async clear(){await Promise.all(this.transfers.map(t=>localStore.remove(this.session.id+'/file/'+t.id)));await localStore.remove(this.session.id+'/mailbox');}
 request(path:string,method:string,bytes:Uint8Array,authorization?:string):Promise<Uint8Array>{const call=this.serial.then(()=>this.handle(path,method,bytes,authorization));this.serial=call.then(()=>{},()=>{});return call;}
 private async handle(path:string,method:string,bytes:Uint8Array,authorization?:string){
  const phone=authorization!==undefined;
  const json=(v:unknown)=>new TextEncoder().encode(JSON.stringify(v));
  const error=(message:string):never=>{throw Error(message);};
  const data=()=>JSON.parse(new TextDecoder().decode(bytes));
  if(bytes.length>(phone?2000000:maxFile))error('Request too large.');
  if(!/^\/(?:pair|snapshot|note(?:\/[a-f0-9]{64})?|upload|file\/[a-f0-9]{64}(?:\?offset=\d+&length=\d+)?)?$/.test(path)&&path!==''&& !/^\?after=/.test(path))error('Unknown peer route.');
  if(phone){const proof=await verifyPhone(authorization!,this.origin+'/api/session/'+this.session.id+path,method,bytes);if(this.proofs.has(proof.id))error('Request already used.');for(const [id,time] of this.proofs)if(time<Date.now()-120000)this.proofs.delete(id);if(this.proofs.size>=2000)error('Too many phone requests. Retry shortly.');this.proofs.set(proof.id,Date.now());
   if(path==='/pair'&&method==='POST'){if(data().pair!==this.session.pair)error('Scan a fresh pairing code.');if(this.session.pubkey&&this.session.pubkey!==proof.pubkey)error('Use the same phone identity, or clear this browser workspace first.');this.session.pubkey=proof.pubkey;this.session.expires=Math.floor(Date.now()/1000)+86400;await saveSession(this.session);return json({expires:this.session.expires});}
   if(proof.pubkey!==this.session.pubkey)error('Phone is not paired.');
   if(this.session.expires<=Date.now()/1000)error('Session expired. Reconnect by scanning a new code.');
  }
  if(!path||path.startsWith('?')){if(method==='DELETE'){// Peer disconnect does not erase browser drafts.
    return json({ended:true});
   }if(method==='GET')return json({paired:!!this.session.pubkey,expires:this.session.expires,updated:this.updated,revision:this.snapshot.slice(0,16),snapshot:phone?undefined:this.snapshot,edits:phone?this.edits.filter(e=>e.status==='queued').slice(0,1):this.edits,transfers:phone?this.transfers.filter(t=>t.status==='ready').slice(0,100):this.transfers});}
  if(!this.session.pubkey)error('Approve this browser on your phone first.');
  if(path==='/snapshot'&&method==='PUT'&&phone){const d=data();if(typeof d.sealed!=='string'||d.sealed.length>1700000)error('Snapshot too large.');this.snapshot=d.sealed;this.updated=Math.floor(Date.now()/1000);await this.persist();return json({saved:true});}
  if(path==='/note'&&method==='POST'&&!phone){const d=data();if(!validID(d.id)||typeof d.sealed!=='string'||d.sealed.length<40||d.sealed.length>1400000)error('Invalid journal operation.');const prior=this.edits.find(e=>e.id===d.id);if(prior){if(prior.status==='queued'&&prior.sealed!==d.sealed)error('Operation identity conflict.');}else{if(this.edits.length>=500||this.edits.reduce((n,e)=>n+e.sealed.length+(e.result?.length||0),0)+d.sealed.length>12000000)error('Local queue full. Connect your phone.');this.edits.push({id:d.id,sealed:d.sealed,status:'queued'});}await this.persist();return json({queued:true});}
  if(path.startsWith('/note/')){const row=this.edits.find(e=>e.id===path.slice(6));if(!row)error('Journal operation not found.');if(method==='POST'&&phone){const d=data();if(!['saved','loaded','conflict','rejected'].includes(d.status)||typeof d.result!=='string'||d.result.length>1400000)error('Invalid phone receipt.');if(row!.status==='queued'){row!.status=d.status;row!.result=d.result;row!.sealed='';}await this.persist();return json({received:true});}if(method==='DELETE'&&!phone){if(row!.status==='queued')error('Phone has not saved this operation.');this.edits=this.edits.filter(e=>e!==row);await this.persist();return json({removed:true});}}
  if(path==='/upload'&&method==='POST'&&!phone){const d=data();if(!validID(d.id)||typeof d.meta!=='string'||d.meta.length>8000||!Number.isInteger(d.bytes)||d.bytes<29||d.bytes>maxFile)error('Invalid file.');const prior=this.transfers.find(t=>t.id===d.id);if(prior){if(prior.meta!==d.meta||prior.bytes!==d.bytes)error('Transfer identity conflict.');}else{if(this.transfers.length>=500||this.transfers.reduce((n,t)=>n+(t.status==='saved'?0:t.bytes),0)+d.bytes>262144000)error('Local file queue full.');this.transfers.push({...d,status:'pending'});}await this.persist();return json({id:d.id});}
  if(path.startsWith('/file/')){const url=new URL(path,'https://example.com'),id=url.pathname.slice(6),row=this.transfers.find(t=>t.id===id);if(!row)error('File not found.');const key=this.session.id+'/file/'+id;
   if(method==='PUT'&&!phone){if(bytes.length!==row!.bytes)error('Incomplete file.');await localStore.set(key,bytes);row!.status='ready';await this.persist();return json({waitingForPhone:true});}
   if(method==='GET'&&phone&&row!.status==='ready'){const offset=Number(url.searchParams.get('offset')),length=Number(url.searchParams.get('length'));if(!Number.isInteger(offset)||!Number.isInteger(length)||offset<0||length<1||length>32768)error('Invalid file range.');const file=await localStore.get(key) as Uint8Array;if(!file)error('Reselect the original file.');return file.slice(offset,offset+length);}
   if(method==='POST'&&phone){if(row!.status!=='ready'&&row!.status!=='saved')error('File incomplete.');await localStore.remove(key);row!.status='saved';await this.persist();return json({saved:true});}
   if(method==='DELETE'&&!phone&&row!.status==='pending'){await localStore.remove(key);this.transfers=this.transfers.filter(t=>t!==row);await this.persist();return json({removed:true});}}
  return error('Unknown peer action.');
 }
}
