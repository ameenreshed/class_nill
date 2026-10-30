-- ============================================================
-- LPU Scheduler — PRODUCTION CLEAN INSTALL
-- Run ONCE in Supabase SQL Editor
-- Drops EVERYTHING and rebuilds from scratch
-- Only creates: schema + config + one admin user
-- Everything else (rooms, faculty, timetable) added via UI
-- ============================================================

-- ============================================================
-- 1. DROP EVERYTHING
-- ============================================================
drop table if exists worker_calls cascade;
drop table if exists sync_log cascade;
drop table if exists activity_log cascade;
drop table if exists system_settings cascade;
drop table if exists academic_calendar cascade;
drop table if exists faculty_unavailability cascade;
drop table if exists bookings cascade;
drop table if exists timetable cascade;
drop table if exists courses cascade;
drop table if exists sections cascade;
drop table if exists time_slots cascade;
drop table if exists rooms cascade;
drop table if exists room_types cascade;
drop table if exists building_floors cascade;
drop table if exists buildings cascade;
drop table if exists profiles cascade;

drop function if exists admin_create_user(text,text,text,text,text,text,text) cascade;
drop function if exists admin_create_user(text,text,text,text,text,text) cascade;
drop function if exists admin_update_user(uuid,text,text,text,text,text,text) cascade;
drop function if exists admin_reset_password(uuid,text) cascade;
drop function if exists admin_delete_user(uuid) cascade;
drop function if exists admin_set_setting(text,jsonb) cascade;
drop function if exists admin_change_user_userid(uuid,text) cascade;
drop function if exists admin_bulk_change_userids(jsonb) cascade;
drop function if exists mark_password_changed() cascade;
drop function if exists handle_new_user() cascade;
drop function if exists my_role() cascade;
drop function if exists apply_auto_approve() cascade;
drop function if exists log_booking_change() cascade;
drop function if exists import_timetable(jsonb) cascade;

-- ============================================================
-- 2. EXTENSIONS
-- ============================================================
create extension if not exists pgcrypto;

-- ============================================================
-- 3. PROFILES
-- ============================================================
create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text unique not null,
  full_name text,
  role text not null default 'faculty' check (role in ('admin','faculty')),
  department text,
  phone text,
  is_active boolean default true,
  suspended_at timestamptz,
  suspended_reason text,
  password_changed_at timestamptz,
  last_active_at timestamptz default now(),
  created_at timestamptz default now()
);
create index profiles_role on profiles (role);

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

-- ============================================================
-- 4. BUILDINGS
-- ============================================================
create table buildings (
  id text primary key,
  name text not null,
  address text,
  is_active boolean default true,
  sort_order int default 0,
  created_at timestamptz default now()
);

create table building_floors (
  id uuid primary key default gen_random_uuid(),
  building_id text references buildings(id) on delete cascade,
  floor int not null check (floor >= 1 and floor <= 20),
  is_active boolean default true,
  unique(building_id, floor)
);

-- ============================================================
-- 5. ROOM TYPES (config — must be seeded)
-- ============================================================
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
  ('office',   'Office',    'fa-briefcase',       false, 6),
  ('store',    'Store',     'fa-box',             false, 7),
  ('other',    'Other',     'fa-ellipsis',        false, 8);

-- ============================================================
-- 6. ROOMS
-- ============================================================
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

-- ============================================================
-- 7. TIME SLOTS
-- ============================================================
create table time_slots (
  slot_id text primary key,
  start_time time not null,
  end_time time not null,
  label text,
  is_active boolean default true,
  sort_order int default 0
);

-- ============================================================
-- 8. TIMETABLE
-- ============================================================
create table timetable (
  id uuid primary key default gen_random_uuid(),
  day_of_week int not null check (day_of_week between 0 and 6),
  slot_id text not null references time_slots(slot_id) on delete cascade,
  room_id text not null references rooms(room_id) on delete cascade,
  faculty_id uuid references profiles(id) on delete set null,
  course_code text,
  course_name text,
  is_active boolean default true,
  created_at timestamptz default now()
);
create index tt_room_slot on timetable (room_id, day_of_week, slot_id);
create index tt_faculty on timetable (faculty_id, day_of_week);

-- ============================================================
-- 9. BOOKINGS
-- ============================================================
create table bookings (
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
create unique index bookings_no_overlap
  on bookings (room_id, book_date, slot_id)
  where status in ('pending','approved');
create index bookings_date on bookings (book_date, slot_id, status);
create index bookings_faculty on bookings (faculty_id, book_date);

-- ============================================================
-- 10. FACULTY UNAVAILABILITY (leave)
-- ============================================================
create table faculty_unavailability (
  id uuid primary key default gen_random_uuid(),
  faculty_id uuid not null references profiles(id) on delete cascade,
  date date not null,
  slot_id text references time_slots(slot_id) on delete cascade,
  reason text,
  created_at timestamptz default now(),
  unique(faculty_id, date, slot_id)
);
create index fu_lookup on faculty_unavailability (date, faculty_id);

-- ============================================================
-- 11. ACADEMIC CALENDAR
-- ============================================================
create table academic_calendar (
  date date primary key,
  kind text not null check (kind in ('holiday','event','exam_week','working_saturday','special')),
  label text,
  created_at timestamptz default now()
);

-- ============================================================
-- 12. SYSTEM SETTINGS
-- ============================================================
create table system_settings (
  key text primary key,
  value jsonb not null default 'null'::jsonb,
  updated_at timestamptz default now()
);

insert into system_settings (key, value) values
  ('booking_auto_approve', 'false'::jsonb),
  ('allow_faculty_makeup', 'true'::jsonb),
  ('allow_faculty_exam',   'true'::jsonb),
  ('allow_faculty_event',  'true'::jsonb),
  ('site_banner',          '""'::jsonb),
  ('lpu_api_url',          '""'::jsonb),
  ('lpu_api_key',          '""'::jsonb);

-- ============================================================
-- 13. ACTIVITY LOG
-- ============================================================
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
create index al_created on activity_log (created_at desc);

-- ============================================================
-- 14. ROW LEVEL SECURITY
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

create policy "profiles read" on profiles for select
  using (id = auth.uid() or my_role() = 'admin');
create policy "profiles admin write" on profiles for all
  using (my_role() = 'admin') with check (my_role() = 'admin');
create policy "profiles self update" on profiles for update
  using (id = auth.uid())
  with check (id = auth.uid() and role = (select role from profiles where id = auth.uid()));

create policy "buildings read" on buildings for select using (auth.role() = 'authenticated');
create policy "buildings write" on buildings for all using (my_role() = 'admin') with check (my_role() = 'admin');
create policy "floors read" on building_floors for select using (auth.role() = 'authenticated');
create policy "floors write" on building_floors for all using (my_role() = 'admin') with check (my_role() = 'admin');
create policy "types read" on room_types for select using (auth.role() = 'authenticated');
create policy "types write" on room_types for all using (my_role() = 'admin') with check (my_role() = 'admin');

create policy "rooms read" on rooms for select using (auth.role() = 'authenticated');
create policy "rooms write" on rooms for all using (my_role() = 'admin') with check (my_role() = 'admin');

create policy "tt read" on timetable for select using (auth.role() = 'authenticated');
create policy "tt write" on timetable for all using (my_role() = 'admin') with check (my_role() = 'admin');

create policy "slots read" on time_slots for select using (true);
create policy "slots write" on time_slots for all using (my_role() = 'admin') with check (my_role() = 'admin');

create policy "bk read" on bookings for select using (auth.role() = 'authenticated');
create policy "bk insert" on bookings for insert with check (
  my_role() in ('faculty','admin') and created_by = auth.uid()
);
create policy "bk update" on bookings for update using (
  my_role() = 'admin' or (faculty_id = auth.uid() and status in ('pending','approved'))
);
create policy "bk delete" on bookings for delete using (my_role() = 'admin');

create policy "fu read" on faculty_unavailability for select using (auth.role() = 'authenticated');
create policy "fu write" on faculty_unavailability for all
  using (faculty_id = auth.uid() or my_role() = 'admin')
  with check (faculty_id = auth.uid() or my_role() = 'admin');

create policy "cal read" on academic_calendar for select using (auth.role() = 'authenticated');
create policy "cal write" on academic_calendar for all using (my_role() = 'admin') with check (my_role() = 'admin');

create policy "settings read" on system_settings for select using (auth.role() = 'authenticated');
create policy "settings write" on system_settings for all using (my_role() = 'admin') with check (my_role() = 'admin');

create policy "al read" on activity_log for select using (my_role() = 'admin' or user_id = auth.uid());
create policy "al insert" on activity_log for insert with check (auth.role() = 'authenticated');

-- ============================================================
-- 15. RPCs
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

create or replace function admin_update_user(
  p_user_id uuid, p_full_name text, p_department text, p_phone text,
  p_role text, p_new_userid text default null, p_new_password text default null
)
returns jsonb language plpgsql security definer
set search_path = public, auth, extensions as $$
declare v_new_email text;
begin
  if my_role() <> 'admin' then return jsonb_build_object('error', 'Admin only'); end if;
  if p_role not in ('admin','faculty') then
    return jsonb_build_object('error', 'Role must be admin or faculty');
  end if;
  if p_user_id = auth.uid() and p_role <> 'admin' then
    return jsonb_build_object('error', 'You cannot demote yourself');
  end if;
  update public.profiles set
    full_name  = nullif(trim(coalesce(p_full_name, '')), ''),
    department = nullif(trim(coalesce(p_department, '')), ''),
    phone      = nullif(trim(coalesce(p_phone, '')), ''),
    role       = p_role
  where id = p_user_id;
  if not found then return jsonb_build_object('error', 'User not found'); end if;
  if p_new_userid is not null and length(trim(p_new_userid)) > 0 then
    if p_new_userid !~ '^[0-9]{3,20}$' then
      return jsonb_build_object('error', 'User ID must be 3–20 digits');
    end if;
    v_new_email := trim(p_new_userid) || '@lpu.in';
    if exists(select 1 from auth.users where lower(email) = lower(v_new_email) and id <> p_user_id) then
      return jsonb_build_object('error', 'User ID already taken');
    end if;
    update auth.users set email = v_new_email, updated_at = now() where id = p_user_id;
    update auth.identities
      set identity_data = jsonb_set(identity_data, '{email}', to_jsonb(v_new_email)),
          provider_id = v_new_email
      where user_id = p_user_id and provider = 'email';
    update public.profiles set email = v_new_email where id = p_user_id;
  end if;
  if p_new_password is not null and length(p_new_password) > 0 then
    if length(p_new_password) < 6 then
      return jsonb_build_object('error', 'Password must be 6+ characters');
    end if;
    update auth.users
      set encrypted_password = crypt(p_new_password, gen_salt('bf')), updated_at = now()
      where id = p_user_id;
    update public.profiles set password_changed_at = null where id = p_user_id;
  end if;
  return jsonb_build_object('success', true);
end; $$;
grant execute on function admin_update_user(uuid,text,text,text,text,text,text) to authenticated;

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
  update profiles set password_changed_at = null where id = p_user_id;
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

create or replace function admin_change_user_userid(p_user_id uuid, p_new_userid text)
returns jsonb language plpgsql security definer
set search_path = public, auth, extensions as $$
declare v_new_email text;
begin
  if my_role() <> 'admin' then return jsonb_build_object('error', 'Admin only'); end if;
  if p_new_userid !~ '^[0-9]{3,20}$' then
    return jsonb_build_object('error', 'User ID must be 3–20 digits');
  end if;
  v_new_email := p_new_userid || '@lpu.in';
  if exists(select 1 from auth.users where email = v_new_email and id <> p_user_id) then
    return jsonb_build_object('error', 'User ID already taken');
  end if;
  update auth.users set email = v_new_email, updated_at = now() where id = p_user_id;
  if not found then return jsonb_build_object('error', 'User not found'); end if;
  update auth.identities
    set identity_data = jsonb_set(identity_data, '{email}', to_jsonb(v_new_email)),
        provider_id = v_new_email
    where user_id = p_user_id and provider = 'email';
  update public.profiles set email = v_new_email where id = p_user_id;
  return jsonb_build_object('success', true, 'new_email', v_new_email);
end; $$;
grant execute on function admin_change_user_userid(uuid, text) to authenticated;

create or replace function admin_bulk_change_userids(p_updates jsonb)
returns jsonb language plpgsql security definer
set search_path = public, auth, extensions as $$
declare
  v_item jsonb; v_uid uuid; v_new_id text; v_new_email text;
  v_success int := 0; v_errors jsonb := '[]'::jsonb;
begin
  if my_role() <> 'admin' then return jsonb_build_object('error', 'Admin only'); end if;
  for v_item in select * from jsonb_array_elements(p_updates) loop
    v_uid := (v_item->>'user_id')::uuid;
    v_new_id := v_item->>'new_userid';
    v_new_email := v_new_id || '@lpu.in';
    if v_new_id !~ '^[0-9]{3,20}$' then
      v_errors := v_errors || jsonb_build_object('user_id', v_uid, 'error', 'Invalid format');
      continue;
    end if;
    if exists(select 1 from auth.users where email = v_new_email and id <> v_uid) then
      v_errors := v_errors || jsonb_build_object('user_id', v_uid, 'error', 'Already taken');
      continue;
    end if;
    update auth.users set email = v_new_email, updated_at = now() where id = v_uid;
    if not found then
      v_errors := v_errors || jsonb_build_object('user_id', v_uid, 'error', 'User not found');
      continue;
    end if;
    update auth.identities
      set identity_data = jsonb_set(identity_data, '{email}', to_jsonb(v_new_email)),
          provider_id = v_new_email
      where user_id = v_uid and provider = 'email';
    update public.profiles set email = v_new_email where id = v_uid;
    v_success := v_success + 1;
  end loop;
  return jsonb_build_object('success', true, 'updated', v_success, 'errors', v_errors);
end; $$;
grant execute on function admin_bulk_change_userids(jsonb) to authenticated;

create or replace function admin_set_setting(p_key text, p_value jsonb)
returns jsonb language plpgsql security definer as $$
begin
  if my_role() <> 'admin' then return jsonb_build_object('error', 'Admin only'); end if;
  insert into system_settings (key, value, updated_at) values (p_key, p_value, now())
    on conflict (key) do update set value = excluded.value, updated_at = now();
  return jsonb_build_object('success', true);
end; $$;
grant execute on function admin_set_setting(text, jsonb) to authenticated;

create or replace function mark_password_changed()
returns void language plpgsql security definer set search_path = public as $$
begin
  update profiles set password_changed_at = now() where id = auth.uid();
end; $$;
grant execute on function mark_password_changed() to authenticated;

-- ============================================================
-- 16. TRIGGERS
-- ============================================================
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

-- ============================================================
-- 17. CREATE THE FIRST (AND ONLY) ADMIN USER
-- ============================================================
-- ⚠️ CHANGE THESE BEFORE RUNNING:
--   v_admin_uid → your preferred numeric login ID
--   v_admin_pwd → your preferred password (min 6 chars)
-- After running, you can log in with these credentials.
-- ============================================================

do $$
declare
  v_admin_uid   text := '11111111';       -- ← change if you want
  v_admin_pwd   text := 'admin123';        -- ← change if you want
  v_admin_email text := v_admin_uid || '@lpu.in';
  v_uid uuid;
begin
  select id into v_uid from auth.users where email = v_admin_email;
  if v_uid is null then
    v_uid := gen_random_uuid();
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, created_at, updated_at,
      confirmation_token, email_change, email_change_token_new, recovery_token,
      raw_app_meta_data, raw_user_meta_data
    ) values (
      '00000000-0000-0000-0000-000000000000', v_uid,
      'authenticated', 'authenticated', v_admin_email,
      crypt(v_admin_pwd, gen_salt('bf')),
      now(), now(), now(), '', '', '', '',
      jsonb_build_object('provider','email','providers',jsonb_build_array('email')),
      jsonb_build_object('full_name','Administrator')
    );
    insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), v_uid, v_uid::text, 'email',
      jsonb_build_object('sub', v_uid::text, 'email', v_admin_email),
      now(), now(), now());
  end if;
  insert into public.profiles (id, email, full_name, role, is_active, password_changed_at)
  values (v_uid, v_admin_email, 'Administrator', 'admin', true, now())
  on conflict (id) do update set
    role = 'admin',
    is_active = true,
    full_name = 'Administrator',
    password_changed_at = now();
end $$;

-- ============================================================
-- 18. VERIFY
-- ============================================================
select 'Profiles' as section, count(*)::text as count from profiles
union all select 'Buildings', count(*)::text from buildings
union all select 'Rooms', count(*)::text from rooms
union all select 'Time slots', count(*)::text from time_slots
union all select 'Timetable', count(*)::text from timetable
union all select 'Bookings', count(*)::text from bookings
union all select 'Room types (config)', count(*)::text from room_types
union all select 'Settings (config)', count(*)::text from system_settings;

select email, role, is_active,
       case when password_changed_at is null then 'needs change' else 'set' end as pwd_status
from profiles
order by role, email;