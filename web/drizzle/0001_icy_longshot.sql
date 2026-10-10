CREATE TABLE `journal_edits` (
	`id` text PRIMARY KEY NOT NULL,
	`session` text NOT NULL,
	`sealed` text NOT NULL,
	`status` text DEFAULT 'queued' NOT NULL,
	`result` text,
	`created` integer NOT NULL
);
--> statement-breakpoint
CREATE INDEX `idx_edits_session` ON `journal_edits` (`session`);