-- ============================================================
-- LPU Scheduler v4 — Admin RPCs for user management
-- Run AFTER schema.sql, schema-additions.sql, schema-v3.sql
-- ============================================================

-- Create a user (auth.users + auth.identities + profiles)
create or replace function admin_create_user(
  p_email text,
  p_password text,
  p_full_name text,
  p_role text,
  p_department text default null,
  p_section_id text default null,
  p_phone text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, extensions
as $$
declare
  v_uid uuid;
  v_existing uuid;
begin
  if my_role() <> 'admin' then
    return jsonb_build_object('error', 'Admin only');
  end if;

  if p_role not in ('admin','faculty','student') then
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
    '00000000-0000-0000-0000-000000000000',
    v_uid, 'authenticated', 'authenticated',
    p_email, crypt(p_password, gen_salt('bf')),
    now(), now(), now(), '', '', '', '',
    jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
    jsonb_build_object('full_name', coalesce(p_full_name, p_email))
  );

  insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
  values (
    gen_random_uuid(), v_uid, v_uid::text, 'email',
    jsonb_build_object('sub', v_uid::text, 'email', p_email),
    now(), now(), now()
  );

  insert into public.profiles (id, email, full_name, role, department, section_id, phone, is_active)
  values (v_uid, p_email, p_full_name, p_role, p_department, p_section_id, p_phone, true)
  on conflict (id) do update set
    full_name = excluded.full_name,
    role = excluded.role,
    department = excluded.department,
    section_id = excluded.section_id,
    phone = excluded.phone,
    is_active = true;

  return jsonb_build_object('success', true, 'user_id', v_uid);
end;
$$;
grant execute on function admin_create_user(text, text, text, text, text, text, text) to authenticated;

-- Reset a user's password
create or replace function admin_reset_password(p_user_id uuid, p_new_password text)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, extensions
as $$
begin
  if my_role() <> 'admin' then
    return jsonb_build_object('error', 'Admin only');
  end if;
  if p_new_password is null or length(p_new_password) < 6 then
    return jsonb_build_object('error', 'Password must be at least 6 characters');
  end if;
  update auth.users
    set encrypted_password = crypt(p_new_password, gen_salt('bf')),
        updated_at = now()
    where id = p_user_id;
  if not found then
    return jsonb_build_object('error', 'User not found');
  end if;
  return jsonb_build_object('success', true);
end;
$$;
grant execute on function admin_reset_password(uuid, text) to authenticated;

-- Delete a user entirely (auth + profile)
create or replace function admin_delete_user(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if my_role() <> 'admin' then
    return jsonb_build_object('error', 'Admin only');
  end if;
  if p_user_id = auth.uid() then
    return jsonb_build_object('error', 'You cannot delete your own account');
  end if;
  delete from auth.users where id = p_user_id;
  if not found then
    return jsonb_build_object('error', 'User not found');
  end if;
  return jsonb_build_object('success', true);
end;
$$;
grant execute on function admin_delete_user(uuid) to authenticated;

-- Bulk-assign students to a section
create or replace function admin_assign_students(p_section_id text, p_user_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count int;
begin
  if my_role() <> 'admin' then
    return jsonb_build_object('error', 'Admin only');
  end if;
  update profiles set section_id = p_section_id
    where id = any(p_user_ids) and role = 'student';
  get diagnostics v_count = row_count;
  return jsonb_build_object('success', true, 'updated', v_count);
end;
$$;
grant execute on function admin_assign_students(text, uuid[]) to authenticated;

-- Bulk-remove students from their section
create or replace function admin_remove_students(p_user_ids uuid[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count int;
begin
  if my_role() <> 'admin' then
    return jsonb_build_object('error', 'Admin only');
  end if;
  update profiles set section_id = null
    where id = any(p_user_ids) and role = 'student';
  get diagnostics v_count = row_count;
  return jsonb_build_object('success', true, 'updated', v_count);
end;
$$;
grant execute on function admin_remove_students(uuid[]) to authenticated;

select 'v4 ready — admin RPCs installed' as status;