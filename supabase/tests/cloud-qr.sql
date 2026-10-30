begin;
do $$
declare challenge text:=repeat('a',64); secret text:=repeat('b',64); r jsonb;
begin
 if has_function_privilege('anon','public.cloud_qr(text,text,text,text,text)','execute') or has_function_privilege('authenticated','public.cloud_qr(text,text,text,text,text)','execute') then raise exception 'QR RPC exposed'; end if;
 r=public.cloud_qr('start',challenge,secret,'',repeat('c',64));
 if (r->>'expires')::numeric<=extract(epoch from now()) then raise exception 'no expiry'; end if;
 if (public.cloud_qr('poll',challenge,repeat('d',64),'','')->>'error')<>'QR_EXPIRED' then raise exception 'wrong capability accepted'; end if;
 perform public.cloud_qr('complete',challenge,'',repeat('A',80),'');
 if (public.cloud_qr('poll',challenge,secret,'','')->>'payload')<>repeat('A',80) then raise exception 'lost encrypted payload'; end if;
 begin
  perform public.cloud_qr('complete',challenge,'',repeat('B',80),'');
  raise exception 'overwrite accepted';
 exception when raise_exception then if sqlerrm<>'already approved' then raise; end if; end;
 perform public.cloud_qr('ack',challenge,secret,'','');
 if (public.cloud_qr('poll',challenge,secret,'','')->>'error')<>'QR_EXPIRED' then raise exception 'replayed consumed login'; end if;
 if exists(select 1 from cloud_private.qr_logins where id=repeat('a',64) and payload is not null) then raise exception 'payload retained'; end if;
end $$;
rollback;
