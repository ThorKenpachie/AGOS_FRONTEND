-- ═══════════════════════════════════════════════════════════════════════════
-- AGOS Flood Early Warning System — full schema reference
-- Consolidated from supabase/migrations/*.sql for pasting directly into the
-- Supabase SQL Editor (Dashboard → SQL Editor → New query → paste → Run).
--
-- Safe to run against the live AGOS project as-is: every CREATE TABLE uses
-- IF NOT EXISTS, and every CREATE POLICY is wrapped in a DO block that
-- swallows "already exists" errors — so running this changes nothing on a
-- database that already has these objects, but gives you one script that
-- fully documents (and can rebuild, e.g. on a fresh project) the schema.
--
-- After running, click "Save" in the SQL Editor to keep this as a named
-- snippet — that's what makes it show up in the editor going forward.
-- ═══════════════════════════════════════════════════════════════════════════

create extension if not exists pgcrypto;

-- ─── roles ──────────────────────────────────────────────────────────────────
create table if not exists public.roles (
  role_id   serial primary key,
  role_desc text not null unique
);

insert into public.roles (role_id, role_desc) values
  (1, 'Admin'),
  (2, 'Barangay Captain'),
  (3, 'Barangay Secretary'),
  (4, 'DRRM Team'),
  (7, 'Resident')
on conflict (role_id) do nothing;

select setval('public.roles_role_id_seq', (select max(role_id) from public.roles));

-- ─── profiles ───────────────────────────────────────────────────────────────
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  name       text not null,
  username   text not null unique,
  phone      text,
  role_id    int references public.roles(role_id),
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

do $$ begin
  create policy "profiles: read own row"
    on public.profiles for select to authenticated
    using (id = auth.uid());
exception when duplicate_object then null; end $$;

-- Locked to role_id = 7 (Resident) so the public self-signup page can never
-- be used to grant elevated (Admin/staff) access.
do $$ begin
  create policy "profiles: self-insert as resident"
    on public.profiles for insert to authenticated
    with check (id = auth.uid() and role_id = 7);
exception when duplicate_object then null; end $$;

-- ─── flood_snapshots ────────────────────────────────────────────────────────
create table if not exists public.flood_snapshots (
  id           bigint generated always as identity primary key,
  created_at   timestamptz not null default now(),
  alert_level  int,
  alert_key    text,
  probability  numeric,
  rainfall_mm  numeric,
  humidity     numeric,
  wind_signal  int,
  status       text
);

create index if not exists flood_snapshots_created_at_idx
  on public.flood_snapshots (created_at desc);

alter table public.flood_snapshots enable row level security;

do $$ begin
  create policy "flood_snapshots: read"
    on public.flood_snapshots for select to authenticated using (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "flood_snapshots: insert"
    on public.flood_snapshots for insert to authenticated with check (true);
exception when duplicate_object then null; end $$;

-- ─── alerts ─────────────────────────────────────────────────────────────────
create table if not exists public.alerts (
  id         bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  type       text not null,
  message    text not null,
  sent_by    text
);

alter table public.alerts enable row level security;

do $$ begin
  create policy "alerts: read"
    on public.alerts for select to authenticated using (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "alerts: insert"
    on public.alerts for insert to authenticated with check (true);
exception when duplicate_object then null; end $$;

-- ─── incident_reports ───────────────────────────────────────────────────────
create table if not exists public.incident_reports (
  id               uuid primary key default gen_random_uuid(),
  created_at       timestamptz not null default now(),
  category         text not null,
  description      text not null,
  location_label   text,
  latitude         numeric,
  longitude        numeric,
  photo_url        text,
  reporter_id      uuid references public.profiles(id),
  reporter_name    text,
  status           text not null default 'pending'
                     check (status in ('pending', 'verified', 'rejected')),
  rejection_reason text,
  reviewed_by      uuid references public.profiles(id),
  reviewed_at      timestamptz
);

create index if not exists incident_reports_created_at_idx
  on public.incident_reports (created_at desc);

alter table public.incident_reports enable row level security;

do $$ begin
  create policy "incident_reports: read"
    on public.incident_reports for select to authenticated using (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "incident_reports: insert own"
    on public.incident_reports for insert to authenticated with check (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "incident_reports: update"
    on public.incident_reports for update to authenticated using (true) with check (true);
exception when duplicate_object then null; end $$;

-- ─── flood_reports ──────────────────────────────────────────────────────────
create table if not exists public.flood_reports (
  id                      bigint generated always as identity primary key,
  created_at              timestamptz not null default now(),
  date_occurred           date not null,
  time_occurred           time,
  severity                text not null
                            check (severity in ('NORMAL', 'ADVISORY', 'WARNING', 'CRITICAL')),
  location                text not null,
  water_level             numeric,
  rainfall_mm_at_event    numeric,
  duration_hours          numeric,
  flood_source            text,
  affected_hh             int,
  displaced_persons       int,
  casualties              int default 0,
  infrastructure_damage   text,
  estimated_damage_php    numeric,
  evacuation_center_used  text,
  response_time_minutes   int,
  actions_taken           text,
  model_alert_level       text,
  description             text not null,
  status                  text not null default 'OPEN'
                            check (status in ('OPEN', 'MONITORING', 'RESOLVED')),
  reported_by             text,
  reporter_role           text
);

create index if not exists flood_reports_date_occurred_idx
  on public.flood_reports (date_occurred desc);

alter table public.flood_reports enable row level security;

do $$ begin
  create policy "flood_reports: read"
    on public.flood_reports for select to authenticated using (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "flood_reports: insert"
    on public.flood_reports for insert to authenticated with check (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "flood_reports: update"
    on public.flood_reports for update to authenticated using (true) with check (true);
exception when duplicate_object then null; end $$;

-- ─── cleanup_log ────────────────────────────────────────────────────────────
-- Job bookkeeping (likely a scheduled prune job) — service_role only, no
-- client-facing policies by design.
create table if not exists public.cleanup_log (
  id           bigint generated always as identity primary key,
  table_name   text not null,
  rows_deleted int,
  cutoff_time  timestamptz,
  ran_at       timestamptz default now()
);

alter table public.cleanup_log enable row level security;

-- ─── device_tokens ──────────────────────────────────────────────────────────
-- FCM push registration, consumed by the send-push-notification edge
-- function. Registered from the separate resident/mobile app.
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
    on public.device_tokens for all using (true) with check (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "Anyone can register their token"
    on public.device_tokens for insert with check (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "Anyone can update their token"
    on public.device_tokens for update using (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "Service role can delete stale tokens"
    on public.device_tokens for delete using (auth.role() = 'service_role');
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "Service role can read all tokens"
    on public.device_tokens for select using (auth.role() = 'service_role');
exception when duplicate_object then null; end $$;

-- ─── evacuation_centers ─────────────────────────────────────────────────────
-- NOTE: not yet wired up in the frontend — FloodMapPage.jsx currently
-- hardcodes its evacuation center list instead of reading from this table.
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
    on public.evacuation_centers for select using (true);
exception when duplicate_object then null; end $$;

-- ─── flood_events ───────────────────────────────────────────────────────────
-- Historical typhoon/flood event log — distinct from flood_reports (the
-- staff-filed incident form). Not currently read by this frontend.
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
    on public.flood_events for select to authenticated using (true);
exception when duplicate_object then null; end $$;

-- ─── prediction_logs ────────────────────────────────────────────────────────
-- Same shape as flood_snapshots plus seasonal month_sin/month_cos — looks
-- like a superseded earlier version. Not read/written anywhere in this repo.
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
    on public.prediction_logs for select to authenticated using (true);
exception when duplicate_object then null; end $$;

do $$ begin
  create policy "Service role can insert prediction_logs"
    on public.prediction_logs for insert to service_role with check (true);
exception when duplicate_object then null; end $$;

-- ─── RPC functions ──────────────────────────────────────────────────────────
create or replace function public.get_daily_flood_avg(days_back int)
returns table (day date, avg_probability numeric, readings bigint)
language sql stable as $$
  select
    (created_at at time zone 'Asia/Manila')::date as day,
    avg(probability)                               as avg_probability,
    count(*)                                        as readings
  from public.flood_snapshots
  where created_at >= now() - (days_back || ' days')::interval
  group by day
  order by day;
$$;

create or replace function public.get_daily_rainfall(days_back int)
returns table (day date, rainfall numeric)
language sql stable as $$
  select
    (created_at at time zone 'Asia/Manila')::date as day,
    sum(rainfall_mm)                               as rainfall
  from public.flood_snapshots
  where created_at >= now() - (days_back || ' days')::interval
  group by day
  order by day;
$$;

grant execute on function public.get_daily_flood_avg(int) to authenticated;
grant execute on function public.get_daily_rainfall(int)  to authenticated;

-- ─── Realtime ───────────────────────────────────────────────────────────────
do $$ begin
  alter publication supabase_realtime add table public.flood_snapshots;
exception when duplicate_object then null; end $$;

do $$ begin
  alter publication supabase_realtime add table public.incident_reports;
exception when duplicate_object then null; end $$;
