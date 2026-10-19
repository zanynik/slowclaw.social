import { DatabaseSync } from 'node:sqlite';
import { mkdirSync } from 'node:fs';
import { dirname } from 'node:path';
import { randomUUID, createHash } from 'node:crypto';

const now = () => new Date().toISOString();
const decode = (value) => JSON.parse(value);
const LIMIT = 100_000;

export class Store {
  constructor(filename) {
    if (filename !== ':memory:') mkdirSync(dirname(filename), { recursive: true, mode: 0o700 });
    this.db = new DatabaseSync(filename);
    this.db.exec('PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; PRAGMA foreign_keys=ON;');
    this.db.exec(`
      CREATE TABLE IF NOT EXISTS passages (
        id TEXT PRIMARY KEY, source TEXT NOT NULL, revision INTEGER NOT NULL,
        occurred_at TEXT NOT NULL, body TEXT NOT NULL, updated_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS jobs (
        id TEXT PRIMARY KEY, kind TEXT NOT NULL, payload TEXT NOT NULL,
        status TEXT NOT NULL CHECK(status IN ('queued','running','done','failed')),
        attempts INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL, result TEXT, error TEXT
      );
      CREATE TABLE IF NOT EXISTS proposals (
        id TEXT PRIMARY KEY, job_id TEXT NOT NULL REFERENCES jobs(id),
        kind TEXT NOT NULL, title TEXT NOT NULL, explanation TEXT NOT NULL,
        source_ids TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending'
          CHECK(status IN ('pending','accepted','rejected')),
        created_at TEXT NOT NULL, reviewed_at TEXT, signature TEXT UNIQUE
      );
      CREATE TABLE IF NOT EXISTS events (
        id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
        target_id TEXT NOT NULL, at TEXT NOT NULL, meta TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS schedules (
        kind TEXT PRIMARY KEY, interval_minutes INTEGER NOT NULL,
        enabled INTEGER NOT NULL, last_enqueued_at TEXT
      );
      INSERT OR IGNORE INTO schedules(kind,interval_minutes,enabled) VALUES ('discover-connections',1440,0);
    `);
  }
  close() { this.db.close(); }
  transaction(callback) {
    this.db.exec('BEGIN IMMEDIATE');
    try { const result = callback(); this.db.exec('COMMIT'); return result; }
    catch (error) { this.db.exec('ROLLBACK'); throw error; }
  }
  event(name, targetId, meta = {}) {
    this.db.prepare('INSERT INTO events(name,target_id,at,meta) VALUES (?,?,?,?)')
      .run(name,targetId,now(),JSON.stringify(meta));
  }
  importPassages(records) {
    if (!Array.isArray(records) || !records.length || records.length > 100) throw new Error('Expected 1–100 passages');
    return this.transaction(() => {
      let changed = 0;
      const get = this.db.prepare('SELECT revision, body, source, occurred_at FROM passages WHERE id=?');
      const put = this.db.prepare(`INSERT INTO passages(id,source,revision,occurred_at,body,updated_at)
        VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET source=excluded.source,
        revision=excluded.revision, occurred_at=excluded.occurred_at,
        body=excluded.body, updated_at=excluded.updated_at`);
      for (const p of records) {
        if (!p || typeof p.id !== 'string' || !/^[a-zA-Z0-9._:-]{1,120}$/.test(p.id)) throw new Error('Invalid passage id');
        if (typeof p.source !== 'string' || !/^[a-zA-Z0-9._:-]{1,120}$/.test(p.source)) throw new Error('Invalid source reference');
        if (!Number.isSafeInteger(p.revision) || p.revision < 1) throw new Error('Revision must be a positive integer');
        if (typeof p.body !== 'string' || !p.body.trim() || p.body.length > LIMIT) throw new Error('Invalid passage body');
        if (typeof p.occurred_at !== 'string' || !/^\d{4}-\d\d-\d\dT/.test(p.occurred_at) || Number.isNaN(Date.parse(p.occurred_at))) throw new Error('Invalid occurred_at timestamp');
        const old = get.get(p.id);
        if (old && old.revision > p.revision) throw new Error(`Stale revision for ${p.id}`);
        if (old && old.revision === p.revision) {
          if (old.body !== p.body || old.source !== p.source || old.occurred_at !== p.occurred_at) throw new Error(`Revision conflict for ${p.id}`);
          continue;
        }
        put.run(p.id,p.source,p.revision,p.occurred_at,p.body,now());
        this.event('passage.mirrored',p.id,{source:p.source,revision:p.revision});
        changed++;
      }
      if (changed) this.enqueue('discover-connections',{},true);
      return {changed, total:records.length};
    });
  }
  passages(ids) {
    if (ids) {
      const one=this.db.prepare('SELECT id,source,revision,occurred_at,body FROM passages WHERE id=?');
      return ids.map(id=>one.get(id)).filter(Boolean);
    }
    return this.db.prepare('SELECT id,source,revision,occurred_at,body FROM passages ORDER BY occurred_at DESC LIMIT 500').all();
  }
  enqueue(kind,payload = {},dedupe = false) {
    if (!['discover-connections','reflect'].includes(kind)) throw new Error('Unsupported job');
    if (dedupe) {
      const existing = this.db.prepare("SELECT id FROM jobs WHERE kind=? AND status='queued' LIMIT 1").get(kind);
      if (existing) return existing.id;
    }
    if (kind === 'reflect') {
      if (!payload || !Array.isArray(payload.source_ids) || payload.source_ids.length < 1 || payload.source_ids.length > 12 || payload.source_ids.some(x=>typeof x!=='string')) throw new Error('Reflection needs 1–12 source IDs');
      if (payload.allow_model_provider !== true) throw new Error('External/local model usage requires explicit approval');
    }
    const id=randomUUID(), t=now();
    this.db.prepare('INSERT INTO jobs(id,kind,payload,status,created_at,updated_at) VALUES(?,?,?,?,?,?)')
      .run(id,kind,JSON.stringify(payload),'queued',t,t);
    this.event('job.queued',id,{kind});
    return id;
  }
  recoverJobs() {
    this.transaction(()=>{
      this.db.prepare("UPDATE jobs SET status='queued', updated_at=? WHERE status='running' AND attempts<2").run(now());
      this.db.prepare("UPDATE jobs SET status='failed',error='Interrupted twice; manual retry required',updated_at=? WHERE status='running'").run(now());
    });
  }
  claim() {
    return this.transaction(()=>{
      const job = this.db.prepare("SELECT * FROM jobs WHERE status='queued' ORDER BY created_at,id LIMIT 1").get();
      if (!job) return null;
      this.db.prepare("UPDATE jobs SET status='running',attempts=attempts+1,updated_at=? WHERE id=?").run(now(),job.id);
      this.event('job.started',job.id,{kind:job.kind,attempt:job.attempts+1});
      return {...job,payload:decode(job.payload)};
    });
  }
  finish(job,result,proposals=[]) {
    this.transaction(()=>{
      const insert=this.db.prepare(`INSERT OR IGNORE INTO proposals(id,job_id,kind,title,explanation,source_ids,status,created_at,signature)
        VALUES(?,?,?,?,?,?,'pending',?,?)`);
      let saved=0;
      const revisions=this.db.prepare('SELECT revision FROM passages WHERE id=?');
      for (const p of proposals) {
        // Deterministic suggestions are shown once per exact source revision set.
        // Rejections persist across scheduled runs; edited sources can produce new suggestions.
        const signature=p.kind==='candidate-connection' ? createHash('sha256').update(JSON.stringify({
          kind:p.kind, sources:[...p.source_ids].sort().map(id=>[id,revisions.get(id)?.revision])
        })).digest('hex') : null;
        const result=insert.run(randomUUID(),job.id,p.kind,p.title,p.explanation,JSON.stringify(p.source_ids),now(),signature);
        saved+=Number(result.changes);
      }
      this.db.prepare("UPDATE jobs SET status='done',result=?,updated_at=? WHERE id=? AND status='running'")
        .run(JSON.stringify(result),now(),job.id);
      this.event('job.finished',job.id,{kind:job.kind,proposals:saved});
    });
  }
  fail(job,error) {
    this.transaction(()=>{
      this.db.prepare("UPDATE jobs SET status='failed',error=?,updated_at=? WHERE id=?").run(String(error).slice(0,240),now(),job.id);
      this.event('job.failed',job.id,{kind:job.kind});
    });
  }
  listJobs() { return this.db.prepare('SELECT id,kind,status,attempts,created_at,updated_at,error FROM jobs ORDER BY created_at DESC LIMIT 100').all(); }
  listProposals() {
    return this.db.prepare('SELECT * FROM proposals ORDER BY created_at DESC LIMIT 100').all().map(p=>({...p,source_ids:decode(p.source_ids)}));
  }
  decide(id,status) {
    if (!['accepted','rejected'].includes(status)) throw new Error('Invalid decision');
    return this.transaction(()=>{
      const p=this.db.prepare('SELECT id,status FROM proposals WHERE id=?').get(id);
      if (!p) throw new Error('Proposal not found');
      if (p.status!== 'pending') {
        if (p.status===status) return p;
        throw new Error('Proposal was already reviewed');
      }
      this.db.prepare('UPDATE proposals SET status=?,reviewed_at=? WHERE id=?').run(status,now(),id);
      this.event('proposal.reviewed',id,{status});
      return {id,status};
    });
  }
  listEvents() { return this.db.prepare('SELECT * FROM events ORDER BY id DESC LIMIT 100').all().map(e=>({...e,meta:decode(e.meta)})); }
  getSchedule() { return this.db.prepare("SELECT * FROM schedules WHERE kind='discover-connections'").get(); }
  updateSchedule({enabled,interval_minutes}) {
    if (typeof enabled!=='boolean' || !Number.isSafeInteger(interval_minutes) || interval_minutes < 60 || interval_minutes > 43200) throw new Error('Interval must be 60–43200 minutes');
    this.db.prepare('UPDATE schedules SET enabled=?,interval_minutes=? WHERE kind=?').run(enabled?1:0,interval_minutes,'discover-connections');
    this.event('schedule.updated','discover-connections',{enabled,interval_minutes});
    return this.getSchedule();
  }
  scheduleTick() {
    const s=this.getSchedule();
    if (!s.enabled) return false;
    if (s.last_enqueued_at && Date.now()-Date.parse(s.last_enqueued_at) < s.interval_minutes*60_000) return false;
    this.transaction(()=>{
      this.enqueue('discover-connections',{},true);
      this.db.prepare('UPDATE schedules SET last_enqueued_at=? WHERE kind=?').run(now(),s.kind);
    });
    return true;
  }
}
