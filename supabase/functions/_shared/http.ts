import {createClient} from 'npm:@supabase/supabase-js@2.118.0';

export class Problem extends Error {
  constructor(public code: string, public status = 400) { super(code); }
}
export const origins = new Set(['https://slowclaw.social', 'http://localhost:5173', 'http://127.0.0.1:5173']);
export function headers(req: Request) {
  const origin = req.headers.get('Origin');
  if (origin && !origins.has(origin)) throw new Problem('ORIGIN_NOT_ALLOWED', 403);
  return {'Content-Type':'application/json', 'Cache-Control':'no-store', 'Vary':'Origin',
    ...(origin ? {'Access-Control-Allow-Origin':origin} : {}),
    'Access-Control-Allow-Headers':'authorization,apikey,content-type,x-client-info',
    'Access-Control-Allow-Methods':'POST,OPTIONS'};
}
export function admin() {
  const keys = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') || '{}');
  const key = keys.default || Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!key) throw new Problem('BACKEND_NOT_CONFIGURED',503);
  return createClient(Deno.env.get('SUPABASE_URL')!,key,{auth:{persistSession:false,autoRefreshToken:false}});
}
export type DB = ReturnType<typeof admin>;
export async function user(req: Request, db: DB) {
  const token=req.headers.get('Authorization')?.replace(/^Bearer /,'');
  if (!token) throw new Problem('SIGN_IN_REQUIRED',401);
  const {data,error}=await db.auth.getUser(token);
  if (error || !data.user) throw new Problem('SIGN_IN_REQUIRED',401);
  return data.user.id;
}
export async function body(req: Request, max = 1200000): Promise<Record<string,unknown>> {
  if (!req.body) throw new Problem('EMPTY_REQUEST');
  const reader=req.body.getReader(), chunks:Uint8Array[]=[];let size=0;
  for (;;) {const {done,value}=await reader.read();if(done)break;size+=value.length;if(size>max){await reader.cancel();throw new Problem('REQUEST_TOO_LARGE',413);}chunks.push(value);}
  const bytes=new Uint8Array(size);let offset=0;for(const c of chunks){bytes.set(c,offset);offset+=c.length;}
  try { const value=JSON.parse(new TextDecoder().decode(bytes));if(!value||typeof value!=='object'||Array.isArray(value))throw Error();return value; }
  catch {throw new Problem('INVALID_JSON');}
}
export function string(value: unknown, max: number, allowEmpty = false): string {
  if(typeof value!=='string'||value.length>max||(!allowEmpty&&!value.trim()))throw new Problem('INVALID_INPUT');return value;
}
// A successful single/read response is non-null; mutation response bodies are intentionally ignored.
export function checked<T>(result:{data:T;error:unknown}):NonNullable<T> {if(result.error)throw new Problem('DATABASE_OPERATION_FAILED',503);return result.data as NonNullable<T>;}
export function optional<T>(result:{data:T;error:unknown}):T {if(result.error)throw new Problem('DATABASE_OPERATION_FAILED',503);return result.data;}
export async function rpc<T=any>(db:DB,name:string,args:Record<string,unknown>):Promise<T>{return checked(await db.rpc(name,args)) as T;}
export function failure(e:unknown) {return e instanceof Problem ? {error:e.code,status:e.status} : {error:'OPERATION_FAILED',status:503};}
export async function serve(req:Request,handler:(req:Request)=>Promise<unknown>) {
  try {const h=headers(req);if(req.method==='OPTIONS')return new Response(null,{status:204,headers:h});if(req.method!=='POST')throw new Problem('METHOD_NOT_ALLOWED',405);
    return new Response(JSON.stringify(await handler(req)),{headers:h});
  } catch(e) {const p=failure(e);let h:Record<string,string>={'Content-Type':'application/json','Cache-Control':'no-store'};try{h=headers(req);}catch{}
    return new Response(JSON.stringify({error:p.error}),{status:p.status,headers:h});}
}
