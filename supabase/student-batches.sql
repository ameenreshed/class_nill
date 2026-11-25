-- ============================================================
-- STUDENTS, BATCHES & STUDENT DASHBOARD
-- Run AFTER schema.sql, assignments.sql and admin-assignment.sql.
-- Idempotent: safe to re-run.
--
-- Fixes: admin/students.html used a `students` table and the
-- RPCs get_student_batches / bulk_upsert_students that were never
-- created. They are created here.
-- ============================================================

-- ── 1. Allow the student role ─────────────────────────────────
alter table profiles drop constraint if exists profiles_role_check;
alter table profiles add constraint profiles_role_check
  check (role in ('admin','faculty','student'));

-- ── 2. Batches (admin controls access per batch) ──────────────
create table if not exists batches (
  name       text primary key,
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);

alter table batches enable row level security;

drop policy if exists "batches read" on batches;
create policy "batches read" on batches for select
  using (auth.role() = 'authenticated');

drop policy if exists "batches admin write" on batches;
create policy "batches admin write" on batches for all
  using (my_role() = 'admin') with check (my_role() = 'admin');

-- ── 3. Students registry (a student may or may not have a login) ─
create table if not exists students (
  id         text primary key,                       -- registration / student ID
  full_name  text not null,
  batch      text not null references batches(name) on update cascade,
  user_id    uuid unique references profiles(id) on delete set null,
  created_at timestamptz not null default now()
);
create index if not exists students_batch on students(batch);

alter table students enable row level security;

drop policy if exists "students admin all" on students;
create policy "students admin all" on students for all
  using (my_role() = 'admin') with check (my_role() = 'admin');

drop policy if exists "students self read" on students;
create policy "students self read" on students for select
  using (user_id = auth.uid());

-- ── 4. Backfill batches from existing data ────────────────────
insert into batches (name)
  select distinct batch from students where batch is not null and batch <> ''
  on conflict (name) do nothing;
insert into batches (name)
  select distinct batch from assignments where batch is not null and batch <> ''
  on conflict (name) do nothing;

-- ══════════════════════════════════════════════════════════════
-- RPCs
-- ══════════════════════════════════════════════════════════════

-- ── Batch list with counts (used by admin/students.html and batches.html)
drop function if exists get_student_batches();
create or replace function get_student_batches()
returns table(batch text, cnt int, accounts int, assignments int, is_active boolean)
language sql stable security definer set search_path = public as $$
  select
    b.name,
    (select count(*)::int from students s where s.batch = b.name),
    (select count(*)::int from students s where s.batch = b.name and s.user_id is not null),
    (select count(*)::int from assignments a where a.batch = b.name),
    b.is_active
  from batches b
  where my_role() = 'admin'
  order by b.name;
$$;

-- ── Bulk import / upsert students (used by admin/students.html) ─
create or replace function bulk_upsert_students(p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  r jsonb;
  n int := 0;
begin
  if my_role() <> 'admin' then return jsonb_build_object('error', 'Admin only'); end if;

  for r in select * from jsonb_array_elements(p_rows) loop
    if coalesce(trim(r->>'id'), '') = '' or coalesce(trim(r->>'batch'), '') = '' then
      continue;
    end if;
    insert into batches (name) values (trim(r->>'batch')) on conflict (name) do nothing;
    insert into students (id, full_name, batch)
      values (trim(r->>'id'), trim(r->>'full_name'), trim(r->>'batch'))
    on conflict (id) do update
      set full_name = excluded.full_name,
          batch     = excluded.batch;
    n := n + 1;
  end loop;

  return jsonb_build_object('success', true, 'count', n);
end; $$;

-- ── Pause / resume a batch. Students in it cannot sign in while paused.
create or replace function admin_set_batch_active(p_name text, p_active boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if my_role() <> 'admin' then return jsonb_build_object('error', 'Admin only'); end if;

  update batches set is_active = p_active where name = p_name;
  if not found then return jsonb_build_object('error', 'Batch not found'); end if;

  update profiles p set is_active = p_active
    from students s
    where s.user_id = p.id and s.batch = p_name;

  return jsonb_build_object('success', true);
end; $$;

-- ── Rename a batch (students and assignments follow it) ────────
create or replace function admin_rename_batch(p_old text, p_new text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_active boolean;
begin
  if my_role() <> 'admin' then return jsonb_build_object('error', 'Admin only'); end if;

  p_new := trim(coalesce(p_new, ''));
  if p_new = '' then return jsonb_build_object('error', 'Batch name is required'); end if;
  if p_old = p_new then return jsonb_build_object('success', true); end if;

  select is_active into v_active from batches where name = p_old;
  if not found then return jsonb_build_object('error', 'Batch not found'); end if;
  if exists (select 1 from batches where name = p_new) then
    return jsonb_build_object('error', 'A batch with that name already exists');
  end if;

  insert into batches (name, is_active) values (p_new, v_active);
  update students    set batch = p_new where batch = p_old;
  update assignments set batch = p_new where batch = p_old;
  delete from batches where name = p_old;

  return jsonb_build_object('success', true);
end; $$;

-- ── Move students to another batch ────────────────────────────
create or replace function admin_move_students(p_ids text[], p_batch text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_active boolean;
begin
  if my_role() <> 'admin' then return jsonb_build_object('error', 'Admin only'); end if;

  select is_active into v_active from batches where name = p_batch;
  if not found then return jsonb_build_object('error', 'Target batch not found'); end if;

  update students set batch = p_batch where id = any(p_ids);

  -- Sign-in follows the batch: moved students take the target batch's status
  update profiles p set is_active = v_active
    from students s
    where s.user_id = p.id and s.id = any(p_ids);

  return jsonb_build_object('success', true, 'moved', (select count(*) from students where id = any(p_ids)));
end; $$;

-- ── Create login accounts for students (temporary password) ────
-- Login ID = student ID, email = <id>@lpu.in (matches auth/login.html).
-- password_changed_at is left null, so the student is forced to set
-- their own password on first sign-in.
create or replace function admin_provision_students(p_ids text[], p_password text)
returns jsonb
language plpgsql security definer
set search_path = public, auth, extensions as $$
declare
  s            students;
  v_uid        uuid;
  v_email      text;
  v_role       text;
  v_active     boolean;
  v_created    int := 0;
  v_linked     int := 0;
  v_skipped    jsonb := '[]'::jsonb;
begin
  if my_role() <> 'admin' then return jsonb_build_object('error', 'Admin only'); end if;
  if p_password is null or length(p_password) < 6 then
    return jsonb_build_object('error', 'Temporary password must be 6+ characters');
  end if;

  for s in select * from students where id = any(p_ids) and user_id is null order by id loop
    v_email := s.id || '@lpu.in';

    select b.is_active into v_active from batches b where b.name = s.batch;
    v_active := coalesce(v_active, true);

    select id into v_uid from auth.users where email = v_email;

    if v_uid is null then
      v_uid := gen_random_uuid();
      insert into auth.users (
        instance_id, id, aud, role, email, encrypted_password,
        email_confirmed_at, created_at, updated_at,
        confirmation_token, email_change, email_change_token_new, recovery_token,
        raw_app_meta_data, raw_user_meta_data
      ) values (
        '00000000-0000-0000-0000-000000000000', v_uid,
        'authenticated', 'authenticated', v_email,
        crypt(p_password, gen_salt('bf')), now(), now(), now(),
        '', '', '', '',
        jsonb_build_object('provider','email','providers',jsonb_build_array('email')),
        jsonb_build_object('full_name', s.full_name)
      );
      insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
      values (gen_random_uuid(), v_uid, v_uid::text, 'email',
        jsonb_build_object('sub', v_uid::text, 'email', v_email),
        now(), now(), now());
      v_created := v_created + 1;
    else
      -- Never take over a staff account that happens to share the email
      select role into v_role from profiles where id = v_uid;
      if v_role is not null and v_role <> 'student' then
        v_skipped := v_skipped || jsonb_build_array(
          jsonb_build_object('id', s.id, 'reason', 'Email belongs to a staff account'));
        continue;
      end if;
      update auth.users
        set encrypted_password = crypt(p_password, gen_salt('bf')), updated_at = now()
        where id = v_uid;
      v_linked := v_linked + 1;
    end if;

    insert into profiles (id, email, full_name, role, is_active, password_changed_at)
    values (v_uid, v_email, s.full_name, 'student', v_active, null)
    on conflict (id) do update
      set role = 'student',
          full_name = excluded.full_name,
          email = excluded.email,
          is_active = excluded.is_active,
          password_changed_at = null;

    update students set user_id = v_uid where id = s.id;
  end loop;

  return jsonb_build_object(
    'success', true,
    'created', v_created,
    'linked', v_linked,
    'skipped', v_skipped
  );
end; $$;

-- ── Student dashboard: their batch's assignments + their own submissions
create or replace function student_dashboard()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  v_s     students;
  v_on    boolean;
  v_list  jsonb;
begin
  select * into v_s from students where user_id = auth.uid();
  if not found then
    return jsonb_build_object('error',
      'Your account is not linked to a student record. Contact your administrator.');
  end if;

  select b.is_active into v_on from batches b where b.name = v_s.batch;
  if coalesce(v_on, false) = false then
    return jsonb_build_object('error',
      'Your batch is currently paused. Contact your administrator.');
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
      'id',                a.id,
      'title',             a.title,
      'description',       a.description,
      'course_code',       a.course_code,
      'deadline',          a.deadline,
      'max_files',         a.max_files,
      'submission_policy', a.submission_policy,
      'share_token',       a.share_token,
      'files', (
        select coalesce(jsonb_agg(jsonb_build_object(
            'name', x.file_name, 'size', x.file_size, 'uploaded_at', x.submitted_at
          ) order by x.submitted_at), '[]'::jsonb)
        from submissions x
        where x.assignment_id = a.id
          and x.student_id = v_s.id
          and x.is_superseded = false
      )
    ) order by a.deadline nulls last, a.created_at), '[]'::jsonb)
  into v_list
  from assignments a
  where a.batch = v_s.batch and a.is_active = true;

  return jsonb_build_object(
    'student', jsonb_build_object('id', v_s.id, 'name', v_s.full_name, 'batch', v_s.batch),
    'assignments', v_list
  );
end; $$;

-- ── Grants ────────────────────────────────────────────────────
revoke execute on function get_student_batches()                    from public, anon;
revoke execute on function bulk_upsert_students(jsonb)              from public, anon;
revoke execute on function admin_set_batch_active(text, boolean)    from public, anon;
revoke execute on function admin_rename_batch(text, text)           from public, anon;
revoke execute on function admin_move_students(text[], text)        from public, anon;
revoke execute on function admin_provision_students(text[], text)   from public, anon;
revoke execute on function student_dashboard()                      from public, anon;

grant execute on function get_student_batches()                     to authenticated;
grant execute on function bulk_upsert_students(jsonb)               to authenticated;
grant execute on function admin_set_batch_active(text, boolean)     to authenticated;
grant execute on function admin_rename_batch(text, text)            to authenticated;
grant execute on function admin_move_students(text[], text)         to authenticated;
grant execute on function admin_provision_students(text[], text)    to authenticated;
grant execute on function student_dashboard()                       to authenticated;
