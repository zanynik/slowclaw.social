import type {JournalEntry} from './journal-draft';
export const ideaModel='onnx-community/embeddinggemma-2-ONNX';
export const ideaRevision='daa72c51243991dfcaf9f9137d2c573d8f7790c0';
export const cpuIdeaModelURL='https://huggingface.co/litert-community/embeddinggemma-2-text-270m-litert-lm/resolve/9be6e8b90982095dc05c2bd162e4b954ee4dbac7/embeddinggemma-2-text-270m.litertlm';
export const ideaModelVersion=ideaModel+'@'+ideaRevision+':768:title-none:cpu-litert-9be6e8b90982095dc05c2bd162e4b954ee4dbac7:v3';
export type EmbeddingBackend='webgpu'|'wasm';
export async function embeddingBackend():Promise<EmbeddingBackend>{
 const gpu=(navigator as Navigator&{gpu?:{requestAdapter:()=>Promise<unknown>}}).gpu;
 try{if(gpu&&await gpu.requestAdapter())return 'webgpu';}catch{}return 'wasm';
}
export type IdeaChunk={id:string;sourceKey:string;revision:string;title:string;date?:string;text:string;start:number;end:number};
export type EmbeddedIdea=IdeaChunk&{vector:number[]};
export type IdeaPath={ideas:EmbeddedIdea[];similarity:number;alignment:number;score:number};
const dot=(a:number[],b:number[])=>a.reduce((s,x,i)=>s+x*b[i],0);
const norm=(a:number[])=>Math.sqrt(dot(a,a));
const sub=(a:number[],b:number[])=>a.map((x,i)=>x-b[i]);
const cosine=(a:number[],b:number[])=>norm(a)*norm(b)>1e-10?Math.max(-1,Math.min(1,dot(a,b)/norm(a)/norm(b))):0;
export function normalizeIdea(values:number[]):number[]{
 if(values.length!==768||values.some(x=>!Number.isFinite(x)))throw Error('Expected 768 finite embedding coordinates.');
 const length=norm(values);if(length<1e-10)throw Error('The model returned an empty embedding.');return values.map(x=>x/length);
}
export function latestJournals(entries:JournalEntry[]):JournalEntry[]{
 return [...entries].filter(e=>e.revision).sort((a,b)=>(Date.parse(b.date||'')||0)-(Date.parse(a.date||'')||0)||a.id.localeCompare(b.id)).slice(0,3);
}
/** Five source lines (or five sentences for a single-paragraph transcript).
 * Bound oversized lines without dropping characters or inventing source text. */
export function journalChunks(entry:JournalEntry):IdeaChunk[]{
 const text=entry.text||'',pieces:{start:number;end:number}[]=[];
 if(text.split(/\r?\n/).filter(s=>s.trim()).length>1){const re=/[^\n]+(?:\n|$)/g;for(const m of text.matchAll(re))if(m[0].trim())pieces.push({start:m.index!,end:m.index!+m[0].length});}
 else for(const s of new Intl.Segmenter(undefined,{granularity:'sentence'}).segment(text))if(s.segment.trim())pieces.push({start:s.index,end:s.index+s.segment.length});
 const chunks:IdeaChunk[]=[];
 for(let i=0;i<pieces.length;i+=5){let start=pieces[i].start;const end=pieces[Math.min(i+4,pieces.length-1)].end;
  while(start<end){let stop=Math.min(start+1600,end);if(stop<end&&/[\uD800-\uDBFF]/.test(text[stop-1]))stop--;const raw=text.slice(start,stop),clean=raw.trim();if(clean){const offset=raw.indexOf(clean),a=start+offset,b=a+clean.length;chunks.push({id:entry.id+'@'+entry.revision+':'+a+':'+b,sourceKey:entry.id,revision:entry.revision!,title:entry.title||'Untitled journal',date:entry.date,text:clean,start:a,end:b});}start=stop;}
 }
 return chunks;
}
/** Prototype score: equal blend of adjacent idea cosine and step-vector alignment. */
export function pathMetrics(ideas:EmbeddedIdea[]):Omit<IdeaPath,'ideas'>{
 if(ideas.length<2)return {similarity:1,alignment:0,score:0};
 const edges=ideas.slice(1).map((x,i)=>sub(x.vector,ideas[i].vector));
 const similarity=ideas.slice(1).reduce((s,x,i)=>s+cosine(x.vector,ideas[i].vector),0)/(ideas.length-1);
 const alignment=edges.length>1?edges.slice(1).reduce((s,x,i)=>s+cosine(x,edges[i]),0)/(edges.length-1):0;
 return {similarity,alignment,score:.5*(similarity+alignment)};
}
/** Complete-link groups avoid unrelated passages joining via a weak bridge. */
export function buildIdeaPaths(ideas:EmbeddedIdea[],threshold=.86):IdeaPath[]{
 const groups=ideas.map(x=>[x]);
 for(;;){let best=-1,a=-1,b=-1;for(let i=0;i<groups.length;i++)for(let j=i+1;j<groups.length;j++){
  if(groups[i].length+groups[j].length>8)continue;
  const score=Math.min(...groups[i].flatMap(x=>groups[j].map(y=>cosine(x.vector,y.vector))));
  if(score>=threshold&&score>best){best=score;a=i;b=j;}
 }if(a<0)break;groups[a].push(...groups[b]);groups.splice(b,1);}
 return groups.map(group=>{
  const chronological=[...group].sort((a,b)=>(Date.parse(a.date||'')||0)-(Date.parse(b.date||'')||0)||a.sourceKey.localeCompare(b.sourceKey)||a.start-b.start);
  if(group.length<3)return {ideas:chronological,...pathMetrics(chronological)};
  // Keep earliest/latest source anchors. Exhaustively score up to six interior
  // ideas, at most 720 routes per card; no factorial search over the whole corpus.
  let best=chronological,bestScore=-Infinity;const first=chronological[0],last=chronological[chronological.length-1];
  function visit(path:EmbeddedIdea[],rest:EmbeddedIdea[]){if(!rest.length){const route=[first,...path,last],score=pathMetrics(route).score;if(score>bestScore){bestScore=score;best=route;}return;}rest.forEach((x,i)=>visit([...path,x],rest.filter((_,j)=>j!==i)));}
  visit([],chronological.slice(1,-1));return {ideas:best,...pathMetrics(best)};
 }).sort((a,b)=>b.ideas.length-a.ideas.length||b.score-a.score);
}
