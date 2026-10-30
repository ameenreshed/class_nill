-- ============================================================
-- LPU Scheduler v5
-- Run AFTER schema.sql, schema-additions.sql, schema-v3.sql, schema-v4.sql
-- ============================================================

create table if not exists system_settings (
  key        text primary key,
  value      jsonb not null default 'null'::jsonb,
  updated_at timestamptz default now()
);
alter table system_settings enable row level security;
drop policy if exists "settings read" on system_settings;
create policy "settings read" on system_settings for select using (auth.role() = 'authenticated');
drop policy if exists "settings admin write" on system_settings;
create policy "settings admin write" on system_settings for all
  using (my_role() = 'admin') with check (my_role() = 'admin');

insert into system_settings (key, value) values
  ('student_portal_enabled',  'true'::jsonb),
  ('booking_auto_approve',    'false'::jsonb),
  ('allow_makeup',            'true'::jsonb),
  ('allow_exam',              'true'::jsonb),
  ('allow_event',             'true'::jsonb),
  ('allow_maintenance',       'true'::jsonb),
  ('site_banner',             '""'::jsonb),
  ('lpu_api_url',             '""'::jsonb),
  ('lpu_api_key',             '""'::jsonb)
on conflict (key) do nothing;

create table if not exists faculty_unavailability (
  id         uuid primary key default gen_random_uuid(),
  faculty_id uuid not null references profiles(id) on delete cascade,
  date       date not null,
  slot_id    text references time_slots(slot_id) on delete cascade,
  reason     text,
  created_at timestamptz default now(),
  unique(faculty_id, date, slot_id)
);
create index if not exists faculty_unavail_lookup on faculty_unavailability (date, faculty_id);
alter table faculty_unavailability enable row level security;

drop policy if exists "unavail read" on faculty_unavailability;
create policy "unavail read" on faculty_unavailability for select using (auth.role() = 'authenticated');
drop policy if exists "unavail self write" on faculty_unavailability;
create policy "unavail self write" on faculty_unavailability for all
  using (faculty_id = auth.uid() or my_role() = 'admin')
  with check (faculty_id = auth.uid() or my_role() = 'admin');

drop policy if exists "timetable faculty self" on timetable;
create policy "timetable faculty self" on timetable for all
  using (faculty_id = auth.uid() or my_role() = 'admin')
  with check (faculty_id = auth.uid() or my_role() = 'admin');

alter table timetable alter column section_id drop not null;
alter table bookings  alter column section_id drop not null;

alter table timetable drop constraint if exists timetable_section_id_day_of_week_slot_id_key;
create unique index if not exists timetable_faculty_slot_unique
  on timetable (faculty_id, day_of_week, slot_id) where faculty_id is not null;

create or replace function apply_auto_approve()
returns trigger language plpgsql as $$
declare v_on boolean := false;
begin
  select coalesce((value)::text::boolean, false) into v_on
    from system_settings where key = 'booking_auto_approve';
  if v_on and new.status = 'pending' then new.status := 'approved'; end if;
  return new;
end; $$;

drop trigger if exists trg_apply_auto_approve on bookings;
create trigger trg_apply_auto_approve before insert on bookings
  for each row execute function apply_auto_approve();

create or replace function admin_set_setting(p_key text, p_value jsonb)
returns jsonb language plpgsql security definer as $$
begin
  if my_role() <> 'admin' then return jsonb_build_object('error', 'Admin only'); end if;
  insert into system_settings (key, value, updated_at) values (p_key, p_value, now())
    on conflict (key) do update set value = excluded.value, updated_at = now();
  return jsonb_build_object('success', true);
end; $$;
grant execute on function admin_set_setting(text, jsonb) to authenticated;

select 'v5 ready' as status;