-- =====================================================
-- Four-character pickup codes
-- =====================================================
--
-- Requested by the ministry lead: a code in the shape of the reference tag,
-- four characters read at a glance rather than six read off a label.
--
-- The alphabet is unchanged — the same 22 symbols, with O/I/L/S/Z/B/G excluded
-- because these codes get read aloud across a corridor and written on paper
-- tickets when the printer dies. normalize_pickup_code already folds the
-- confusable characters onto their twins, so a parent who writes 0 for O still
-- resolves.
--
-- THE COST, STATED PLAINLY. 22^6 was ~113 million. 22^4 is 234,256. Against a
-- busy morning of ~80 live codes a single blind guess lands on SOME live batch
-- about once in 2,900 attempts, and resolve_pickup only rate-limits attempts
-- once they match a batch — a guess that matches nothing locks nothing, so
-- there is no ceiling on blind guessing today.
--
-- That is a real reduction and it is the trade the lead asked for. Two things
-- keep it from being a release: check_out_children refuses to release a child
-- with a restriction on file unless the collector is NAMED, and every resolve
-- attempt writes a code_failed audit row. The gap worth closing next is a
-- per-session ceiling on failed attempts regardless of whether they matched.
--
-- Collisions are handled, not hoped away: check_in_children already retries up
-- to ten times on unique_violation, and at four characters a whole morning of
-- 80 batches collides at ~1.3% — well inside that budget.

CREATE OR REPLACE FUNCTION church.generate_pickup_code()
RETURNS TEXT
LANGUAGE plpgsql
SET search_path = church, public, extensions
AS $$
DECLARE
  _alphabet TEXT := '23456789ACDEFHJKMNPRTY';
  _out TEXT := '';
  _i INTEGER;
BEGIN
  FOR _i IN 1..4 LOOP
    -- gen_random_bytes, not random(): random() is seeded and predictable, and
    -- this value releases a child.
    --
    -- 256 is not a multiple of 22, so a plain modulo would make the first six
    -- symbols of the alphabet very slightly likelier than the rest. Rejecting
    -- the short tail keeps the draw uniform. At four characters the space is
    -- small enough that a biased draw is no longer a rounding error.
    LOOP
      DECLARE _b INTEGER := get_byte(gen_random_bytes(1), 0);
      BEGIN
        IF _b < 252 THEN
          _out := _out || substr(_alphabet, 1 + (_b % 22), 1);
          EXIT;
        END IF;
      END;
    END LOOP;
  END LOOP;
  RETURN _out;
END;
$$;

REVOKE ALL ON FUNCTION church.generate_pickup_code() FROM PUBLIC;

NOTIFY pgrst, 'reload schema';
