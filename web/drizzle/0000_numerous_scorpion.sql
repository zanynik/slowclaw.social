CREATE TABLE `proofs` (
	`id` text PRIMARY KEY NOT NULL,
	`session` text NOT NULL
);
--> statement-breakpoint
CREATE TABLE `sessions` (
	`id` text PRIMARY KEY NOT NULL,
	`browser_hash` text NOT NULL,
	`pair_hash` text NOT NULL,
	`pubkey` text,
	`created` integer NOT NULL,
	`expires` integer NOT NULL,
	`closed` integer DEFAULT 0 NOT NULL,
	`snapshot` text,
	`updated` integer
);
--> statement-breakpoint
CREATE INDEX `idx_sessions_expires` ON `sessions` (`expires`);--> statement-breakpoint
CREATE TABLE `transfers` (
	`id` text PRIMARY KEY NOT NULL,
	`session` text NOT NULL,
	`meta` text NOT NULL,
	`bytes` integer NOT NULL,
	`status` text NOT NULL,
	`created` integer NOT NULL
);
--> statement-breakpoint
CREATE INDEX `idx_transfers_session` ON `transfers` (`session`);