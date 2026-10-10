/** Public model weights only. Journal text never enters this cache or fetch. */
export async function modelBytes(url:string,progress?:(message:string)=>void):Promise<Uint8Array>{
 let cache:Cache|undefined;try{cache=await caches.open('slowclaw-public-models-v1');}catch{}
 const saved=await cache?.match(url);if(saved){progress?.('Loading the downloaded model…');return new Uint8Array(await saved.arrayBuffer());}
 const response=await fetch(url,{credentials:'omit'});if(!response.ok)throw Error('Model download failed. Check your connection and retry.');
 const limit=500*1024*1024;if(Number(response.headers.get('Content-Length')||0)>limit)throw Error('Model download exceeds the local size limit.');
 const reader=response.body?.getReader();if(!reader)throw Error('Model download was empty.');
 const chunks:Uint8Array[]=[];let size=0,last=0;
 for(;;){const {value,done}=await reader.read();if(done)break;size+=value.length;if(size>limit){await reader.cancel();throw Error('Model download exceeds the local size limit.');}chunks.push(value);if(size-last>=2*1024*1024){last=size;progress?.('Downloading model · '+Math.round(size/1024/1024)+' MB');}}
 if(!size)throw Error('Model download was empty.');const bytes=new Uint8Array(size);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length;}
 try{await cache?.put(url,new Response(bytes));}catch{}return bytes;
}
