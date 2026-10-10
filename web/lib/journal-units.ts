export const unitModel='embeddinggemma-2-text-vision-440m@e301f74d5551b0c2641bd5cb4652a76239d5c5f8:256';
export const modelURL='https://huggingface.co/litert-community/embeddinggemma-2-text-vision-440m-litert-lm/resolve/e301f74d5551b0c2641bd5cb4652a76239d5c5f8/embeddinggemma-2-text-vision-440m.litertlm';
export type Candidate={text:string;vector:number[]};
export type UnitGroup={id:string;title:string;units:{id:string;sourceKey:string;text:string}[]};
export function normalize(values:ArrayLike<number>):number[]{
 const vector=Array.from(values).slice(0,256);
 if(vector.length!==256||vector.some(x=>!Number.isFinite(x)))throw Error('The embedding model returned an invalid vector.');
 const norm=Math.sqrt(vector.reduce((s,x)=>s+x*x,0));
 if(norm<1e-12)throw Error('The embedding model returned an empty vector.');
 return vector.map(x=>Number((x/norm).toFixed(6)));
}
export const similarity=(a:number[],b:number[])=>a.reduce((sum,x,i)=>sum+x*b[i],0);
/** Sentence boundaries, preserving every source character and avoiding surrogate cuts. */
export function segments(text:string):string[]{
 const segmenter=new Intl.Segmenter(undefined,{granularity:'sentence'});
 const result:string[]=[];
 for(const {segment} of segmenter.segment(text)){
  const chars=Array.from(segment);for(let i=0;i<chars.length;i+=450){const part=chars.slice(i,i+450).join('');if(part.trim())result.push(part);}
 }
 return result;
}
/** Merge adjacent sentences when their meanings agree; never paraphrase the journal. */
export async function extractUnits(text:string,embed:(s:string)=>Promise<number[]>,progress?:()=>void):Promise<Candidate[]>{
 if(new TextEncoder().encode(text).length>1000000)throw Error('This journal is over the processing limit.');
 const pieces=segments(text);if(pieces.length>1500)throw Error('This journal is too long to organize in one pass.');
 const units:Candidate[]=[];let pending='',anchor:number[]=[];
 async function finish(){if(pending.trim()){const clean=pending.trim();units.push({text:clean,vector:await embed(clean)});}pending='';}
 for(const piece of pieces){
  const vector=await embed(piece.trim());progress?.();
  if(pending&&(pending.length+piece.length>1200||similarity(anchor,vector)<0.93))await finish();
  if(!pending)anchor=vector;pending+=piece;
 }
 await finish();if(units.length>512)throw Error('This journal contains too many separate thoughts.');
 return units.filter((u,i,all)=>all.findIndex(v=>v.text===u.text)===i);
}
