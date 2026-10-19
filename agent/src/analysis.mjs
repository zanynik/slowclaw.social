// Deterministic candidate generation; not an embedding model and not an interpretation of the user's intent.
const STOP=new Set('about after again also and are been being but can could does for from had has have here into its just more much not only our out over really should some than that the their them there these they this those through was were what when where which while with would your journal like think want need feel very something really because into'.split(' '));
const terms=(text)=>new Set((text.toLowerCase().match(/[\p{L}\p{N}]{4,}/gu)||[]).filter(t=>!STOP.has(t)).slice(0,500));
export function discoverConnections(passages,limit=12) {
  const vectors=passages.slice(0,200).map(p=>({p,terms:terms(p.body)}));
  const ranked=[];
  for(let i=0;i<vectors.length;i++) for(let j=i+1;j<vectors.length;j++){
    const a=vectors[i], b=vectors[j];
    const common=[...a.terms].filter(t=>b.terms.has(t));
    if(common.length<2) continue;
    const score=common.length / Math.sqrt(Math.max(a.terms.size,1)*Math.max(b.terms.size,1));
    if(score<0.18) continue;
    ranked.push({score,source_ids:[a.p.id,b.p.id],common:common.slice(0,8)});
  }
  ranked.sort((a,b)=>b.score-a.score);
  return ranked.slice(0,limit).map(pair=>({
    kind:'candidate-connection',title:`Possible connection: ${pair.common.slice(0,3).join(', ')}`,
    explanation:`Shared terms: ${pair.common.join(', ')}. Similarity ${pair.score.toFixed(2)}. This is a lexical candidate, not an AI conclusion.`,
    source_ids:pair.source_ids
  }));
}
