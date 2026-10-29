-- Synthetic, rollback-only integration test. No mail or provider calls.
begin;
insert into auth.users(id,email,role,aud) values
 ('11111111-1111-4111-8111-111111111111','slowclaw_user_a@example.invalid','authenticated','authenticated'),
 ('22222222-2222-4222-8222-222222222222','slowclaw_user_b@example.invalid','authenticated','authenticated');
insert into public.cloud_settings(user_id,sync_enabled,ai_enabled,daily_enabled,daily_budget,monthly_budget) values
 ('11111111-1111-4111-8111-111111111111',true,true,true,10,50),
 ('22222222-2222-4222-8222-222222222222',true,true,true,10,50);
select public.cloud_provider_secret('11111111-1111-4111-8111-111111111111','openai','slowclaw_test_key_not_a_real_provider_key');
do $$
declare u uuid:='11111111-1111-4111-8111-111111111111'; r jsonb; j jsonb; j2 jsonb; committed boolean;
begin
  r:=public.cloud_save_entry(u,'journal_test','🌿 A meaningful journal entry.','Journal','text',now(),0,false);
  assert (r->>'ok')::boolean and (r->'entry'->>'revision')::integer=1,'initial save';
  r:=public.cloud_save_entry(u,'journal_test','🌿 A meaningful journal entry.','Journal','text',now(),0,false);
  assert (r->'entry'->>'revision')::integer=1,'lost receipt retry must not duplicate';
  r:=public.cloud_save_entry(u,'journal_test','Changed on another device.','Journal','text',now(),1,false);
  assert (r->'entry'->>'revision')::integer=2,'revision advances';
  assert exists(select 1 from public.cloud_entry_history where user_id=u and id='journal_test' and revision=1 and text='🌿 A meaningful journal entry.'),'exact old source retained';
  r:=public.cloud_save_entry(u,'journal_test','Conflicting local edit.','Journal','text',now(),1,false);
  assert not (r->>'ok')::boolean and r->'conflict'->>'text'='Changed on another device.','stale write returns remote conflict';
  j:=public.cloud_claim_job(u);
  assert j->>'kind'='analyze' and j->>'status'='running','claim leases one job';
  assert public.cloud_claim_job(u) is null,'active lease cannot be claimed twice';
  r:=public.cloud_save_entry(u,'journal_test','A newer source revision.','Journal','text',now(),2,false);
  committed:=public.cloud_commit_analysis((j->>'id')::uuid,(j->>'lease_token')::uuid,2,'[{"kind":"summary","title":"Old result","body":{"text":"Stale"}}]','[]','test-model');
  assert not committed,'edit cancels stale AI completion';
  j2:=public.cloud_claim_job(u);
  committed:=public.cloud_commit_analysis((j2->>'id')::uuid,(j2->>'lease_token')::uuid,3,'[{"kind":"summary","title":"Summary","body":{"text":"Reviewable result"}}]','[]','test-model');
  assert committed,'current leased result commits';
  assert exists(select 1 from public.cloud_artifacts where user_id=u and title='Summary'),'artifact stored';
  insert into public.cloud_reads(user_id,url,title,source,reason,sources,read_at) values
    (u,'https://example.com/article','Public article','Test source','Explanation tied to this journal','[{"id":"journal_test","revision":3}]',now());
  r:=public.cloud_save_entry(u,'journal_test','','','text',now(),3,true);
  assert (r->>'ok')::boolean,'deletion acknowledged';
  assert not exists(select 1 from public.cloud_entry_history where user_id=u and id='journal_test'),'deletion removes archived private text';
  assert not exists(select 1 from public.cloud_artifacts where user_id=u),'source-derived artifacts removed';
  assert exists(select 1 from public.cloud_reads where user_id=u and reason='' and read_at is not null),'recommendation and read status preserved; private explanation redacted';
  r:=public.cloud_save_entry(u,'journal_test','','','text',now(),3,true);
  assert (r->>'ok')::boolean,'deletion lost receipt is idempotent';
  assert not has_function_privilege('authenticated','public.cloud_provider_secret(uuid,text,text,boolean)','execute'),'Vault RPC denied to ordinary users';
  assert not has_function_privilege('anon','public.cloud_claim_job(uuid)','execute'),'job claim denied anonymously';
  -- Explicit leases exercise consent guards without making provider calls.
  r:=public.cloud_save_entry(u,'transcript_test','','Audio','audio',now(),0,false);
  insert into public.cloud_jobs(user_id,kind,entry_id,input_hash,status,lease_token,lease_until)
    values(u,'transcribe','transcript_test','test_transcript','running',gen_random_uuid(),now()+interval '5 minutes') returning to_jsonb(cloud_jobs.*) into j;
  update public.cloud_settings set ai_enabled=false where user_id=u;
  assert not public.cloud_commit_transcript((j->>'id')::uuid,(j->>'lease_token')::uuid,1,'Must not overwrite after consent revoked'),'revoked AI consent discards transcript';
  assert (select text='' from public.cloud_entries where user_id=u and id='transcript_test'),'revoked transcript leaves source unchanged';
  update public.cloud_settings set ai_enabled=true where user_id=u;
  update public.cloud_jobs set status='running' where id=(j->>'id')::uuid;
  assert public.cloud_commit_transcript((j->>'id')::uuid,(j->>'lease_token')::uuid,1,'Synthetic verified transcript'),'current consent and lease allow atomic transcript';
  assert (select text='Synthetic verified transcript' and revision=2 from public.cloud_entries where user_id=u and id='transcript_test'),'transcript advances source revision';
  update public.cloud_jobs set status='cancelled' where user_id=u and status='pending' and entry_id='transcript_test';
  assert not has_function_privilege('authenticated','public.cloud_phone_user(text)','execute'),'phone identity lookup denied to clients';
  assert not has_function_privilege('anon','public.cloud_phone_claim(text,text,bigint)','execute'),'anonymous phone proof insertion denied';
  perform public.cloud_phone_claim(repeat('a',64),repeat('b',64),extract(epoch from now())::bigint);
  begin
    perform public.cloud_phone_claim(repeat('a',64),repeat('b',64),extract(epoch from now())::bigint);
    raise exception 'replay accepted';
  exception when unique_violation then null;
  end;
  update public.cloud_settings set daily_budget=0 where user_id=u;
  insert into public.cloud_jobs(user_id,kind,input_hash) values(u,'daily','test_day');
  -- First claim performs deletion maintenance, which remains allowed when AI budget is zero.
  j:=public.cloud_claim_job(u);
  assert j->>'kind'='purge_media','deletion maintenance is not blocked by AI budget';
  update public.cloud_jobs set status='completed' where id=(j->>'id')::uuid;
  assert public.cloud_claim_job(u) is null,'zero budget blocks provider work';
  assert exists(select 1 from public.cloud_jobs where user_id=u and kind='daily' and status='blocked' and error_code='BUDGET_LIMIT'),'budget block is visible';
end $$;
select set_config('request.jwt.claims','{"sub":"22222222-2222-4222-8222-222222222222","role":"authenticated"}',true);
set local role authenticated;
do $$ begin
  assert (select count(*) from public.cloud_entries)=0,'another account cannot read journal rows';
  assert (select count(*) from public.cloud_artifacts)=0,'another account cannot read generated content';
  assert (select count(*) from public.cloud_reads)=0,'another account cannot read recommendations';
  assert (select count(*) from public.cloud_usage)=0,'another account cannot read usage';
end $$;
reset role;
rollback;
