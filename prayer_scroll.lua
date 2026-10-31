-- prayer_scroll.lua
-- What this file does: Adjusts the prayer panel's scrollable content height to fit its
-- arranged icons and separators.
-- How it connects: Layout calls apply and maintain. This module owns only scroll
-- extent, scroll offset and the scrollbar's Lua hidden flag.
-- Reading guide: START-HERE.txt lists the numbered sections below.

-- SECTION 1: Scroll IDs and property setters
-- Layer 8 is the scroll viewport; layer 20 is the scrollbar. Use the API methods for
-- extent and offset changes.
local Catalog = require("prayer_catalog")
local Scroll = {}
Scroll.__index = Scroll
local VIEWPORT, SCROLLBAR = 8, 20

local function write(component, field, value)
    if field == "scrollHeight" then
        component:SetScrollSize(component.scrollWidth, value)
    elseif field == "scrollY" then
        component:SetScrollPos(component.scrollX, value)
    else
        component.hidden = value
    end
end

-- SECTION 2: Record and restore scroll changes
-- Save original values before writing. Restore content height before its offset, and
-- avoid restoring old geometry onto a different book.
function Scroll.new(api)
    return setmetatable({api = api, changes = {}}, Scroll)
end

-- Record before writing, including setters that fail after changing state.
function Scroll:set(component, staticID, field, value)
    if component[field] == value then return end
    local key = tostring(staticID) .. ":" .. field
    local change = self.changes[key]
    if not change then
        change = {component = component, staticID = staticID, field = field, original = component[field]}
        self.changes[key] = change
    end
    change.assigned = value
    local ok, reason = pcall(function()
        write(component, field, value)
        assert(component[field] == value, "Scroll write not confirmed")
    end)
    if not ok then change.assigned = component[field]; error(reason, 0) end
end

function Scroll:restore()
    -- Restore the extent before any clamped offset, so the old offset is valid.
    for _, field in ipairs({"scrollHeight", "scrollY", "hidden"}) do
        for key, change in pairs(self.changes) do
            if change.field == field then
                local ok = pcall(function()
                    local current = self.api.get(change.staticID)
                    if current ~= change.component or current[field] ~= change.assigned then return end
                    -- Scroll geometry may now belong to another book on reused
                    -- handles. Release this plugin's Lua hiding, but leave that geometry.
                    if field ~= "hidden" and self.api.acceptBook and not self.api.acceptBook() then return end
                    local restored, reason = pcall(function()
                        write(current, field, change.original)
                        assert(current[field] == change.original, "Scroll restore not confirmed")
                    end)
                    if not restored then change.assigned = current[field]; error(reason, 0) end
                end)
                if ok then self.changes[key] = nil end
            end
        end
    end
    if next(self.changes) then return false end
    self.context = nil
    return true
end

-- SECTION 3: Validate and measure the viewport
-- Check the same viewport handles and dimensions. Save the native padding so the new
-- content range retains it.
function Scroll:unchanged()
    local context = self.context
    if not context then return true end
    local ok, result = pcall(function()
        return self.api.get(VIEWPORT) == context.viewport and self.api.get(SCROLLBAR) == context.bar
            and context.viewport.width == context.width and context.viewport.height == context.height
    end)
    return ok and result
end

function Scroll:apply(entries, hidden, originalBottom, force, minimumBottom)
    if not force and next(hidden) == nil then return end -- Show all keeps native scrolling.
    local viewport, bar = self.api.get(VIEWPORT), self.api.get(SCROLLBAR)
    for _, pair in ipairs({{viewport, VIEWPORT}, {bar, SCROLLBAR}}) do
        local component, staticID = pair[1], pair[2]
        assert(component and not component.isRestricted and component.type == self.api.layerType
            and component.interfaceID == Catalog.INTERFACE and component.staticID == staticID
            and component.categoryID == -1 and component.dynamicID == -1, "Prayer scroll layers unavailable")
    end
    assert(viewport.scrollable and viewport.height > 0 and type(bar.hidden) == "boolean",
        "Prayer scroll region unavailable")
    for _, entry in ipairs(entries) do
        assert(entry.buttonParent.parent == viewport and entry.glowParent.parent == viewport,
            "Prayer scroll ancestry changed")
    end
    self.context = {viewport = viewport, bar = bar, width = viewport.width, height = viewport.height,
        originalHidden = bar.hidden, minimumBottom = minimumBottom or 0,
        padding = math.max(0, viewport.scrollHeight - math.max(viewport.height, originalBottom))}
    self:maintain(entries, hidden)
end

-- SECTION 4: Fit content and clamp the offset
-- Find the lowest shown icon or divider. Keep valid scrolling untouched; clamp an offset
-- only when it falls outside the new range.
-- A client refresh can reset the range/scrollbar without rebuilding icons.
-- Clamp only an out-of-range offset; ordinary user scrolling remains untouched.
function Scroll:maintain(entries, hidden)
    local context = self.context
    if not context then return end
    assert(self:unchanged(), "Prayer viewport changed")
    local viewport, bottom = context.viewport, context.minimumBottom
    for _, entry in ipairs(entries) do
        if not hidden[entry.index] then
            bottom = math.max(bottom, entry.buttonParent.y + entry.button.y + entry.button.height,
                entry.glowParent.y + entry.glow.y + entry.glow.height)
        end
    end
    local extent = math.max(viewport.height, bottom > 0 and bottom + context.padding or 0)
    -- Clamp first, because SetScrollSize may clamp implicitly and hide the old
    -- offset before it can be recorded for restoration.
    local offset = math.max(0, math.min(viewport.scrollY, extent - viewport.height))
    self:set(viewport, VIEWPORT, "scrollY", offset)
    self:set(viewport, VIEWPORT, "scrollHeight", extent)
    self:set(context.bar, SCROLLBAR, "hidden", extent <= viewport.height or context.originalHidden)
end

return Scroll
