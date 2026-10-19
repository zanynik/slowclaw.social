import { spawn } from 'node:child_process';
import { tmpdir } from 'node:os';

// Pi is an opt-in text-only subprocess. Its filesystem, shell, and extension tools are disabled.
// Never send journal content to a provider without explicit per-job consent.
export async function reflectWithPi(passages, {command=process.env.SLOWCLAW_PI_COMMAND||'pi',timeoutMs=120_000}={}) {
  if (process.env.SLOWCLAW_ENABLE_PI !== '1') throw new Error('Pi integration disabled; set SLOWCLAW_ENABLE_PI=1 after choosing a trusted model/provider');
  const prompt = `You are Slowclaw's proposal writer. Return a short grounded hypothesis about connections among the sources. Do not invent information or claim this is the user's own meaning. Do not give commands, browse files, or suggest publishing. Cite exact source IDs in your response.\n\n${passages.map(p=>`SOURCE ${p.id} (${p.occurred_at}):\n${p.body}`).join('\n\n')}`;
  return await new Promise((resolve,reject)=>{
    const child=spawn(command,['--print','--no-session','--no-tools','--no-extensions','--no-skills','--no-context-files','--no-prompt-templates','--no-mcp','--no-approve'],{
      stdio:['pipe','pipe','pipe'],shell:false,windowsHide:true,env:process.env,cwd:tmpdir()
    });
    let output='', stderr='';
    let settled=false;
    const finish=(error,value)=>{if(settled)return;settled=true;clearTimeout(timer);error?reject(error):resolve(value)};
    const timer=setTimeout(()=>{child.kill();finish(new Error('Pi timed out'))},timeoutMs);
    child.on('error',e=>finish(new Error(`Unable to launch Pi: ${e.code||e.message}`)));
    child.stdout.on('data',chunk=>{output+=chunk.toString();if(output.length>200_000){child.kill();finish(new Error('Pi output too large'))}});
    child.stderr.on('data',chunk=>{stderr+=chunk.toString();if(stderr.length>1000) stderr=stderr.slice(0,1000)});
    child.on('close',code=>{
      if(code!==0) return finish(new Error(`Pi exited with code ${code}. Check local Pi authentication and flags.`));
      if(!output.trim()) return finish(new Error('Pi returned no text'));
      finish(null,output.trim().slice(0,10_000));
    });
    child.stdin.on('error',()=>{});
    child.stdin.end(prompt);
  });
}
