const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const crypto = require('node:crypto');
const {EventEmitter} = require('node:events');
const source = fs.readFileSync(__dirname + '/asc-issue-cert-profile.js', 'utf8');
const pem = crypto.generateKeyPairSync('ec', {namedCurve:'prime256v1'}).privateKey.export({type:'pkcs8',format:'pem'});
async function check(status) {
  const calls = [], messages = [];
  const result = await new Promise((resolve,reject) => {
    const timeout = setTimeout(()=>reject(Error('Preflight did not finish.')),2000);
    const finish = value => {clearTimeout(timeout);resolve(value);};
    const fakeFS = {
      readFileSync:()=>pem,
      existsSync:()=>false,
      writeFileSync:()=>reject(Error('Preflight wrote a signing asset.')),
      appendFileSync:()=>reject(Error('Preflight changed signing state.')),
      unlinkSync:()=>reject(Error('Preflight deleted signing state.')),
    };
    const fakeHTTPS = {request(options,callback) {
      calls.push({method:options.method,path:options.path});
      assert.equal(options.method,'GET');
      assert.ok(options.path.startsWith('/v1/bundleIds?'));
      const req = new EventEmitter(); req.write=()=>reject(Error('Preflight sent a mutation body.'));
      req.end=()=>queueMicrotask(()=>{
        const response=new EventEmitter();response.statusCode=status;response.setEncoding=()=>{};callback(response);
        response.emit('data',JSON.stringify(status===200?{data:[{id:'slowclaw_fixture'}]}:{errors:[{detail:'Account Holder must accept the Program License Agreement.'}]}));
        response.emit('end');
      });
      return req;
    }};
    vm.runInNewContext(source,{
      Buffer,
      require:name=>({crypto,fs:fakeFS,https:fakeHTTPS}[name]),
      process:{env:{SIGNING_PREFLIGHT:'1',ASC_KEY_PATH:'fixture-key',ASC_KEY_ID:'fixture',ASC_ISSUER_ID:'fixture',APP_BUNDLE_ID:'com.slowclaw.app'},exit:code=>finish(code)},
      console:{log:message=>{messages.push(message);finish(0);},error:message=>messages.push(message)},
    });
  });
  assert.equal(result,status===200?0:1);
  assert.equal(calls.length,1);
  if(status===403)assert.ok(messages.some(x=>x.includes('License Agreement')));
}
(async()=>{await check(200);await check(403);console.log('PASS: membership preflight is read-only and surfaces agreement failures.');})().catch(error=>{console.error(error);process.exitCode=1;});
