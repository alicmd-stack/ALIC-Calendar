-- =====================================================
-- The four team leads move from director to team lead
-- =====================================================
--
-- Azeb, Hana, Biruck and Salem were provisioned as kids_admin because that was
-- the only level that existed. That gave each of them override rights over
-- every child in the branch — see 20260321001000 for why the scope table did
-- not contain that.
--
-- Tibarek and Edilawit stay kids_admin: they are the directors and the
-- escalation path for an override.

-- Future invitations for these four issue the new permission.
UPDATE church.kids_leader_invites
   SET permission = 'kids_leader', updated_at = now()
 WHERE scope_room_ids IS NOT NULL
   AND array_length(scope_room_ids, 1) > 0
   AND permission = 'kids_admin';

-- And the grants already claimed. Insert before delete so nobody is briefly
-- left with no kids permission at all.
INSERT INTO church.module_grants
  (user_id, organization_id, permission, granted_by_name, notes)
SELECT g.user_id, g.organization_id, 'kids_leader', g.granted_by_name,
       'Downgraded from kids_admin: team lead scoped to their grades'
FROM church.module_grants g
WHERE g.permission = 'kids_admin'
  AND EXISTS (SELECT 1 FROM church.kids_leader_scope s
               WHERE s.user_id = g.user_id
                 AND s.organization_id = g.organization_id)
ON CONFLICT (user_id, organization_id, permission) DO NOTHING;

DELETE FROM church.module_grants g
WHERE g.permission = 'kids_admin'
  AND EXISTS (SELECT 1 FROM church.kids_leader_scope s
               WHERE s.user_id = g.user_id
                 AND s.organization_id = g.organization_id);

NOTIFY pgrst, 'reload schema';
