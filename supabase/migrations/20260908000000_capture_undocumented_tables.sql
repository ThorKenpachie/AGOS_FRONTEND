-- These 5 tables (cleanup_log, device_tokens, evacuation_centers,
-- flood_events, prediction_logs) already exist in production but had NO
-- corresponding file anywhere in this repo -- someone created them by
-- running SQL directly (SQL Editor or another tool) against the live
-- database, and once that query succeeds Supabase doesn't retain the SQL
-- as a file anywhere. This file is a reverse-engineered capture of their
-- current live definitions (columns, PK, indexes, RLS policies), pulled
-- via information_schema/pg_policies through the pooler connection on
-- 2026-09-08, purely so the schema has a readable source of truth in git.
--
-- `create table if not exists` + a `do $$ ... exception` guard on each
-- policy make this safe to run again without erroring, but it is written
-- as documentation of what's live, not as a migration you need to apply --
-- the objects already exist in the AGOS project.

-- ─── cleanup_log ────────────────────────────────────────────────────────────
-- Presumably written by a scheduled job (pg_cron or an edge function not in
-- this repo) that prunes old rows from other tables and records what it did.

create table if not exists public.cleanup_log (
  id           bigint generated always as identity primary key,
  table_name   text not null,
  rows_deleted int,
  cutoff_time  timestamptz,
  ran_at       timestamptz default now()
);

alter table public.cleanup_log enable row level security;
-- No policies exist on this table live -- RLS is on with zero policies,
-- which means it's effectively unreadable/unwritable to any client role
-- except service_role (which bypasses RLS entirely). Consistent with this
-- being an internal job-only table.

-- ─── device_tokens ──────────────────────────────────────────────────────────
-- FCM push-notification device registration, backing send-push-notification.
-- Not referenced anywhere in this frontend repo -- registration must happen
-- from the separate resident/mobile app.

create table if not exists public.device_tokens (
  id         bigint generated always as identity primary key,
  token      text not null unique,
  user_id    uuid,
  platform   text not null default 'android',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.device_tokens enable row level security;

do $$ begin
  create policy "Allow device token upsert"
    on public.device_tokens for all
    using (true) with check (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "Anyone can register their token"
    on public.device_tokens for insert
    with check (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "Anyone can update their token"
    on public.device_tokens for update
    using (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "Service role can delete stale tokens"
    on public.device_tokens for delete
    using (auth.role() = 'service_role');
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "Service role can read all tokens"
    on public.device_tokens for select
    using (auth.role() = 'service_role');
exception when duplicate_object then null; end $$;

-- ─── evacuation_centers ─────────────────────────────────────────────────────
-- NOT currently read by this frontend -- FloodMapPage.jsx / EvacuationMap3D
-- render a hardcoded list of centers in the component code instead of
-- querying this table. This table looks like the intended real source; the
-- frontend just hasn't been wired up to it yet.

create table if not exists public.evacuation_centers (
  id                 text primary key,
  name               text not null,
  type               text not null,
  address            text not null,
  latitude           double precision not null,
  longitude          double precision not null,
  is_open            boolean not null default true,
  capacity           int,
  current_occupancy  int,
  updated_at         timestamptz not null default now()
);

alter table public.evacuation_centers enable row level security;

do $$ begin
  create policy "Public can read evacuation centers"
    on public.evacuation_centers for select
    using (true);
exception when duplicate_object then null; end $$;

-- ─── flood_events ───────────────────────────────────────────────────────────
-- Historical typhoon/flood event log -- distinct from flood_reports (the
-- staff-filed incident form in ReportsPage.jsx). Not read anywhere in this
-- frontend repo currently; likely seeded for a "past events" feature that
-- was never built, or feeds a report not yet wired up.

create table if not exists public.flood_events (
  id              bigint generated always as identity primary key,
  date            text not null,
  typhoon         text not null,
  severity        text not null,
  affected_zones  text[] default '{}',
  max_water_level numeric,
  casualties      int default 0,
  displaced       int default 0,
  duration_hours  int,
  notes           text,
  created_at      timestamptz default now()
);

alter table public.flood_events enable row level security;

do $$ begin
  create policy "Authenticated users can read flood_events"
    on public.flood_events for select
    to authenticated
    using (true);
exception when duplicate_object then null; end $$;

-- ─── prediction_logs ────────────────────────────────────────────────────────
-- Looks like an earlier/parallel version of flood_snapshots (same shape of
-- fields: rainfall_mm, wind_signal, humidity, probability, alert_level,
-- status -- plus month_sin/month_cos, which match the AI_Model feature
-- contract's seasonal encoding). Nothing in this frontend repo reads or
-- writes it -- flood_snapshots is what useModelPrediction actually uses.
-- Only service_role can insert, so it's written by a job/function not in
-- this repo (possibly an earlier iteration of poll-flood, superseded).

create table if not exists public.prediction_logs (
  id           bigint generated always as identity primary key,
  recorded_at  timestamptz default now(),
  rainfall_mm  numeric,
  wind_signal  int,
  humidity     numeric,
  probability  numeric,
  alert_level  int,
  status       text,
  month_sin    numeric,
  month_cos    numeric
);

alter table public.prediction_logs enable row level security;

do $$ begin
  create policy "Authenticated users can read prediction_logs"
    on public.prediction_logs for select
    to authenticated
    using (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "Service role can insert prediction_logs"
    on public.prediction_logs for insert
    to service_role
    with check (true);
exception when duplicate_object then null; end $$;
