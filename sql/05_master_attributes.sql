-- ============================================================================
-- FARM & HOME ACCOUNTS — LEDGER CORE
-- File 5 : MASTER ATTRIBUTES (aliases column + attribute setter)
--
-- Run AFTER files 01–04, in the Supabase SQL editor.
-- Do NOT re-run files 01–04: they drop and recreate tables.
-- This file is re-runnable on its own (add column if not exists,
-- create or replace function). It touches no ledger row and no data.
--
-- WHY THIS FILE EXISTS
--   Masters admin (Stage A screen 2) must be able to change attributes on an
--   existing master value — above all `required_unit`, which drives the
--   missing-quantity warning (§3F). Only about a dozen of the 76 activities
--   carry one today; the rest are blank, so the warning fires on a fraction of
--   the work it should, and the §7 quantity-capture metric cannot ratchet.
--
--   Until now there was no way to do it. `fn_master_relabel` changes only the
--   label; `fn_master_append` writes attributes only at insert time; and no
--   role holds UPDATE on any table (§14.1). So the screen could add a value
--   and rename it, and nothing else.
--
--   This file adds the one missing write path, plus the empty `aliases`
--   column — added now, while the database holds sample data only, because
--   adding a column to a live ledger later is a different kind of afternoon.
--
-- WHAT IT DOES NOT DO
--   No alias search, no substring matcher, no use-ranked ordering (§3F2).
--   Deferred by owner decision, 19-07-2026. The column ships empty and unused;
--   nothing reads it. Activity search stays label-only, exactly as today.
--   No seed values of any kind.
--
-- Spec references: §3F, §3F2, §3H, §13 (rename ban), §14.1 (security)
-- ============================================================================


-- ---------------------------------------------------------------------------
-- 1. THE ALIASES COLUMN
--    Comma-separated search terms for ACTIVITY rows; NULL on every other list,
--    the same way required_unit is NULL outside ACTIVITY and mode_kind is NULL
--    outside MODE. Plain text, not text[]: masters admin edits it as one
--    field, and an array buys nothing for a substring test over 76 rows.
--
--    Nothing reads this column yet. It exists so that when the review queue
--    ships and starts feeding real terms into it, no schema change is needed
--    against a live ledger.
-- ---------------------------------------------------------------------------
alter table master_values
  add column if not exists aliases text;

comment on column master_values.aliases is
  'Comma-separated search terms, ACTIVITY rows (§3F2). Owner-editable via masters admin. Not yet read by any search — column provisioned ahead of the review queue.';


-- ---------------------------------------------------------------------------
-- 2. fn_master_set_attrs — THE MISSING WRITE PATH
--
--    Patch semantics: only the keys PRESENT in p_attrs are written. Absent
--    keys are left exactly as they are. This matters — a screen that sends
--    the whole row back would silently blank every attribute it did not
--    happen to render.
--
--    To CLEAR an attribute, send the key with a JSON null:
--        fn_master_set_attrs('ACTIVITY','PRUNING','{"required_unit": null}')
--    To leave it alone, omit the key entirely.
--
--    Cannot change list_name, code (rename ban, §13 — the
--    master_code_immutable trigger refuses it anyway) or created_at.
--    Label is deliberately NOT here: it has its own function with its own
--    permission check, because relabelling is the operation §13 cares about.
--
--    Permission: MASTER_MANAGE (owner/admin). The accountant's MASTER_APPEND
--    grant does NOT reach this — she may add a value, never reshape one.
--
--    Referential checks: required_unit, output_unit and parent_farm must be
--    live master codes. Free text here would put a unit nobody can enter into
--    the warning logic. cost_object_type / mode_kind / attributed_to are
--    guarded by the table's own CHECK constraints and need nothing extra.
-- ---------------------------------------------------------------------------
create or replace function fn_master_set_attrs(
  p_list  text,
  p_code  text,
  p_attrs jsonb)
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_exists boolean;
begin
  perform fn_require('MASTER_MANAGE');

  select exists (select 1 from master_values
                  where list_name = p_list and code = p_code)
    into v_exists;
  if not v_exists then
    raise exception 'No such master value %/%', p_list, p_code;
  end if;

  -- Validate the three attributes that point at other lists, but only when
  -- the caller actually sent them. fn_assert_master returns quietly on NULL,
  -- so clearing an attribute is always allowed.
  if p_attrs ? 'required_unit' then
    perform fn_assert_master('UNIT', p_attrs->>'required_unit');
  end if;
  if p_attrs ? 'output_unit' then
    perform fn_assert_master('UNIT', p_attrs->>'output_unit');
  end if;
  if p_attrs ? 'parent_farm' then
    perform fn_assert_master('FARM', p_attrs->>'parent_farm');
  end if;

  update master_values set
    aliases          = case when p_attrs ? 'aliases'
                            then p_attrs->>'aliases'          else aliases          end,
    required_unit    = case when p_attrs ? 'required_unit'
                            then p_attrs->>'required_unit'    else required_unit    end,
    notes            = case when p_attrs ? 'notes'
                            then p_attrs->>'notes'            else notes            end,
    sort_order       = case when p_attrs ? 'sort_order'
                            then coalesce((p_attrs->>'sort_order')::int, sort_order)
                            else sort_order end,
    cost_object_type = case when p_attrs ? 'cost_object_type'
                            then p_attrs->>'cost_object_type' else cost_object_type end,
    output_unit      = case when p_attrs ? 'output_unit'
                            then p_attrs->>'output_unit'      else output_unit      end,
    sellable         = case when p_attrs ? 'sellable'
                            then (p_attrs->>'sellable')::boolean else sellable      end,
    mode_kind        = case when p_attrs ? 'mode_kind'
                            then p_attrs->>'mode_kind'        else mode_kind        end,
    parent_farm      = case when p_attrs ? 'parent_farm'
                            then p_attrs->>'parent_farm'      else parent_farm      end,
    attributed_to    = case when p_attrs ? 'attributed_to'
                            then p_attrs->>'attributed_to'    else attributed_to    end
  where list_name = p_list and code = p_code;
end $$;

comment on function fn_master_set_attrs(text, text, jsonb) is
  'Patch attributes on an existing master value. Only keys present in p_attrs are written; JSON null clears. MASTER_MANAGE only. Label has its own function (§13); code is immutable.';


-- ---------------------------------------------------------------------------
-- 3. fn_master_append — REPLACED, ONE LINE LONGER
--
--    Identical to the version in file 4 except that p_attrs may now carry
--    'aliases'. Without this, a value created through masters admin could
--    never be given aliases at birth — only afterwards, through the setter
--    above. Behaviour is otherwise unchanged; existing callers are unaffected.
-- ---------------------------------------------------------------------------
create or replace function fn_master_append(
  p_list text, p_code text, p_label text, p_attrs jsonb default '{}')
returns void
language plpgsql security definer set search_path = public as $$
begin
  if not (fn_has_capability('MASTER_MANAGE') or fn_has_capability('MASTER_APPEND')) then
    raise exception 'Not permitted: master append';
  end if;

  insert into master_values (list_name, code, label,
    cost_object_type, output_unit, sellable, mode_kind, parent_farm,
    required_unit, attributed_to, aliases, sort_order, notes)
  values (p_list, p_code, p_label,
    p_attrs->>'cost_object_type', p_attrs->>'output_unit',
    (p_attrs->>'sellable')::boolean, p_attrs->>'mode_kind', p_attrs->>'parent_farm',
    p_attrs->>'required_unit', p_attrs->>'attributed_to', p_attrs->>'aliases',
    coalesce((p_attrs->>'sort_order')::int, 999), p_attrs->>'notes');
end $$;


-- ============================================================================
-- SMOKE TEST — paste below the file, or run separately in the SQL editor.
-- Safe: it sets a required unit on one activity and puts it back.
--
--   -- before
--   select code, required_unit, aliases from master_values
--    where list_name='ACTIVITY' and code='PRUNING';
--
--   -- set it
--   select fn_master_set_attrs('ACTIVITY','PRUNING','{"required_unit":"TREE"}');
--   select code, required_unit from master_values
--    where list_name='ACTIVITY' and code='PRUNING';        -- expect TREE
--
--   -- patch semantics: notes changes, required_unit survives untouched
--   select fn_master_set_attrs('ACTIVITY','PRUNING','{"notes":"test note"}');
--   select code, required_unit, notes from master_values
--    where list_name='ACTIVITY' and code='PRUNING';        -- expect TREE + note
--
--   -- clearing with an explicit null
--   select fn_master_set_attrs('ACTIVITY','PRUNING',
--            '{"required_unit":null,"notes":null}');       -- back to blank
--
--   -- a bad unit must be refused
--   select fn_master_set_attrs('ACTIVITY','PRUNING','{"required_unit":"BUNDLE"}');
--   -- expect: UNIT "BUNDLE" is not an active value in masters
--
--   -- an unknown value must be refused
--   select fn_master_set_attrs('ACTIVITY','NO SUCH THING','{"notes":"x"}');
--   -- expect: No such master value ACTIVITY/NO SUCH THING
--
-- After this runs clean, fold it into the schema.sql snapshot (§14 keeps one
-- current-state file, not a chain of migrations).
-- ============================================================================
