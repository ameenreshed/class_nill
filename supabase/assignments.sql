-- ============================================================
-- ASSIGNMENT COLLECTION SYSTEM
-- Run after schema.sql. Safe to re-run (idempotent).
-- ============================================================

-- ── Tables ────────────────────────────────────────────────
create table if not exists assignments (
  id            uuid primary key default gen_random_uuid(),
  faculty_id    uuid not null references profiles(id) on delete cascade,
  title         text not null,
  description   text,
  course_code   text,
  batch         text not null,
  drive_link    text,
  deadline      timestamptz,
  allowed_types text[] not null default array['pdf','doc','docx','ppt','pptx','txt','zip'],
  max_size_mb   int not null default 25 check (max_size_mb between 1 and 50),
  share_token   text unique not null default encode(gen_random_bytes(20), 'hex'),
  is_active     boolean not null default true,
  created_at    timestamptz not null default now()
);
create index if not exists ass_faculty on assignments(faculty_id);
create index if not exists ass_token   on assignments(share_token);

create table if not exists submissions (
  id            uuid primary key default gen_random_uuid(),
  assignment_id uuid not null references assignments(id) on delete cascade,
  student_id    text not null,
  student_name  text,
  file_path     text not null,
  file_name     text not null,
  file_size     bigint,
  mime_type     text,
  submitted_at  timestamptz not null default now(),
  unique(assignment_id, student_id)
);
create index if not exists sub_ass on submissions(assignment_id);

-- ── RLS: assignments & submissions ────────────────────────
alter table assignments enable row level security;
alter table submissions enable row level security;

drop policy if exists "ass faculty read"   on assignments;
drop policy if exists "ass faculty insert" on assignments;
drop policy if exists "ass faculty update" on assignments;
drop policy if exists "ass faculty delete" on assignments;
create policy "ass faculty read"   on assignments for select
  using (faculty_id = auth.uid() or my_role() = 'admin');
create policy "ass faculty insert" on assignments for insert
  with check (faculty_id = auth.uid() and my_role() in ('faculty','admin'));
create policy "ass faculty update" on assignments for update
  using (faculty_id = auth.uid() or my_role() = 'admin');
create policy "ass faculty delete" on assignments for delete
  using (faculty_id = auth.uid() or my_role() = 'admin');

drop policy if exists "sub faculty read"   on submissions;
drop policy if exists "sub faculty delete" on submissions;
create policy "sub faculty read" on submissions for select
  using (exists(
    select 1 from assignments a
    where a.id = assignment_id
      and (a.faculty_id = auth.uid() or my_role() = 'admin')
  ));
create policy "sub faculty delete" on submissions for delete
  using (exists(
    select 1 from assignments a
    where a.id = assignment_id
      and (a.faculty_id = auth.uid() or my_role() = 'admin')
  ));

-- ── Storage bucket (private) ──────────────────────────────
insert into storage.buckets (id, name, public, file_size_limit)
values ('assignment-submissions', 'assignment-submissions', false, 50 * 1024 * 1024)
on conflict (id) do nothing;

-- ── Storage helper functions ──────────────────────────────
create or replace function assignment_token_valid(p_path text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(
    select 1 from assignments
    where share_token = split_part(p_path, '/', 1)
      and is_active = true
  );
$$;
grant execute on function assignment_token_valid(text) to anon, authenticated;

create or replace function faculty_can_read_submission(p_path text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(
    select 1 from assignments a
    where a.share_token = split_part(p_path, '/', 1)
      and (a.faculty_id = auth.uid() or my_role() = 'admin')
  );
$$;
grant execute on function faculty_can_read_submission(text) to authenticated;

-- ── Storage policies ──────────────────────────────────────
-- Note: covers BOTH anon AND authenticated — so a logged-in student (or a
-- faculty member using a different tab) can still upload to a valid token.
drop policy if exists "public upload submission" on storage.objects;
create policy "public upload submission" on storage.objects for insert
  to anon, authenticated
with check (
  bucket_id = 'assignment-submissions'
  and assignment_token_valid(name)
);

drop policy if exists "faculty read submission" on storage.objects;
create policy "faculty read submission" on storage.objects for select
  to authenticated
using (
  bucket_id = 'assignment-submissions'
  and faculty_can_read_submission(name)
);

drop policy if exists "faculty delete submission" on storage.objects;
create policy "faculty delete submission" on storage.objects for delete
  to authenticated
using (
  bucket_id = 'assignment-submissions'
  and faculty_can_read_submission(name)
);

-- ── Public RPCs (token-based) ─────────────────────────────
create or replace function get_assignment_by_token(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_a assignments;
begin
  select * into v_a from assignments where share_token = p_token and is_active = true;
  if not found then return jsonb_build_object('error', 'Invalid or expired link'); end if;
  return jsonb_build_object(
    'id', v_a.id, 'title', v_a.title, 'description', v_a.description,
    'course_code', v_a.course_code, 'batch', v_a.batch, 'drive_link', v_a.drive_link,
    'deadline', v_a.deadline, 'allowed_types', v_a.allowed_types, 'max_size_mb', v_a.max_size_mb
  );
end; $$;
grant execute on function get_assignment_by_token(text) to anon, authenticated;

create or replace function check_student_submission(p_token text, p_student_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_a_id uuid; v_sub submissions;
begin
  select id into v_a_id from assignments where share_token = p_token and is_active = true;
  if v_a_id is null then return jsonb_build_object('error', 'Invalid link'); end if;
  if p_student_id is null or length(trim(p_student_id)) = 0 then
    return jsonb_build_object('error', 'Student ID required');
  end if;
  select * into v_sub from submissions
    where assignment_id = v_a_id and lower(student_id) = lower(trim(p_student_id));
  if not found then return jsonb_build_object('exists', false); end if;
  return jsonb_build_object(
    'exists', true, 'file_name', v_sub.file_name, 'submitted_at', v_sub.submitted_at
  );
end; $$;
grant execute on function check_student_submission(text, text) to anon, authenticated;

create or replace function record_submission(
  p_token text, p_student_id text, p_student_name text,
  p_file_path text, p_file_name text, p_file_size bigint, p_mime_type text
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_a assignments; v_ext text;
begin
  select * into v_a from assignments where share_token = p_token and is_active = true;
  if not found then return jsonb_build_object('error', 'Invalid or expired link'); end if;
  if p_student_id is null or length(trim(p_student_id)) = 0 then
    return jsonb_build_object('error', 'Student ID required');
  end if;
  if p_student_id !~ '^[A-Za-z0-9_-]{3,30}$' then
    return jsonb_build_object('error', 'Student ID must be 3-30 letters/numbers/dashes');
  end if;
  if exists(select 1 from submissions
            where assignment_id = v_a.id and lower(student_id) = lower(trim(p_student_id))) then
    return jsonb_build_object('error', 'You have already submitted for this assignment');
  end if;
  v_ext := lower(regexp_replace(p_file_name, '^.*\.', ''));
  if not (v_ext = any(v_a.allowed_types)) then
    return jsonb_build_object('error', 'File type .' || v_ext || ' is not allowed');
  end if;
  if p_file_size is not null and p_file_size > v_a.max_size_mb * 1024 * 1024 then
    return jsonb_build_object('error', 'File too large (max ' || v_a.max_size_mb || ' MB)');
  end if;
  if v_a.deadline is not null and now() > v_a.deadline then
    return jsonb_build_object('error', 'Deadline has passed');
  end if;
  if not assignment_token_valid(p_file_path) then
    return jsonb_build_object('error', 'Invalid file path');
  end if;
  insert into submissions (assignment_id, student_id, student_name, file_path, file_name, file_size, mime_type)
  values (v_a.id, trim(p_student_id), nullif(trim(p_student_name), ''), p_file_path, p_file_name, p_file_size, p_mime_type);
  return jsonb_build_object('success', true);
end; $$;
grant execute on function record_submission(text,text,text,text,text,bigint,text) to anon, authenticated;