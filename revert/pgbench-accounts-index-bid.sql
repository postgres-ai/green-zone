-- Revert green-zone:pgbench-accounts-index-bid from pg

begin;

drop index if exists bid_idx;

commit;
