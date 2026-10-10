import { NextResponse } from 'next/server';
export function middleware() {
 const response=NextResponse.next();
 response.headers.set('Referrer-Policy','no-referrer');
 response.headers.set('X-Content-Type-Options','nosniff');
 response.headers.set('X-Frame-Options','DENY');
 response.headers.set('Cache-Control','no-store');
 response.headers.set('Permissions-Policy','camera=(), microphone=(), geolocation=()');
 return response;
}
