import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { timingSafeEqual } from 'node:crypto';

const html=readFileSync(fileURLToPath(new URL('../ui/index.html',import.meta.url)));
const script=readFileSync(fileURLToPath(new URL('../ui/app.js',import.meta.url)));
const equal=(a,b)=>{const x=Buffer.from(a),y=Buffer.from(b);return x.length===y.length&&timingSafeEqual(x,y)};
function send(res,status,payload){res.writeHead(status,{'Content-Type':'application/json; charset=utf-8','Cache-Control':'no-store','X-Content-Type-Options':'nosniff'});res.end(JSON.stringify(payload));}
function jsonBody(req){return new Promise((resolve,reject)=>{
  let input='',bytes=0;
  req.on('data',chunk=>{bytes+=chunk.length;if(bytes>512_000){reject(new Error('Request too large'));req.destroy();return;} input+=chunk;});
  req.on('end',()=>{try{resolve(JSON.parse(input||'{}'))}catch{reject(new Error('Malformed JSON'))}});
  req.on('error',reject);
});}
export function makeServer(store,token,{port=4317}={}) {
  return createServer(async(req,res)=>{
    res.setHeader('X-Frame-Options','DENY');
    res.setHeader('Referrer-Policy','no-referrer');
    res.setHeader('Cross-Origin-Resource-Policy','same-origin');
    res.setHeader('Content-Security-Policy',"default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'");
    const origin=req.headers.origin;
    if(origin && origin!==`http://127.0.0.1:${port}`)return send(res,403,{error:'Cross-origin request blocked'});
    const path=(req.url||'/').split('?')[0];
    if(req.method==='GET'&&path==='/'){res.writeHead(200,{'Content-Type':'text/html; charset=utf-8','Cache-Control':'no-store'});res.end(html);return;}
    if(req.method==='GET'&&path==='/app.js'){res.writeHead(200,{'Content-Type':'text/javascript; charset=utf-8','Cache-Control':'no-store'});res.end(script);return;}
    if(!equal((req.headers.authorization||'').replace(/^Bearer /,''),token))return send(res,401,{error:'Local access token required'});
    try {
      if(req.method==='GET'&&path==='/v1/status') return send(res,200,{name:'slowclaw-local-agent',version:1,schedule:store.getSchedule(),pi_enabled:process.env.SLOWCLAW_ENABLE_PI==='1'});
      if(req.method==='GET'&&path==='/v1/passages') return send(res,200,{passages:store.passages()});
      if(req.method==='GET'&&path==='/v1/jobs') return send(res,200,{jobs:store.listJobs()});
      if(req.method==='GET'&&path==='/v1/proposals') return send(res,200,{proposals:store.listProposals()});
      if(req.method==='GET'&&path==='/v1/events') return send(res,200,{events:store.listEvents()});
      if(req.method==='POST'&&path==='/v1/passages') return send(res,200,store.importPassages((await jsonBody(req)).passages));
      if(req.method==='POST'&&path==='/v1/jobs') {
        const {kind,payload}=await jsonBody(req);
        return send(res,202,{id:store.enqueue(kind,payload)});
      }
      if(req.method==='PUT'&&path==='/v1/schedule') return send(res,200,store.updateSchedule(await jsonBody(req)));
      if(req.method==='POST'&&/^\/v1\/proposals\/[a-f\d-]+\/decision$/.test(path)) {
        return send(res,200,store.decide(path.split('/')[3],(await jsonBody(req)).status));
      }
      return send(res,404,{error:'Not found'});
    }catch(error){return send(res,400,{error:error.message||'Bad request'})}
  });
}
