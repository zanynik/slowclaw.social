import {createRequire} from 'node:module';
import {mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {pathToFileURL} from 'node:url';
import assert from 'node:assert/strict';
const require=createRequire(import.meta.url),wr=createRequire(require.resolve('wrangler/package.json')),{build}=wr('esbuild');
const dir=mkdtempSync(join(tmpdir(),'slowclaw-units-'));
try{
 await build({entryPoints:['lib/journal-units.ts'],outdir:dir,format:'esm',platform:'node'});
 const {normalize,segments,extractUnits}=await import(pathToFileURL(join(dir,'journal-units.js')));
 const a=normalize([1,...Array(767).fill(0)]),b=normalize([0,1,...Array(766).fill(0)]);
 assert.equal(a.length,256);assert.equal(a.reduce((s,x)=>s+x*x,0),1);
 assert.throws(()=>normalize([0,...Array(767).fill(0)]));assert.throws(()=>normalize([NaN,...Array(767).fill(0)]));
 const source='A quiet walk helps me reflect. I return with a clearer mind.\n\nThe project needs a better review process.';
 const units=await extractUnits(source,async text=>text.includes('project')?b:a);
 assert.equal(units.length,2);for(const u of units)assert.ok(source.includes(u.text));
 const unicode='思考。'.repeat(100)+'👩🏽‍💻'.repeat(130);for(const p of segments(unicode))assert.ok(unicode.includes(p));
 assert.deepEqual(await extractUnits('  \n ',async()=>a),[]);
 const repeated=await extractUnits('A thought. A thought.',async()=>a);assert.equal(repeated.length,1);
 console.log('PASS: semantic boundaries, exact source excerpts, Unicode, finite normalized 256d vectors, empty journals');
}finally{rmSync(dir,{recursive:true,force:true});}
