-- ============================================================
-- LPU Scheduler — complete schema (admin + faculty only)
-- Run this ONCE in Supabase SQL Editor
-- ============================================================

create extension if not exists pgcrypto;

-- ---------- profiles ----------
create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text unique not null,
  full_name text,
  role text not null default 'faculty' check (role in ('admin','faculty')),
  department text,
  phone text,
  is_active boolean default true,
  suspended_at timestamptz,
  suspended_reason text,
  last_active_at timestamptz default now(),
  created_at timestamptz default now()
);
create index if not exists profiles_role on profiles (role);

create or replace function handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  insert into public.profiles (id, email, full_name, role, is_active)
  values (new.id, new.email,
    coalesce(new.raw_user_meta_data->>'full_name', new.email),
    'faculty', true)
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
  ('office',   'Office',    'fa-briefcase',       false, 6),
  ('store',    'Store',     'fa-box',             false, 7),
  ('other',    'Other',     'fa-ellipsis',        false, 8)
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

-- ---------- timetable ----------
create table if not exists timetable (
  id uuid primary key default gen_random_uuid(),
  day_of_week int not null check (day_of_week between 0 and 6),
  slot_id text not null references time_slots(slot_id) on delete cascade,
  room_id text not null references rooms(room_id) on delete cascade,
  faculty_id uuid references profiles(id) on delete set null,
  course_code text,
  course_name text,
  is_active boolean default true,
  created_at timestamptz default now(),
  unique(faculty_id, day_of_week, slot_id)
);
create index if not exists tt_room_slot on timetable (room_id, day_of_week, slot_id);
create index if not exists tt_faculty on timetable (faculty_id, day_of_week);

-- ---------- bookings ----------
create table if not exists bookings (
  id uuid primary key default gen_random_uuid(),
  room_id text not null references rooms(room_id) on delete cascade,
  book_date date not null,
  slot_id text not null references time_slots(slot_id),
  type text not null check (type in ('regular','makeup','exam','event','maintenance')),
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
create index if not exists bookings_date on bookings (book_date, slot_id, status);
create index if not exists bookings_faculty on bookings (faculty_id, book_date);

-- ---------- faculty leave ----------
create table if not exists faculty_unavailability (
  id uuid primary key default gen_random_uuid(),
  faculty_id uuid not null references profiles(id) on delete cascade,
  date date not null,
  slot_id text references time_slots(slot_id) on delete cascade,
  reason text,
  created_at timestamptz default now(),
  unique(faculty_id, date, slot_id)
);
create index if not exists fu_lookup on faculty_unavailability (date, faculty_id);

-- ---------- academic calendar ----------
create table if not exists academic_calendar (
  date date primary key,
  kind text not null check (kind in ('holiday','event','exam_week','working_saturday','special')),
  label text,
  created_at timestamptz default now()
);

-- ---------- settings ----------
create table if not exists system_settings (
  key text primary key,
  value jsonb not null default 'null'::jsonb,
  updated_at timestamptz default now()
);
insert into system_settings (key, value) values
  ('booking_auto_approve',   'false'::jsonb),
  ('allow_faculty_makeup',   'true'::jsonb),
  ('allow_faculty_exam',     'true'::jsonb),
  ('allow_faculty_event',    'true'::jsonb),
  ('site_banner',            '""'::jsonb),
  ('lpu_api_url',            '""'::jsonb),
  ('lpu_api_key',            '""'::jsonb)
on conflict (key) do nothing;

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
create index if not exists al_created on activity_log (created_at desc);

-- ============================================================
-- RLS
-- ============================================================
alter table profiles enable row level security;
alter table buildings enable row level security;
alter table building_floors enable row level security;
alter table room_types enable row level security;
alter table rooms enable row level security;
alter table timetable enable row level security;
alter table bookings enable row level security;
alter table time_slots enable row level security;
alter table faculty_unavailability enable row level security;
alter table academic_calendar enable row level security;
alter table system_settings enable row level security;
alter table activity_log enable row level security;

create or replace function my_role() returns text
language sql stable security definer as $$
  select coalesce((select role from profiles where id = auth.uid()), 'faculty');
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
  using (id = auth.uid()) with check (id = auth.uid() and role = (select role from profiles where id = auth.uid()));

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
drop policy if exists "rooms write" on rooms;
create policy "rooms write" on rooms for all using (my_role() = 'admin') with check (my_role() = 'admin');

-- timetable
drop policy if exists "tt read" on timetable;
create policy "tt read" on timetable for select using (auth.role() = 'authenticated');
drop policy if exists "tt admin write" on timetable;
create policy "tt admin write" on timetable for all using (my_role() = 'admin') with check (my_role() = 'admin');

-- time slots
drop policy if exists "slots read" on time_slots;
create policy "slots read" on time_slots for select using (true);
drop policy if exists "slots write" on time_slots;
create policy "slots write" on time_slots for all using (my_role() = 'admin') with check (my_role() = 'admin');

-- bookings
drop policy if exists "bk read" on bookings;
create policy "bk read" on bookings for select using (auth.role() = 'authenticated');
drop policy if exists "bk insert" on bookings;
create policy "bk insert" on bookings for insert with check (
  my_role() in ('faculty','admin') and created_by = auth.uid()
);
drop policy if exists "bk update" on bookings;
create policy "bk update" on bookings for update using (
  my_role() = 'admin' or (faculty_id = auth.uid() and status in ('pending','approved'))
);
drop policy if exists "bk delete" on bookings;
create policy "bk delete" on bookings for delete using (my_role() = 'admin');

-- faculty unavailability
drop policy if exists "fu read" on faculty_unavailability;
create policy "fu read" on faculty_unavailability for select using (auth.role() = 'authenticated');
drop policy if exists "fu write" on faculty_unavailability;
create policy "fu write" on faculty_unavailability for all
  using (faculty_id = auth.uid() or my_role() = 'admin')
  with check (faculty_id = auth.uid() or my_role() = 'admin');

-- calendar
drop policy if exists "cal read" on academic_calendar;
create policy "cal read" on academic_calendar for select using (auth.role() = 'authenticated');
drop policy if exists "cal write" on academic_calendar;
create policy "cal write" on academic_calendar for all using (my_role() = 'admin') with check (my_role() = 'admin');

-- settings
drop policy if exists "settings read" on system_settings;
create policy "settings read" on system_settings for select using (auth.role() = 'authenticated');
drop policy if exists "settings write" on system_settings;
create policy "settings write" on system_settings for all using (my_role() = 'admin') with check (my_role() = 'admin');

-- activity log
drop policy if exists "al admin read" on activity_log;
create policy "al admin read" on activity_log for select using (my_role() = 'admin');
drop policy if exists "al self read" on activity_log;
create policy "al self read" on activity_log for select using (user_id = auth.uid());
drop policy if exists "al insert" on activity_log;
create policy "al insert" on activity_log for insert with check (auth.role() = 'authenticated');

-- ============================================================
-- RPCs
-- ============================================================
create or replace function admin_create_user(
  p_email text, p_password text, p_full_name text, p_role text,
  p_department text default null, p_phone text default null
)
returns jsonb language plpgsql security definer
set search_path = public, auth, extensions as $$
declare v_uid uuid; v_existing uuid;
begin
  if my_role() <> 'admin' then return jsonb_build_object('error', 'Admin only'); end if;
  if p_role not in ('admin','faculty') then
    return jsonb_build_object('error', 'Role must be admin or faculty');
  end if;
  if p_email is null or length(trim(p_email)) < 3 then
    return jsonb_build_object('error', 'Email required');
  end if;
  if p_password is null or length(p_password) < 6 then
    return jsonb_build_object('error', 'Password must be 6+ characters');
  end if;
  p_email := lower(trim(p_email));
  select id into v_existing from auth.users where email = p_email;
  if v_existing is not null then
    return jsonb_build_object('error', 'Email already exists');
  end if;
  v_uid := gen_random_uuid();
  insert into auth.users (
    instance_id, id, aud, role, email, encrypted_password,
    email_confirmed_at, created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token,
    raw_app_meta_data, raw_user_meta_data
  ) values (
    '00000000-0000-0000-0000-000000000000', v_uid,
    'authenticated', 'authenticated', p_email,
    crypt(p_password, gen_salt('bf')), now(), now(), now(),
    '', '', '', '',
    jsonb_build_object('provider','email','providers',jsonb_build_array('email')),
    jsonb_build_object('full_name', coalesce(p_full_name, p_email))
  );
  insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), v_uid, v_uid::text, 'email',
    jsonb_build_object('sub', v_uid::text, 'email', p_email), now(), now(), now());
  insert into public.profiles (id, email, full_name, role, department, phone, is_active)
  values (v_uid, p_email, p_full_name, p_role, p_department, p_phone, true)
  on conflict (id) do update set
    full_name=excluded.full_name, role=excluded.role,
    department=excluded.department, phone=excluded.phone, is_active=true;
  return jsonb_build_object('success', true, 'user_id', v_uid);
end; $$;
grant execute on function admin_create_user(text,text,text,text,text,text) to authenticated;

create or replace function admin_reset_password(p_user_id uuid, p_new_password text)
returns jsonb language plpgsql security definer
set search_path = public, auth, extensions as $$
begin
  if my_role() <> 'admin' then return jsonb_build_object('error', 'Admin only'); end if;
  if p_new_password is null or length(p_new_password) < 6 then
    return jsonb_build_object('error', 'Password must be 6+ characters');
  end if;
  update auth.users
    set encrypted_password = crypt(p_new_password, gen_salt('bf')), updated_at = now()
    where id = p_user_id;
  if not found then return jsonb_build_object('error', 'User not found'); end if;
  return jsonb_build_object('success', true);
end; $$;
grant execute on function admin_reset_password(uuid, text) to authenticated;

create or replace function admin_delete_user(p_user_id uuid)
returns jsonb language plpgsql security definer
set search_path = public, auth as $$
begin
  if my_role() <> 'admin' then return jsonb_build_object('error', 'Admin only'); end if;
  if p_user_id = auth.uid() then return jsonb_build_object('error', 'Cannot delete yourself'); end if;
  delete from auth.users where id = p_user_id;
  if not found then return jsonb_build_object('error', 'User not found'); end if;
  return jsonb_build_object('success', true);
end; $$;
grant execute on function admin_delete_user(uuid) to authenticated;

create or replace function admin_set_setting(p_key text, p_value jsonb)
returns jsonb language plpgsql security definer as $$
begin
  if my_role() <> 'admin' then return jsonb_build_object('error', 'Admin only'); end if;
  insert into system_settings (key, value, updated_at) values (p_key, p_value, now())
    on conflict (key) do update set value = excluded.value, updated_at = now();
  return jsonb_build_object('success', true);
end; $$;
grant execute on function admin_set_setting(text, jsonb) to authenticated;

-- Auto-approve trigger
create or replace function apply_auto_approve()
returns trigger language plpgsql as $$
declare v_on boolean := false;
begin
  select coalesce((value)::text::boolean, false) into v_on
    from system_settings where key = 'booking_auto_approve';
  if v_on and new.status = 'pending' then new.status := 'approved'; end if;
  return new;
end; $$;

drop trigger if exists trg_auto_approve on bookings;
create trigger trg_auto_approve before insert on bookings
  for each row execute function apply_auto_approve();

-- Activity logging triggers
create or replace function log_booking_change()
returns trigger language plpgsql security definer as $$
declare v_email text;
begin
  select email into v_email from profiles where id = auth.uid();
  insert into activity_log (user_id, user_email, action, entity, entity_id, details)
  values (auth.uid(), v_email, 'booking.'||lower(TG_OP), 'booking',
    coalesce(new.id, old.id)::text,
    case when TG_OP='DELETE' then to_jsonb(old) else to_jsonb(new) end);
  return coalesce(new, old);
end; $$;
drop trigger if exists trg_log_booking on bookings;
create trigger trg_log_booking after insert or update or delete on bookings
  for each row execute function log_booking_change();

-- Seed buildings
insert into buildings (id, name) values
  ('25','Block 25'),('26','Block 26'),('27','Block 27'),('28','Block 28')
on conflict (id) do nothing;

insert into building_floors (building_id, floor) values
  ('25',1),('25',2),('25',3),('25',4),
  ('26',1),('26',2),('26',3),('26',4),
  ('27',1),('27',2),('27',3),('27',4),
  ('28',1),('28',2),('28',3),('28',4)
on conflict (building_id, floor) do nothing;

insert into rooms (room_id, display_name, building, floor, floor_digit, room_number, suffix, type, capacity, bookable, weekend_open, facilities) values
  ('27-107',  '27-107',   '27',1,'1','07','',  'lecture',60,true,false,'{projector,fan}'),
  ('27-107A', '27-107 A', '27',1,'1','07','A', 'lecture',60,true,false,'{projector,fan}'),
  ('27-108',  '27-108',   '27',1,'1','08','',  'lab',    30,true,true, '{computers,ac}'),
  ('27-207A', '27-207 A', '27',2,'2','07','A', 'lecture',60,true,false,'{projector,fan}'),
  ('27-208',  '27-208',   '27',2,'2','08','',  'lab',    30,true,false,'{computers,ac}')
on conflict (room_id) do nothing;

select 'Schema installed' as status;