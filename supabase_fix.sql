-- ==============================================================================
-- 🚂 FATAK TRACKER: FIX PERMISSIONS, RLS, AND ADD ROBUST RPC FUNCTIONS
-- Run this entire script in Supabase Dashboard -> SQL Editor -> Run
-- ==============================================================================

-- 1. Ensure PostGIS is enabled
create extension if not exists postgis;

-- 2. Make sure the schema usage is granted to public/anon/authenticated roles
grant usage on schema public to anon, authenticated, service_role;
grant all on all tables in schema public to anon, authenticated, service_role;
grant all on all sequences in schema public to anon, authenticated, service_role;
grant all on all routines in schema public to anon, authenticated, service_role;

alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
alter default privileges in schema public grant all on routines to anon, authenticated, service_role;

-- 3. Configure Row Level Security (RLS) on public.level_crossings
alter table public.level_crossings enable row level security;

-- Drop any conflicting old policies if they exist
drop policy if exists "Allow public read access on level_crossings" on public.level_crossings;
drop policy if exists "Allow public insert on level_crossings" on public.level_crossings;
drop policy if exists "Allow public update on level_crossings" on public.level_crossings;
drop policy if exists "Enable read access for all users" on public.level_crossings;
drop policy if exists "Enable insert for all users" on public.level_crossings;

-- Create clean policies allowing both anonymous and logged-in users to SELECT and INSERT
create policy "Allow public read access on level_crossings"
  on public.level_crossings
  for select
  to public
  using (true);

create policy "Allow public insert on level_crossings"
  on public.level_crossings
  for insert
  to public
  with check (true);

create policy "Allow public update on level_crossings"
  on public.level_crossings
  for update
  to public
  using (true)
  with check (true);

-- 4. Create stored database functions (RPC)
-- This completely bypasses PostGIS REST serialization quirks and makes insert & read 100% fail-safe!

-- A. Submit Fatak RPC
create or replace function public.submit_fatak(
    p_name text,
    p_status text,
    p_lat double precision,
    p_lon double precision
)
returns json
language plpgsql
security definer -- runs with elevated rights so RLS/permission issues never block pin saves
as $$
declare
    v_id bigint;
    v_clean_status text;
    v_result json;
begin
    -- Sanitize status
    v_clean_status := lower(trim(p_status));
    if v_clean_status not in ('open', 'closed', 'closing_soon', 'unknown') then
        v_clean_status := 'unknown';
    end if;

    -- Insert crossing using standard PostGIS ST_SetSRID(ST_MakePoint(lon, lat), 4326)
    insert into public.level_crossings (name, status, location, updated_at)
    values (
        trim(p_name),
        v_clean_status,
        st_setsrid(st_makepoint(p_lon, p_lat), 4326)::geography,
        now()
    )
    returning id into v_id;

    select json_build_object(
        'id', v_id,
        'name', trim(p_name),
        'status', v_clean_status,
        'latitude', p_lat,
        'longitude', p_lon,
        'created_at', now()
    ) into v_result;

    return v_result;
end;
$$;

-- B. Get Crossings RPC (returns cleaned lat & lon ready for Leaflet)
create or replace function public.get_crossings()
returns table (
    id bigint,
    name text,
    status text,
    latitude double precision,
    longitude double precision,
    created_at timestamptz,
    updated_at timestamptz
)
language sql
security definer
stable
as $$
    select
        lc.id,
        lc.name,
        lc.status,
        st_y(lc.location::geometry) as latitude,
        st_x(lc.location::geometry) as longitude,
        lc.created_at,
        lc.updated_at
    from public.level_crossings lc
    order by lc.created_at desc;
$$;

-- C. Update Fatak Status RPC (quick toggle open/closed)
create or replace function public.update_fatak_status(
    p_id bigint,
    p_status text
)
returns boolean
language plpgsql
security definer
as $$
begin
    update public.level_crossings
    set status = lower(trim(p_status)),
        updated_at = now()
    where id = p_id;

    return found;
end;
$$;

-- 5. Grant execute rights on RPC functions to public
grant execute on function public.submit_fatak(text, text, double precision, double precision) to anon, authenticated, service_role;
grant execute on function public.get_crossings() to anon, authenticated, service_role;
grant execute on function public.update_fatak_status(bigint, text) to anon, authenticated, service_role;

-- ==============================================================================
-- 6. Crowd Consensus Voting Table (5-10 On-Site Approvals Model)
-- ==============================================================================
create table if not exists public.crossing_votes (
    id bigint generated by default as identity primary key,
    crossing_id bigint references public.level_crossings(id) on delete cascade,
    vote text not null check (vote in ('open', 'closed')),
    device_id text not null,
    time_bucket text not null, -- e.g. "2026-10-06T16:35" (+-2 mins)
    latitude double precision,
    longitude double precision,
    created_at timestamptz default now()
);

-- Index for fast time-bucket consensus queries
create index if not exists idx_crossing_votes_bucket on public.crossing_votes(crossing_id, time_bucket);

-- Enable RLS and grant public access
alter table public.crossing_votes enable row level security;

drop policy if exists "Allow public read on crossing_votes" on public.crossing_votes;
drop policy if exists "Allow public insert on crossing_votes" on public.crossing_votes;

create policy "Allow public read on crossing_votes"
  on public.crossing_votes
  for select
  to public
  using (true);

create policy "Allow public insert on crossing_votes"
  on public.crossing_votes
  for insert
  to public
  with check (true);

grant all on public.crossing_votes to anon, authenticated, service_role;
grant usage, select on all sequences in schema public to anon, authenticated, service_role;
