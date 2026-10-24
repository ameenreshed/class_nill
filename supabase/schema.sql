-- ============================================================
-- LPU Scheduler — Complete schema
-- Run once in Supabase SQL editor
-- ============================================================

create extension if not exists pgcrypto;

-- ---------- profiles ----------
create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text unique not null,
  full_name text,
  role text not null default 'student' check (role in ('admin','faculty','student')),
  department text,
  phone text,
  is_active boolean default true,
  password_changed_at timestamptz,
  suspended_at timestamptz,
  suspended_reason text,
  last_active_at timestamptz default now(),
  created_at timestamptz default now()
);

create index if not exists profiles_active on profiles (is_active);
create index if not exists profiles_role on profiles (role);
create index if not exists profiles_last_active on profiles (last_active_at desc nulls last);

create or replace function handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  insert into public.profiles (id, email, full_name, role, is_active)
  values (
    new.id, new.email,
    coalesce(new.raw_user_meta_data->>'full_name', new.email),
    'student', true
  )
  on conflict (id) do nothing;
  return new;
end; $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- ---------- buildings ----------
create table if not exists buildings (
  id text primary key,
  name text not null,
  address text,
  is_active boolean default true,
  sort_order int default 0,
  created_at timestamptz default now()
);

create table if not exists building_floors (
  id uuid primary key default gen_random_uuid(),
  building_id text references buildings(id) on delete cascade,
  floor int not null check (floor >= 1 and floor <= 20),
  is_active boolean default true,
  unique(building_id, floor)
);

-- ---------- room types ----------
create table if not exists room_types (
  id text primary key,
  label text not null,
  icon text default 'fa-door-open',
  bookable boolean default true,
  color text default '#EA580C',
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

-- ---------- rooms ----------
create table if not exists rooms (
  room_id text primary key,
  display_name text not null,
  building text not null,
  floor int not null check (floor between 1 and 20),
  floor_digit text not null,
  room_number text not null,
  suffix text default '',
  type text not null references room_types(id),
  capacity int,
  bookable boolean default true,
  weekend_open boolean default false,
  facilities text[] default '{}',
  notes text,
  created_at timestamptz default now()
);

create index if not exists rooms_lookup on rooms (building, floor, bookable);

-- ---------- time slots ----------
create table if not exists time_slots (
  slot_id text primary key,
  start_time time not null,
  end_time time not null,
  label text,
  is_active boolean default true,
  sort_order int default 0
);

insert into time_slots (slot_id, start_time, end_time, label, sort_order) values
  ('P1','09:00','09:50','1st period',1),
  ('P2','09:50','10:40','2nd period',2),
  ('P3','10:50','11:40','3rd period',3),
  ('P4','11:40','12:30','4th period',4),
  ('P5','13:30','14:20','5th period',5),
  ('P6','14:20','15:10','6th period',6),
  ('P7','15:10','16:00','7th period',7)
on conflict (slot_id) do nothing;

-- ---------- sections ----------
create table if not exists sections (
  section_id text primary key,
  name text not null,
  strength int default 60,
  department text
);

-- ---------- bookings ----------
create table if not exists bookings (
  id uuid primary key default gen_random_uuid(),
  room_id text not null references rooms(room_id) on delete cascade,
  book_date date not null,
  slot_id text not null references time_slots(slot_id),
  type text not null check (type in ('regular','makeup','exam','event','maintenance')),
  section_id text references sections(section_id),
  faculty_id uuid references profiles(id) on delete set null,
  course_code text,
  status text not null default 'pending' check (status in ('pending','approved','rejected','cancelled')),
  reason text,
  created_by uuid references profiles(id) on delete set null,
  approved_by uuid references profiles(id) on delete set null,
  created_at timestamptz default now()
);

create unique index if not exists bookings_no_overlap
  on bookings (room_id, book_date, slot_id)
  where status in ('pending','approved');

create index if not exists bookings_date_slot on bookings (book_date, slot_id, status);
create index if not exists bookings_faculty on bookings (faculty_id, book_date);
create index if not exists bookings_section on bookings (section_id, book_date);

-- ---------- activity log ----------
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

-- ---------- RLS ----------
alter table profiles enable row level security;
alter table buildings enable row level security;
alter table building_floors enable row level security;
alter table room_types enable row level security;
alter table rooms enable row level security;
alter table sections enable row level security;
alter table bookings enable row level security;
alter table time_slots enable row level security;
alter table activity_log enable row level security;

create or replace function my_role() returns text
language sql stable security definer as $$
  select coalesce((select role from profiles where id = auth.uid()), 'student');
$$;

-- profiles
drop policy if exists "profiles read" on profiles;
create policy "profiles read" on profiles for select
  using (id = auth.uid() or my_role() = 'admin');
drop policy if exists "profiles admin write" on profiles;
create policy "profiles admin write" on profiles for all
  using (my_role() = 'admin') with check (my_role() = 'admin');
drop policy if exists "profiles self update" on profiles;
create policy "profiles self update" on profiles for update
  using (id = auth.uid()) with check (id = auth.uid());

-- buildings / floors / types
drop policy if exists "buildings read" on buildings;
create policy "buildings read" on buildings for select using (auth.role() = 'authenticated');
drop policy if exists "buildings write" on buildings;
create policy "buildings write" on buildings for all using (my_role() = 'admin') with check (my_role() = 'admin');

drop policy if exists "floors read" on building_floors;
create policy "floors read" on building_floors for select using (auth.role() = 'authenticated');
drop policy if exists "floors write" on building_floors;
create policy "floors write" on building_floors for all using (my_role() = 'admin') with check (my_role() = 'admin');

drop policy if exists "types read" on room_types;
create policy "types read" on room_types for select using (auth.role() = 'authenticated');
drop policy if exists "types write" on room_types;
create policy "types write" on room_types for all using (my_role() = 'admin') with check (my_role() = 'admin');

-- rooms
drop policy if exists "rooms read" on rooms;
create policy "rooms read" on rooms for select using (auth.role() = 'authenticated');
drop policy if exists "rooms admin write" on rooms;
create policy "rooms admin write" on rooms for all using (my_role() = 'admin') with check (my_role() = 'admin');

-- sections
drop policy if exists "sections read" on sections;
create policy "sections read" on sections for select using (auth.role() = 'authenticated');
drop policy if exists "sections admin write" on sections;
create policy "sections admin write" on sections for all using (my_role() = 'admin') with check (my_role() = 'admin');

-- time slots
drop policy if exists "slots read" on time_slots;
create policy "slots read" on time_slots for select using (true);
drop policy if exists "slots admin write" on time_slots;
create policy "slots admin write" on time_slots for all using (my_role() = 'admin') with check (my_role() = 'admin');

-- bookings
drop policy if exists "bookings read" on bookings;
create policy "bookings read" on bookings for select using (
  status = 'approved' or my_role() = 'admin'
  or faculty_id = auth.uid() or created_by = auth.uid()
);
drop policy if exists "bookings insert" on bookings;
create policy "bookings insert" on bookings for insert with check (
  my_role() in ('faculty','admin') and created_by = auth.uid()
);
drop policy if exists "bookings update" on bookings;
create policy "bookings update" on bookings for update using (
  my_role() = 'admin' or (faculty_id = auth.uid() and status = 'pending')
);
drop policy if exists "bookings delete" on bookings;
create policy "bookings delete" on bookings for delete using (
  my_role() = 'admin' or (created_by = auth.uid() and status = 'pending')
);

-- activity log
drop policy if exists "activity admin read" on activity_log;
create policy "activity admin read" on activity_log for select using (my_role() = 'admin');
drop policy if exists "activity self read" on activity_log;
create policy "activity self read" on activity_log for select using (user_id = auth.uid());

-- ---------- RPCs ----------
create or replace function update_my_profile(p_full_name text, p_phone text)
returns void language plpgsql security definer set search_path = public as $$
begin
  update profiles
  set full_name = coalesce(nullif(trim(p_full_name), ''), full_name),
      phone = nullif(trim(p_phone), ''),
      last_active_at = now()
  where id = auth.uid();
end; $$;
grant execute on function update_my_profile(text, text) to authenticated;

create or replace function mark_password_changed()
returns void language plpgsql security definer set search_path = public as $$
begin
  update profiles set password_changed_at = now() where id = auth.uid();
end; $$;
grant execute on function mark_password_changed() to authenticated;

create or replace function heartbeat()
returns void language plpgsql security definer set search_path = public as $$
begin
  update profiles set last_active_at = now() where id = auth.uid();
end; $$;
grant execute on function heartbeat() to authenticated;

create or replace function log_login(p_user_agent text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into activity_log (user_id, user_email, action, entity, details)
  select auth.uid(), email, 'auth.login', 'session',
         jsonb_build_object('user_agent', coalesce(p_user_agent, 'unknown'))
  from profiles where id = auth.uid();
end; $$;
grant execute on function log_login(text) to authenticated;

create or replace function server_now() returns timestamptz
language sql stable as $$ select now(); $$;
grant execute on function server_now() to authenticated, anon;

-- ---------- logging triggers ----------
create or replace function log_room_change()
returns trigger language plpgsql security definer as $$
declare v_email text;
begin
  select email into v_email from profiles where id = auth.uid();
  insert into activity_log (user_id, user_email, action, entity, entity_id, details)
  values (auth.uid(), v_email,
    case TG_OP when 'INSERT' then 'room.create' when 'UPDATE' then 'room.update' when 'DELETE' then 'room.delete' end,
    'room', coalesce(NEW.room_id, OLD.room_id),
    case when TG_OP = 'DELETE' then to_jsonb(OLD) else to_jsonb(NEW) end);
  return coalesce(NEW, OLD);
end; $$;
drop trigger if exists trg_log_room on rooms;
create trigger trg_log_room after insert or update or delete on rooms
  for each row execute function log_room_change();

create or replace function log_booking_change()
returns trigger language plpgsql security definer as $$
declare v_email text;
begin
  select email into v_email from profiles where id = auth.uid();
  insert into activity_log (user_id, user_email, action, entity, entity_id, details)
  values (auth.uid(), v_email, 'booking.' || lower(TG_OP),
    'booking', coalesce(NEW.id, OLD.id)::text,
    case when TG_OP = 'DELETE' then to_jsonb(OLD) else to_jsonb(NEW) end);
  return coalesce(NEW, OLD);
end; $$;
drop trigger if exists trg_log_booking on bookings;
create trigger trg_log_booking after insert or update or delete on bookings
  for each row execute function log_booking_change();

create or replace function log_profile_change()
returns trigger language plpgsql security definer as $$
declare v_email text;
begin
  if TG_OP = 'UPDATE' then
    if NEW.last_active_at is distinct from OLD.last_active_at
       and NEW.full_name is not distinct from OLD.full_name
       and NEW.phone is not distinct from OLD.phone
       and NEW.role is not distinct from OLD.role
       and NEW.is_active is not distinct from OLD.is_active
       and NEW.department is not distinct from OLD.department then
      return NEW;
    end if;
  end if;
  select email into v_email from profiles where id = auth.uid();
  insert into activity_log (user_id, user_email, action, entity, entity_id, details)
  values (auth.uid(), v_email, 'user.' || lower(TG_OP),
    'profile', coalesce(NEW.id, OLD.id)::text,
    case when TG_OP = 'DELETE' then to_jsonb(OLD) else to_jsonb(NEW) end);
  return coalesce(NEW, OLD);
end; $$;
drop trigger if exists trg_log_profile on profiles;
create trigger trg_log_profile after insert or update or delete on profiles
  for each row execute function log_profile_change();

-- ---------- Seed data ----------
insert into buildings (id, name) values
  ('25', 'Block 25'), ('26', 'Block 26'), ('27', 'Block 27'), ('28', 'Block 28')
on conflict (id) do nothing;

insert into building_floors (building_id, floor) values
  ('25', 1),('25', 2),('25', 3),('25', 4),
  ('26', 1),('26', 2),('26', 3),('26', 4),
  ('27', 1),('27', 2),('27', 3),('27', 4),
  ('28', 1),('28', 2),('28', 3),('28', 4)
on conflict (building_id, floor) do nothing;

insert into rooms (room_id, display_name, building, floor, floor_digit, room_number, suffix, type, capacity, bookable, weekend_open, facilities) values
  ('27-107', '27-107',   '27',1,'1','07','', 'lecture',60,true, false,'{projector,fan}'),
  ('27-107A','27-107 A', '27',1,'1','07','A','lecture',60,true, false,'{projector,fan}'),
  ('27-108', '27-108',   '27',1,'1','08','', 'lab',    30,true, true, '{computers,ac}'),
  ('27-207A','27-207 A', '27',2,'2','07','A','lecture',60,true, false,'{projector,fan}'),
  ('27-208', '27-208',   '27',2,'2','08','', 'lab',    30,true, false,'{computers,ac}')
on conflict (room_id) do nothing;

select 'Setup complete' as status;