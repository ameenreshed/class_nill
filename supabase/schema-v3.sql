-- ============================================================
-- Phase 3: user profiles + admin controls
-- Safe to re-run
-- ============================================================

-- New columns
alter table profiles add column if not exists is_active boolean default true;
alter table profiles add column if not exists phone text;
alter table profiles add column if not exists password_changed_at timestamptz;
alter table profiles add column if not exists suspended_at timestamptz;
alter table profiles add column if not exists suspended_reason text;

update profiles set is_active = true where is_active is null;

create index if not exists profiles_active on profiles (is_active);
create index if not exists profiles_role on profiles (role);
create index if not exists profiles_last_active on profiles (last_active_at desc nulls last);

-- Ensure new signups are active
create or replace function handle_new_user()
returns trigger language plpgsql security definer as $$
begin
  insert into public.profiles (id, email, full_name, role, is_active)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'full_name', new.email),
    'student',
    true
  )
  on conflict (id) do nothing;
  return new;
end; $$;

-- Allow user to update own profile (name/phone only — enforced by RPC, not raw UPDATE)
drop policy if exists "profiles self update" on profiles;
create policy "profiles self update" on profiles for update
  using (id = auth.uid())
  with check (id = auth.uid());

-- ---- RPCs ----
create or replace function update_my_profile(p_full_name text, p_phone text)
returns void language plpgsql security definer set search_path = public as $$
begin
  update profiles
  set full_name = coalesce(nullif(trim(p_full_name), ''), full_name),
      phone = nullif(trim(p_phone), ''),
      last_active_at = now()
  where id = auth.uid();
end; $$;
grant execute on function update_my_profile(text, text) to authenticated;

create or replace function mark_password_changed()
returns void language plpgsql security definer set search_path = public as $$
begin
  update profiles set password_changed_at = now() where id = auth.uid();
end; $$;
grant execute on function mark_password_changed() to authenticated;

create or replace function heartbeat()
returns void language plpgsql security definer set search_path = public as $$
begin
  update profiles set last_active_at = now() where id = auth.uid();
end; $$;
grant execute on function heartbeat() to authenticated;

create or replace function log_login(p_user_agent text default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into activity_log (user_id, user_email, action, entity, details)
  select auth.uid(), email, 'auth.login', 'session',
         jsonb_build_object('user_agent', coalesce(p_user_agent, 'unknown'))
  from profiles where id = auth.uid();
end; $$;
grant execute on function log_login(text) to authenticated;

-- ---- Activity: self-read ----
drop policy if exists "activity self read" on activity_log;
create policy "activity self read" on activity_log for select
  using (user_id = auth.uid());

-- ---- Profile change log (skips heartbeat-only updates) ----
create or replace function log_profile_change()
returns trigger language plpgsql security definer as $$
declare v_email text;
begin
  if TG_OP = 'UPDATE' then
    -- Skip if only last_active_at changed
    if NEW.last_active_at is distinct from OLD.last_active_at
       and NEW.full_name     is not distinct from OLD.full_name
       and NEW.phone         is not distinct from OLD.phone
       and NEW.role          is not distinct from OLD.role
       and NEW.is_active     is not distinct from OLD.is_active
       and NEW.department    is not distinct from OLD.department then
      return NEW;
    end if;
  end if;

  select email into v_email from profiles where id = auth.uid();
  insert into activity_log (user_id, user_email, action, entity, entity_id, details)
  values (
    auth.uid(), v_email,
    'user.' || lower(TG_OP),
    'profile',
    coalesce(NEW.id, OLD.id)::text,
    case when TG_OP = 'DELETE' then to_jsonb(OLD) else to_jsonb(NEW) end
  );
  return coalesce(NEW, OLD);
end; $$;

drop trigger if exists trg_log_profile on profiles;
create trigger trg_log_profile
  after insert or update or delete on profiles
  for each row execute function log_profile_change();

-- ---- Verify ----
select
  count(*) as total_users,
  count(*) filter (where is_active)          as active,
  count(*) filter (where not is_active)      as suspended,
  count(*) filter (where role = 'admin')     as admins,
  count(*) filter (where role = 'faculty')   as faculty,
  count(*) filter (where role = 'student')   as students
from profiles;