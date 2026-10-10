/** An unresponsive STUN server need not invalidate usable local candidates. */
export function gatherCandidates(pc:RTCPeerConnection,timeout=12000):Promise<void>{
 return new Promise((resolve,reject)=>{
  let timer:ReturnType<typeof setTimeout>;
  const finish=(error?:Error)=>{clearTimeout(timer);pc.removeEventListener('icegatheringstatechange',check);pc.removeEventListener('connectionstatechange',check);error?reject(error):resolve();};
  const check=()=>{if(pc.connectionState==='closed')finish(Error('Pairing ended.'));else if(pc.iceGatheringState==='complete')finish();};
  timer=setTimeout(()=>{if(/^a=candidate:/m.test(pc.localDescription?.sdp||''))finish();else finish(Error('No network route was found. Try the same Wi-Fi and disable a VPN that blocks WebRTC.'));},timeout);
  pc.addEventListener('icegatheringstatechange',check);pc.addEventListener('connectionstatechange',check);check();
 });
}
