-- ============================================================
-- LPU Scheduler — demo users with numeric registration IDs
-- Run AFTER schema.sql in Supabase SQL Editor
-- ============================================================

do $$
declare uid uuid;
begin
  -----------------------------------------------------------
  -- ADMIN  —  11111111 / admin123
  -----------------------------------------------------------
  select id into uid from auth.users where email = '11111111@lpu.in';
  if uid is null then
    uid := gen_random_uuid();
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, created_at, updated_at,
      confirmation_token, email_change, email_change_token_new, recovery_token,
      raw_app_meta_data, raw_user_meta_data
    ) values (
      '00000000-0000-0000-0000-000000000000',
      uid, 'authenticated', 'authenticated',
      '11111111@lpu.in', crypt('admin123', gen_salt('bf')),
      now(), now(), now(), '', '', '', '',
      '{"provider":"email","providers":["email"]}',
      '{"full_name":"Admin"}'
    );
    insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), uid, uid::text, 'email',
      jsonb_build_object('sub', uid::text, 'email', '11111111@lpu.in'),
      now(), now(), now());
  end if;
  insert into profiles (id, email, full_name, role, is_active)
  values (uid, '11111111@lpu.in', 'Admin', 'admin', true)
  on conflict (id) do update set role = 'admin', is_active = true, full_name = 'Admin';

  -----------------------------------------------------------
  -- FACULTY  —  22222222 / faculty123
  -----------------------------------------------------------
  select id into uid from auth.users where email = '22222222@lpu.in';
  if uid is null then
    uid := gen_random_uuid();
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, created_at, updated_at,
      confirmation_token, email_change, email_change_token_new, recovery_token,
      raw_app_meta_data, raw_user_meta_data
    ) values (
      '00000000-0000-0000-0000-000000000000',
      uid, 'authenticated', 'authenticated',
      '22222222@lpu.in', crypt('faculty123', gen_salt('bf')),
      now(), now(), now(), '', '', '', '',
      '{"provider":"email","providers":["email"]}',
      '{"full_name":"Faculty"}'
    );
    insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), uid, uid::text, 'email',
      jsonb_build_object('sub', uid::text, 'email', '22222222@lpu.in'),
      now(), now(), now());
  end if;
  insert into profiles (id, email, full_name, role, is_active)
  values (uid, '22222222@lpu.in', 'Faculty', 'faculty', true)
  on conflict (id) do update set role = 'faculty', is_active = true, full_name = 'Faculty';

  -----------------------------------------------------------
  -- STUDENT  —  33333333 / student123
  -----------------------------------------------------------
  select id into uid from auth.users where email = '33333333@lpu.in';
  if uid is null then
    uid := gen_random_uuid();
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, created_at, updated_at,
      confirmation_token, email_change, email_change_token_new, recovery_token,
      raw_app_meta_data, raw_user_meta_data
    ) values (
      '00000000-0000-0000-0000-000000000000',
      uid, 'authenticated', 'authenticated',
      '33333333@lpu.in', crypt('student123', gen_salt('bf')),
      now(), now(), now(), '', '', '', '',
      '{"provider":"email","providers":["email"]}',
      '{"full_name":"Student"}'
    );
    insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), uid, uid::text, 'email',
      jsonb_build_object('sub', uid::text, 'email', '33333333@lpu.in'),
      now(), now(), now());
  end if;
  insert into profiles (id, email, full_name, role, is_active)
  values (uid, '33333333@lpu.in', 'Student', 'student', true)
  on conflict (id) do update set role = 'student', is_active = true, full_name = 'Student';
end $$;

-- verify
select email, role, full_name, is_active from profiles order by role;