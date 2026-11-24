-- ============================================================
-- ADMIN ASSIGNMENT FULL CONTROL — extends assignments.sql
-- Run ONCE after assignments.sql. Fully idempotent.
-- ============================================================

-- ── 1. Admin can create assignments for any faculty ──
-- The existing "ass faculty insert" policy remains; PERMISSIVE
-- policies OR, so faculty still self-insert and admins can too.
drop policy if exists "ass admin insert any" on assignments;
create policy "ass admin insert any" on assignments for insert
  with check (my_role() = 'admin');

-- ── 2. Join-based storage access check ──
-- Original version resolved via current share_token in the path,
-- so regenerating a token orphaned every existing file. This one
-- resolves via the submissions row — survives token changes.
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

-- ── 3. Admin full storage access ──
-- Without these, admins CANNOT:
--   • browse the bucket (list policy keys off faculty_can_read_submission,
--     which returns false for orphan files → they're invisible)
--   • delete orphans (no matching submissions row → delete policy denies)
--   • force-delete files after a partial failure
-- These three policies fix all of that.
drop policy if exists "admin full storage select" on storage.objects;
create policy "admin full storage select" on storage.objects for select
  to authenticated
using (bucket_id = 'assignment-submissions' and my_role() = 'admin');

drop policy if exists "admin full storage delete" on storage.objects;
create policy "admin full storage delete" on storage.objects for delete
  to authenticated
using (bucket_id = 'assignment-submissions' and my_role() = 'admin');

drop policy if exists "admin full storage update" on storage.objects;
create policy "admin full storage update" on storage.objects for update
  to authenticated
using (bucket_id = 'assignment-submissions' and my_role() = 'admin');

-- ── 4. Speed up path lookups (used by faculty_can_read_submission) ──
create index if not exists sub_path on submissions(file_path);