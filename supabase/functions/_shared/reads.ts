import {Problem} from './http.ts';
// Fixed public sources prevent arbitrary URLs/SSRF and never receive private journal text.
export const feeds=[
  {name:'MIT Technology Review',url:'https://www.technologyreview.com/feed/'},
  {name:'Quanta Magazine',url:'https://www.quantamagazine.org/feed/'},
  {name:'Our World in Data',url:'https://ourworldindata.org/atom.xml'},
  {name:'Hacker News',url:'https://hnrss.org/frontpage'},
  {name:'Aeon',url:'https://aeon.co/feed.rss'},
];
export type Reading={url:string;title:string;description:string;source:string;score?:number;reason?:string};
export function httpsURL(value:string):string|null {try{const u=new URL(value);return u.protocol==='https:'&&!u.username&&!u.password&&u.href.length<=2048?u.href:null;}catch{return null;}}
function clean(s:string){return s.replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g,'$1').replace(/<[^>]*>/g,' ').replace(/&amp;/g,'&').replace(/&lt;/g,'<').replace(/&gt;/g,'>').replace(/&quot;/g,'"').replace(/&#39;/g,"'").replace(/\s+/g,' ').trim();}
export function parseFeed(xml:string,source:string):Reading[]{
  const result:Reading[]=[];const blocks=xml.match(/<item\b[\s\S]*?<\/item>|<entry\b[\s\S]*?<\/entry>/gi)||[];
  for(const block of blocks.slice(0,12)){
    const tag=(name:string)=>clean(block.match(new RegExp('<'+name+'[^>]*>([\\s\\S]*?)<\\/'+name+'>','i'))?.[1]||'');
    const link=block.match(/<link\b(?=[^>]*\brel=['"]alternate['"])[^>]*href=['"]([^'"]+)/i)?.[1]||block.match(/<link\b(?![^>]*\brel=)[^>]*href=['"]([^'"]+)/i)?.[1]||tag('link');
    const url=httpsURL(clean(link)),title=tag('title');if(url&&title)result.push({url,title:title.slice(0,300),description:(tag('description')||tag('summary')).slice(0,1000),source});
  }return result;
}
export async function candidates():Promise<Reading[]>{
  const lists=await Promise.allSettled(feeds.map(async f=>{
    const response=await fetch(f.url,{redirect:'error',signal:AbortSignal.timeout(8000)});if(!response.ok)throw new Problem('FEED_UNAVAILABLE');
    const reader=response.body!.getReader();let xml='',size=0;const decoder=new TextDecoder();for(;;){const {done,value}=await reader.read();if(done)break;size+=value.length;if(size>1500000){await reader.cancel();throw new Problem('FEED_TOO_LARGE');}xml+=decoder.decode(value,{stream:true});}xml+=decoder.decode();return parseFeed(xml,f.name);
  }));
  const result=lists.flatMap(r=>r.status==='fulfilled'?r.value:[]);if(!result.length)throw new Problem('FEEDS_UNAVAILABLE',503);
  return [...new Map(result.map(r=>[r.url,r])).values()].slice(0,50);
}
