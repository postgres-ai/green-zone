-- Revert green-zone:pgbench-accounts-index-bid from pg

begin;

drop index concurrently if exists bid_idx;

commit;
