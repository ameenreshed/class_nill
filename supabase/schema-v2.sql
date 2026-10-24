-- ============================================================
-- Phase 2 migration
-- ============================================================

-- ---- Buildings ----
create table if not exists buildings (
  id text primary key,
  name text not null,
  address text,
  is_active boolean default true,
  sort_order int default 0,
  created_at timestamptz default now()
);

insert into buildings (id, name)
select distinct building, 'Block ' || building from rooms
where building is not null
on conflict (id) do nothing;

-- ---- Floors per building ----
create table if not exists building_floors (
  id uuid primary key default gen_random_uuid(),
  building_id text references buildings(id) on delete cascade,
  floor int not null check (floor >= 1 and floor <= 20),
  is_active boolean default true,
  unique(building_id, floor)
);

insert into building_floors (building_id, floor)
select distinct building, floor from rooms
on conflict do nothing;

-- ---- Room types ----
create table if not exists room_types (
  id text primary key,
  label text not null,
  icon text default 'fa-door-open',
  bookable boolean default true,
  color text default '#F97316',
  is_active boolean default true,
  sort_order int default 0,
  created_at timestamptz default now()
);

insert into room_types (id, label, icon, bookable, sort_order) values
  ('lecture',  'Lecture',   'fa-chalkboard-user', true,  1),
  ('lab',      'Lab',       'fa-flask',           true,  2),
  ('seminar',  'Seminar',   'fa-users-rectangle', true,  3),
  ('library',  'Library',   'fa-book',            true,  4),
  ('staffroom','Staffroom', 'fa-user-tie',        false, 5),
  ('hod',      'HOD Cabin', 'fa-crown',           false, 6),
  ('office',   'Office',    'fa-briefcase',       false, 7),
  ('store',    'Store',     'fa-box',             false, 8),
  ('washroom', 'Washroom',  'fa-restroom',        false, 9),
  ('other',    'Other',     'fa-ellipsis',        false, 10)
on conflict (id) do nothing;

-- ---- Alter rooms: type now FK ----
alter table rooms drop constraint if exists rooms_type_check;
alter table rooms drop constraint if exists rooms_type_fk;
alter table rooms add constraint rooms_type_fk
  foreign key (type) references room_types(id);

-- ---- Alter time_slots ----
alter table time_slots add column if not exists is_active boolean default true;
alter table time_slots add column if not exists sort_order int default 0;

-- ---- Activity log ----
create table if not exists activity_log (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references profiles(id) on delete set null,
  user_email text,
  action text not null,
  entity text,
  entity_id text,
  details jsonb,
  created_at timestamptz default now()
);

create index if not exists activity_log_created on activity_log (created_at desc);
create index if not exists activity_log_user on activity_log (user_id);

-- ---- Trigger: log room changes ----
create or replace function log_room_change()
returns trigger language plpgsql security definer as $$
declare v_email text;
begin
  select email into v_email from profiles where id = auth.uid();
  insert into activity_log (user_id, user_email, action, entity, entity_id, details)
  values (
    auth.uid(), v_email,
    case TG_OP
      when 'INSERT' then 'room.create'
      when 'UPDATE' then 'room.update'
      when 'DELETE' then 'room.delete'
    end,
    'room',
    coalesce(NEW.room_id, OLD.room_id),
    case when TG_OP = 'DELETE' then to_jsonb(OLD) else to_jsonb(NEW) end
  );
  return coalesce(NEW, OLD);
end; $$;

drop trigger if exists trg_log_room on rooms;
create trigger trg_log_room
  after insert or update or delete on rooms
  for each row execute function log_room_change();

-- ---- Trigger: log booking changes ----
create or replace function log_booking_change()
returns trigger language plpgsql security definer as $$
declare v_email text;
begin
  select email into v_email from profiles where id = auth.uid();
  insert into activity_log (user_id, user_email, action, entity, entity_id, details)
  values (
    auth.uid(), v_email,
    'booking.' || lower(TG_OP),
    'booking',
    coalesce(NEW.id, OLD.id)::text,
    case when TG_OP = 'DELETE' then to_jsonb(OLD) else to_jsonb(NEW) end
  );
  return coalesce(NEW, OLD);
end; $$;

drop trigger if exists trg_log_booking on bookings;
create trigger trg_log_booking
  after insert or update or delete on bookings
  for each row execute function log_booking_change();

-- ---- RLS ----
alter table buildings enable row level security;
alter table building_floors enable row level security;
alter table room_types enable row level security;
alter table activity_log enable row level security;

drop policy if exists "buildings read" on buildings;
create policy "buildings read" on buildings for select using (auth.role() = 'authenticated');
drop policy if exists "buildings write" on buildings;
create policy "buildings write" on buildings for all
  using (my_role() = 'admin') with check (my_role() = 'admin');

drop policy if exists "floors read" on building_floors;
create policy "floors read" on building_floors for select using (auth.role() = 'authenticated');
drop policy if exists "floors write" on building_floors;
create policy "floors write" on building_floors for all
  using (my_role() = 'admin') with check (my_role() = 'admin');

drop policy if exists "types read" on room_types;
create policy "types read" on room_types for select using (auth.role() = 'authenticated');
drop policy if exists "types write" on room_types;
create policy "types write" on room_types for all
  using (my_role() = 'admin') with check (my_role() = 'admin');

drop policy if exists "activity admin read" on activity_log;
create policy "activity admin read" on activity_log for select
  using (my_role() = 'admin');

drop policy if exists "slots admin write" on time_slots;
create policy "slots admin write" on time_slots for all
  using (my_role() = 'admin') with check (my_role() = 'admin');

-- ---- Server time function (for NTP-equivalent sync) ----
create or replace function server_now() returns timestamptz
language sql stable as $$ select now(); $$;
grant execute on function server_now() to authenticated, anon;

-- ---- Extend profile activity ----
alter table profiles add column if not exists last_active_at timestamptz default now();