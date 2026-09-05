-- Allow a freshly authenticated user to create their OWN profile row as a
-- Resident (role_id 7) — needed for the public self-signup page. Staff/admin
-- roles are still only ever assigned via the create-user edge function
-- (which runs as service role and requires an existing Admin session), so
-- this policy is deliberately locked to role_id = 7 to prevent someone from
-- signing up and granting themselves elevated access.

create policy "profiles: self-insert as resident"
  on public.profiles for insert
  to authenticated
  with check (id = auth.uid() and role_id = 7);
