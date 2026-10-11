import type {EmbeddedIdea} from './idea-paths';
export type SpaceSuggestion={id:string;ideas:EmbeddedIdea[];representative:string;cohesion:number};
const cosine=(a:number[],b:number[])=>a.reduce((s,x,i)=>s+x*b[i],0);
const center=(xs:EmbeddedIdea[])=>{const v=Array(768).fill(0);for(const x of xs)x.vector.forEach((n,i)=>v[i]+=n);const magnitude=Math.hypot(...v);return v.map(n=>magnitude?n/magnitude:0)};
/** Broad thematic grouping, separate from the much stricter sequential Idea Paths.
 * Noise remains unassigned; never force unrelated journal text into a Space. */
export function discoverSpaces(ideas:EmbeddedIdea[],threshold=.75):SpaceSuggestion[]{
 const groups:EmbeddedIdea[][]=[];const sorted=[...ideas].sort((a,b)=>a.id.localeCompare(b.id));
 for(const item of sorted){
  let index=-1,score=threshold;
  groups.forEach((g,i)=>{const s=cosine(item.vector,center(g));if(s>score){score=s;index=i;}});
  if(index<0)groups.push([item]);else groups[index].push(item);
 }
 // Merge broadly related themes when their centroids agree.
 let changed=true;while(changed){changed=false;outer:for(let i=0;i<groups.length;i++)for(let j=i+1;j<groups.length;j++){
  if(cosine(center(groups[i]),center(groups[j]))>=threshold){groups[i].push(...groups[j]);groups.splice(j,1);changed=true;break outer;}
 }}
 return groups.filter(g=>g.length>=2).map(g=>{
  const centroid=center(g);
  const ranked=[...g].sort((a,b)=>cosine(b.vector,centroid)-cosine(a.vector,centroid));
  return {id:ranked.map(x=>x.id).sort().join('|'),ideas:g,representative:ranked[0].text,cohesion:g.reduce((n,x)=>n+cosine(x.vector,centroid),0)/g.length};
 }).sort((a,b)=>b.ideas.length-a.ideas.length||b.cohesion-a.cohesion);
}
/** Keep near-duplicate passages out of the suggested booklet, but not Thoughts. */
export function bookletIdeas(ideas:EmbeddedIdea[],limit=20):EmbeddedIdea[]{
 const ranked=[...ideas].sort((a,b)=>(a.date||'').localeCompare(b.date||'')||a.start-b.start);
 const chosen:EmbeddedIdea[]=[];for(const idea of ranked){
  if(chosen.every(x=>cosine(x.vector,idea.vector)<.965)){chosen.push(idea);if(chosen.length===limit)break;}
 }return chosen;
}
