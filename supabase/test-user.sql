create extension if not exists pgcrypto;

do $$
declare
  uid uuid;
begin
  -- ADMIN
  select id into uid from auth.users where email = 'admin@amnrd.com';
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
      'admin@amnrd.com',
      crypt('admin123', gen_salt('bf')),
      now(), now(), now(),
      '', '', '', '',
      '{"provider":"email","providers":["email"]}',
      '{"full_name":"Admin"}'
    );
    insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), uid, uid::text, 'email',
      jsonb_build_object('sub', uid::text, 'email', 'admin@amnrd.com'),
      now(), now(), now());
  end if;
  insert into profiles (id, email, full_name, role)
  values (uid, 'admin@amnrd.com', 'Admin', 'admin')
  on conflict (id) do update set role = 'admin', full_name = 'Admin';

  -- FACULTY
  select id into uid from auth.users where email = 'faculty@amnrd.com';
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
      'faculty@amnrd.com',
      crypt('faculty123', gen_salt('bf')),
      now(), now(), now(),
      '', '', '', '',
      '{"provider":"email","providers":["email"]}',
      '{"full_name":"Faculty"}'
    );
    insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), uid, uid::text, 'email',
      jsonb_build_object('sub', uid::text, 'email', 'faculty@amnrd.com'),
      now(), now(), now());
  end if;
  insert into profiles (id, email, full_name, role)
  values (uid, 'faculty@amnrd.com', 'Faculty', 'faculty')
  on conflict (id) do update set role = 'faculty', full_name = 'Faculty';

  -- STUDENT
  select id into uid from auth.users where email = 'student@amnrd.com';
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
      'student@amnrd.com',
      crypt('student123', gen_salt('bf')),
      now(), now(), now(),
      '', '', '', '',
      '{"provider":"email","providers":["email"]}',
      '{"full_name":"Student"}'
    );
    insert into auth.identities (id, user_id, provider_id, provider, identity_data, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), uid, uid::text, 'email',
      jsonb_build_object('sub', uid::text, 'email', 'student@amnrd.com'),
      now(), now(), now());
  end if;
  insert into profiles (id, email, full_name, role)
  values (uid, 'student@amnrd.com', 'Student', 'student')
  on conflict (id) do update set role = 'student', full_name = 'Student';
end $$;

select email, role, full_name from profiles order by role;