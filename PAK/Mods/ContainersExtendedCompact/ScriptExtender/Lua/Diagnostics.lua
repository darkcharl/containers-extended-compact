-- ContainersExtendedCompact — Debug Diagnostics
--
-- Listener 0 — AddedTo (any inventory, no sorting tags):
--   Fires on every AddedTo for non-story items with no known sorting category tag.
--   These items hit the BoH catch-all regardless of FORCESORT status and are
--   flagged as <<NEEDS PATCH?>> to identify missing tag entries.
--   Also logs all raw tag UUIDs on the item (RawTags line) so you can see what
--   tags are present and determine which one(s) should be added to SORT_TAGS.
--
-- Listener 1 — AddedTo:
--   Fires whenever an item lands in the BoH during a sort pass.
--   Logs template, stack amounts, IsStoryItem, and which sorting category tags
--   are present on the item. "tags=none <<CATCH-ALL>>" means the item has no
--   known category tag and fell through to the BoH catch-all rule. Also flags
--   if the same template is moved multiple times in one session (<<DUPE_TPL>>).
--
-- Listener 2 — UseStarted on BoH:
--   Resets the session tracker, snapshots the inventory, and triggers an
--   IterateInventory dump.
--
-- Listener 3 — EntityEvent "CE_DbgDumpItem" / "CE_DbgDumpDone":
--   Processes each item from the IterateInventory call and logs details,
--   flagging same-template siblings with <<DUPE>> (engine already merged them
--   if you only see one entity with a high actual count instead).
--   Also logs the extracted item-name prefix and flags same-template items
--   with different names (<<NAME_DIFF>>).
--
-- Listener 4 — EntityEvent "CE_StackItem":
--   Fires for every item the stacking pass evaluates.
--   Logs name prefix, template, stack amounts, and flags:
--     <<NAME_CONFLICT>> — two items with same template but different name prefix
--                         are present in the same pass (SE keeps these separate).
--     [gsMax!]          — scripted amount > actual (gsMax guard would block this).
--     [story]           — IsStoryItem=1 (pass skips these).
--
-- Listener 5 — ObjectTimerFinished "CE_Cleanup":
--   Fires ~1 s after the stack pass. Compares pre-pass inventory snapshot against
--   the current inventory to summarise what happened:
--     MERGED   — entity survived but amount changed.
--     DELETED  — entity was deleted (merged into another stack).
--     NEW      — entity appeared (shouldn't happen; flags unexpected creation).
--     UNCHANGED— entity survived with the same amount.

if not CE_DIAGNOSTICS then return end

-- Per-open-session tracker: template → count of AddedTo events
local sessionTpls = {}

-- Per-dump tracker: template → { name → true } for <<NAME_DIFF>> and <<DUPE>> flags
local dumpSeenTpls = {}

-- Pre-pass snapshot: entity → { tpl, name, amount }
-- Populated in UseStarted, compared in ObjectTimerFinished.
local prePassSnapshot = {}

-- Per-pass tracker: template → { name → count }
-- Populated by the CE_StackItem diagnostic listener.
local passNames = {}

-- All category tags used by the sorting rules, in the same order as SortItems.txt.
-- An item that reaches the BoH catch-all will have none of these set.
local SORT_TAGS = {
    { name = "ADVENTURING",    guid = "92921695-ebb1-4bf3-a455-205dea38629f" },
    { name = "ALCH_EXTRACT",   guid = "85b58b89-c881-43c2-bbbe-7c8a0b3bf981" },
    { name = "ALCH_INGREDIENT",guid = "64b824e7-50c5-475a-98c2-52026e372d77" },
    { name = "ARCHERYWEAPON",  guid = "73d71484-d9eb-4b7f-9f8e-ef06f9f75199" },
    { name = "ARMOR",          guid = "d14e607b-d199-421a-837b-9e5223b2d67c" },
    { name = "ARROW",          guid = "fa8afea4-4742-4467-bdef-69851bd15878" },
    { name = "BARREL",         guid = "70044544-72b7-4340-bf32-37bb9c2a8314" },
    { name = "BOOK",           guid = "8a8e253a-c081-45a1-9fa2-91b6901dc568" },
    { name = "CAMPSUPPLIES",   guid = "14e17bf7-a466-404a-b097-29642492a2b2" },
    { name = "CLOAK",          guid = "6de7409e-eef8-402f-955c-5a8198b6480a" },
    { name = "COATING",        guid = "354041e2-72d7-422d-ae75-aa0ac22d5ebd" },
    { name = "DYE",            guid = "d8ef5332-ed2f-42cb-817d-bd2164673223" },
    { name = "FOOTWEAR",       guid = "664dcf78-071c-44de-8208-d38a8989560a" },
    { name = "GLOVE",          guid = "874d2efb-77ad-45ef-9cd3-2a114e9f3610" },
    { name = "GOLD",           guid = "6c6b7cac-113c-42ee-bc46-05567b067a9f" },
    { name = "GRENADE",        guid = "fe0d86c3-a562-430e-a633-d8bf9bb27284" },
    { name = "HEADWEAR",       guid = "d4058e67-954f-46d8-9b0d-4dbc4087a44d" },
    { name = "JEWELRY",        guid = "69d067e4-6c41-4812-92d8-aab0eb8ef2ac" },
    { name = "KEY",            guid = "9851fa99-5538-432a-8e77-c90929a88974" },
    { name = "MELEEWEAPON",    guid = "c73365d5-38c3-49b4-9542-4f0c1e39c1d8" },
    { name = "POTION",         guid = "56c99a77-8f6a-4584-8e41-2a3b9f6b5261" },
    { name = "SCROLL",         guid = "dd86c045-0370-4ec9-b7c5-b0b160706f09" },
    { name = "SHIELD",         guid = "c8a90e5f-86ac-48e3-a4ed-06c2d6f44a65" },
    { name = "TOY",            guid = "454d69b9-11c3-4d79-95f6-607b88bbef75" },
    { name = "THROWNWEAPON",   guid = "a9088b32-1917-46ca-9f08-5b0f46a5936a" },
    { name = "VALUABLES",      guid = "058af61c-25e7-4f7c-95dd-4a3890d25f48" },
    { name = "WARDROBE",       guid = "74c4425e-edf0-417b-95af-cf3fe2cb7446" },
}

-- Returns a comma-separated list of the sorting tags present on item,
-- or "none" if the item has none — indicating it hit the catch-all.
local function sortTagsPresent(item)
    local found = {}
    for _, tag in ipairs(SORT_TAGS) do
        if Osi.IsTagged(item, tag.guid) == 1 then
            found[#found + 1] = tag.name
        end
    end
    return #found > 0 and table.concat(found, ",") or "none <<CATCH-ALL>>"
end

-- All proficiency groups across MeleeWeaponsChest, ThrownWeaponsChest, ArcheryWeaponsChest filters.
local PROF_GROUPS = {
    "Battleaxes", "Clubs", "Flails", "Glaives", "Greataxes", "Greatclubs",
    "Greatswords", "Halberds", "Longswords", "Maces", "Mauls", "Morningstars",
    "Pikes", "Quarterstaffs", "Rapiers", "Scimitars", "Shortswords", "Sickles",
    "Warhammers", "Warpicks",
    "Daggers", "Handaxes", "Javelins", "LightHammers", "Spears", "Tridents",
    "HandCrossbows", "HeavyCrossbows", "LightCrossbows", "Longbows", "Shortbows",
}

-- LISTENER 0: Item picked up with no known sorting tags — candidate for patching.
-- Fires regardless of FORCESORT status, catching items the sorting rule never evaluates.
Ext.Osiris.RegisterListener("AddedTo", 3, "after", function(item, inventory, _)
    if Osi.IsStoryItem(item) == 1 then return end
    if sortTagsPresent(item) ~= "none <<CATCH-ALL>>" then return end

    local tpl = Osi.GetTemplate(item) or "?"
    log(string.format("Pickup_NoTag | entity=%-60s | tpl=%s | tags=none <<CATCH-ALL>> <<NEEDS PATCH?>>",
        item, tpl))

    local matched = {}
    for _, pg in ipairs(PROF_GROUPS) do
        if Osi.IsEquipmentWithProficiency(item, pg) == 1 then
            matched[#matched + 1] = pg
        end
    end
    log(string.format("  ProfCheck  | entity=%-60s | tpl=%s | IsEquipmentWithProficiency=%s",
        item, tpl, #matched > 0 and table.concat(matched, ",") or "none"))

    -- Dump every raw tag UUID on the item so missing entries can be identified.
    local entity = Ext.Entity.Get(item)
    if entity and entity.Tag and entity.Tag.Tags then
        local rawTags = {}
        for _, tag in pairs(entity.Tag.Tags) do
            rawTags[#rawTags + 1] = tostring(tag)
        end
        table.sort(rawTags)
        log(string.format("  RawTags    | entity=%-60s | tpl=%s | %s",
            item, tpl, #rawTags > 0 and table.concat(rawTags, ", ") or "none"))
    end
end)

-- Templates for the three proficiency-matched weapon chests.
local WEAPON_CHEST_TPLS = {
    ["OBJ_ContainersExtended_MeleeWeaponsChest_2e850e24-0c13-49ff-bf51-29948baaf7f4"]   = "MeleeChest",
    ["OBJ_ContainersExtended_ArcheryWeaponsChest_c92f1609-45d1-4b97-8135-20b4473ddfb3"] = "ArcheryChest",
    ["OBJ_ContainersExtended_ThrownWeaponsChest_3552b5eb-b261-4f9e-bd46-8830d3f898d1"]  = "ThrownChest",
}

-- LISTENER 1b: Item lands in a weapon chest — tells us if the proficiency PROC fired.
Ext.Osiris.RegisterListener("AddedTo", 3, "after", function(item, inventory, _)
    local chestName = WEAPON_CHEST_TPLS[Osi.GetTemplate(inventory)]
    if not chestName then return end
    local tpl = Osi.GetTemplate(item) or "?"
    log(string.format("AddedTo_WeaponChest | entity=%-60s | tpl=%s | chest=%s",
        item, tpl, chestName))
end)

-- LISTENER 1: Item lands in the BoH (fired by PROC_CE_MoveItem → ToInventory)
Ext.Osiris.RegisterListener("AddedTo", 3, "after", function(item, inventory, _)
    if Osi.GetTemplate(inventory) ~= BOH_TPL then return end

    local tpl   = Osi.GetTemplate(item)   or "?"
    local s, a  = Osi.GetStackAmount(item)
    local max   = Osi.GetMaxStackAmount(item)
    local story = Osi.IsStoryItem(item)
    local tags  = sortTagsPresent(item)

    sessionTpls[tpl] = (sessionTpls[tpl] or 0) + 1
    local dupeFlag = sessionTpls[tpl] > 1 and " <<DUPE_TPL>>" or ""

    log(string.format("AddedTo_BoH | entity=%-60s | tpl=%s | s=%-3s a=%-3s max=%-3s story=%s | tags=%s%s",
        item, tpl, tostring(s), tostring(a), tostring(max), tostring(story), tags, dupeFlag))
end)

-- LISTENER 2: Player opens the BoH → reset trackers, snapshot inventory, dump contents.
Ext.Osiris.RegisterListener("UseStarted", 2, "after", function(_, used)
    if Osi.GetTemplate(used) ~= BOH_TPL then return end

    sessionTpls     = {}
    dumpSeenTpls    = {}
    passNames       = {}
    prePassSnapshot = {}

    log("=== BoH opened — snapshotting inventory ===")

    -- Build pre-pass snapshot via a separate IterateInventory pass using dump events.
    -- The dump listener below populates prePassSnapshot from CE_DbgDumpItem events.
    Osi.IterateInventory(used, "CE_DbgDumpItem", "CE_DbgDumpDone")
end)

-- LISTENER 3: IterateInventory events for the dump + pre-pass snapshot.
Ext.Osiris.RegisterListener("EntityEvent", 2, "after", function(entity, event)
    if event == "CE_DbgDumpItem" then
        local tpl   = Osi.GetTemplate(entity) or "?"
        local name  = guidName(entity)
        local s, a  = Osi.GetStackAmount(entity)
        local max   = Osi.GetMaxStackAmount(entity)
        local story = Osi.IsStoryItem(entity)

        -- Populate pre-pass snapshot.
        prePassSnapshot[entity] = { tpl = tpl, name = name, amount = a }

        -- Detect same-template siblings with different name prefixes.
        dumpSeenTpls[tpl] = dumpSeenTpls[tpl] or {}
        local seenNames = dumpSeenTpls[tpl]
        local dupeFlag  = seenNames[name] and " <<DUPE>>" or ""
        seenNames[name] = true

        -- Count distinct names for this template across the whole dump so far.
        local nameCount = 0
        for _ in pairs(seenNames) do nameCount = nameCount + 1 end
        local nameDiffFlag = nameCount > 1 and " <<NAME_DIFF>>" or ""

        log(string.format("  BoH_item | entity=%-60s | name=%-40s | tpl=%s | s=%-3s a=%-3s max=%-3s story=%s%s%s",
            entity, name, tpl, tostring(s), tostring(a), tostring(max), tostring(story),
            dupeFlag, nameDiffFlag))

    elseif event == "CE_DbgDumpDone" then
        -- Print a summary of any template+name conflicts found in the dump.
        local conflicts = {}
        for tpl, names in pairs(dumpSeenTpls) do
            local list = {}
            for n in pairs(names) do list[#list + 1] = n end
            if #list > 1 then
                conflicts[#conflicts + 1] = string.format("    tpl=%s  names=[%s]", tpl, table.concat(list, ", "))
            end
        end
        if #conflicts > 0 then
            log("!!! NAME_DIFF templates (same template, different item-name — will NOT be merged):")
            for _, line in ipairs(conflicts) do log(line) end
        else
            log("    No NAME_DIFF templates found — all same-template items share the same name prefix.")
        end
        log("=== dump done ===")
    end
end)

-- LISTENER 4: Each item evaluated by the stacking pass.
-- Fires for every CE_StackItem EntityEvent — same items the SE stacking handler sees.
-- Use this to validate that guidName() extracts the correct prefix and to catch
-- template+name conflicts (<<NAME_CONFLICT>>) that SE correctly keeps separate.
Ext.Osiris.RegisterListener("EntityEvent", 2, "after", function(entity, event)
    if event ~= "CE_StackItem" then return end

    local tpl   = Osi.GetTemplate(entity) or "?"
    local name  = guidName(entity)
    local s, a  = Osi.GetStackAmount(entity)
    local max   = Osi.GetMaxStackAmount(entity)
    local story = Osi.IsStoryItem(entity)

    -- Strip 3-digit instance counter to get the same base name Stacking.lua uses as its key.
    local baseName = name:gsub("_%d%d%d$", "")
    local stripped = baseName ~= name and " [>" .. baseName .. "]" or ""

    -- Track distinct base names per template across this pass.
    passNames[tpl] = passNames[tpl] or {}
    passNames[tpl][baseName] = (passNames[tpl][baseName] or 0) + 1

    local nameCount = 0
    for _ in pairs(passNames[tpl]) do nameCount = nameCount + 1 end

    local conflictFlag = nameCount > 1 and " <<NAME_CONFLICT>>" or ""
    local storyFlag    = story == 1 and " [story]" or ""
    local gsMaxFlag    = (s ~= nil and a ~= nil and tonumber(s) ~= nil and tonumber(a) ~= nil
                          and tonumber(s) > tonumber(a)) and " [gsMax!]" or ""

    log(string.format("  CE_Stack   | name=%-40s | tpl=%s | s=%-3s a=%-3s max=%-3s%s%s%s%s",
        name, tpl, tostring(s), tostring(a), tostring(max),
        storyFlag, gsMaxFlag, conflictFlag, stripped))
end)

-- LISTENER 5: Cleanup timer fired — stack pass is complete.
-- Compares the pre-pass snapshot against the current inventory state and logs
-- what actually happened: merges, deletes, unchanged items.
Ext.Osiris.RegisterListener("ObjectTimerFinished", 2, "after", function(object, timer)
    if timer ~= "CE_Cleanup" then return end
    if Osi.GetTemplate(object) ~= BOH_TPL then return end

    log("=== CE_Cleanup fired — post-pass diff ===")

    local merged    = {}
    local deleted   = {}
    local unchanged = {}

    for entity, snap in pairs(prePassSnapshot) do
        local _, aCurrent = Osi.GetStackAmount(entity)

        if aCurrent == nil then
            -- Entity no longer queryable → deleted (merged into another stack).
            deleted[#deleted + 1] = string.format(
                "  DELETED   | name=%-40s | tpl=%s | was=%s",
                snap.name, snap.tpl, tostring(snap.amount))
        elseif tostring(aCurrent) ~= tostring(snap.amount) then
            merged[#merged + 1] = string.format(
                "  MERGED    | name=%-40s | tpl=%s | was=%-3s now=%s",
                snap.name, snap.tpl, tostring(snap.amount), tostring(aCurrent))
        else
            unchanged[#unchanged + 1] = string.format(
                "  UNCHANGED | name=%-40s | tpl=%s | amt=%s",
                snap.name, snap.tpl, tostring(snap.amount))
        end
    end

    if #merged == 0 and #deleted == 0 then
        log("  (no changes detected — no items were merged or deleted)")
    else
        for _, line in ipairs(merged)    do log(line) end
        for _, line in ipairs(deleted)   do log(line) end
    end
    for _, line in ipairs(unchanged) do log(line) end

    -- Print pass-level name-conflict summary.
    local conflicts = {}
    for tpl, names in pairs(passNames) do
        local list = {}
        for n in pairs(names) do list[#list + 1] = n end
        if #list > 1 then
            conflicts[#conflicts + 1] = string.format("    tpl=%s  names=[%s]", tpl, table.concat(list, ", "))
        end
    end
    if #conflicts > 0 then
        log("!!! NAME_CONFLICT templates seen during pass (SE kept these separate):")
        for _, line in ipairs(conflicts) do log(line) end
    end

    log("=== post-pass diff done ===")
    prePassSnapshot = {}
    passNames       = {}
end)
