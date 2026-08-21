-- =====================================================
-- A child's emergency contact is their parents
-- =====================================================
--
-- station_child_safety_card read person_emergency_contacts and nothing else.
-- That table is filled in only when somebody typed an emergency contact during
-- registration — an optional field — so for most children the volunteer
-- holding a reacting child saw a blank where a phone number should be, while
-- the child's own mother's number sat in the directory.
--
-- The people you call about a child are their parents. An "emergency contact"
-- in the registration form is the person to try when the parents cannot be
-- reached — an addition, not a replacement.
--
-- So the card now names the parents first and falls back to the recorded
-- contact, and returns both rather than making the volunteer choose.

DROP FUNCTION IF EXISTS church.station_child_safety_card(UUID, TEXT);

CREATE OR REPLACE FUNCTION church.station_child_safety_card(
  _check_in_id UUID, _shift_token TEXT DEFAULT NULL)
RETURNS TABLE (
  child_name TEXT,
  allergy_severity TEXT,
  allergies TEXT,
  medications TEXT,
  special_needs TEXT,
  emergency_name TEXT,
  emergency_phone TEXT,
  /* Everyone worth calling, parents first, so a volunteer working down the
     list does not have to guess who is who. */
  contacts JSONB
)
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  a church.resolved_actor;
  ci church.kids_check_ins%ROWTYPE;
BEGIN
  a := church.resolve_actor(_shift_token);
  SELECT * INTO ci FROM church.kids_check_ins
   WHERE id = _check_in_id AND organization_id = a.organization_id
     AND status = 'checked_in';
  IF NOT FOUND THEN RAISE EXCEPTION 'check_in_not_active'; END IF;

  INSERT INTO church.check_in_audit
    (organization_id, action, check_in_id, child_person_id, station_id,
     volunteer_id, actor_auth_user_id, actor_name)
  VALUES (a.organization_id, 'sensitive_viewed', _check_in_id,
          ci.child_person_id, a.station_id, a.volunteer_id, auth.uid(), a.actor_name);

  RETURN QUERY
  WITH parents AS (
    -- A guardian relationship first, then any other adult of the household.
    -- Someone barred by a protective order is excluded: telephoning them in an
    -- emergency is the one thing the order exists to prevent.
    SELECT DISTINCT ON (p.id)
           coalesce(p.preferred_name, p.first_name) || ' ' || p.last_name AS nm,
           p.phone,
           CASE WHEN rt.implies_guardianship THEN 'Parent'
                ELSE 'Household' END AS rel,
           CASE WHEN rt.implies_guardianship THEN 0 ELSE 1 END AS rank
    FROM church.household_members hm_child
    JOIN church.household_members hm_adult
      ON hm_adult.household_id = hm_child.household_id
     AND hm_adult.end_date IS NULL
    JOIN church.people p
      ON p.id = hm_adult.person_id AND NOT p.is_child AND p.is_active
    LEFT JOIN church.person_relationships rel
      ON rel.person_id = p.id
     AND rel.related_person_id = ci.child_person_id
     AND rel.end_date IS NULL
    LEFT JOIN church.relationship_types rt ON rt.id = rel.relationship_type_id
    WHERE hm_child.person_id = ci.child_person_id
      AND hm_child.end_date IS NULL
      AND p.phone IS NOT NULL
      AND NOT church.restriction_names_person(ci.child_person_id, p.id, NULL)
    ORDER BY p.id, rank
  ),
  recorded AS (
    SELECT e.name AS nm, e.phone,
           coalesce(NULLIF(btrim(coalesce(e.relationship, '')), ''),
                    'Emergency contact') AS rel,
           2 + e.priority AS rank
    FROM church.person_emergency_contacts e
    WHERE e.person_id = ci.child_person_id
  ),
  everyone AS (
    SELECT * FROM parents
    UNION ALL
    SELECT * FROM recorded
  )
  SELECT ci.label_child_name, s.allergy_severity, s.allergies, s.medications,
         s.special_needs,
         first_contact.nm,
         first_contact.phone,
         coalesce(all_contacts.list, '[]'::jsonb)
  FROM (SELECT 1) dummy
  LEFT JOIN church.person_sensitive s ON s.person_id = ci.child_person_id
  LEFT JOIN LATERAL (
    SELECT e.nm, e.phone FROM everyone e ORDER BY e.rank, e.nm LIMIT 1
  ) first_contact ON true
  LEFT JOIN LATERAL (
    SELECT jsonb_agg(jsonb_build_object(
             'name', e.nm, 'phone', e.phone, 'relationship', e.rel)
           ORDER BY e.rank, e.nm) AS list
    FROM everyone e
  ) all_contacts ON true;
END;
$$;

GRANT EXECUTE ON FUNCTION church.station_child_safety_card(UUID, TEXT)
  TO authenticated;

NOTIFY pgrst, 'reload schema';
