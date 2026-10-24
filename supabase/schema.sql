-- ============================================================
-- LPU Scheduler — Full schema (fresh install)
-- ============================================================

create extension if not exists pgcrypto;

-- 1. profiles
create table profiles (
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

create index profiles_active on profiles (is_active);
create index profiles_role on profiles (role);
create index profiles_last_active on profiles (last_active_at desc nulls last);

-- 2. auto-create profile on signup
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

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- 3. buildings
create table buildings (
  id text primary key,
  name text not null,
  address text,
  is_active boolean default true,
  sort_order int default 0,
  created_at timestamptz default now()
);

-- 4. building_floors
create table building_floors (
  id uuid primary key default gen_random_uuid(),
  building_id text references buildings(id) on delete cascade,
  floor int not null check (floor >= 1 and floor <= 20),
  is_active boolean default true,
  unique(building_id, floor)
);

-- 5. room_types
create table room_types (
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
  ('other',    'Other',     'fa-ellipsis',        false, 10);

-- 6. rooms
create table rooms (
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

create index rooms_lookup on rooms (building, floor, bookable);

-- 7. time_slots
create table time_slots (
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
  ('P7','15:10','16:00','7th period',7);

-- 8. sections
create table sections (
  section_id text primary key,
  name text not null,
  strength int default 60,
  department text
);

-- 9. bookings
create table bookings (
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

create unique index bookings_no_overlap
  on bookings (room_id, book_date, slot_id)
  where status in ('pending','approved');

create index bookings_date_slot on bookings (book_date, slot_id, status);
create index bookings_faculty on bookings (faculty_id, book_date);
create index bookings_section on bookings (section_id, book_date);

-- 10. activity_log
create table activity_log (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references profiles(id) on delete set null,
  user_email text,
  action text not null,
  entity text,
  entity_id text,
  details jsonb,
  created_at timestamptz default now()
);

create index activity_log_created on activity_log (created_at desc);
create index activity_log_user on activity_log (user_id);

-- 11. Enable RLS
alter table profiles        enable row level security;
alter table buildings       enable row level security;
alter table building_floors enable row level security;
alter table room_types      enable row level security;
alter table rooms           enable row level security;
alter table sections        enable row level security;
alter table bookings        enable row level security;
alter table time_slots      enable row level security;
alter table activity_log    enable row level security;

-- 12. my_role helper (needed by policies)
create or replace function my_role() returns text
language sql stable security definer as $$
  select coalesce((select role from profiles where id = auth.uid()), 'student');
$$;

-- 13. Policies
create policy "profiles read" on profiles for select
  using (id = auth.uid() or my_role() = 'admin');
create policy "profiles admin write" on profiles for all
  using (my_role() = 'admin') with check (my_role() = 'admin');
create policy "profiles self update" on profiles for update
  using (id = auth.uid()) with check (id = auth.uid());

create policy "buildings read" on buildings for select using (auth.role() = 'authenticated');
create policy "buildings write" on buildings for all using (my_role() = 'admin') with check (my_role() = 'admin');

create policy "floors read" on building_floors for select using (auth.role() = 'authenticated');
create policy "floors write" on building_floors for all using (my_role() = 'admin') with check (my_role() = 'admin');

create policy "types read" on room_types for select using (auth.role() = 'authenticated');
create policy "types write" on room_types for all using (my_role() = 'admin') with check (my_role() = 'admin');

create policy "rooms read" on rooms for select using (auth.role() = 'authenticated');
create policy "rooms admin write" on rooms for all using (my_role() = 'admin') with check (my_role() = 'admin');

create policy "sections read" on sections for select using (auth.role() = 'authenticated');
create policy "sections admin write" on sections for all using (my_role() = 'admin') with check (my_role() = 'admin');

create policy "slots read" on time_slots for select using (true);
create policy "slots admin write" on time_slots for all using (my_role() = 'admin') with check (my_role() = 'admin');

create policy "bookings read" on bookings for select using (
  status = 'approved' or my_role() = 'admin'
  or faculty_id = auth.uid() or created_by = auth.uid()
);
create policy "bookings insert" on bookings for insert with check (
  my_role() in ('faculty','admin') and created_by = auth.uid()
);
create policy "bookings update" on bookings for update using (
  my_role() = 'admin' or (faculty_id = auth.uid() and status = 'pending')
);
create policy "bookings delete" on bookings for delete using (
  my_role() = 'admin' or (created_by = auth.uid() and status = 'pending')
);

create policy "activity admin read" on activity_log for select using (my_role() = 'admin');
create policy "activity self read" on activity_log for select using (user_id = auth.uid());

-- 14. RPCs
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

-- 15. Logging triggers
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

create trigger trg_log_profile after insert or update or delete on profiles
  for each row execute function log_profile_change();

-- 16. Seed data
insert into buildings (id, name) values
  ('25', 'Block 25'), ('26', 'Block 26'), ('27', 'Block 27'), ('28', 'Block 28');

insert into building_floors (building_id, floor) values
  ('25', 1),('25', 2),('25', 3),('25', 4),
  ('26', 1),('26', 2),('26', 3),('26', 4),
  ('27', 1),('27', 2),('27', 3),('27', 4),
  ('28', 1),('28', 2),('28', 3),('28', 4);

insert into rooms (room_id, display_name, building, floor, floor_digit, room_number, suffix, type, capacity, bookable, weekend_open, facilities) values
  ('27-107', '27-107',   '27',1,'1','07','', 'lecture',60,true, false,'{projector,fan}'),
  ('27-107A','27-107 A', '27',1,'1','07','A','lecture',60,true, false,'{projector,fan}'),
  ('27-108', '27-108',   '27',1,'1','08','', 'lab',    30,true, true, '{computers,ac}'),
  ('27-207A','27-207 A', '27',2,'2','07','A','lecture',60,true, false,'{projector,fan}'),
  ('27-208', '27-208',   '27',2,'2','08','', 'lab',    30,true, false,'{computers,ac}');

select 'Step 2 done — run test-users now' as status;