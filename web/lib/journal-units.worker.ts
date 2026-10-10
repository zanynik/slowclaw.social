import {UniversalEmbedder,FilesetResolver} from '@mediapipe/tasks-retrieval';
import {extractUnits,normalize,modelURL} from './journal-units';
let model:Promise<UniversalEmbedder>|undefined;
const runtime='https://cdn.jsdelivr.net/npm/@mediapipe/tasks-retrieval@1.1.0-rc.20260929/wasm';
async function embed(text:string){
 model??=(async()=>{postMessage({status:'Preparing the local model…'});const files=await FilesetResolver.forRetrievalTasks(runtime,true);return UniversalEmbedder.createFromOptions(files,{baseOptions:{modelAssetPath:modelURL,delegate:'CPU'},l2Normalize:false,activationDataType:'FLOAT32'});})();
 const result=await (await model).embedText('task: clustering | query: '+text);
 return normalize(result.embeddings[0]?.floatEmbedding||[]);
}
self.onmessage=async(e:MessageEvent<{text:string}>)=>{
 try{let n=0;const units=await extractUnits(e.data.text,embed,()=>{postMessage({status:'Organizing thought '+(++n)+'…'});});postMessage({units});}
 catch(error){model=undefined;postMessage({error:(error as Error).message});}
};
