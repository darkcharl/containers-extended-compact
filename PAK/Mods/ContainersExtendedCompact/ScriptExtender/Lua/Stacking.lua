-- ContainersExtendedCompact — SE Stacking Pass
--
-- Registers DB_CE_HasScriptEngine(1) to disable the Osiris stacking rules
-- (Rules 1, 2a, 2b) and replaces them with a name-aware merge pass.
-- The pass piggy-backs on the CE_StackItem EntityEvents that Osiris's
-- own IterateInventory call fires from the unguarded UseStarted rule.
-- Items with identical templates but different name prefixes are keyed
-- separately and therefore never merged into each other.
--
-- Container key: GetDirectInventoryOwner returns a bare UUID while
-- ObjectTimerFinished delivers the full prefixed GUIDSTRING.  bareUUID()
-- normalises both to the bare UUID for consistent Lua table lookups.

-- Inform Osiris that SE is handling the stacking pass.
-- Must be deferred into an Osiris event listener — Osi.* calls are only permitted
-- inside Osiris listener contexts (not at script-load time or in Lua events like SessionLoaded).
-- LevelGameplayStarted fires after story compilation, before any player interaction.
-- This causes NOT DB_CE_HasScriptEngine((INTEGER)_) to fail in Rules 1, 2a, 2b,
-- so those rules are skipped for every CE_StackItem event.
Ext.Osiris.RegisterListener("LevelGameplayStarted", 2, "after", function(_, _)
    Osi.DB_CE_HasScriptEngine(1)
end)

-- Per-pass canonicals: bare-UUID container → (template.."\0"..name) → { item, amt, max }
-- Mirrors the role of DB_CE_CanonicalItem / DB_CE_CanonicalAmt / DB_CE_CanonicalMax
-- in the Osiris rules, but held in Lua so no Osiris DB writes are needed.
local seCanonicals = {}

-- STACKING: name-aware merge for each item in the IterateInventory pass.
-- Mirrors Osiris Rules 1, 2a, and 2b with (template, guidName) as the key.
Ext.Osiris.RegisterListener("EntityEvent", 2, "after", function(entity, event)
    if event ~= "CE_StackItem" then return end

    local tpl   = Osi.GetTemplate(entity)
    local max   = Osi.GetMaxStackAmount(entity)
    local story = Osi.IsStoryItem(entity)
    local name  = guidName(entity)

    -- Guards: mirror Osiris header (IsStoryItem, max > 1, S_ prefix).
    if not max or max <= 1 then return end
    if story == 1 then return end
    if name:sub(1, 2) == "S_" then return end

    local gsMax, actual = Osi.GetStackAmount(entity)
    gsMax  = tonumber(gsMax)
    actual = tonumber(actual)
    max    = tonumber(max)

    -- Skip items already at or above cap (nothing to merge).
    if not actual or actual >= max then return end

    local container = Osi.GetDirectInventoryOwner(entity)
    if not container then return end

    -- Strip trailing 3-digit world-placement instance counter (e.g. _010, _012) before
    -- keying, so that world-placed copies of the same item are merged together.
    -- The template UUID still distinguishes item types; only same-template items share a key.
    local baseName = name:gsub("_%d%d%d$", "")
    local key = tpl .. "\0" .. baseName
    seCanonicals[container] = seCanonicals[container] or {}
    local cans = seCanonicals[container]

    if not cans[key] then
        -- Rule 1: designate first qualifying partial stack as canonical.
        -- gsMax guard: scripted amount must be <= actual (see Osiris header comment).
        if gsMax and gsMax <= actual then
            cans[key] = { item = entity, amt = actual, max = max }
        end
    else
        local g = cans[key]
        local combined = g.amt + actual

        if combined <= g.max then
            -- Rule 2a: combined fits within cap — full merge into canonical.
            Osi.SetStackAmount(g.item, combined)
            Osi.RequestDelete(entity)
            g.amt = combined

        elseif g.amt < g.max then
            -- Rule 2b: overflow — fill canonical to cap, item becomes remainder.
            -- gsMax guard on the item before promoting it to canonical.
            local remainder = combined - g.max
            Osi.SetStackAmount(g.item, g.max)
            Osi.SetStackAmount(entity, remainder)
            if gsMax and gsMax <= actual then
                g.item = entity
                g.amt  = remainder
            end
        end
        -- If canonical is already full (g.amt >= g.max), neither branch fires;
        -- no further merging is possible for this key in this pass.
    end
end)

-- CLEANUP: release SE state when the Osiris cleanup timer fires.
-- ObjectTimerFinished delivers the container as a full prefixed GUIDSTRING;
-- bareUUID() normalises it to the bare UUID used as the seCanonicals key.
Ext.Osiris.RegisterListener("ObjectTimerFinished", 2, "after", function(object, timer)
    if timer ~= "CE_Cleanup" then return end
    seCanonicals[bareUUID(object)] = nil
end)

-- CAMPSUPPLIES sort fallback ---------------------------------------------------
-- The CampSupplySack has a built-in engine-level supply filter that silently
-- rejects items like rotten eggs even though they carry the CAMPSUPPLIES tag.
-- IsSupply() is not an exposed Osiris query, so the sort rule calls ToInventory
-- blindly and the rejection is invisible.  The catch-all Osiris rule explicitly
-- excludes CAMPSUPPLIES items, leaving them stuck in the player's main inventory.
--
-- This listener fires AFTER all Osiris rules triggered by AddedTo have run.
-- GetDirectInventoryOwner (returns a bare UUID) tells us where the item actually
-- ended up.  If it still matches the player inventory the sort rule failed;
-- we route the item to the BoH instead.
-- ------------------------------------------------------------------------------
local CAMPSUPPLIES_GUID = "14e17bf7-a466-404a-b097-29642492a2b2"

Ext.Osiris.RegisterListener("AddedTo", 3, "after", function(item, inventory, _)
    if Osi.IsStoryItem(item) == 1 then return end
    if Osi.IsContainer(item) == 1 then return end
    if Osi.IsTagged(item, CAMPSUPPLIES_GUID) ~= 1 then return end

    -- Item must still be owned by the player character — if GetDirectInventoryOwner
    -- returns anything other than bareUUID(inventory) the Osiris rule succeeded and
    -- there is nothing to do.  bareUUID() normalises inventory from its full
    -- prefixed GUIDSTRING to the bare UUID that GetDirectInventoryOwner returns.
    if Osi.GetDirectInventoryOwner(item) ~= bareUUID(inventory) then return end

    -- Find the BoH in the player's inventory and route the item there.
    local boh = Osi.GetItemByTemplateInInventory(BOH_TPL, inventory)
    if not boh then return end

    local s, _ = Osi.GetStackAmount(item)
    if CE_DIAGNOSTICS then
        log(string.format("CAMPSUPPLIES_Fallback | entity=%-60s | CampSupplySack rejected — routing to BoH", item))
    end
    Osi.ToInventory(item, boh, s, 0, 0)
end)
