import { Store } from './store.mjs';
import { startWorker } from './worker.mjs';
import { makeServer } from './server.mjs';
import { randomBytes } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync, existsSync, chmodSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { homedir } from 'node:os';

const home=resolve(process.env.SLOWCLAW_AGENT_HOME||join(homedir(),'.slowclaw','agent'));
mkdirSync(home,{recursive:true,mode:0o700});
const tokenPath=join(home,'access-token');
if(!existsSync(tokenPath))writeFileSync(tokenPath,randomBytes(32).toString('hex'),{flag:'wx',mode:0o600});
chmodSync(tokenPath,0o600);
const token=readFileSync(tokenPath,'utf8').trim();
const [command='serve',argument]=process.argv.slice(2);
if(command==='token'){
  process.stdout.write(token+'\n');
}else if(command==='serve'){
  const port=Number(process.env.SLOWCLAW_AGENT_PORT||4317);
  if(!Number.isSafeInteger(port)||port<1024||port>65535)throw new Error('Invalid port');
  const store=new Store(join(home,'agent.sqlite'));
  store.recoverJobs();
  const worker=startWorker(store);
  const server=makeServer(store,token,{port});
  server.listen(port,'127.0.0.1',()=>console.log(`Slowclaw local agent: http://127.0.0.1:${port} (loopback only)`));
  let stopping=false;
  const stop=async()=>{if(stopping)return;stopping=true;await worker.stop();await new Promise(r=>server.close(r));store.close();};
  process.on('SIGINT',()=>{void stop()});process.on('SIGTERM',()=>{void stop()});
}else if(command==='import'){
  if(!argument)throw new Error('Usage: node src/main.mjs import path/to/passages.json');
  const store=new Store(join(home,'agent.sqlite'));
  const data=JSON.parse(readFileSync(resolve(argument),'utf8'));
  console.log(JSON.stringify(store.importPassages(Array.isArray(data)?data:data.passages)));
  store.close();
}else{
  throw new Error('Commands: serve | import <file> | token');
}
