-- Revert green-zone:pgbench-accounts-index-bid from pg

drop index concurrently if exists bid_idx;
