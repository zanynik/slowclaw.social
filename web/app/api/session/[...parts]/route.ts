import { handle } from '@/lib/session-server';
export const dynamic='force-dynamic';
async function route(request:Request,ctx:{params:Promise<{parts:string[]}>}){return handle(request,(await ctx.params).parts);}
export {route as GET,route as POST,route as PUT,route as DELETE};
