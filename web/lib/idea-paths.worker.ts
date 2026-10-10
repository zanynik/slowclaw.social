import {ideaModel,ideaRevision,cpuIdeaModelURL,normalizeIdea,EmbeddingBackend} from './idea-paths';
let extractor:any;
let cpu:any;
self.onmessage=async(e:MessageEvent<{texts:string[];backend:EmbeddingBackend}>)=>{
 try{
  if(e.data.backend==='wasm'&&!cpu){
   postMessage({status:'Preparing the smaller CPU model…'});
   const {UniversalEmbedder,FilesetResolver}=await import('@mediapipe/tasks-retrieval');
   const files=await FilesetResolver.forRetrievalTasks('https://cdn.jsdelivr.net/npm/@mediapipe/tasks-retrieval@1.1.0-rc.20260929/wasm',true);
   cpu=await UniversalEmbedder.createFromOptions(files,{baseOptions:{modelAssetPath:cpuIdeaModelURL,delegate:'CPU'},l2Normalize:true,activationDataType:'FLOAT32'});
  }
  if(e.data.backend==='webgpu'&&!extractor){postMessage({status:'Downloading the local model…'});
   const runtime='https://cdn.jsdelivr.net/npm/@huggingface/transformers@4.3.1';
   const {pipeline,env}=await import(/* @vite-ignore */runtime);
   env.allowLocalModels=false;env.backends.onnx.wasm.numThreads=1;
   extractor=await pipeline('feature-extraction',ideaModel,{revision:ideaRevision,device:'webgpu',dtype:'q4',progress_callback:(p:any)=>postMessage({status:'Loading model'+(typeof p.progress==='number'?' · '+Math.round(p.progress)+'%':'…')})});
  }
  const vectors:number[][]=[];
  for(let i=0;i<e.data.texts.length;i++){
   postMessage({status:`Embedding passage ${i+1} of ${e.data.texts.length}…`});
   const prompt='title: none | text: '+e.data.texts[i];
   if(cpu){const output=await cpu.embedText(prompt);vectors.push(normalizeIdea(Array.from(output.embeddings[0]?.floatEmbedding||[])));}
   else {const output=await extractor(prompt,{pooling:'mean',normalize:true});vectors.push(normalizeIdea(output.tolist()[0]));}
  }
  postMessage({vectors});
 }catch(error){try{await extractor?.dispose();cpu?.close();}catch{}extractor=undefined;cpu=undefined;postMessage({error:'The local embedding model could not run. '+(error as Error).message});}
};
