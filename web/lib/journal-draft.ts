export type JournalEntry={id:string;title?:string;text?:string;date?:string;revision?:string;kind?:string};
export type Pending={id:string;sealed:string;kind:'read'|'write';title:string;text:string};
export type Draft={id:string;title:string;text:string;base:string|null;dirty:boolean;pending?:Pending;status:string;conflict?:JournalEntry};
export function applyJournalReceipt(d:Draft,pending:Pending,status:string,result:{entry?:JournalEntry;error?:string}):Draft{
 if(status==='conflict')return {...d,pending:undefined,conflict:result.entry,status:'Changed on phone — choose a version'};
 if(status==='rejected')return {...d,pending:undefined,status:'Unavailable: '+(result.error||'Check your phone')};
 const entry=result.entry;if(!entry?.revision||entry.id!==d.id)throw Error('Invalid phone journal receipt.');
 if(status==='loaded')return {...d,title:entry.title||'',text:entry.text||'',base:entry.revision,dirty:false,pending:undefined,status:'Saved on phone'};
 if(status!=='saved')throw Error('Invalid phone save state.');
 const same=d.title===pending.title&&d.text===pending.text;
 return {...d,base:entry.revision,dirty:!same,pending:undefined,status:same?'Saved on phone':'Unsaved changes'};
}
