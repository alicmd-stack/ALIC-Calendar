-- =====================================================
-- Somewhere to record a child's allergy
-- =====================================================
--
-- church.person_sensitive is READ in four places — the check-in label, the
-- safety card a volunteer opens during an emergency, and the two roster views —
-- and WRITTEN by nothing. Not by registration, not by import, not by any
-- screen. It is empty for every child and always will be.
--
-- So station_child_safety_card, which exists so a volunteer can find out what
-- a child is allergic to while that child is reacting, returns NULLs. And
-- check_in_one_child stamps label_allergy_flag from it, so the printed tag
-- carries no allergy warning either.
--
-- This is also what locked decision 13 traded away. Org admins were given
-- access to children's medical data on the grounds that every access is
-- audited — a reasonable trade only if the data is ever actually there.
--
-- The audit row here is on the WRITE. Reads are already audited by
-- station_child_safety_card; an edit to a child's allergy record deserves the
-- same, because "who changed this and when" is the first question after an
-- incident.

CREATE OR REPLACE FUNCTION church.upsert_person_sensitive(
  _person_id UUID,
  _allergy_severity TEXT DEFAULT 'none',
  _allergies TEXT DEFAULT NULL,
  _allergy_label_short TEXT DEFAULT NULL,
  _medications TEXT DEFAULT NULL,
  _medical_notes TEXT DEFAULT NULL,
  _special_needs TEXT DEFAULT NULL,
  _photo_consent BOOLEAN DEFAULT false
)
RETURNS church.person_sensitive
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  _org UUID;
  _actor TEXT;
  _row church.person_sensitive;
  _label TEXT;
  _severity TEXT := coalesce(NULLIF(btrim(coalesce(_allergy_severity, '')), ''), 'none');
BEGIN
  SELECT p.organization_id INTO _org FROM church.people p WHERE p.id = _person_id;
  IF _org IS NULL THEN RAISE EXCEPTION 'person_not_found'; END IF;

  IF NOT church.has_permission_in_org(
       _org, ARRAY['members_admin','kids_admin']::church.module_permission[]) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  IF _severity NOT IN ('none', 'mild', 'severe', 'life_threatening') THEN
    RAISE EXCEPTION 'invalid_allergy_severity'
      USING DETAIL = 'Expected none, mild, severe or life_threatening';
  END IF;

  -- The short label is what fits on the printed tag beside the child's name.
  -- Derived from the full allergy text when nobody supplied one, because an
  -- allergy recorded in the notes and absent from the label is an allergy the
  -- volunteer in the room never sees.
  _label := NULLIF(btrim(coalesce(_allergy_label_short, '')), '');
  IF _label IS NULL AND _severity <> 'none' THEN
    _label := left(btrim(coalesce(_allergies, 'ALLERGY')), 24);
  END IF;
  IF _label IS NOT NULL AND char_length(_label) > 24 THEN
    RAISE EXCEPTION 'allergy_label_too_long'
      USING DETAIL = format('%s characters; the printed tag fits 24',
                            char_length(_label));
  END IF;

  _actor := coalesce(
    (SELECT full_name FROM public.profiles WHERE id = auth.uid()), 'Administrator');

  INSERT INTO church.person_sensitive (
    person_id, organization_id, allergy_severity, allergies,
    allergy_label_short, medications, medical_notes, special_needs,
    special_needs_flag, photo_consent, updated_by, updated_by_name)
  VALUES (
    _person_id, _org, _severity,
    NULLIF(btrim(coalesce(_allergies, '')), ''),
    _label,
    NULLIF(btrim(coalesce(_medications, '')), ''),
    NULLIF(btrim(coalesce(_medical_notes, '')), ''),
    NULLIF(btrim(coalesce(_special_needs, '')), ''),
    NULLIF(btrim(coalesce(_special_needs, '')), '') IS NOT NULL,
    coalesce(_photo_consent, false), auth.uid(), _actor)
  ON CONFLICT (person_id) DO UPDATE SET
    allergy_severity = EXCLUDED.allergy_severity,
    allergies = EXCLUDED.allergies,
    allergy_label_short = EXCLUDED.allergy_label_short,
    medications = EXCLUDED.medications,
    medical_notes = EXCLUDED.medical_notes,
    special_needs = EXCLUDED.special_needs,
    special_needs_flag = EXCLUDED.special_needs_flag,
    photo_consent = EXCLUDED.photo_consent,
    updated_by = EXCLUDED.updated_by,
    updated_by_name = EXCLUDED.updated_by_name,
    updated_at = now()
  RETURNING * INTO _row;

  -- Traceable for the same reason reads are.
  INSERT INTO church.check_in_audit (
    organization_id, action, outcome, child_person_id,
    actor_auth_user_id, actor_name, detail)
  VALUES (
    _org, 'sensitive_viewed', 'success', _person_id, auth.uid(), _actor,
    jsonb_build_object('action', 'medical_record_edited',
                       'severity', _severity,
                       'has_allergies', _row.allergies IS NOT NULL,
                       'has_medications', _row.medications IS NOT NULL));

  RETURN _row;
END;
$$;

GRANT EXECUTE ON FUNCTION church.upsert_person_sensitive(
  UUID, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, BOOLEAN) TO authenticated;

-- ---------------------------------------------------------------------------
-- Bringing an already-checked-in child's label up to date
-- ---------------------------------------------------------------------------
--
-- check_in_one_child copies the allergy flag onto the check-in row at check-in
-- time, deliberately: a later edit must not silently rewrite the history of a
-- Sunday. But when a parent mentions an allergy AT the desk, after the tag has
-- printed, the flag the volunteers see all morning is the stale one.
--
-- This refreshes the live check-ins only — never a closed one.
CREATE OR REPLACE FUNCTION church.refresh_child_allergy_flags(_person_id UUID)
RETURNS INTEGER
LANGUAGE plpgsql VOLATILE SECURITY DEFINER
SET search_path = church, public, extensions
AS $$
DECLARE
  _org UUID;
  _n INTEGER;
BEGIN
  SELECT p.organization_id INTO _org FROM church.people p WHERE p.id = _person_id;
  IF _org IS NULL THEN RAISE EXCEPTION 'person_not_found'; END IF;

  IF NOT church.has_permission_in_org(
       _org, ARRAY['members_admin','kids_admin']::church.module_permission[]) THEN
    RAISE EXCEPTION 'not_permitted' USING ERRCODE = '42501';
  END IF;

  UPDATE church.kids_check_ins c
     SET label_allergy_flag = coalesce(s.allergy_severity <> 'none', false),
         label_allergy_short = s.allergy_label_short,
         label_special_needs_flag = coalesce(s.special_needs_flag, false),
         updated_at = now()
    FROM church.person_sensitive s
   WHERE s.person_id = c.child_person_id
     AND c.child_person_id = _person_id
     AND c.status = 'checked_in';

  GET DIAGNOSTICS _n = ROW_COUNT;
  RETURN _n;
END;
$$;

GRANT EXECUTE ON FUNCTION church.refresh_child_allergy_flags(UUID) TO authenticated;

NOTIFY pgrst, 'reload schema';
