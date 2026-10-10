import { sqliteTable, text, integer, index } from 'drizzle-orm/sqlite-core';
export const sessions = sqliteTable('sessions', {
 id:text('id').primaryKey(), browserHash:text('browser_hash').notNull(), pairHash:text('pair_hash').notNull(),
 pubkey:text('pubkey'), created:integer('created').notNull(), expires:integer('expires').notNull(),
 closed:integer('closed').notNull().default(0), snapshot:text('snapshot'), updated:integer('updated'),
}, t=>[index('idx_sessions_expires').on(t.expires)]);
export const transfers = sqliteTable('transfers', {
 id:text('id').primaryKey(), session:text('session').notNull(), meta:text('meta').notNull(), bytes:integer('bytes').notNull(),
 status:text('status').notNull(), created:integer('created').notNull(),
},t=>[index('idx_transfers_session').on(t.session)]);
export const proofs = sqliteTable('proofs', {id:text('id').primaryKey(), session:text('session').notNull()});
export const edits = sqliteTable('journal_edits', {
 id:text('id').primaryKey(), session:text('session').notNull(), sealed:text('sealed').notNull(),
 status:text('status').notNull().default('queued'), result:text('result'), created:integer('created').notNull(),
},t=>[index('idx_edits_session').on(t.session)]);
