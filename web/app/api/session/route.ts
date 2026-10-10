import { handle } from '@/lib/session-server';
export const dynamic='force-dynamic';
export const POST=(request:Request)=>handle(request,[]);
