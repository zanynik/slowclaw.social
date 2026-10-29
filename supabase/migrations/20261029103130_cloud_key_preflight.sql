grant select on cloud_private.provider_keys to service_role;
create or replace function public.cloud_claim_job(p_user uuid default null) returns jsonb language plpgsql set search_path='' as $$
declare j public.cloud_jobs; s public.cloud_settings; cost numeric:=0.10;
begin
  select * into j from public.cloud_jobs where (p_user is null or user_id=p_user)
    and ((status='pending' and available_at<=now()) or (status='running' and lease_until<now()))
    order by case when kind='purge_media' then 0 else 1 end,available_at for update skip locked limit 1;
  if not found then return null; end if;
  select * into s from public.cloud_settings where user_id=j.user_id for update;
  if j.kind<>'purge_media' then
    if not s.sync_enabled or not s.ai_enabled or (j.kind='daily' and not s.daily_enabled) then
      update public.cloud_jobs set status='blocked',error_code='PROCESSING_DISABLED',updated_at=now() where id=j.id; return null;
    end if;
    if j.kind='transcribe' then cost:=0.50; end if;
    if not exists(select 1 from cloud_private.provider_keys where user_id=j.user_id and provider=case when j.kind='transcribe' then 'openai' else s.provider end) then
      update public.cloud_jobs set status='blocked',error_code=case when j.kind='transcribe' or s.provider='openai' then 'OPENAI_KEY_REQUIRED' else 'OPENROUTER_KEY_REQUIRED' end,updated_at=now() where id=j.id;
      return null;
    end if;
    if j.attempts>=4 then update public.cloud_jobs set status='failed',error_code='RETRY_LIMIT',updated_at=now() where id=j.id; return null; end if;
    if (select count(*) from public.cloud_usage where user_id=j.user_id and created_at>=date_trunc('day',now()))>=s.daily_limit
      or coalesce((select sum(reserved_usd) from public.cloud_usage where user_id=j.user_id and created_at>=date_trunc('day',now())),0)+cost>s.daily_budget
      or coalesce((select sum(reserved_usd) from public.cloud_usage where user_id=j.user_id and created_at>=date_trunc('month',now())),0)+cost>s.monthly_budget then
      update public.cloud_jobs set status='blocked',error_code='BUDGET_LIMIT',updated_at=now() where id=j.id; return null;
    end if;
  end if;
  update public.cloud_jobs set status='running',attempts=attempts+1,lease_token=gen_random_uuid(),lease_until=now()+interval '3 minutes',updated_at=now(),error_code=null where id=j.id returning * into j;
  if j.kind<>'purge_media' then insert into public.cloud_usage(user_id,job_id,attempt,reserved_usd) values(j.user_id,j.id,j.attempts,cost); end if;
  return to_jsonb(j);
end $$;

-- Only the trusted backend can read or write Vault keys. The private implementation is not a Data API schema.;
