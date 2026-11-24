-- ============================================================
-- STUDENT ROLE — schema migration v2
-- Run ONCE after schema.sql + assignments.sql + admin-assignment.sql
-- Idempotent — safe to re-run.
-- ============================================================

-- ── 1. Extend role check to include 'student' ──
alter table profiles drop constraint if exists profiles_role_check;
alter table profiles add constraint profiles_role_check
  check (role in ('admin', 'faculty', 'student'));

-- ── 2. Add roll_number + batch to profiles ──
alter table profiles add column if not exists roll_number text;
alter table profiles add column if not exists batch text;
create unique index if not exists profiles_roll on profiles(roll_number)
  where roll_number is not null;

-- ── 3. Students directory (used by admin-students.html) ──
create table if not exists students (
  id text primary key,
  full_name text not null,
  batch text not null,
  created_at timestamptz not null default now()
);
create index if not exists students_batch on students(batch);
alter table students enable row level security;

drop policy if exists "students admin read"  on students;
drop policy if exists "students admin write" on students;
create policy "students admin read" on students for select
  using (my_role() = 'admin');
create policy "students admin write" on students for all
  using (my_role() = 'admin') with check (my_role() = 'admin');

-- ── 4. RPC: batch counts for the directory filter ──
create or replace function get_student_batches()
returns table(batch text, cnt bigint)
language sql stable security definer set search_path = public as $$
  select batch, count(*) from students group by batch order by batch;
$$;
grant execute on function get_student_batches() to authenticated;

-- ── 5. RPC: bulk upsert from Excel import ──
create or replace function bulk_upsert_students(p_rows jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_count int := 0;
begin
  if my_role() <> 'admin' then raise exception 'Admin only'; end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    return jsonb_build_object('error', 'p_rows must be a JSON array');
  end if;
  insert into students (id, full_name, batch)
  select trim(r->>'id'), trim(r->>'full_name'), trim(r->>'batch')
  from jsonb_array_elements(p_rows) r
  where coalesce(trim(r->>'id'), '') <> ''
    and coalesce(trim(r->>'full_name'), '') <> ''
    and coalesce(trim(r->>'batch'), '') <> ''
  on conflict (id) do update
    set full_name = excluded.full_name,
        batch     = excluded.batch;
  get diagnostics v_count = row_count;
  return jsonb_build_object('success', true, 'count', v_count);
end; $$;
grant execute on function bulk_upsert_students(jsonb) to authenticated;

-- ── 6. RPC: create a single student auth account ──
create or replace function admin_create_student(
  p_email text, p_password text, p_full_name text,
  p_roll_number text, p_batch text
) returns jsonb
language plpgsql security definer
set search_path = public, auth, extensions as $$
declare
  v_uid uuid := gen_random_uuid();
  v_existing uuid;
  v_email text := lower(trim(p_email));
begin
  if my_role() <> 'admin' then raise exception 'Admin only'; end if;
  if v_email = '' or v_email is null then raise exception 'Email required'; end if;
  if p_password is null or length(p_password) < 8 then
    raise exception 'Password must be at least 8 characters';
  end if;
  if p_roll_number is null or trim(p_roll_number) = '' then
    raise exception 'Roll number required';
  end if;

  select id into v_existing from auth.users where email = v_email;
  if v_existing is not null then raise exception 'Email already in use'; end if;

  select id into v_existing from profiles where roll_number = trim(p_roll_number);
  if v_existing is not null then raise exception 'Roll number already assigned'; end if;

  insert into auth.users (
    id, email, encrypted_password, email_confirmed_at,
    raw_app_meta_data, raw_user_meta_data,
    created_at, updated_at,
    confirmation_token, email_change, email_change_token_new, recovery_token
  ) values (
    v_uid, v_email, crypt(p_password, gen_salt('bf')), now(),
    jsonb_build_object('provider','email','providers', array['email']),
    jsonb_build_object('full_name', p_full_name, 'role', 'student'),
    now(), now(), '', '', '', ''
  );

  insert into profiles (id, email, full_name, role, roll_number, batch, is_active)
  values (v_uid, v_email, p_full_name, 'student', trim(p_roll_number), trim(p_batch), true)
  on conflict (id) do update
    set role = 'student',
        roll_number = excluded.roll_number,
        batch       = excluded.batch,
        full_name   = coalesce(profiles.full_name, excluded.full_name);

  return jsonb_build_object('success', true, 'user_id', v_uid);
end; $$;
grant execute on function admin_create_student(text, text, text, text, text) to authenticated;

-- ── 7. RPC: update a student account (null = leave unchanged) ──
create or replace function admin_update_student(
  p_user_id uuid, p_full_name text, p_roll_number text,
  p_batch text, p_is_active boolean
) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if my_role() <> 'admin' then raise exception 'Admin only'; end if;
  update profiles set
    full_name   = coalesce(p_full_name, full_name),
    roll_number = coalesce(p_roll_number, roll_number),
    batch       = coalesce(p_batch, batch),
    is_active   = coalesce(p_is_active, is_active)
  where id = p_user_id and role = 'student';
  if not found then raise exception 'Student not found'; end if;
  return jsonb_build_object('success', true);
end; $$;
grant execute on function admin_update_student(uuid, text, text, text, boolean) to authenticated;

-- ── 8. RPC: create accounts for every directory student without one ──
create or replace function admin_bulk_create_students_from_directory(p_default_password text)
returns jsonb
language plpgsql security definer
set search_path = public, auth, extensions as $$
declare
  s record;
  v_uid uuid;
  v_email text;
  v_ok int := 0;
  v_skip int := 0;
  v_err text[] := array[]::text[];
begin
  if my_role() <> 'admin' then raise exception 'Admin only'; end if;
  if p_default_password is null or length(p_default_password) < 8 then
    raise exception 'Password must be at least 8 characters';
  end if;

  for s in
    select st.* from students st
    where not exists (
      select 1 from profiles p
      where p.role = 'student' and p.roll_number = st.id
    )
  loop
    v_email := lower(s.id || '@lpu.co.in');
    if exists (select 1 from auth.users where email = v_email) then
      v_skip := v_skip + 1; continue;
    end if;
    begin
      v_uid := gen_random_uuid();
      insert into auth.users (
        id, email, encrypted_password, email_confirmed_at,
        raw_app_meta_data, raw_user_meta_data,
        created_at, updated_at,
        confirmation_token, email_change, email_change_token_new, recovery_token
      ) values (
        v_uid, v_email, crypt(p_default_password, gen_salt('bf')), now(),
        jsonb_build_object('provider','email','providers', array['email']),
        jsonb_build_object('full_name', s.full_name, 'role', 'student'),
        now(), now(), '', '', '', ''
      );
      insert into profiles (id, email, full_name, role, roll_number, batch, is_active)
      values (v_uid, v_email, s.full_name, 'student', s.id, s.batch, true)
      on conflict (id) do update
        set role = 'student', roll_number = excluded.roll_number, batch = excluded.batch;
      v_ok := v_ok + 1;
    exception when others then
      v_err := array_append(v_err, s.id || ': ' || SQLERRM);
    end;
  end loop;

  return jsonb_build_object('success', true, 'created', v_ok,
                            'skipped', v_skip, 'errors', to_jsonb(v_err));
end; $$;
grant execute on function admin_bulk_create_students_from_directory(text) to authenticated;

-- ── 9. Students can read assignments for their batch ──
drop policy if exists "ass student read" on assignments;
create policy "ass student read" on assignments for select
  using (
    is_active = true
    and exists (
      select 1 from profiles p
      where p.id = auth.uid()
        and p.role = 'student'
        and p.batch = assignments.batch
    )
  );

-- ── 10. Students can read their own submissions ──
drop policy if exists "sub student read" on submissions;
create policy "sub student read" on submissions for select
  using (
    exists (
      select 1 from profiles p
      where p.id = auth.uid()
        and p.role = 'student'
        and p.roll_number = submissions.student_id
    )
  );