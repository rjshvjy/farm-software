-- https://github.com/rjshvjy/farm-software  ·  sql/11_fix_party_upsert.sql
-- ============================================================================
-- FARM & HOME ACCOUNTS — file 11: fn_party_upsert actually works.
--
-- RUN AFTER file 10. Idempotent. Small and surgical.
--
-- ---------------------------------------------------------------------------
-- THE BUG
--
--   fn_party_upsert called fn_has_permission(...). No such function exists and
--   never did. The permission helpers in this system are:
--
--       fn_has_capability(p_capability text) -> boolean
--       fn_require(p_capability text)        -> void, raises if not permitted
--
--   Every other function uses fn_require. fn_party_upsert alone used an
--   invented name, so any call died with:
--
--       function fn_has_permission(unknown) does not exist
--
--   It came in with file 08 and was copied verbatim into file 10 without being
--   checked against the schema. So INLINE PARTY CREATION HAS NEVER WORKED —
--   not once, in any version, since file 08. It went unnoticed because nobody
--   had yet added a party from the entry screen; the first real attempt found
--   it (20 July, "Semalai").
--
--   Two lessons, both recorded in the spec §16.11:
--     - Check function names against DB_SCHEMA_CURRENT, never against memory
--       or against another file that might itself be wrong.
--     - A code path with no test is a code path that does not work. This one
--       parsed, deployed, reviewed cleanly, and was broken the whole time.
--
-- ---------------------------------------------------------------------------
-- THE SECOND PROBLEM: A STALE OVERLOAD
--
--   File 10 added a 6-argument fn_party_upsert (p_default_entity). Postgres
--   treats a new signature as a NEW function, so file 08's 5-argument version
--   is still there — also carrying the bug. The screen resolves to the 6-arg
--   version because it passes six named parameters, but the old one remains a
--   live trap for anything calling positionally. Dropped below.
--
--   General rule from this: when a function gains a parameter, drop the old
--   signature in the same file. `create or replace` does not replace across
--   differing signatures.
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. Remove the stale 5-argument version from file 08
-- ---------------------------------------------------------------------------
drop function if exists fn_party_upsert(text, text, text, text, text);


-- ---------------------------------------------------------------------------
-- 2. Replace the 6-argument version with a working permission check
--
--    Behaviour is otherwise identical to file 10: MASTER_APPEND is enough, so
--    the accountant creates a party inline mid-voucher without calling the
--    owner; party_code stays the never-rewritten identity (§13); kind is
--    validated against the PARTY_KIND master; default_entity falls back to the
--    kind's own usual entity.
-- ---------------------------------------------------------------------------
create or replace function fn_party_upsert(
  p_code           text,
  p_name           text,
  p_kind           text default 'DAILY LABOUR',
  p_mobile         text default null,
  p_notes          text default null,
  p_default_entity text default null)
returns text
language plpgsql security definer set search_path = public as $$
declare
  v_code   text := upper(trim(p_code));
  v_kind   text := upper(trim(coalesce(p_kind, 'DAILY LABOUR')));
  v_entity text;
begin
  -- FIXED: was fn_has_permission, which does not exist.
  -- MASTER_APPEND covers the accountant; MASTER_MANAGE covers the owner.
  if not (fn_has_capability('MASTER_APPEND')
          or fn_has_capability('MASTER_MANAGE')) then
    raise exception
      'You do not have permission to add parties (signed in as %)',
      fn_actor_email();
  end if;

  if v_code = '' then
    raise exception 'A party needs a code';
  end if;
  if trim(coalesce(p_name,'')) = '' then
    raise exception 'A party needs a name';
  end if;

  -- The trigger from file 10 judges the kind too; this gives the friendlier
  -- message, naming the fix rather than the failure.
  if not exists (select 1 from master_values
                  where list_name = 'PARTY_KIND' and code = v_kind and active) then
    raise exception
      'Party kind "%" is not an active PARTY_KIND value. Add it in masters admin first.',
      v_kind;
  end if;

  v_entity := coalesce(
    nullif(trim(coalesce(p_default_entity,'')), ''),
    (select default_entity from master_values
      where list_name = 'PARTY_KIND' and code = v_kind));

  insert into parties (party_code, name, kind, mobile, notes, default_entity, created_by)
  values (v_code, trim(p_name), v_kind,
          nullif(trim(coalesce(p_mobile,'')),''),
          nullif(trim(coalesce(p_notes,'')),''),
          v_entity, fn_actor_email())
  on conflict (party_code) do update set
    name           = excluded.name,
    kind           = excluded.kind,
    mobile         = coalesce(excluded.mobile, parties.mobile),
    notes          = coalesce(excluded.notes, parties.notes),
    default_entity = coalesce(excluded.default_entity, parties.default_entity);

  return v_code;
end $$;

comment on function fn_party_upsert(text,text,text,text,text,text) is
  'Create or update a party. MASTER_APPEND is enough — the accountant adds parties inline mid-voucher. party_code is never rewritten. Kind validated against the PARTY_KIND master. File 11 fixed the permission check, which named a function that never existed.';


-- ============================================================================
-- VERIFY — run this, expect one row saying "1 overload"
--
--   select count(*)::text || ' overload(s) of fn_party_upsert' as check
--     from pg_proc p
--     join pg_namespace n on n.oid = p.pronamespace and n.nspname = 'public'
--    where p.proname = 'fn_party_upsert';
--
-- SMOKE TEST — from the SQL editor these run as OWNER:SQL-EDITOR, which holds
-- every capability, so they exercise the logic but NOT the permission path.
-- The permission path is only really tested from the app, signed in as the
-- accountant — which is how this bug survived. Test path 3 in the browser.
--
--   1. select fn_party_upsert('SEMALAI','Semalai','TRACTOR DRIVER');
--      -> 'SEMALAI'; default_entity becomes BUSINESS from the kind.
--   2. select fn_party_upsert('LATHA','Latha','HOUSE COOK');
--      -> 'LATHA'; default_entity becomes PERSONAL.
--   3. select fn_party_upsert('KUPPU','Kuppu','HOUSEHOLD');
--      -> REFUSED: that is a group heading, not a kind.
--   4. select fn_party_upsert('X','X','SHEPHERD');
--      -> REFUSED: not an active PARTY_KIND value.
--   5. select party_code, name, kind, default_entity from parties
--       where party_code in ('SEMALAI','LATHA');
--
-- Then regenerate DB_SCHEMA_CURRENT with 00_schema_snapshot.sql.
-- ============================================================================
