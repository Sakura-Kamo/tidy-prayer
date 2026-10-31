-- prayer_catalog.lua
-- What this file does: Finds and validates the actual prayer button and glow
-- components in the open game interface.
-- How it connects: Filter requests a capture before writing. Books also uses a smaller
-- artwork-only read to recognise the open book.
-- Reading guide: START-HERE.txt lists the numbered sections below.

-- SECTION 1: Native component IDs and validation helpers
-- Interface 1458 contains button collection 40 and glow collection 39 under shared layer
-- 8. These IDs are checked alongside type, ancestry and size.
local Catalog = {}
Catalog.INTERFACE = 1458
Catalog.BUTTONS = 40
Catalog.GLOWS = 39
local SHARED_LAYER = 8
local MAX_ENTRIES = 128

local function check(condition, message)
    if not condition then error(message, 0) end
end

local function nameOf(button)
    local ok, text = pcall(function() return button.opConfig.opBaseName end)
    if not ok or type(text) ~= "string" then return nil end
    -- Native labels can contain colour tags. Render plain text in the settings list.
    text = text:gsub("<[^>]*>", ""):gsub("[%c]", " "):match("^%s*(.-)%s*$")
    if text == "" or #text > 120 or text:find("[<>]") then return nil end
    return text
end

local function matches(component, staticID, index, spriteType)
    return component and not component.isRestricted and component.type == spriteType
        and component.interfaceID == Catalog.INTERFACE and component.staticID == staticID
        and component.categoryID == 0 and component.dynamicID == index
end

-- SECTION 2: Validate one button and glow pair
-- Check that the same handles still represent the same prayer. A slot number alone is
-- not a stable prayer identity.
-- Validate before native writes and while maintaining owned changes. A dynamic
-- slot is not a prayer identity: retained handle and icon must still match.
-- A readable name is an extra check, not a requirement for this live session.
function Catalog.validate(api, entry, hiddenByUs, maintaining)
    local ok, reason = pcall(function()
        local button = api.get(Catalog.BUTTONS, entry.index)
        local glow = api.get(Catalog.GLOWS, entry.index)
        check(button == entry.button and glow == entry.glow, "The prayer panel was rebuilt")
        check(matches(button, Catalog.BUTTONS, entry.index, api.spriteType), "Prayer button changed")
        check(matches(glow, Catalog.GLOWS, entry.index, api.spriteType), "Prayer glow changed")
        check(button.spriteID == entry.spriteID and nameOf(button) == entry.name, "Prayer identity changed")
        local buttonParent, glowParent = button.parent, glow.parent
        check(buttonParent == entry.buttonParent and glowParent == entry.glowParent, "Prayer parents changed")
        check(not buttonParent.isRestricted and not glowParent.isRestricted, "Prayer parent is restricted")
        local common = buttonParent.parent
        check(common and common == glowParent.parent and not common.isRestricted
            and common.interfaceID == Catalog.INTERFACE and common.staticID == SHARED_LAYER, "Prayer layers changed")
        -- A temporarily closed/occluded parent does not change prayer identity.
        if not maintaining then
            check(buttonParent.visibleGlobal and glowParent.visibleGlobal, "Open the prayer panel")
        end
        check(button.width == 30 and button.height == 30 and glow.width == 34 and glow.height == 34
            and button.x == glow.x + 2 and button.y == glow.y + 2, "Prayer layout changed")
        if maintaining then
            check(type(button.hidden) == "boolean" and type(glow.hidden) == "boolean", "Visibility unavailable")
        elseif hiddenByUs then
            check(button.hidden == true and glow.hidden == true, "Visibility changed outside this selection")
        else
            check(button.visibleGlobal and button.hidden == false and glow.hidden == false, "Prayer is already hidden")
        end
    end)
    return ok, ok and nil or tostring(reason)
end

-- SECTION 3: Read the visible prayer collection
-- Collect compatible pairs, resolve their saved keys and reject duplicate identities for
-- editing. Return entries in the panel's current row order.
function Catalog.read(api)
    local ok, result = pcall(function()
        local parent, glowParent = api.get(Catalog.BUTTONS), api.get(Catalog.GLOWS)
        check(parent and glowParent, "Open the prayer book before loading its icons")
        for _, pair in ipairs({{parent, Catalog.BUTTONS}, {glowParent, Catalog.GLOWS}}) do
            local component, staticID = pair[1], pair[2]
            check(not component.isRestricted and component.interfaceID == Catalog.INTERFACE
                and component.staticID == staticID and component.categoryID == -1
                and component.dynamicID == -1 and component.visibleGlobal, "Prayer collection unavailable")
        end
        local entries, seen, callbacks = {}, {}, 0
        parent:IterateDynamicComponents(function(button)
            callbacks = callbacks + 1
            check(callbacks <= MAX_ENTRIES, "Too many prayer entries; no icons loaded")
            local index = button.dynamicID
            if type(index) ~= "number" or index < 0 or index % 1 ~= 0
                or not matches(button, Catalog.BUTTONS, index, api.spriteType) or seen[index] then return false end
            seen[index] = true
            local spriteID = button.spriteID
            if type(spriteID) ~= "number" or spriteID < 0 or spriteID % 1 ~= 0 then return false end
            local entry = {index = index, spriteID = spriteID, name = nameOf(button),
                button = button, glow = api.get(Catalog.GLOWS, index),
                buttonParent = parent, glowParent = glowParent}
            local valid = Catalog.validate(api, entry, false)
            if valid then
                entries[#entries + 1] = entry
            end
            return false
        end)
        check(#entries > 0, "No compatible prayer icons found in the open panel")
        -- Native filtering can remove/reindex entries. Resolve artwork to its
        -- game definition, never its old slot.
        -- Unknown artwork stays shown; only config-defined variants are matched.
        local counts = {}
        for _, entry in ipairs(entries) do
            entry.key = api.resolveKey(entry)
            if entry.key then counts[entry.key] = (counts[entry.key] or 0) + 1 end
        end
        for _, entry in ipairs(entries) do
            entry.selectable = entry.key ~= nil and counts[entry.key] == 1
        end
        table.sort(entries, function(a, b)
            if a.button.y ~= b.button.y then return a.button.y < b.button.y end
            if a.button.x ~= b.button.x then return a.button.x < b.button.x end
            return a.index < b.index
        end)
        return entries
    end)
    if not ok then return nil, tostring(result) end
    return result
end

-- SECTION 4: Recognise a book and approve a capture
-- Read a bounded set of artwork IDs for recognition, then require the coordinator's book
-- check before accepting a full capture.
-- Recognition needs only artwork IDs, including Lua-hidden icons. Keep this
-- frequent read bounded to the known collection; full geometry validation and
-- visible-entry selection still happen separately before any native writes.
function Catalog.observedSprites(api)
    local ok, result = pcall(function()
        local parent = api.get(Catalog.BUTTONS)
        check(parent and not parent.isRestricted and parent.interfaceID == Catalog.INTERFACE
            and parent.staticID == Catalog.BUTTONS and parent.categoryID == -1
            and parent.dynamicID == -1, "Prayer collection unavailable")
        local sprites, count = {}, 0
        parent:IterateDynamicComponents(function(button)
            count = count + 1
            check(count <= MAX_ENTRIES, "Too many prayer entries")
            local index, sprite = button.dynamicID, button.spriteID
            if matches(button, Catalog.BUTTONS, index, api.spriteType) and type(sprite) == "number"
                and sprite >= 0 and sprite % 1 == 0 then sprites[tostring(sprite)] = true end
            return false
        end)
        return sprites
    end)
    return ok and result or nil
end

-- The coordinator recognises both books from their complete config catalogues.
-- A missing or unrecognised book cannot receive native writes.
function Catalog.capture(api)
    local entries, reason = Catalog.read(api)
    if not entries then return nil, reason end
    if not api.acceptBook() then return nil, "Switch your character to " .. api.label end
    return entries
end

-- SECTION 5: Detect native collection changes
-- Compare live slots with the previous capture. New, removed or replaced icons trigger
-- recovery instead of reusing stale handles.
-- Inspect only the known button collection on Logic ticks. This catches newly
-- visible/removed icons even when none is hidden by this plugin and existing handles
-- survive. Lua-hidden entries are expected to be invisible; native-only hiding
-- is excluded at the next capture after releasing this plugin's flags.
function Catalog.unchanged(api, entries, applied)
    local ok, result = pcall(function()
        local parent = api.get(Catalog.BUTTONS)
        if not parent or parent.isRestricted then return false end
        local byIndex, seen, callbacks, count = {}, {}, 0, 0
        for _, entry in ipairs(entries) do byIndex[entry.index] = entry end
        parent:IterateDynamicComponents(function(button)
            callbacks = callbacks + 1
            check(callbacks <= MAX_ENTRIES, "Too many prayer entries")
            local index = button.dynamicID
            local entry = byIndex[index]
            if entry then
                check(not seen[index] and button == entry.button
                    and button.spriteID == entry.spriteID and nameOf(button) == entry.name,
                    "Prayer list changed")
                check(applied[index] or button.visible, "Native filter changed")
                seen[index], count = true, count + 1
            elseif matches(button, Catalog.BUTTONS, index, api.spriteType) and button.visible then
                error("New prayer icon", 0)
            end
            return false
        end)
        return count == #entries
    end)
    return ok and result
end

return Catalog
