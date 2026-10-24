-- ============================================================
-- LPU Scheduler — Test accounts
-- Run AFTER schema.sql
-- Passwords: admin123 / faculty123 / student123
-- ============================================================

do $$
declare uid uuid;
begin
  -- ADMIN
  select id into uid from auth.users where email = 'admin@lpu.test';
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
      'admin@lpu.test', crypt('admin123', gen_salt('bf')),
      now(), now(), now(), '', '', '', '',
      '{"provider":"email","providers":["email"]}',
      '{"full_name":"Admin"}'
    );
    insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), uid, uid::text, 'email',
      jsonb_build_object('sub', uid::text, 'email', 'admin@lpu.test'),
      now(), now(), now());
  end if;
  insert into profiles (id, email, full_name, role, is_active)
  values (uid, 'admin@lpu.test', 'Admin', 'admin', true)
  on conflict (id) do update set role = 'admin', is_active = true, full_name = 'Admin';

  -- FACULTY
  select id into uid from auth.users where email = 'faculty@lpu.test';
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
      'faculty@lpu.test', crypt('faculty123', gen_salt('bf')),
      now(), now(), now(), '', '', '', '',
      '{"provider":"email","providers":["email"]}',
      '{"full_name":"Faculty"}'
    );
    insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), uid, uid::text, 'email',
      jsonb_build_object('sub', uid::text, 'email', 'faculty@lpu.test'),
      now(), now(), now());
  end if;
  insert into profiles (id, email, full_name, role, is_active)
  values (uid, 'faculty@lpu.test', 'Faculty', 'faculty', true)
  on conflict (id) do update set role = 'faculty', is_active = true, full_name = 'Faculty';

  -- STUDENT
  select id into uid from auth.users where email = 'student@lpu.test';
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
      'student@lpu.test', crypt('student123', gen_salt('bf')),
      now(), now(), now(), '', '', '', '',
      '{"provider":"email","providers":["email"]}',
      '{"full_name":"Student"}'
    );
    insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), uid, uid::text, 'email',
      jsonb_build_object('sub', uid::text, 'email', 'student@lpu.test'),
      now(), now(), now());
  end if;
  insert into profiles (id, email, full_name, role, is_active)
  values (uid, 'student@lpu.test', 'Student', 'student', true)
  on conflict (id) do update set role = 'student', is_active = true, full_name = 'Student';
end $$;

select email, role, full_name from profiles order by role;