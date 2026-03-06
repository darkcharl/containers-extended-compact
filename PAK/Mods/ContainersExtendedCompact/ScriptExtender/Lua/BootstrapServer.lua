-- ContainersExtendedCompact — Server bootstrap
--
-- Shared utilities used by all modules.
-- Modules are loaded in order: Stacking first (registers listeners before Diagnostics),
-- so the SE merge logic always processes each CE_StackItem event before the
-- diagnostic logger does.

local _BOH_TPL = "OBJ_ContainersExtended_BagOfHolding_6c08cd7c-bc9e-4c2a-aff5-889c8eb9cc27"

-- Expose as globals so Stacking.lua and Diagnostics.lua can reference them.
BOH_TPL = _BOH_TPL

function log(msg)
    Ext.Utils.Print("[CE] " .. tostring(msg))
end

-- Extract the item-name prefix from a GUIDSTRING by stripping the trailing
-- _UUID suffix.  A standard UUID is 36 chars; including the separator '_'
-- that is 37 chars to drop.
function guidName(guidstr)
    if type(guidstr) ~= "string" or #guidstr <= 37 then return guidstr end
    return guidstr:sub(1, #guidstr - 37)
end

-- Extract the bare UUID (last 36 chars) from a full prefixed GUIDSTRING.
-- GetDirectInventoryOwner already returns a bare UUID (no stripping needed);
-- ObjectTimerFinished delivers the full prefixed form, so stripping is required.
function bareUUID(guidstr)
    if type(guidstr) ~= "string" or #guidstr < 36 then return guidstr end
    return guidstr:sub(-36)
end

-- Set to false to suppress all diagnostic logging without removing the code.
CE_DIAGNOSTICS = true

Ext.Require("Stacking.lua")
Ext.Require("Diagnostics.lua")


log("ContainersExtendedCompact loaded.")
