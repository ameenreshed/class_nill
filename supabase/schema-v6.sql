-- ============================================================
-- LPU Scheduler v6 — Worker role + calls + cleanup
-- Run AFTER schema-v5.sql
-- ============================================================

-- Allow 'worker' role on profiles
alter table profiles drop constraint if exists profiles_role_check;
alter table profiles add constraint profiles_role_check
  check (role in ('admin','faculty','worker'));

-- Everyone previously 'student' becomes 'faculty' (safe default).
-- Admin can reclassify individual users in admin-users.html afterwards.
update profiles set role = 'faculty' where role = 'student';

-- Worker calls (faculty reports a room issue → worker resolves)
create table if not exists worker_calls (
  id          uuid primary key default gen_random_uuid(),
  room_id     text references rooms(room_id) on delete cascade,
  called_by   uuid references profiles(id) on delete set null,
  assigned_to uuid references profiles(id) on delete set null,
  issue       text not null,
  priority    text default 'normal' check (priority in ('low','normal','high','urgent')),
  status      text default 'open' check (status in ('open','assigned','in_progress','resolved','cancelled')),
  resolution  text,
  resolved_at timestamptz,
  created_at  timestamptz default now()
);
create index if not exists wc_status on worker_calls (status, created_at desc);
create index if not exists wc_assigned on worker_calls (assigned_to);
alter table worker_calls enable row level security;

drop policy if exists "wc read" on worker_calls;
create policy "wc read" on worker_calls for select using (auth.role() = 'authenticated');
drop policy if exists "wc faculty insert" on worker_calls;
create policy "wc faculty insert" on worker_calls for insert
  with check (called_by = auth.uid() and my_role() in ('faculty','admin'));
drop policy if exists "wc worker update" on worker_calls;
create policy "wc worker update" on worker_calls for update
  using (my_role() in ('worker','admin') or called_by = auth.uid())
  with check (my_role() in ('worker','admin') or called_by = auth.uid());

-- Booking types: workers can create maintenance; faculty can create makeup/event/exam
alter table bookings drop constraint if exists bookings_type_check;
alter table bookings add constraint bookings_type_check
  check (type in ('makeup','exam','event','maintenance','regular'));

-- Update system_settings: remove student portal, add worker toggle
delete from system_settings where key = 'student_portal_enabled';
insert into system_settings (key, value) values
  ('allow_faculty_makeup','true'::jsonb),
  ('allow_faculty_exam','true'::jsonb),
  ('allow_faculty_event','true'::jsonb),
  ('worker_calls_enabled','true'::jsonb),
  ('booking_auto_approve','false'::jsonb)
on conflict (key) do nothing;

-- Make admin_create_user accept 'worker' role
create or replace function admin_create_user(
  p_email text, p_password text, p_full_name text,
  p_role text, p_department text default null,
  p_section_id text default null, p_phone text default null
)
returns jsonb language plpgsql security definer
set search_path = public, auth, extensions as $$
declare v_uid uuid; v_existing uuid;
begin
  if my_role() <> 'admin' then return jsonb_build_object('error', 'Admin only'); end if;
  if p_role not in ('admin','faculty','worker') then
    return jsonb_build_object('error', 'Invalid role');
  end if;
  if p_email is null or length(trim(p_email)) < 3 then
    return jsonb_build_object('error', 'Email required');
  end if;
  if p_password is null or length(p_password) < 6 then
    return jsonb_build_object('error', 'Password must be at least 6 characters');
  end if;
  p_email := lower(trim(p_email));
  select id into v_existing from auth.users where email = p_email;
  if v_existing is not null then
    return jsonb_build_object('error', 'An account with this email already exists');
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
    crypt(p_password, gen_salt('bf')),
    now(), now(), now(), '', '', '', '',
    jsonb_build_object('provider','email','providers',jsonb_build_array('email')),
    jsonb_build_object('full_name', coalesce(p_full_name, p_email))
  );
  insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), v_uid, v_uid::text, 'email',
    jsonb_build_object('sub', v_uid::text, 'email', p_email), now(), now(), now());
  insert into public.profiles (id, email, full_name, role, department, section_id, phone, is_active)
  values (v_uid, p_email, p_full_name, p_role, p_department, p_section_id, p_phone, true)
  on conflict (id) do update set
    full_name=excluded.full_name, role=excluded.role,
    department=excluded.department, section_id=excluded.section_id,
    phone=excluded.phone, is_active=true;
  return jsonb_build_object('success', true, 'user_id', v_uid);
end; $$;
grant execute on function admin_create_user(text,text,text,text,text,text,text) to authenticated;

select 'v6 ready — worker role installed' as status;