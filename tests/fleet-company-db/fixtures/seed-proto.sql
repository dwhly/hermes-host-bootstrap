-- Prototype seed (test identities only; the real seed names come from Dan). Re-runnable.
-- Run by `fleet-company-db seed <file>` (as fleet_owner, one transaction).
INSERT INTO fleet.principals (id, display_name) VALUES
  ('00000000-0000-4000-8000-0000000000e1', 'Test editor'),
  ('00000000-0000-4000-8000-0000000000b1', 'Test viewer'),
  ('00000000-0000-4000-8000-0000000000c1', 'Test revoked editor')
ON CONFLICT (id) DO NOTHING;
INSERT INTO fleet.principal_accounts (provider, subject, principal_id) VALUES
  ('tailscale', 'editor@example.invalid', '00000000-0000-4000-8000-0000000000e1'),
  ('cloudflare_access', 'viewer@example.invalid', '00000000-0000-4000-8000-0000000000b1')
ON CONFLICT DO NOTHING;
INSERT INTO fleet.memberships (principal_id, role)
SELECT p, r FROM (VALUES ('00000000-0000-4000-8000-0000000000e1'::uuid, 'editor'),
                         ('00000000-0000-4000-8000-0000000000b1'::uuid, 'viewer'),
                         ('00000000-0000-4000-8000-0000000000c1'::uuid, 'editor')) v(p, r)
WHERE NOT EXISTS (SELECT 1 FROM fleet.memberships m WHERE m.principal_id = v.p);
UPDATE fleet.memberships SET revoked_at = now()
WHERE principal_id = '00000000-0000-4000-8000-0000000000c1' AND revoked_at IS NULL;
SELECT fleet.seed_task('00000000-0000-4000-8000-00000000a001', 'Disposable test task', 'todo', 'step 2 fixture',
                       '00000000-0000-4000-8000-0000000000e1', 'seed-task-a001');
