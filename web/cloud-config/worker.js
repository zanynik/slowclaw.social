// Deployment supplies public client configuration as bindings. Never bind service/provider secrets.
export default {fetch(request,env){
 const origin=request.headers.get('Origin');
 const headers={'Content-Type':'application/json','Cache-Control':'public,max-age=60','Access-Control-Allow-Origin':'https://slowclaw.social','Vary':'Origin'};
 if(origin&&origin!=='https://slowclaw.social')return new Response('{}',{status:403,headers});
 if(request.method!=='GET'||new URL(request.url).pathname!=='/')return new Response('{}',{status:404,headers});
 return new Response(JSON.stringify({url:env.CLOUD_URL,publishableKey:env.CLOUD_PUBLISHABLE_KEY}),{headers});
}};
