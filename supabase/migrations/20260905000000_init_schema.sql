-- AGOS Flood Early Warning System — initial schema
-- Reconstructed from the frontend + edge function code (no prior migration
-- existed in the repo). Run this once against the target Supabase project
-- (SQL Editor, or `supabase db push` once linked).

create extension if not exists pgcrypto;

-- ─── roles ──────────────────────────────────────────────────────────────────
-- Referenced by profiles.role_id. role_id = 7 is hardcoded as "Resident" in
-- src/lib/roles.js (RESIDENT_ROLE_ID), so it must exist with that exact id.

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

-- Keep the sequence ahead of the highest seeded id so future inserts
-- (new roles added from the app) don't collide with the explicit values above.
select setval('public.roles_role_id_seq', (select max(role_id) from public.roles));

-- ─── profiles ───────────────────────────────────────────────────────────────
-- One row per auth.users row. Created by the create-user edge function
-- (service role — bypasses RLS), never inserted directly from the client.

create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  name       text not null,
  username   text not null unique,
  phone      text,
  role_id    int references public.roles(role_id),
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

create policy "profiles: read own row"
  on public.profiles for select
  to authenticated
  using (id = auth.uid());

-- ─── flood_snapshots ────────────────────────────────────────────────────────
-- One row per model poll (~30s). Written client-side by useModelPrediction
-- (src/lib/modelApi.js) and by the poll-flood edge function (service role).

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

create policy "flood_snapshots: read"
  on public.flood_snapshots for select
  to authenticated
  using (true);

create policy "flood_snapshots: insert"
  on public.flood_snapshots for insert
  to authenticated
  with check (true);

-- ─── alerts ─────────────────────────────────────────────────────────────────
-- Evacuation / auto alerts. Insert triggers the on-alert-change DB webhook
-- (SMS + push dispatch).

create table if not exists public.alerts (
  id         bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  type       text not null,
  message    text not null,
  sent_by    text
);

alter table public.alerts enable row level security;

create policy "alerts: read"
  on public.alerts for select
  to authenticated
  using (true);

create policy "alerts: insert"
  on public.alerts for insert
  to authenticated
  with check (true);

-- ─── incident_reports ───────────────────────────────────────────────────────
-- Resident-submitted reports (filed from the separate resident/mobile app —
-- not in this repo). This web app reviews/moderates them.

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

create policy "incident_reports: read"
  on public.incident_reports for select
  to authenticated
  using (true);

create policy "incident_reports: insert own"
  on public.incident_reports for insert
  to authenticated
  with check (true);

create policy "incident_reports: update"
  on public.incident_reports for update
  to authenticated
  using (true)
  with check (true);

-- ─── flood_reports ──────────────────────────────────────────────────────────
-- Historical/incident-log form filed by staff (ReportsPage.jsx).

create table if not exists public.flood_reports (
  id                      bigint generated always as identity primary key,
  created_at              timestamptz not null default now(),
  date_occurred           date not null,
  time_occurred           time,
  severity                text not null
                            check (severity in ('NORMAL', 'ADVISORY', 'WARNING', 'CRITICAL')),
  location                text not null,
  -- Environmental
  water_level             numeric,
  rainfall_mm_at_event    numeric,
  duration_hours          numeric,
  flood_source            text,
  -- Impact
  affected_hh             int,
  displaced_persons       int,
  casualties              int default 0,
  infrastructure_damage   text,
  estimated_damage_php    numeric,
  -- Response
  evacuation_center_used  text,
  response_time_minutes   int,
  actions_taken           text,
  -- System / narrative
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

create policy "flood_reports: read"
  on public.flood_reports for select
  to authenticated
  using (true);

create policy "flood_reports: insert"
  on public.flood_reports for insert
  to authenticated
  with check (true);

create policy "flood_reports: update"
  on public.flood_reports for update
  to authenticated
  using (true)
  with check (true);

-- ─── RPC: daily aggregates (Dashboard 7-day chart, RainfallPage daily view) ──
-- Bucketed in Asia/Manila local time so "day" lines up with what a user in
-- the Philippines expects, not UTC.

create or replace function public.get_daily_flood_avg(days_back int)
returns table (day date, avg_probability numeric, readings bigint)
language sql
stable
as $$
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
language sql
stable
as $$
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
-- Dashboard/RainfallPage subscribe to INSERT on flood_snapshots; the
-- Community Reports page subscribes to all changes on incident_reports.

alter publication supabase_realtime add table public.flood_snapshots;
alter publication supabase_realtime add table public.incident_reports;
