-- Deploy green-zone:pgbench-accounts-index-bid to pg

create index concurrently bid_idx on pgbench_accounts(bid);
