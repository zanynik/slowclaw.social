import {ideaModel,ideaRevision,normalizeIdea} from './idea-paths';
let extractor:any;
self.onmessage=async(e:MessageEvent<{texts:string[]}>)=>{
 try{
  if(!extractor){postMessage({status:'Downloading the local model…'});
   const runtime='https://cdn.jsdelivr.net/npm/@huggingface/transformers@4.3.1';
   const {pipeline,env}=await import(/* @vite-ignore */runtime);
   env.allowLocalModels=false;env.backends.onnx.wasm.numThreads=1;
   extractor=await pipeline('feature-extraction',ideaModel,{revision:ideaRevision,device:'wasm',dtype:'q4',progress_callback:(p:any)=>postMessage({status:'Loading model'+(typeof p.progress==='number'?' · '+Math.round(p.progress)+'%':'…')})});
  }
  const vectors:number[][]=[];
  for(let i=0;i<e.data.texts.length;i++){
   postMessage({status:`Embedding passage ${i+1} of ${e.data.texts.length}…`});
   const output=await extractor('title: none | text: '+e.data.texts[i],{pooling:'mean',normalize:true});vectors.push(normalizeIdea(output.tolist()[0]));
  }
  postMessage({vectors});
 }catch(error){try{await extractor?.dispose();}catch{}extractor=undefined;postMessage({error:'The local embedding model could not run. '+(error as Error).message});}
};
