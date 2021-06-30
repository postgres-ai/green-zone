-- Deploy green-zone:initial to pg

BEGIN;

--
-- PostgreSQL database dump
--

-- Dumped from database version 12.2 (Ubuntu 12.2-2.pgdg18.04+1)
-- Dumped by pg_dump version 12.2 (Ubuntu 12.2-2.pgdg18.04+1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: metric_helpers; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA metric_helpers;


ALTER SCHEMA metric_helpers OWNER TO postgres;

--
-- Name: user_management; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA user_management;


ALTER SCHEMA user_management OWNER TO postgres;

--
-- Name: pg_stat_statements; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_stat_statements WITH SCHEMA public;


--
-- Name: EXTENSION pg_stat_statements; Type: COMMENT; Schema: -; Owner:
--

COMMENT ON EXTENSION pg_stat_statements IS 'track execution statistics of all SQL statements executed';


--
-- Name: pg_stat_kcache; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_stat_kcache WITH SCHEMA public;


--
-- Name: EXTENSION pg_stat_kcache; Type: COMMENT; Schema: -; Owner:
--

COMMENT ON EXTENSION pg_stat_kcache IS 'Kernel statistics gathering';


--
-- Name: set_user; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS set_user WITH SCHEMA public;


--
-- Name: EXTENSION set_user; Type: COMMENT; Schema: -; Owner:
--

COMMENT ON EXTENSION set_user IS 'similar to SET ROLE but with added logging';


--
-- Name: get_btree_bloat_approx(); Type: FUNCTION; Schema: metric_helpers; Owner: postgres
--

CREATE FUNCTION metric_helpers.get_btree_bloat_approx(OUT i_database name, OUT i_schema_name name, OUT i_table_name name, OUT i_index_name name, OUT i_real_size numeric, OUT i_extra_size numeric, OUT i_extra_ratio double precision, OUT i_fill_factor integer, OUT i_bloat_size double precision, OUT i_bloat_ratio double precision, OUT i_is_na boolean) RETURNS SETOF record
  LANGUAGE sql IMMUTABLE STRICT SECURITY DEFINER
  SET search_path TO 'pg_catalog'
AS $$
SELECT current_database(), nspname AS schemaname, tblname, idxname, bs*(relpages)::bigint AS real_size,
       bs*(relpages-est_pages)::bigint AS extra_size,
       100 * (relpages-est_pages)::float / relpages AS extra_ratio,
       fillfactor,
       CASE WHEN relpages > est_pages_ff
              THEN bs*(relpages-est_pages_ff)
            ELSE 0
         END AS bloat_size,
       100 * (relpages-est_pages_ff)::float / relpages AS bloat_ratio,
       is_na
       -- , 100-(pst).avg_leaf_density AS pst_avg_bloat, est_pages, index_tuple_hdr_bm, maxalign, pagehdr, nulldatawidth, nulldatahdrwidth, reltuples, relpages -- (DEBUG INFO)
FROM (
       SELECT coalesce(1 +
                       ceil(reltuples/floor((bs-pageopqdata-pagehdr)/(4+nulldatahdrwidth)::float)), 0 -- ItemIdData size + computed avg size of a tuple (nulldatahdrwidth)
                ) AS est_pages,
              coalesce(1 +
                       ceil(reltuples/floor((bs-pageopqdata-pagehdr)*fillfactor/(100*(4+nulldatahdrwidth)::float))), 0
                ) AS est_pages_ff,
              bs, nspname, tblname, idxname, relpages, fillfactor, is_na
              -- , pgstatindex(idxoid) AS pst, index_tuple_hdr_bm, maxalign, pagehdr, nulldatawidth, nulldatahdrwidth, reltuples -- (DEBUG INFO)
       FROM (
              SELECT maxalign, bs, nspname, tblname, idxname, reltuples, relpages, idxoid, fillfactor,
                     ( index_tuple_hdr_bm +
                       maxalign - CASE -- Add padding to the index tuple header to align on MAXALIGN
                                    WHEN index_tuple_hdr_bm%maxalign = 0 THEN maxalign
                                    ELSE index_tuple_hdr_bm%maxalign
                         END
                         + nulldatawidth + maxalign - CASE -- Add padding to the data to align on MAXALIGN
                                                        WHEN nulldatawidth = 0 THEN 0
                                                        WHEN nulldatawidth::integer%maxalign = 0 THEN maxalign
                                                        ELSE nulldatawidth::integer%maxalign
                         END
                       )::numeric AS nulldatahdrwidth, pagehdr, pageopqdata, is_na
                     -- , index_tuple_hdr_bm, nulldatawidth -- (DEBUG INFO)
              FROM (
                     SELECT n.nspname, ct.relname AS tblname, i.idxname, i.reltuples, i.relpages,
                            i.idxoid, i.fillfactor, current_setting('block_size')::numeric AS bs,
                            CASE -- MAXALIGN: 4 on 32bits, 8 on 64bits (and mingw32 ?)
                              WHEN version() ~ 'mingw32' OR version() ~ '64-bit|x86_64|ppc64|ia64|amd64' THEN 8
                              ELSE 4
                              END AS maxalign,
                       /* per page header, fixed size: 20 for 7.X, 24 for others */
                            24 AS pagehdr,
                       /* per page btree opaque data */
                            16 AS pageopqdata,
                       /* per tuple header: add IndexAttributeBitMapData if some cols are null-able */
                            CASE WHEN max(coalesce(s.stanullfrac,0)) = 0
                                   THEN 2 -- IndexTupleData size
                                 ELSE 2 + (( 32 + 8 - 1 ) / 8) -- IndexTupleData size + IndexAttributeBitMapData size ( max num filed per index + 8 - 1 /8)
                              END AS index_tuple_hdr_bm,
                       /* data len: we remove null values save space using it fractionnal part from stats */
                            sum( (1-coalesce(s.stanullfrac, 0)) * coalesce(s.stawidth, 1024)) AS nulldatawidth,
                            max( CASE WHEN a.atttypid = 'pg_catalog.name'::regtype THEN 1 ELSE 0 END ) > 0 AS is_na
                     FROM (
                            SELECT idxname, reltuples, relpages, tbloid, idxoid, fillfactor,
                                   CASE WHEN indkey[i]=0 THEN idxoid ELSE tbloid END AS att_rel,
                                   CASE WHEN indkey[i]=0 THEN i ELSE indkey[i] END AS att_pos
                            FROM (
                                   SELECT idxname, reltuples, relpages, tbloid, idxoid, fillfactor, indkey, generate_series(1,indnatts) AS i
                                   FROM (
                                          SELECT ci.relname AS idxname, ci.reltuples, ci.relpages, i.indrelid AS tbloid,
                                                 i.indexrelid AS idxoid,
                                                 coalesce(substring(
                                                            array_to_string(ci.reloptions, ' ')
                                                            from 'fillfactor=([0-9]+)')::smallint, 90) AS fillfactor,
                                                 i.indnatts,
                                                 string_to_array(textin(int2vectorout(i.indkey)),' ')::int[] AS indkey
                                          FROM pg_index i
                                               JOIN pg_class ci ON ci.oid=i.indexrelid
                                          WHERE ci.relam=(SELECT oid FROM pg_am WHERE amname = 'btree')
                                          AND ci.relpages > 0
                                        ) AS idx_data
                                 ) AS idx_data_cross
                          ) i
                          JOIN pg_attribute a ON a.attrelid = i.att_rel
                       AND a.attnum = i.att_pos
                          JOIN pg_statistic s ON s.starelid = i.att_rel
                       AND s.staattnum = i.att_pos
                          JOIN pg_class ct ON ct.oid = i.tbloid
                          JOIN pg_namespace n ON ct.relnamespace = n.oid
                     GROUP BY 1,2,3,4,5,6,7,8,9,10
                   ) AS rows_data_stats
            ) AS rows_hdr_pdg_stats
     ) AS relation_stats;
$$;


ALTER FUNCTION metric_helpers.get_btree_bloat_approx(OUT i_database name, OUT i_schema_name name, OUT i_table_name name, OUT i_index_name name, OUT i_real_size numeric, OUT i_extra_size numeric, OUT i_extra_ratio double precision, OUT i_fill_factor integer, OUT i_bloat_size double precision, OUT i_bloat_ratio double precision, OUT i_is_na boolean) OWNER TO postgres;

--
-- Name: get_table_bloat_approx(); Type: FUNCTION; Schema: metric_helpers; Owner: postgres
--

CREATE FUNCTION metric_helpers.get_table_bloat_approx(OUT t_database name, OUT t_schema_name name, OUT t_table_name name, OUT t_real_size numeric, OUT t_extra_size double precision, OUT t_extra_ratio double precision, OUT t_fill_factor integer, OUT t_bloat_size double precision, OUT t_bloat_ratio double precision, OUT t_is_na boolean) RETURNS SETOF record
  LANGUAGE sql IMMUTABLE STRICT SECURITY DEFINER
  SET search_path TO 'pg_catalog'
AS $$
SELECT
  current_database(),
  schemaname,
  tblname,
  (bs*tblpages) AS real_size,
  ((tblpages-est_tblpages)*bs) AS extra_size,
  CASE WHEN tblpages - est_tblpages > 0
         THEN 100 * (tblpages - est_tblpages)/tblpages::float
       ELSE 0
    END AS extra_ratio,
  fillfactor,
  CASE WHEN tblpages - est_tblpages_ff > 0
         THEN (tblpages-est_tblpages_ff)*bs
       ELSE 0
    END AS bloat_size,
  CASE WHEN tblpages - est_tblpages_ff > 0
         THEN 100 * (tblpages - est_tblpages_ff)/tblpages::float
       ELSE 0
    END AS bloat_ratio,
  is_na
FROM (
       SELECT ceil( reltuples / ( (bs-page_hdr)/tpl_size ) ) + ceil( toasttuples / 4 ) AS est_tblpages,
              ceil( reltuples / ( (bs-page_hdr)*fillfactor/(tpl_size*100) ) ) + ceil( toasttuples / 4 ) AS est_tblpages_ff,
              tblpages, fillfactor, bs, tblid, schemaname, tblname, heappages, toastpages, is_na
              -- , tpl_hdr_size, tpl_data_size, pgstattuple(tblid) AS pst -- (DEBUG INFO)
       FROM (
              SELECT
                ( 4 + tpl_hdr_size + tpl_data_size + (2*ma)
                  - CASE WHEN tpl_hdr_size%ma = 0 THEN ma ELSE tpl_hdr_size%ma END
                  - CASE WHEN ceil(tpl_data_size)::int%ma = 0 THEN ma ELSE ceil(tpl_data_size)::int%ma END
                  ) AS tpl_size, bs - page_hdr AS size_per_block, (heappages + toastpages) AS tblpages, heappages,
                toastpages, reltuples, toasttuples, bs, page_hdr, tblid, schemaname, tblname, fillfactor, is_na
                -- , tpl_hdr_size, tpl_data_size
              FROM (
                     SELECT
                       tbl.oid AS tblid, ns.nspname AS schemaname, tbl.relname AS tblname, tbl.reltuples,
                       tbl.relpages AS heappages, coalesce(toast.relpages, 0) AS toastpages,
                       coalesce(toast.reltuples, 0) AS toasttuples,
                       coalesce(substring(
                                  array_to_string(tbl.reloptions, ' ')
                                  FROM 'fillfactor=([0-9]+)')::smallint, 100) AS fillfactor,
                       current_setting('block_size')::numeric AS bs,
                       CASE WHEN version()~'mingw32' OR version()~'64-bit|x86_64|ppc64|ia64|amd64' THEN 8 ELSE 4 END AS ma,
                       24 AS page_hdr,
                       23 + CASE WHEN MAX(coalesce(s.null_frac,0)) > 0 THEN ( 7 + count(s.attname) ) / 8 ELSE 0::int END
                         + CASE WHEN bool_or(att.attname = 'oid' and att.attnum < 0) THEN 4 ELSE 0 END AS tpl_hdr_size,
                       sum( (1-coalesce(s.null_frac, 0)) * coalesce(s.avg_width, 0) ) AS tpl_data_size,
                       bool_or(att.atttypid = 'pg_catalog.name'::regtype)
                         OR sum(CASE WHEN att.attnum > 0 THEN 1 ELSE 0 END) <> count(s.attname) AS is_na
                     FROM pg_attribute AS att
                          JOIN pg_class AS tbl ON att.attrelid = tbl.oid
                          JOIN pg_namespace AS ns ON ns.oid = tbl.relnamespace
                          LEFT JOIN pg_stats AS s ON s.schemaname=ns.nspname
                       AND s.tablename = tbl.relname AND s.inherited=false AND s.attname=att.attname
                          LEFT JOIN pg_class AS toast ON tbl.reltoastrelid = toast.oid
                     WHERE NOT att.attisdropped
                     AND tbl.relkind = 'r'
                     GROUP BY 1,2,3,4,5,6,7,8,9,10
                     ORDER BY 2,3
                   ) AS s
            ) AS s2
     ) AS s3 WHERE schemaname NOT LIKE 'information_schema';
$$;


ALTER FUNCTION metric_helpers.get_table_bloat_approx(OUT t_database name, OUT t_schema_name name, OUT t_table_name name, OUT t_real_size numeric, OUT t_extra_size double precision, OUT t_extra_ratio double precision, OUT t_fill_factor integer, OUT t_bloat_size double precision, OUT t_bloat_ratio double precision, OUT t_is_na boolean) OWNER TO postgres;

--
-- Name: pg_stat_statements(boolean); Type: FUNCTION; Schema: metric_helpers; Owner: postgres
--

CREATE FUNCTION metric_helpers.pg_stat_statements(showtext boolean) RETURNS SETOF public.pg_stat_statements
  LANGUAGE sql IMMUTABLE STRICT SECURITY DEFINER
AS $$
SELECT * FROM public.pg_stat_statements(showtext);
$$;


ALTER FUNCTION metric_helpers.pg_stat_statements(showtext boolean) OWNER TO postgres;

--
-- Name: create_application_user(text); Type: FUNCTION; Schema: user_management; Owner: postgres
--

CREATE FUNCTION user_management.create_application_user(username text) RETURNS text
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path TO 'pg_catalog'
AS $_$
DECLARE
  pw text;
BEGIN
  SELECT user_management.random_password(20) INTO pw;
  EXECUTE format($$ CREATE USER %I WITH PASSWORD %L $$, username, pw);
  RETURN pw;
END
$_$;


ALTER FUNCTION user_management.create_application_user(username text) OWNER TO postgres;

--
-- Name: FUNCTION create_application_user(username text); Type: COMMENT; Schema: user_management; Owner: postgres
--

COMMENT ON FUNCTION user_management.create_application_user(username text) IS 'Creates a user that can login, sets the password to a strong random one,
which is then returned';


--
-- Name: create_application_user_or_change_password(text, text); Type: FUNCTION; Schema: user_management; Owner: postgres
--

CREATE FUNCTION user_management.create_application_user_or_change_password(username text, password text) RETURNS void
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path TO 'pg_catalog'
AS $_$
BEGIN
  PERFORM 1 FROM pg_roles WHERE rolname = username;

  IF FOUND
  THEN
    EXECUTE format($$ ALTER ROLE %I WITH PASSWORD %L $$, username, password);
  ELSE
    EXECUTE format($$ CREATE USER %I WITH PASSWORD %L $$, username, password);
  END IF;
END
$_$;


ALTER FUNCTION user_management.create_application_user_or_change_password(username text, password text) OWNER TO postgres;

--
-- Name: FUNCTION create_application_user_or_change_password(username text, password text); Type: COMMENT; Schema: user_management; Owner: postgres
--

COMMENT ON FUNCTION user_management.create_application_user_or_change_password(username text, password text) IS 'USE THIS ONLY IN EMERGENCY!  The password will appear in the DB logs.
Creates a user that can login, sets the password to the one provided.
If the user already exists, sets its password.';


--
-- Name: create_role(text); Type: FUNCTION; Schema: user_management; Owner: postgres
--

CREATE FUNCTION user_management.create_role(rolename text) RETURNS void
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path TO 'pg_catalog'
AS $_$
BEGIN
  -- set ADMIN to the admin user, so every member of admin can GRANT these roles to each other
  EXECUTE format($$ CREATE ROLE %I WITH ADMIN admin $$, rolename);
END;
$_$;


ALTER FUNCTION user_management.create_role(rolename text) OWNER TO postgres;

--
-- Name: FUNCTION create_role(rolename text); Type: COMMENT; Schema: user_management; Owner: postgres
--

COMMENT ON FUNCTION user_management.create_role(rolename text) IS 'Creates a role that cannot log in, but can be used to set up fine-grained privileges';


--
-- Name: create_user(text); Type: FUNCTION; Schema: user_management; Owner: postgres
--

CREATE FUNCTION user_management.create_user(username text) RETURNS void
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path TO 'pg_catalog'
AS $_$
BEGIN
  EXECUTE format($$ CREATE USER %I IN ROLE zalandos, admin $$, username);
  EXECUTE format($$ ALTER ROLE %I SET log_statement TO 'all' $$, username);
END;
$_$;


ALTER FUNCTION user_management.create_user(username text) OWNER TO postgres;

--
-- Name: FUNCTION create_user(username text); Type: COMMENT; Schema: user_management; Owner: postgres
--

COMMENT ON FUNCTION user_management.create_user(username text) IS 'Creates a user that is supposed to be a human, to be authenticated without a password';


--
-- Name: drop_role(text); Type: FUNCTION; Schema: user_management; Owner: postgres
--

CREATE FUNCTION user_management.drop_role(username text) RETURNS void
  LANGUAGE sql SECURITY DEFINER
  SET search_path TO 'pg_catalog'
AS $$
SELECT user_management.drop_user(username);
$$;


ALTER FUNCTION user_management.drop_role(username text) OWNER TO postgres;

--
-- Name: FUNCTION drop_role(username text); Type: COMMENT; Schema: user_management; Owner: postgres
--

COMMENT ON FUNCTION user_management.drop_role(username text) IS 'Drop a human or application user.  Intended for cleanup (either after team changes or mistakes in role setup).
Roles (= users) that own database objects cannot be dropped.';


--
-- Name: drop_user(text); Type: FUNCTION; Schema: user_management; Owner: postgres
--

CREATE FUNCTION user_management.drop_user(username text) RETURNS void
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path TO 'pg_catalog'
AS $_$
BEGIN
  EXECUTE format($$ DROP ROLE %I $$, username);
END
$_$;


ALTER FUNCTION user_management.drop_user(username text) OWNER TO postgres;

--
-- Name: FUNCTION drop_user(username text); Type: COMMENT; Schema: user_management; Owner: postgres
--

COMMENT ON FUNCTION user_management.drop_user(username text) IS 'Drop a human or application user.  Intended for cleanup (either after team changes or mistakes in role setup).
Roles (= users) that own database objects cannot be dropped.';


--
-- Name: random_password(integer); Type: FUNCTION; Schema: user_management; Owner: postgres
--

CREATE FUNCTION user_management.random_password(length integer) RETURNS text
  LANGUAGE sql
  SET search_path TO 'pg_catalog'
AS $$
WITH chars (c) AS (
  SELECT chr(33)
  UNION ALL
  SELECT chr(i) FROM generate_series (35, 38) AS t (i)
  UNION ALL
  SELECT chr(i) FROM generate_series (42, 90) AS t (i)
  UNION ALL
  SELECT chr(i) FROM generate_series (97, 122) AS t (i)
),
     bricks (b) AS (
       -- build a pool of chars (the size will be the number of chars above times length)
       -- and shuffle it
       SELECT c FROM chars, generate_series(1, length) ORDER BY random()
     )
SELECT substr(string_agg(b, ''), 1, length) FROM bricks;
$$;


ALTER FUNCTION user_management.random_password(length integer) OWNER TO postgres;

--
-- Name: revoke_admin(text); Type: FUNCTION; Schema: user_management; Owner: postgres
--

CREATE FUNCTION user_management.revoke_admin(username text) RETURNS void
  LANGUAGE plpgsql SECURITY DEFINER
  SET search_path TO 'pg_catalog'
AS $_$
BEGIN
  EXECUTE format($$ REVOKE admin FROM %I $$, username);
END
$_$;


ALTER FUNCTION user_management.revoke_admin(username text) OWNER TO postgres;

--
-- Name: FUNCTION revoke_admin(username text); Type: COMMENT; Schema: user_management; Owner: postgres
--

COMMENT ON FUNCTION user_management.revoke_admin(username text) IS 'Use this function to make a human user less privileged,
ie. when you want to grant someone read privileges only';


--
-- Name: terminate_backend(integer); Type: FUNCTION; Schema: user_management; Owner: postgres
--

CREATE FUNCTION user_management.terminate_backend(pid integer) RETURNS boolean
  LANGUAGE sql SECURITY DEFINER
  SET search_path TO 'pg_catalog'
AS $$
SELECT pg_terminate_backend(pid);
$$;


ALTER FUNCTION user_management.terminate_backend(pid integer) OWNER TO postgres;

--
-- Name: FUNCTION terminate_backend(pid integer); Type: COMMENT; Schema: user_management; Owner: postgres
--

COMMENT ON FUNCTION user_management.terminate_backend(pid integer) IS 'When there is a process causing harm, you can kill it using this function.  Get the pid from pg_stat_activity
(be careful to match the user name (usename) and the query, in order not to kill innocent kittens) and pass it to terminate_backend()';


--
-- Name: index_bloat; Type: VIEW; Schema: metric_helpers; Owner: postgres
--

CREATE VIEW metric_helpers.index_bloat AS
SELECT get_btree_bloat_approx.i_database,
       get_btree_bloat_approx.i_schema_name,
       get_btree_bloat_approx.i_table_name,
       get_btree_bloat_approx.i_index_name,
       get_btree_bloat_approx.i_real_size,
       get_btree_bloat_approx.i_extra_size,
       get_btree_bloat_approx.i_extra_ratio,
       get_btree_bloat_approx.i_fill_factor,
       get_btree_bloat_approx.i_bloat_size,
       get_btree_bloat_approx.i_bloat_ratio,
       get_btree_bloat_approx.i_is_na
FROM metric_helpers.get_btree_bloat_approx() get_btree_bloat_approx(i_database, i_schema_name, i_table_name, i_index_name, i_real_size, i_extra_size, i_extra_ratio, i_fill_factor, i_bloat_size, i_bloat_ratio, i_is_na);


ALTER TABLE metric_helpers.index_bloat OWNER TO postgres;

--
-- Name: pg_stat_statements; Type: VIEW; Schema: metric_helpers; Owner: postgres
--

CREATE VIEW metric_helpers.pg_stat_statements AS
SELECT pg_stat_statements.userid,
       pg_stat_statements.dbid,
       pg_stat_statements.queryid,
       pg_stat_statements.query,
       pg_stat_statements.calls,
       pg_stat_statements.total_time,
       pg_stat_statements.min_time,
       pg_stat_statements.max_time,
       pg_stat_statements.mean_time,
       pg_stat_statements.stddev_time,
       pg_stat_statements.rows,
       pg_stat_statements.shared_blks_hit,
       pg_stat_statements.shared_blks_read,
       pg_stat_statements.shared_blks_dirtied,
       pg_stat_statements.shared_blks_written,
       pg_stat_statements.local_blks_hit,
       pg_stat_statements.local_blks_read,
       pg_stat_statements.local_blks_dirtied,
       pg_stat_statements.local_blks_written,
       pg_stat_statements.temp_blks_read,
       pg_stat_statements.temp_blks_written,
       pg_stat_statements.blk_read_time,
       pg_stat_statements.blk_write_time
FROM metric_helpers.pg_stat_statements(true) pg_stat_statements(userid, dbid, queryid, query, calls, total_time, min_time, max_time, mean_time, stddev_time, rows, shared_blks_hit, shared_blks_read, shared_blks_dirtied, shared_blks_written, local_blks_hit, local_blks_read, local_blks_dirtied, local_blks_written, temp_blks_read, temp_blks_written, blk_read_time, blk_write_time);


ALTER TABLE metric_helpers.pg_stat_statements OWNER TO postgres;

--
-- Name: table_bloat; Type: VIEW; Schema: metric_helpers; Owner: postgres
--

CREATE VIEW metric_helpers.table_bloat AS
SELECT get_table_bloat_approx.t_database,
       get_table_bloat_approx.t_schema_name,
       get_table_bloat_approx.t_table_name,
       get_table_bloat_approx.t_real_size,
       get_table_bloat_approx.t_extra_size,
       get_table_bloat_approx.t_extra_ratio,
       get_table_bloat_approx.t_fill_factor,
       get_table_bloat_approx.t_bloat_size,
       get_table_bloat_approx.t_bloat_ratio,
       get_table_bloat_approx.t_is_na
FROM metric_helpers.get_table_bloat_approx() get_table_bloat_approx(t_database, t_schema_name, t_table_name, t_real_size, t_extra_size, t_extra_ratio, t_fill_factor, t_bloat_size, t_bloat_ratio, t_is_na);


ALTER TABLE metric_helpers.table_bloat OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: pgbench_accounts; Type: TABLE; Schema: public; Owner: demo
--

CREATE TABLE public.pgbench_accounts (
                                       aid integer NOT NULL,
                                       bid integer,
                                       abalance integer,
                                       filler character(84)
)
  WITH (fillfactor='100');


ALTER TABLE public.pgbench_accounts OWNER TO demo;

--
-- Name: pgbench_branches; Type: TABLE; Schema: public; Owner: demo
--

CREATE TABLE public.pgbench_branches (
                                       bid integer NOT NULL,
                                       bbalance integer,
                                       filler character(88)
)
  WITH (fillfactor='100');


ALTER TABLE public.pgbench_branches OWNER TO demo;

--
-- Name: pgbench_history; Type: TABLE; Schema: public; Owner: demo
--

CREATE TABLE public.pgbench_history (
                                      tid integer,
                                      bid integer,
                                      aid integer,
                                      delta integer,
                                      mtime timestamp without time zone,
                                      filler character(22)
);


ALTER TABLE public.pgbench_history OWNER TO demo;

--
-- Name: pgbench_tellers; Type: TABLE; Schema: public; Owner: demo
--

CREATE TABLE public.pgbench_tellers (
                                      tid integer NOT NULL,
                                      bid integer,
                                      tbalance integer,
                                      filler character(84)
)
  WITH (fillfactor='100');


ALTER TABLE public.pgbench_tellers OWNER TO demo;

--
-- Name: pgbench_accounts pgbench_accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: demo
--

ALTER TABLE ONLY public.pgbench_accounts
  ADD CONSTRAINT pgbench_accounts_pkey PRIMARY KEY (aid);


--
-- Name: pgbench_branches pgbench_branches_pkey; Type: CONSTRAINT; Schema: public; Owner: demo
--

ALTER TABLE ONLY public.pgbench_branches
  ADD CONSTRAINT pgbench_branches_pkey PRIMARY KEY (bid);


--
-- Name: pgbench_tellers pgbench_tellers_pkey; Type: CONSTRAINT; Schema: public; Owner: demo
--

ALTER TABLE ONLY public.pgbench_tellers
  ADD CONSTRAINT pgbench_tellers_pkey PRIMARY KEY (tid);


--
-- Name: SCHEMA metric_helpers; Type: ACL; Schema: -; Owner: postgres
--

GRANT USAGE ON SCHEMA metric_helpers TO admin;
GRANT USAGE ON SCHEMA metric_helpers TO robot_zmon;


--
-- Name: SCHEMA user_management; Type: ACL; Schema: -; Owner: postgres
--

GRANT USAGE ON SCHEMA user_management TO admin;


--
-- Name: FUNCTION get_btree_bloat_approx(OUT i_database name, OUT i_schema_name name, OUT i_table_name name, OUT i_index_name name, OUT i_real_size numeric, OUT i_extra_size numeric, OUT i_extra_ratio double precision, OUT i_fill_factor integer, OUT i_bloat_size double precision, OUT i_bloat_ratio double precision, OUT i_is_na boolean); Type: ACL; Schema: metric_helpers; Owner: postgres
--

REVOKE ALL ON FUNCTION metric_helpers.get_btree_bloat_approx(OUT i_database name, OUT i_schema_name name, OUT i_table_name name, OUT i_index_name name, OUT i_real_size numeric, OUT i_extra_size numeric, OUT i_extra_ratio double precision, OUT i_fill_factor integer, OUT i_bloat_size double precision, OUT i_bloat_ratio double precision, OUT i_is_na boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION metric_helpers.get_btree_bloat_approx(OUT i_database name, OUT i_schema_name name, OUT i_table_name name, OUT i_index_name name, OUT i_real_size numeric, OUT i_extra_size numeric, OUT i_extra_ratio double precision, OUT i_fill_factor integer, OUT i_bloat_size double precision, OUT i_bloat_ratio double precision, OUT i_is_na boolean) TO admin;
GRANT ALL ON FUNCTION metric_helpers.get_btree_bloat_approx(OUT i_database name, OUT i_schema_name name, OUT i_table_name name, OUT i_index_name name, OUT i_real_size numeric, OUT i_extra_size numeric, OUT i_extra_ratio double precision, OUT i_fill_factor integer, OUT i_bloat_size double precision, OUT i_bloat_ratio double precision, OUT i_is_na boolean) TO robot_zmon;


--
-- Name: FUNCTION get_table_bloat_approx(OUT t_database name, OUT t_schema_name name, OUT t_table_name name, OUT t_real_size numeric, OUT t_extra_size double precision, OUT t_extra_ratio double precision, OUT t_fill_factor integer, OUT t_bloat_size double precision, OUT t_bloat_ratio double precision, OUT t_is_na boolean); Type: ACL; Schema: metric_helpers; Owner: postgres
--

REVOKE ALL ON FUNCTION metric_helpers.get_table_bloat_approx(OUT t_database name, OUT t_schema_name name, OUT t_table_name name, OUT t_real_size numeric, OUT t_extra_size double precision, OUT t_extra_ratio double precision, OUT t_fill_factor integer, OUT t_bloat_size double precision, OUT t_bloat_ratio double precision, OUT t_is_na boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION metric_helpers.get_table_bloat_approx(OUT t_database name, OUT t_schema_name name, OUT t_table_name name, OUT t_real_size numeric, OUT t_extra_size double precision, OUT t_extra_ratio double precision, OUT t_fill_factor integer, OUT t_bloat_size double precision, OUT t_bloat_ratio double precision, OUT t_is_na boolean) TO admin;
GRANT ALL ON FUNCTION metric_helpers.get_table_bloat_approx(OUT t_database name, OUT t_schema_name name, OUT t_table_name name, OUT t_real_size numeric, OUT t_extra_size double precision, OUT t_extra_ratio double precision, OUT t_fill_factor integer, OUT t_bloat_size double precision, OUT t_bloat_ratio double precision, OUT t_is_na boolean) TO robot_zmon;


--
-- Name: FUNCTION pg_stat_statements(showtext boolean); Type: ACL; Schema: metric_helpers; Owner: postgres
--

REVOKE ALL ON FUNCTION metric_helpers.pg_stat_statements(showtext boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION metric_helpers.pg_stat_statements(showtext boolean) TO admin;
GRANT ALL ON FUNCTION metric_helpers.pg_stat_statements(showtext boolean) TO robot_zmon;


--
-- Name: FUNCTION pg_stat_statements_reset(userid oid, dbid oid, queryid bigint); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.pg_stat_statements_reset(userid oid, dbid oid, queryid bigint) TO admin;


--
-- Name: FUNCTION set_user(text); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.set_user(text) TO admin;


--
-- Name: FUNCTION create_application_user(username text); Type: ACL; Schema: user_management; Owner: postgres
--

REVOKE ALL ON FUNCTION user_management.create_application_user(username text) FROM PUBLIC;
GRANT ALL ON FUNCTION user_management.create_application_user(username text) TO admin;


--
-- Name: FUNCTION create_application_user_or_change_password(username text, password text); Type: ACL; Schema: user_management; Owner: postgres
--

REVOKE ALL ON FUNCTION user_management.create_application_user_or_change_password(username text, password text) FROM PUBLIC;
GRANT ALL ON FUNCTION user_management.create_application_user_or_change_password(username text, password text) TO admin;


--
-- Name: FUNCTION create_role(rolename text); Type: ACL; Schema: user_management; Owner: postgres
--

REVOKE ALL ON FUNCTION user_management.create_role(rolename text) FROM PUBLIC;
GRANT ALL ON FUNCTION user_management.create_role(rolename text) TO admin;


--
-- Name: FUNCTION create_user(username text); Type: ACL; Schema: user_management; Owner: postgres
--

REVOKE ALL ON FUNCTION user_management.create_user(username text) FROM PUBLIC;
GRANT ALL ON FUNCTION user_management.create_user(username text) TO admin;


--
-- Name: FUNCTION drop_role(username text); Type: ACL; Schema: user_management; Owner: postgres
--

REVOKE ALL ON FUNCTION user_management.drop_role(username text) FROM PUBLIC;
GRANT ALL ON FUNCTION user_management.drop_role(username text) TO admin;


--
-- Name: FUNCTION drop_user(username text); Type: ACL; Schema: user_management; Owner: postgres
--

REVOKE ALL ON FUNCTION user_management.drop_user(username text) FROM PUBLIC;
GRANT ALL ON FUNCTION user_management.drop_user(username text) TO admin;


--
-- Name: FUNCTION revoke_admin(username text); Type: ACL; Schema: user_management; Owner: postgres
--

REVOKE ALL ON FUNCTION user_management.revoke_admin(username text) FROM PUBLIC;
GRANT ALL ON FUNCTION user_management.revoke_admin(username text) TO admin;


--
-- Name: FUNCTION terminate_backend(pid integer); Type: ACL; Schema: user_management; Owner: postgres
--

REVOKE ALL ON FUNCTION user_management.terminate_backend(pid integer) FROM PUBLIC;
GRANT ALL ON FUNCTION user_management.terminate_backend(pid integer) TO admin;


--
-- Name: TABLE index_bloat; Type: ACL; Schema: metric_helpers; Owner: postgres
--

GRANT SELECT ON TABLE metric_helpers.index_bloat TO admin;
GRANT SELECT ON TABLE metric_helpers.index_bloat TO robot_zmon;


--
-- Name: TABLE pg_stat_statements; Type: ACL; Schema: metric_helpers; Owner: postgres
--

GRANT SELECT ON TABLE metric_helpers.pg_stat_statements TO admin;
GRANT SELECT ON TABLE metric_helpers.pg_stat_statements TO robot_zmon;


--
-- Name: TABLE table_bloat; Type: ACL; Schema: metric_helpers; Owner: postgres
--

GRANT SELECT ON TABLE metric_helpers.table_bloat TO admin;
GRANT SELECT ON TABLE metric_helpers.table_bloat TO robot_zmon;


--
-- Name: TABLE pg_stat_activity; Type: ACL; Schema: pg_catalog; Owner: postgres
--

GRANT SELECT ON TABLE pg_catalog.pg_stat_activity TO admin;


--
-- PostgreSQL database dump complete
--

COMMIT;
