-- =====================================================
-- A typo must not collapse into somebody else's code
-- =====================================================
--
-- normalize_pickup_code folded seven characters onto lookalikes and then
-- deleted everything outside the 22-symbol alphabet:
--
--     translate(upper(_raw), 'OILSZBG', '0115287')
--     regexp_replace(..., '[^23456789ACDEFHJKMNPRTY]', '', 'g')
--
-- Four of those folds are right: S->5, Z->2, B->8, G->7 all land on characters
-- that are actually in the alphabet, so a parent who writes S for 5 still
-- resolves. The other three are not. O->0, I->1 and L->1 fold onto 0 and 1,
-- which are excluded from the alphabet for exactly the same reason O, I and L
-- are — so the fold produces a character the next line then deletes. The table
-- promised correction and delivered deletion.
--
-- THE PART THAT MATTERS. Deleting a character SHORTENS the string, and the code
-- is now four characters long:
--
--     '3R5FO'  ->  '3R5F'
--     'O3R5F'  ->  '3R5F'
--
-- Both are valid four-character codes belonging to whichever family holds
-- 3R5F. So a five-character typo did not fail — it succeeded, against someone
-- else's batch. That is a path to handing over the wrong child, not a
-- confusing error message.
--
-- WHAT IT DOES NOW.
--
--   * Folds only the four confusables that have a real target in the alphabet.
--   * Strips FORMATTING only — spaces, hyphens, en/em dashes, underscores,
--     dots — so 'C9A-87H' and a scanner's trailing whitespace still work.
--   * Leaves every other character in place. 'K0LM' stays 'K0LM': four
--     characters, no match, an honest failure. It can no longer become 'KM',
--     and nothing can shrink into a code that was never typed.
--
-- Codes already issued are unaffected: they are drawn from the alphabet, which
-- contains no S, Z, B or G and no formatting, so normalising one is a no-op.

CREATE OR REPLACE FUNCTION church.normalize_pickup_code(_raw TEXT)
RETURNS TEXT
LANGUAGE sql IMMUTABLE
SET search_path = church, public, extensions
AS $$
  SELECT regexp_replace(
           translate(upper(coalesce(_raw, '')),
                     -- Only the folds whose target is in the alphabet.
                     'SZBG',
                     '5287'),
           -- Formatting, not "anything unrecognised". Removing unrecognised
           -- characters is what let a typo shrink into a valid code.
           '[[:space:]_.\-]',
           '', 'g');
$$;

NOTIFY pgrst, 'reload schema';
