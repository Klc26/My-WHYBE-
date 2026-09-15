-- POSTLOGIX AI
-- Supabase/PostgreSQL schema for the parcel and post-office staff dashboard.
--
-- How to use:
-- 1. Open Supabase Dashboard -> SQL Editor.
-- 2. Paste this file and run it once.
-- 3. Create users in Supabase Authentication.
-- 4. New users are created as "staff" automatically. Promote an account to
--    admin with the example statement at the bottom of this file.
--
-- The schema is intentionally API-friendly:
--   parcels                  = the main record submitted by the frontend
--   post_offices             = facilities returned by the identifier
--   post_office_service_areas= PIN/city lookup data
--   parcel_processing_runs   = validate/process/identify audit trail
--   tracking_events           = parcel timeline
--   delivery_attempts         = failed delivery and rescheduling workflow
--   pickup_recommendations    = smart pickup suggestions

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------------

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = timezone('utc', now());
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Postal facilities and coverage
-- ---------------------------------------------------------------------------

create table if not exists public.post_offices (
  id uuid primary key default gen_random_uuid(),
  office_code text not null unique,
  name text not null,
  office_type text not null default 'delivery_office'
    check (office_type in ('head_post_office', 'sub_post_office', 'branch_post_office', 'delivery_office', 'pickup_point')),
  address_line1 text not null,
  address_line2 text,
  city text not null,
  state text not null,
  pin_code text not null check (pin_code ~ '^[0-9]{6}$'),
  latitude numeric(9,6),
  longitude numeric(9,6),
  phone text,
  is_active boolean not null default true,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create table if not exists public.post_office_service_areas (
  pin_code text primary key check (pin_code ~ '^[0-9]{6}$'),
  post_office_id uuid not null references public.post_offices(id) on delete cascade,
  city text,
  state text,
  created_at timestamptz not null default timezone('utc', now())
);

create index if not exists post_offices_pin_code_idx
  on public.post_offices(pin_code);

create index if not exists post_offices_city_idx
  on public.post_offices(lower(city));

create index if not exists service_areas_post_office_id_idx
  on public.post_office_service_areas(post_office_id);

drop trigger if exists set_post_offices_updated_at on public.post_offices;
create trigger set_post_offices_updated_at
before update on public.post_offices
for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- Staff identity and roles
-- ---------------------------------------------------------------------------

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  full_name text,
  office_id uuid references public.post_offices(id) on delete set null,
  preferred_language text not null default 'English'
    check (preferred_language in ('English', 'Hindi', 'Hinglish', 'Regional language')),
  is_active boolean not null default true,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create table if not exists public.user_roles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null default 'staff'
    check (role in ('admin', 'staff')),
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

drop trigger if exists set_profiles_updated_at on public.profiles;
create trigger set_profiles_updated_at
before update on public.profiles
for each row execute function public.set_updated_at();

drop trigger if exists set_user_roles_updated_at on public.user_roles;
create trigger set_user_roles_updated_at
before update on public.user_roles
for each row execute function public.set_updated_at();

create or replace function public.handle_new_user()
returns trigger
security definer
set search_path = public
language plpgsql
as $$
begin
  insert into public.profiles (id, full_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'full_name', new.email));

  insert into public.user_roles (user_id, role)
  values (new.id, 'staff')
  on conflict (user_id) do nothing;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

create or replace function public.is_admin()
returns boolean
security definer
set search_path = public
stable
language sql
as $$
  select exists (
    select 1
    from public.user_roles
    where user_id = auth.uid()
      and role = 'admin'
  );
$$;

create or replace function public.is_staff()
returns boolean
security definer
set search_path = public
stable
language sql
as $$
  select exists (
    select 1
    from public.user_roles
    where user_id = auth.uid()
      and role in ('admin', 'staff')
  );
$$;

-- ---------------------------------------------------------------------------
-- Parcels and operational workflow
-- ---------------------------------------------------------------------------

create table if not exists public.parcels (
  id uuid primary key default gen_random_uuid(),
  tracking_number text not null unique,
  service_type text not null default 'Standard Delivery'
    check (service_type in ('Standard Delivery', 'Speed Post', 'Registered Post', 'Pickup at Post Office')),
  sender_name text not null,
  receiver_name text not null,
  receiver_phone text,
  delivery_address text not null,
  pin_code text not null check (pin_code ~ '^[0-9]{6}$'),
  language text not null default 'English'
    check (language in ('English', 'Hindi', 'Hinglish', 'Regional language')),
  city text,
  state text,
  landmark text,
  normalized_address text,
  current_status text not null default 'created'
    check (current_status in (
      'created', 'validated', 'processing', 'assigned', 'in_transit',
      'out_for_delivery', 'delivered', 'failed_delivery',
      'ready_for_pickup', 'picked_up', 'cancelled'
    )),
  origin_office_id uuid references public.post_offices(id) on delete set null,
  destination_office_id uuid references public.post_offices(id) on delete set null,
  assigned_staff_id uuid references auth.users(id) on delete set null,
  created_by uuid not null default auth.uid() references auth.users(id) on delete restrict,
  validated_at timestamptz,
  processed_at timestamptz,
  identified_at timestamptz,
  delivered_at timestamptz,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default timezone('utc', now()),
  updated_at timestamptz not null default timezone('utc', now())
);

create table if not exists public.parcel_processing_runs (
  id uuid primary key default gen_random_uuid(),
  parcel_id uuid not null references public.parcels(id) on delete cascade,
  stage text not null
    check (stage in ('validate', 'process_ai', 'identify_post_office')),
  status text not null default 'started'
    check (status in ('started', 'succeeded', 'failed')),
  input_text text,
  normalized_address text,
  extracted_city text,
  extracted_state text,
  extracted_landmark text,
  extracted_pin_code text check (extracted_pin_code is null or extracted_pin_code ~ '^[0-9]{6}$'),
  confidence numeric(5,4) check (confidence is null or confidence between 0 and 1),
  provider text,
  model text,
  result jsonb not null default '{}'::jsonb,
  error_message text,
  requested_by uuid not null default auth.uid() references auth.users(id) on delete restrict,
  started_at timestamptz not null default timezone('utc', now()),
  completed_at timestamptz
);

create table if not exists public.tracking_events (
  id uuid primary key default gen_random_uuid(),
  parcel_id uuid not null references public.parcels(id) on delete cascade,
  event_type text not null
    check (event_type in (
      'created', 'validated', 'processing', 'assigned', 'in_transit',
      'out_for_delivery', 'delivered', 'failed_delivery',
      'ready_for_pickup', 'picked_up', 'cancelled', 'note'
    )),
  description text,
  office_id uuid references public.post_offices(id) on delete set null,
  created_by uuid references auth.users(id) on delete set null,
  metadata jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default timezone('utc', now()),
  created_at timestamptz not null default timezone('utc', now())
);

create table if not exists public.delivery_attempts (
  id uuid primary key default gen_random_uuid(),
  parcel_id uuid not null references public.parcels(id) on delete cascade,
  attempt_number integer not null check (attempt_number > 0),
  outcome text not null
    check (outcome in ('delivered', 'recipient_unavailable', 'incorrect_address', 'refused', 'damaged', 'other')),
  failure_reason text,
  notes text,
  risk_score numeric(5,4) check (risk_score is null or risk_score between 0 and 1),
  suggested_action text
    check (suggested_action is null or suggested_action in ('reschedule', 'pickup', 'return_to_sender', 'manual_review')),
  attempted_by uuid references auth.users(id) on delete set null,
  attempted_at timestamptz not null default timezone('utc', now()),
  created_at timestamptz not null default timezone('utc', now()),
  unique (parcel_id, attempt_number)
);

create table if not exists public.pickup_recommendations (
  id uuid primary key default gen_random_uuid(),
  parcel_id uuid not null references public.parcels(id) on delete cascade,
  post_office_id uuid not null references public.post_offices(id) on delete cascade,
  rank integer not null check (rank > 0),
  score numeric(7,4),
  reason text,
  distance_km numeric(10,3),
  is_selected boolean not null default false,
  generated_by text default 'rules'
    check (generated_by in ('rules', 'ai', 'staff')),
  created_at timestamptz not null default timezone('utc', now()),
  unique (parcel_id, rank)
);

create table if not exists public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  actor_id uuid references auth.users(id) on delete set null,
  action text not null,
  table_name text not null,
  record_id uuid,
  old_data jsonb,
  new_data jsonb,
  created_at timestamptz not null default timezone('utc', now())
);

create index if not exists parcels_status_idx
  on public.parcels(current_status);

create index if not exists parcels_pin_code_idx
  on public.parcels(pin_code);

create index if not exists parcels_created_at_idx
  on public.parcels(created_at desc);

create index if not exists parcels_destination_office_idx
  on public.parcels(destination_office_id);

create index if not exists parcel_processing_runs_parcel_idx
  on public.parcel_processing_runs(parcel_id, started_at desc);

create index if not exists tracking_events_parcel_idx
  on public.tracking_events(parcel_id, occurred_at desc);

create index if not exists delivery_attempts_parcel_idx
  on public.delivery_attempts(parcel_id, attempted_at desc);

drop trigger if exists set_parcels_updated_at on public.parcels;
create trigger set_parcels_updated_at
before update on public.parcels
for each row execute function public.set_updated_at();

-- Add the initial timeline entry for every new parcel.
create or replace function public.add_parcel_created_event()
returns trigger
security definer
set search_path = public
language plpgsql
as $$
begin
  insert into public.tracking_events (parcel_id, event_type, description, created_by)
  values (new.id, 'created', 'Parcel record created', new.created_by);
  return new;
end;
$$;

drop trigger if exists on_parcel_created on public.parcels;
create trigger on_parcel_created
after insert on public.parcels
for each row execute function public.add_parcel_created_event();

-- Keep the parcel's summary status in sync with its timeline.
create or replace function public.sync_parcel_status_from_event()
returns trigger
security definer
set search_path = public
language plpgsql
as $$
begin
  if new.event_type <> 'note' then
    update public.parcels
    set current_status = new.event_type,
        delivered_at = case
          when new.event_type = 'delivered' then coalesce(delivered_at, new.occurred_at)
          else delivered_at
        end,
        updated_at = timezone('utc', now())
    where id = new.parcel_id;
  end if;
  return new;
end;
$$;

drop trigger if exists on_tracking_event_created on public.tracking_events;
create trigger on_tracking_event_created
after insert on public.tracking_events
for each row execute function public.sync_parcel_status_from_event();

-- ---------------------------------------------------------------------------
-- Read-only lookup RPC used by the "Identify Post Office" button.
-- Exact PIN matches rank first; city matches are a useful fallback.
-- Call from the frontend:
-- supabase.rpc('recommend_post_offices', { p_pin_code: '382010', p_city: 'Gandhinagar' })
-- ---------------------------------------------------------------------------

create or replace function public.recommend_post_offices(
  p_pin_code text,
  p_city text default null,
  p_limit integer default 5
)
returns table (
  office_id uuid,
  office_code text,
  office_name text,
  office_address text,
  city text,
  state text,
  pin_code text,
  match_type text,
  match_score integer
)
security definer
set search_path = public
stable
language sql
as $$
  with candidates as (
    select
      po.id,
      po.office_code,
      po.name,
      concat_ws(', ', po.address_line1, po.address_line2, po.city, po.state) as address,
      po.city,
      po.state,
      po.pin_code,
      case
        when psa.pin_code = p_pin_code then 'PIN + Location'
        when lower(po.city) = lower(coalesce(p_city, '')) then 'City'
        else 'Nearest active facility'
      end as match_type,
      case
        when psa.pin_code = p_pin_code then 100
        when lower(po.city) = lower(coalesce(p_city, '')) then 60
        else 10
      end as match_score
    from public.post_offices po
    left join public.post_office_service_areas psa
      on psa.post_office_id = po.id
     and psa.pin_code = p_pin_code
    where po.is_active
  )
  select
    id,
    office_code,
    name,
    address,
    city,
    state,
    pin_code,
    match_type,
    match_score
  from candidates
  order by match_score desc, lower(city), lower(name)
  limit greatest(1, least(coalesce(p_limit, 5), 20));
$$;

grant execute on function public.recommend_post_offices(text, text, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------------

alter table public.post_offices enable row level security;
alter table public.post_office_service_areas enable row level security;
alter table public.profiles enable row level security;
alter table public.user_roles enable row level security;
alter table public.parcels enable row level security;
alter table public.parcel_processing_runs enable row level security;
alter table public.tracking_events enable row level security;
alter table public.delivery_attempts enable row level security;
alter table public.pickup_recommendations enable row level security;
alter table public.audit_logs enable row level security;

-- Authenticated staff can use the operational tables. Admins can manage
-- facility, role, and audit data.
drop policy if exists "staff can read active post offices" on public.post_offices;
create policy "staff can read active post offices"
on public.post_offices for select to authenticated
using (is_staff() and is_active);

drop policy if exists "admins manage post offices" on public.post_offices;
create policy "admins manage post offices"
on public.post_offices for all to authenticated
using (is_admin())
with check (is_admin());

drop policy if exists "staff can read service areas" on public.post_office_service_areas;
create policy "staff can read service areas"
on public.post_office_service_areas for select to authenticated
using (is_staff());

drop policy if exists "admins manage service areas" on public.post_office_service_areas;
create policy "admins manage service areas"
on public.post_office_service_areas for all to authenticated
using (is_admin())
with check (is_admin());

drop policy if exists "users read their profile" on public.profiles;
create policy "users read their profile"
on public.profiles for select to authenticated
using (id = auth.uid() or is_admin());

drop policy if exists "users update their profile" on public.profiles;
create policy "users update their profile"
on public.profiles for update to authenticated
using (id = auth.uid() or is_admin())
with check (id = auth.uid() or is_admin());

drop policy if exists "users read their role" on public.user_roles;
create policy "users read their role"
on public.user_roles for select to authenticated
using (user_id = auth.uid() or is_admin());

drop policy if exists "admins manage roles" on public.user_roles;
create policy "admins manage roles"
on public.user_roles for all to authenticated
using (is_admin())
with check (is_admin());

drop policy if exists "staff read parcels" on public.parcels;
create policy "staff read parcels"
on public.parcels for select to authenticated
using (is_staff());

drop policy if exists "staff create parcels" on public.parcels;
create policy "staff create parcels"
on public.parcels for insert to authenticated
with check (is_staff() and created_by = auth.uid());

drop policy if exists "staff update parcels" on public.parcels;
create policy "staff update parcels"
on public.parcels for update to authenticated
using (is_staff())
with check (is_staff());

drop policy if exists "admins delete parcels" on public.parcels;
create policy "admins delete parcels"
on public.parcels for delete to authenticated
using (is_admin());

drop policy if exists "staff read processing runs" on public.parcel_processing_runs;
create policy "staff read processing runs"
on public.parcel_processing_runs for select to authenticated
using (is_staff());

drop policy if exists "staff create processing runs" on public.parcel_processing_runs;
create policy "staff create processing runs"
on public.parcel_processing_runs for insert to authenticated
with check (is_staff() and requested_by = auth.uid());

drop policy if exists "staff update processing runs" on public.parcel_processing_runs;
create policy "staff update processing runs"
on public.parcel_processing_runs for update to authenticated
using (is_staff())
with check (is_staff());

drop policy if exists "staff read tracking events" on public.tracking_events;
create policy "staff read tracking events"
on public.tracking_events for select to authenticated
using (is_staff());

drop policy if exists "staff create tracking events" on public.tracking_events;
create policy "staff create tracking events"
on public.tracking_events for insert to authenticated
with check (is_staff() and (created_by is null or created_by = auth.uid()));

drop policy if exists "staff read delivery attempts" on public.delivery_attempts;
create policy "staff read delivery attempts"
on public.delivery_attempts for select to authenticated
using (is_staff());

drop policy if exists "staff create delivery attempts" on public.delivery_attempts;
create policy "staff create delivery attempts"
on public.delivery_attempts for insert to authenticated
with check (is_staff() and (attempted_by is null or attempted_by = auth.uid()));

drop policy if exists "staff update delivery attempts" on public.delivery_attempts;
create policy "staff update delivery attempts"
on public.delivery_attempts for update to authenticated
using (is_staff())
with check (is_staff());

drop policy if exists "staff read pickup recommendations" on public.pickup_recommendations;
create policy "staff read pickup recommendations"
on public.pickup_recommendations for select to authenticated
using (is_staff());

drop policy if exists "staff manage pickup recommendations" on public.pickup_recommendations;
create policy "staff manage pickup recommendations"
on public.pickup_recommendations for all to authenticated
using (is_staff())
with check (is_staff());

drop policy if exists "admins read audit logs" on public.audit_logs;
create policy "admins read audit logs"
on public.audit_logs for select to authenticated
using (is_admin());

-- ---------------------------------------------------------------------------
-- Demo postal records used by the current static prototype.
-- Safe to re-run because office_code and PIN are unique.
-- ---------------------------------------------------------------------------

insert into public.post_offices
  (office_code, name, office_type, address_line1, city, state, pin_code)
values
  ('GANDHINAGAR-HO', 'Gandhinagar Head Post Office', 'head_post_office',
   'Sector 11', 'Gandhinagar', 'Gujarat', '382010'),
  ('AHMEDABAD-HO', 'Ahmedabad Head Post Office', 'head_post_office',
   'Lal Darwaja', 'Ahmedabad', 'Gujarat', '380001'),
  ('PATNA-GPO', 'Patna GPO', 'head_post_office',
   'Patna', 'Patna', 'Bihar', '800001'),
  ('NEW-DELHI-GPO', 'New Delhi GPO', 'head_post_office',
   'Connaught Place', 'New Delhi', 'Delhi', '110001')
on conflict (office_code) do nothing;

insert into public.post_office_service_areas (pin_code, post_office_id, city, state)
select values_data.pin_code, po.id, values_data.city, values_data.state
from (
  values
    ('382010', 'GANDHINAGAR-HO', 'Gandhinagar', 'Gujarat'),
    ('380001', 'AHMEDABAD-HO', 'Ahmedabad', 'Gujarat'),
    ('800001', 'PATNA-GPO', 'Patna', 'Bihar'),
    ('110001', 'NEW-DELHI-GPO', 'New Delhi', 'Delhi')
) as values_data(pin_code, office_code, city, state)
join public.post_offices po on po.office_code = values_data.office_code
on conflict (pin_code) do update
set post_office_id = excluded.post_office_id,
    city = excluded.city,
    state = excluded.state;

-- ---------------------------------------------------------------------------
-- Admin promotion example. Replace the email before running manually.
-- Do not expose service-role credentials in the browser.
-- ---------------------------------------------------------------------------
--
-- update public.user_roles
-- set role = 'admin'
-- where user_id = (select id from auth.users where email = 'admin@example.com');
