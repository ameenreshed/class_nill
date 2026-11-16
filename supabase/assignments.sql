-- ============================================================
-- ASSIGNMENT COLLECTION SYSTEM (Supabase-only, hybrid-ready)
-- Run after schema.sql. Fully idempotent.
-- ============================================================

-- ── Clean slate ───────────────────────────────────────────
drop table if exists submissions cascade;
drop table if exists assignments cascade;
drop function if exists get_assignment_by_token(text) cascade;
drop function if exists get_student_submission(text, text) cascade;
drop function if exists commit_submission(text, text, text, jsonb) cascade;
drop function if exists assignment_token_valid(text) cascade;
drop function if exists faculty_can_read_submission(text) cascade;

-- ── Tables ────────────────────────────────────────────────
create table assignments (
  id                uuid primary key default gen_random_uuid(),
  faculty_id        uuid not null references profiles(id) on delete cascade,
  title             text not null,
  description       text,
  course_code       text,
  batch             text not null,
  drive_link        text,                                     -- optional reference material
  deadline          timestamptz,
  submission_policy text not null default 'single'
                    check (submission_policy in ('single','overwrite')),
  max_files         int  not null default 1  check (max_files between 1 and 20),
  max_size_mb       int  not null default 25 check (max_size_mb between 1 and 100),
  allowed_types     text[] not null default array['pdf','doc','docx','ppt','pptx','txt','zip'],
  share_token       text unique not null default encode(gen_random_bytes(20), 'hex'),
  is_active         boolean not null default true,
  created_at        timestamptz not null default now()
);
create index ass_faculty on assignments(faculty_id);
create index ass_token   on assignments(share_token);

create table submissions (
  id            uuid primary key default gen_random_uuid(),
  assignment_id uuid not null references assignments(id) on delete cascade,
  student_id    text not null,
  student_name  text,
  file_path     text not null,
  file_name     text not null,
  file_size     bigint,
  mime_type     text,
  is_superseded boolean not null default false,
  superseded_at timestamptz,
  submitted_at  timestamptz not null default now()
);
create index sub_ass     on submissions(assignment_id);
create index sub_current on submissions(assignment_id, student_id) where is_superseded = false;

-- ── RLS on tables ─────────────────────────────────────────
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
values ('assignment-submissions', 'assignment-submissions', false, 104857600)
on conflict (id) do update set file_size_limit = excluded.file_size_limit;

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
drop policy if exists "anon upload submission"    on storage.objects;
drop policy if exists "faculty read submission"   on storage.objects;
drop policy if exists "faculty delete submission" on storage.objects;

create policy "anon upload submission" on storage.objects for insert
  to anon, authenticated
with check (
  bucket_id = 'assignment-submissions'
  and assignment_token_valid(name)
);

create policy "faculty read submission" on storage.objects for select
  to authenticated
using (
  bucket_id = 'assignment-submissions'
  and faculty_can_read_submission(name)
);

create policy "faculty delete submission" on storage.objects for delete
  to authenticated
using (
  bucket_id = 'assignment-submissions'
  and faculty_can_read_submission(name)
);

-- ── Public RPCs ───────────────────────────────────────────
create or replace function get_assignment_by_token(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_a assignments;
begin
  select * into v_a from assignments where share_token = p_token and is_active = true;
  if not found then return jsonb_build_object('error', 'Invalid or expired link'); end if;
  return jsonb_build_object(
    'title', v_a.title, 'description', v_a.description,
    'course_code', v_a.course_code, 'batch', v_a.batch,
    'drive_link', v_a.drive_link, 'deadline', v_a.deadline,
    'submission_policy', v_a.submission_policy,
    'max_files', v_a.max_files, 'max_size_mb', v_a.max_size_mb,
    'allowed_types', v_a.allowed_types
  );
end; $$;
grant execute on function get_assignment_by_token(text) to anon, authenticated;

create or replace function get_student_submission(p_token text, p_student_id text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_a_id uuid; v_files jsonb;
begin
  select id into v_a_id from assignments where share_token = p_token and is_active = true;
  if v_a_id is null then return jsonb_build_object('error', 'Invalid link'); end if;
  if p_student_id is null or length(trim(p_student_id)) = 0 then
    return jsonb_build_object('exists', false);
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'name', file_name, 'size', file_size, 'uploaded_at', submitted_at
    ) order by submitted_at), '[]'::jsonb)
    into v_files
    from submissions
    where assignment_id = v_a_id
      and lower(student_id) = lower(trim(p_student_id))
      and is_superseded = false;
  return jsonb_build_object('exists', jsonb_array_length(v_files) > 0, 'files', v_files);
end; $$;
grant execute on function get_student_submission(text, text) to anon, authenticated;

create or replace function commit_submission(
  p_token text, p_student_id text, p_student_name text, p_files jsonb
)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_a assignments;
  v_file jsonb;
  v_count int;
  v_path text;
  v_ext text;
begin
  -- Lock assignment row to serialize concurrent submissions
  select * into v_a from assignments
    where share_token = p_token and is_active = true for update;
  if not found then return jsonb_build_object('error', 'Invalid or expired link'); end if;

  if p_student_id is null or p_student_id !~ '^[A-Za-z0-9_-]{3,30}$' then
    return jsonb_build_object('error', 'Student ID must be 3-30 letters/numbers/dashes');
  end if;

  if v_a.deadline is not null and now() > v_a.deadline then
    return jsonb_build_object('error', 'Deadline has passed');
  end if;

  v_count := jsonb_array_length(p_files);
  if v_count = 0 then return jsonb_build_object('error', 'No files provided'); end if;
  if v_count > v_a.max_files then
    return jsonb_build_object('error', 'Too many files (max ' || v_a.max_files || ')');
  end if;

  -- Single mode: reject if already submitted
  if v_a.submission_policy = 'single' then
    if exists(
      select 1 from submissions
      where assignment_id = v_a.id
        and lower(student_id) = lower(trim(p_student_id))
        and is_superseded = false
    ) then
      return jsonb_build_object('error', 'Already submitted — re-submission is not allowed');
    end if;
  end if;

  -- Validate each file
  for v_file in select * from jsonb_array_elements(p_files) loop
    v_path := v_file->>'path';
    if split_part(v_path, '/', 1) <> p_token then
      return jsonb_build_object('error', 'Invalid file path');
    end if;
    v_ext := lower(regexp_replace(coalesce(v_file->>'name',''), '^.*\.', ''));
    if not (v_ext = any(v_a.allowed_types)) then
      return jsonb_build_object('error', 'File type .' || v_ext || ' not allowed');
    end if;
    if (v_file->>'size')::bigint > v_a.max_size_mb * 1024 * 1024 then
      return jsonb_build_object('error', 'File too large (max ' || v_a.max_size_mb || ' MB)');
    end if;
  end loop;

  -- Overwrite mode: supersede previous files
  if v_a.submission_policy = 'overwrite' then
    update submissions set is_superseded = true, superseded_at = now()
      where assignment_id = v_a.id
        and lower(student_id) = lower(trim(p_student_id))
        and is_superseded = false;
  end if;

  -- Insert new files
  for v_file in select * from jsonb_array_elements(p_files) loop
    insert into submissions (
      assignment_id, student_id, student_name,
      file_path, file_name, file_size, mime_type
    ) values (
      v_a.id, trim(p_student_id),
      nullif(trim(coalesce(p_student_name,'')), ''),
      v_file->>'path', v_file->>'name',
      (v_file->>'size')::bigint, v_file->>'type'
    );
  end loop;

  return jsonb_build_object('success', true);
end; $$;
grant execute on function commit_submission(text, text, text, jsonb) to anon, authenticated;