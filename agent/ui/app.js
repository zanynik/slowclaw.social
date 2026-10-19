let token='';
const byId=id=>document.getElementById(id);
const error=message=>{byId('error').textContent=message||''};
async function api(path,method='GET',body){
  const response=await fetch(path,{method,headers:{Authorization:`Bearer ${token}`,...(body?{'Content-Type':'application/json'}:{})},...(body?{body:JSON.stringify(body)}:{})});
  const data=await response.json();
  if(!response.ok)throw new Error(data.error||`HTTP ${response.status}`);
  return data;
}
function node(tag,text,cls){const element=document.createElement(tag);element.textContent=text;if(cls)element.className=cls;return element}
async function refresh(){
  const [status,proposals,jobs,passages]=await Promise.all([
    api('/v1/status'),api('/v1/proposals'),api('/v1/jobs'),api('/v1/passages')
  ]);
  byId('status').textContent=`Pi ${status.pi_enabled?'enabled':'disabled'} · ${jobs.jobs.filter(j=>j.status==='queued').length} queued jobs`;
  byId('schedule-enabled').checked=!!status.schedule.enabled;
  byId('schedule-hours').value=status.schedule.interval_minutes/60;
  const proposalsRoot=byId('proposals');proposalsRoot.replaceChildren();
  for(const p of proposals.proposals){
    const item=node('article','', 'item');
    item.append(node('strong',p.title),node('p',p.explanation),node('small',`Source IDs: ${p.source_ids.join(', ')} · ${p.status}`));
    if(p.status==='pending')for(const decision of ['accepted','rejected']){
      const button=node('button',decision==='accepted'?'Accept':'Reject');
      button.addEventListener('click',()=>action(async()=>{await api(`/v1/proposals/${p.id}/decision`,'POST',{status:decision});await refresh()}));
      item.append(button);
    }
    proposalsRoot.append(item);
  }
  if(!proposals.proposals.length)proposalsRoot.append(node('p','No proposals yet. Add at least two related passages and run discovery.','muted'));
  const jobsRoot=byId('jobs');jobsRoot.replaceChildren();
  for(const j of jobs.jobs.slice(0,15))jobsRoot.append(node('div',`${j.kind}: ${j.status}${j.error?' · '+j.error:''}`,'item'));
  const passageRoot=byId('passages');passageRoot.replaceChildren();
  for(const p of passages.passages.slice(0,15)){
    const item=node('div','','item');item.append(node('small',`${p.id} · revision ${p.revision}`),node('p',p.body));passageRoot.append(item);
  }
}
async function action(fn){error('');try{await fn()}catch(e){error(e.message||String(e))}}
byId('login-button').addEventListener('click',()=>action(async()=>{
  token=byId('access-token').value.trim();await api('/v1/status');
  byId('access-token').value='';byId('login').hidden=true;byId('workspace').hidden=false;await refresh();
}));
byId('refresh').addEventListener('click',()=>action(refresh));
byId('run-discovery').addEventListener('click',()=>action(async()=>{await api('/v1/jobs','POST',{kind:'discover-connections'});await refresh()}));
byId('save-schedule').addEventListener('click',()=>action(async()=>{await api('/v1/schedule','PUT',{enabled:byId('schedule-enabled').checked,interval_minutes:Number(byId('schedule-hours').value)*60});await refresh()}));
byId('add-passage').addEventListener('click',()=>action(async()=>{
  const body=byId('passage-body').value;
  await api('/v1/passages','POST',{passages:[{id:`manual:${crypto.randomUUID()}`,source:'manual-entry',revision:1,occurred_at:new Date().toISOString(),body}]});
  byId('passage-body').value='';await refresh();
}));
byId('reflect').addEventListener('click',()=>action(async()=>{
  if(!byId('model-consent').checked)throw new Error('Explicit model-provider consent is required.');
  const source_ids=byId('source-ids').value.split(',').map(s=>s.trim()).filter(Boolean);
  await api('/v1/jobs','POST',{kind:'reflect',payload:{source_ids,allow_model_provider:true}});
  byId('model-consent').checked=false;await refresh();
}));
