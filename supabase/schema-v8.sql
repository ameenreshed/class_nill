-- ============================================================
-- LPU Scheduler v8 — user ID management + password tracking
-- Run AFTER schema-v7.sql
-- ============================================================

-- Single user ID change
create or replace function admin_change_user_userid(p_user_id uuid, p_new_userid text)
returns jsonb language plpgsql security definer
set search_path = public, auth, extensions as $$
declare v_new_email text;
begin
  if my_role() <> 'admin' then return jsonb_build_object('error', 'Admin only'); end if;
  if p_new_userid !~ '^[0-9]{3,20}$' then
    return jsonb_build_object('error', 'User ID must be 3–20 digits');
  end if;
  v_new_email := p_new_userid || '@lpu.in';
  if exists(select 1 from auth.users where email = v_new_email and id <> p_user_id) then
    return jsonb_build_object('error', 'User ID already taken by another account');
  end if;
  update auth.users set email = v_new_email, updated_at = now() where id = p_user_id;
  if not found then return jsonb_build_object('error', 'User not found'); end if;
  update auth.identities
    set identity_data = jsonb_set(identity_data, '{email}', to_jsonb(v_new_email)),
        provider_id = v_new_email
    where user_id = p_user_id and provider = 'email';
  update public.profiles set email = v_new_email where id = p_user_id;
  return jsonb_build_object('success', true, 'new_email', v_new_email);
end; $$;
grant execute on function admin_change_user_userid(uuid, text) to authenticated;

-- Bulk user ID change
create or replace function admin_bulk_change_userids(p_updates jsonb)
returns jsonb language plpgsql security definer
set search_path = public, auth, extensions as $$
declare
  v_item jsonb;
  v_uid uuid;
  v_new_id text;
  v_new_email text;
  v_success int := 0;
  v_errors jsonb := '[]'::jsonb;
begin
  if my_role() <> 'admin' then return jsonb_build_object('error', 'Admin only'); end if;
  for v_item in select * from jsonb_array_elements(p_updates) loop
    v_uid := (v_item->>'user_id')::uuid;
    v_new_id := v_item->>'new_userid';
    v_new_email := v_new_id || '@lpu.in';
    if v_new_id !~ '^[0-9]{3,20}$' then
      v_errors := v_errors || jsonb_build_object('user_id', v_uid, 'error', 'Invalid format');
      continue;
    end if;
    if exists(select 1 from auth.users where email = v_new_email and id <> v_uid) then
      v_errors := v_errors || jsonb_build_object('user_id', v_uid, 'error', 'Already taken');
      continue;
    end if;
    update auth.users set email = v_new_email, updated_at = now() where id = v_uid;
    if not found then
      v_errors := v_errors || jsonb_build_object('user_id', v_uid, 'error', 'User not found');
      continue;
    end if;
    update auth.identities
      set identity_data = jsonb_set(identity_data, '{email}', to_jsonb(v_new_email)),
          provider_id = v_new_email
      where user_id = v_uid and provider = 'email';
    update public.profiles set email = v_new_email where id = v_uid;
    v_success := v_success + 1;
  end loop;
  return jsonb_build_object('success', true, 'updated', v_success, 'errors', v_errors);
end; $$;
grant execute on function admin_bulk_change_userids(jsonb) to authenticated;

-- Password-change marker (called from profile.html after change)
create or replace function mark_password_changed()
returns void language plpgsql security definer set search_path = public as $$
begin
  update profiles set password_changed_at = now() where id = auth.uid();
end; $$;
grant execute on function mark_password_changed() to authenticated;

select 'v8 ready — user ID management installed' as status;