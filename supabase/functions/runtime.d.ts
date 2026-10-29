declare namespace Deno { const env:{get(name:string):string|undefined}; function serve(handler:(request:Request)=>Promise<Response>):void; }
