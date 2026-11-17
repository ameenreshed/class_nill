-- ============================================================
-- ADMIN ASSIGNMENT CONTROL — extends assignments.sql
-- Run ONCE after assignments.sql. Fully idempotent.
-- ============================================================

-- ── 1. Admin can create assignments on behalf of ANY faculty ──
-- Existing "ass faculty insert" policy stays intact. PERMISSIVE
-- policies OR together, so faculty still self-insert, admin can
-- insert for anyone.
drop policy if exists "ass admin insert any" on assignments;
create policy "ass admin insert any" on assignments for insert
  with check (my_role() = 'admin');

-- ── 2. Fast path lookups for the new storage access check ──
create index if not exists sub_path on submissions(file_path);

-- ── 3. Token-independent storage read/delete ──
-- Previous implementation resolved the assignment via the CURRENT
-- share_token embedded in the file path. If an admin regenerated
-- the token, every old file became unreachable. This version
-- resolves via the submissions row instead — survives token changes.
create or replace function faculty_can_read_submission(p_path text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists(
    select 1
    from submissions s
    join assignments a on a.id = s.assignment_id
    where s.file_path = p_path
      and (a.faculty_id = auth.uid() or my_role() = 'admin')
  );
$$;
grant execute on function faculty_can_read_submission(text) to authenticated;

-- ── 4. Admin dashboard stats RPC ──
create or replace function admin_assignment_stats()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_out jsonb;
begin
  if my_role() <> 'admin' then
    return jsonb_build_object('error', 'Admin only');
  end if;
  select jsonb_build_object(
    'total_assignments',  (select count(*) from assignments),
    'active_assignments', (select count(*) from assignments where is_active = true),
    'past_deadline',      (select count(*) from assignments
                           where is_active = true
                             and deadline is not null
                             and deadline < now()),
    'total_submissions',  (select count(*) from submissions where is_superseded = false),
    'unique_students',    (select count(distinct student_id) from submissions where is_superseded = false)
  ) into v_out;
  return v_out;
end; $$;
grant execute on function admin_assignment_stats() to authenticated;