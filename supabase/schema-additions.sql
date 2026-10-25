-- ============================================================
-- LPU Scheduler — Live data architecture
-- Run AFTER schema.sql
-- ============================================================

-- Section reference on profiles (students belong to a section)
alter table profiles add column if not exists section_id text references sections(section_id);

-- ============================================================
-- TIMETABLE — recurring regular classes
-- One row = "Section X has Course Y in Room Z on Day D at Slot S"
-- ============================================================
create table if not exists timetable (
  id uuid primary key default gen_random_uuid(),
  section_id text not null references sections(section_id) on delete cascade,
  day_of_week int not null check (day_of_week between 0 and 6), -- 0=Sun, 1=Mon … 6=Sat
  slot_id text not null references time_slots(slot_id) on delete cascade,
  room_id text not null references rooms(room_id) on delete cascade,
  faculty_id uuid references profiles(id) on delete set null,
  course_code text,
  course_name text,
  semester text,
  is_active boolean default true,
  synced_at timestamptz default now(),
  unique(section_id, day_of_week, slot_id)
);

create index if not exists timetable_room_slot on timetable (room_id, day_of_week, slot_id);
create index if not exists timetable_faculty on timetable (faculty_id, day_of_week);
create index if not exists timetable_section on timetable (section_id, day_of_week);

-- ============================================================
-- ACADEMIC CALENDAR — holidays, working Saturdays, events, exams
-- ============================================================
create table if not exists academic_calendar (
  date date primary key,
  kind text not null check (kind in ('holiday','event','exam_week','working_saturday','special')),
  label text,
  is_working_day boolean, -- null = infer from kind
  created_at timestamptz default now()
);

-- ============================================================
-- SYNC LOG — every import from the university, audited
-- ============================================================
create table if not exists sync_log (
  id uuid primary key default gen_random_uuid(),
  source text not null,           -- 'university_api' | 'csv_upload' | 'manual'
  kind text not null,             -- 'timetable' | 'rooms' | 'sections' | 'makeup' | 'calendar'
  records_count int default 0,
  status text default 'success' check (status in ('success','partial','failed')),
  message text,
  synced_by uuid references profiles(id),
  created_at timestamptz default now()
);

create index if not exists sync_log_created on sync_log (created_at desc);

-- ============================================================
-- RLS for new tables
-- ============================================================
alter table timetable enable row level security;
alter table academic_calendar enable row level security;
alter table sync_log enable row level security;

-- timetable: read for authenticated, write for admin
drop policy if exists "timetable read" on timetable;
create policy "timetable read" on timetable for select using (auth.role() = 'authenticated');
drop policy if exists "timetable write" on timetable;
create policy "timetable write" on timetable for all using (my_role() = 'admin') with check (my_role() = 'admin');

-- calendar: read for all authenticated
drop policy if exists "calendar read" on academic_calendar;
create policy "calendar read" on academic_calendar for select using (auth.role() = 'authenticated');
drop policy if exists "calendar write" on academic_calendar;
create policy "calendar write" on academic_calendar for all using (my_role() = 'admin') with check (my_role() = 'admin');

-- sync_log: admin read only
drop policy if exists "sync_log admin read" on sync_log;
create policy "sync_log admin read" on sync_log for select using (my_role() = 'admin');
drop policy if exists "sync_log admin write" on sync_log;
create policy "sync_log admin write" on sync_log for all using (my_role() = 'admin') with check (my_role() = 'admin');

-- ============================================================
-- RPC: bulk timetable import (used by admin import page)
-- ============================================================
create or replace function import_timetable(p_rows jsonb)
returns jsonb language plpgsql security definer as $$
declare
  v_count int := 0;
  v_err   int := 0;
begin
  if my_role() <> 'admin' then
    return jsonb_build_object('error', 'admin only');
  end if;

  insert into timetable (
    section_id, day_of_week, slot_id, room_id,
    faculty_id, course_code, course_name, semester, is_active, synced_at
  )
  select
    row->>'section_id',
    (row->>'day_of_week')::int,
    row->>'slot_id',
    row->>'room_id',
    nullif(row->>'faculty_id','')::uuid,
    row->>'course_code',
    row->>'course_name',
    row->>'semester',
    true,
    now()
  from jsonb_array_elements(p_rows) as row
  on conflict (section_id, day_of_week, slot_id)
  do update set
    room_id      = excluded.room_id,
    faculty_id   = excluded.faculty_id,
    course_code  = excluded.course_code,
    course_name  = excluded.course_name,
    semester     = excluded.semester,
    is_active    = true,
    synced_at    = now();

  get diagnostics v_count = row_count;

  insert into sync_log (source, kind, records_count, status, synced_by)
  values ('manual', 'timetable', v_count, 'success', auth.uid());

  return jsonb_build_object('imported', v_count);
end; $$;
grant execute on function import_timetable(jsonb) to authenticated;