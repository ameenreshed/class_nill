-- ============================================================
-- LPU Scheduler v3 — courses catalog + enhancements
-- Run AFTER schema.sql + schema-additions.sql
-- ============================================================

-- Courses catalog (separate from timetable rows)
create table if not exists courses (
  course_id text primary key,
  name text not null,
  department text,
  credits int default 3,
  description text,
  is_active boolean default true,
  created_at timestamptz default now()
);

alter table courses enable row level security;
drop policy if exists "courses read" on courses;
create policy "courses read" on courses for select using (auth.role() = 'authenticated');
drop policy if exists "courses write" on courses;
create policy "courses write" on courses for all using (my_role() = 'admin') with check (my_role() = 'admin');

-- Seed samples
insert into courses (course_id, name, department, credits) values
  ('CS401', 'Compiler Design',    'CSE', 4),
  ('CS402', 'Computer Networks',  'CSE', 4),
  ('CS403', 'DBMS Lab',           'CSE', 2),
  ('CS404', 'Operating Systems',  'CSE', 4),
  ('CS405', 'Software Engineering','CSE', 3),
  ('EC301', 'Signals & Systems',  'ECE', 4),
  ('EC302', 'Digital Electronics','ECE', 4),
  ('EC303', 'Microprocessors',    'ECE', 4)
on conflict (course_id) do nothing;

-- Helpful index for looking up classes by course
create index if not exists timetable_course on timetable (course_code);
create index if not exists profiles_section on profiles (section_id) where section_id is not null;

select 'v3 schema ready' as status;