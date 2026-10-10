import {createRequire} from 'node:module';
import {mkdtempSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import assert from 'node:assert/strict';
const require=createRequire(import.meta.url),wr=createRequire(require.resolve('wrangler/package.json')),{build}=wr('esbuild');
const dir=mkdtempSync(join(tmpdir(),'slowclaw-paths-'));
try{
 await build({entryPoints:['lib/idea-paths.ts','lib/ice-gathering.ts'],outdir:dir,format:'esm',platform:'node'});
 const {journalChunks,latestJournals,normalizeIdea,pathMetrics,buildIdeaPaths}=await import(join(dir,'idea-paths.js'));
 const {gatherCandidates}=await import(join(dir,'ice-gathering.js'));
 const entry={id:'journal_example',revision:'revision_example',title:'Example',text:Array.from({length:11},(_,i)=>'Line '+i+' 👩🏽‍💻').join('\n')};
 const chunks=journalChunks(entry);assert.equal(chunks.length,3);assert.equal(chunks[0].text.split('\n').length,5);for(const c of chunks)assert.equal(entry.text.slice(c.start,c.end),c.text);
 const prose={...entry,text:'One sentence. Two sentences. Three sentences. Four sentences. Five sentences. Six sentences.'};assert.equal(journalChunks(prose).length,2);
 const long={...entry,text:'👩🏽‍💻'.repeat(700)};for(const c of journalChunks(long)){assert.equal(long.text.slice(c.start,c.end),c.text);assert(!/[\uD800-\uDBFF]$/.test(c.text));}
 assert.deepEqual(journalChunks({...entry,text:' \n '}),[]);
 assert.deepEqual(latestJournals([1,4,2,3].map(n=>({...entry,id:String(n),date:'2026-01-0'+n}))).map(e=>e.id),['4','3','2']);
 assert.throws(()=>normalizeIdea(Array(256).fill(1)));assert.throws(()=>normalizeIdea(Array(768).fill(0)));assert.throws(()=>normalizeIdea([NaN,...Array(767).fill(1)]));
 const vector=(x,y)=>normalizeIdea([x,y,...Array(766).fill(0)]);
 const ideas=[vector(1,0),vector(1,1),vector(0,1)].map((v,i)=>({...chunks[0],id:String(i),start:i,date:'2026-01-0'+(i+1),vector:v}));
 const m=pathMetrics(ideas);assert(Math.abs(m.similarity-Math.SQRT1_2)<1e-8);assert(Math.abs(m.alignment-Math.SQRT1_2)<1e-8);
 const backwards=pathMetrics([ideas[0],ideas[1],ideas[0]]);assert.equal(backwards.alignment,-1);
 const routes=buildIdeaPaths(ideas,-1);assert.equal(routes.length,1);assert.deepEqual(routes[0].ideas.map(i=>i.id),['0','1','2']);
 // Complete-link clustering does not merge distant endpoints through a bridge.
 assert.equal(buildIdeaPaths(ideas,.7).length,2);
 const repeated=Array.from({length:17},(_,i)=>({...ideas[0],id:String(i),start:i}));assert(buildIdeaPaths(repeated).every(p=>p.ideas.length<=8));
 class PC extends EventTarget{iceGatheringState='gathering';connectionState='new';localDescription={sdp:''};}
 const complete=new PC();const done=gatherCandidates(complete,30);complete.iceGatheringState='complete';complete.dispatchEvent(new Event('icegatheringstatechange'));await done;
 const slow=new PC();slow.localDescription.sdp='v=0\r\na=candidate:1 1 udp 1 local 123 typ host\r\n';await gatherCandidates(slow,10);
 await assert.rejects(gatherCandidates(new PC(),10),/No network route/);
 const closed=new PC(),cancel=gatherCandidates(closed,100);closed.connectionState='closed';closed.dispatchEvent(new Event('connectionstatechange'));await assert.rejects(cancel,/Pairing ended/);
 console.log('PASS: five-line exact chunks, full 768d normalization, prototype step scoring, bounded complete-link chains, stalled/absent/cancelled ICE');
}finally{rmSync(dir,{recursive:true,force:true});}
