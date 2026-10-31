-- prayer_layout.lua
-- What this file does: Moves native prayer buttons with their glows for Fill spaces
-- and Custom layouts.
-- How it connects: Filter calls this after validation. Order supplies custom rows;
-- Scroll manages the required scroll range. Saved preferences are not written here.
-- Reading guide: START-HERE.txt lists the numbered sections below.

-- SECTION 1: Dependencies and position comparison
-- Positions include relative anchors as well as coordinates. Keep those anchors when
-- saving and restoring the original placement.
local Catalog = require("prayer_catalog")
local Scroll = require("prayer_scroll")
local Order = require("prayer_order")
local Layout = {}
Layout.__index = Layout
local POSITION_FIELDS = {"x", "y", "xParentPc", "yParentPc", "xSelfPc", "ySelfPc"}

local function samePosition(a, b)
    for _, field in ipairs(POSITION_FIELDS) do
        if a[field] ~= b[field] then return false end
    end
    return true
end

-- SECTION 2: Plan Custom positions and dividers
-- Measure the native columns and row pitch, then place visible entries and separators.
-- Reject an unmeasurable or irregular grid before writing.
local function planCustomLayout(entries, hidden, order, keyOf, dividerSpacing)
    local visible = {}
    for _, entry in ipairs(entries) do
        if not hidden[entry.index] then visible[#visible + 1] = entry end
    end
    local sequence = Order.sequence(visible, order, keyOf)
    if #sequence == 0 then return {}, {}, 0 end
    local first = assert(entries[1], "Open the prayer panel to measure its grid")
    local columns, rowPositions, rowSet = {}, {}, {}
    for _, entry in ipairs(entries) do
        local button = entry.button
        if button.y == first.button.y then columns[#columns + 1] = button.x end
        if not rowSet[button.y] then
            rowSet[button.y] = true
            rowPositions[#rowPositions + 1] = button.y
        end
    end
    table.sort(columns)
    table.sort(rowPositions)
    assert(#columns > 0, "Native prayer columns unavailable")
    local _, rows = Order.cells(sequence, #columns)
    -- A single row supports reordering within existing slots. A new
    -- row needs an observed pitch; never guess how a small panel would wrap.
    local pitch = rowPositions[2] and rowPositions[2] - rowPositions[1]
    assert(rows <= 1 or (pitch and pitch >= 34), "More native prayer rows are needed for this layout")
    if pitch then
        for i, y in ipairs(rowPositions) do
            assert(y == rowPositions[1] + (i - 1) * pitch, "Irregular native prayer rows")
        end
    end
    for i = 2, #columns do
        assert(columns[i] - columns[i - 1] >= 34, "Native prayer columns overlap")
    end
    for _, entry in ipairs(entries) do
        local found = false
        for _, x in ipairs(columns) do
            if entry.button.x == x then found = true; break end
        end
        assert(found, "Irregular native prayer columns")
    end
    local spacing = dividerSpacing == nil and Order.DEFAULT_DIVIDER_SPACING or dividerSpacing
    local cells = Order.geometry(sequence, #columns, pitch or 34, spacing, (pitch or 34) - first.button.height)
    local placements, bars = {}, {}
    local bottom = 0
    for _, cell in ipairs(cells) do
        local x, y = columns[cell.col + 1], rowPositions[1] + cell.y
        if cell.item.kind == "prayer" then
            placements[cell.item.entry.index] = {button = ui.Pos.new(x, y), glow = ui.Pos.new(x - 2, y - 2)}
        elseif cell.item.kind == "separator" then
            bars[#bars + 1] = {x = first.buttonParent.x + columns[1] - 2,
                y = first.buttonParent.y + y + spacing, width = columns[#columns] - columns[1] + 34}
        end
        -- Keep the existing button/glow extent for ordinary cells.
        local extent = cell.item.kind == "separator" and cell.height or 32
        bottom = math.max(bottom, first.buttonParent.y + y + extent)
    end
    return placements, bars, bottom
end

-- SECTION 3: Track and restore native changes
-- changes stores original and assigned positions; decorations stores plugin-created
-- lines. Restore only matching writes on surviving prayer identities.
function Layout.new(api)
    return setmetatable({api = api, changes = {}, decorations = {}, scroll = Scroll.new(api)}, Layout)
end

function Layout:hasChanges()
    return #self.changes > 0 or #self.decorations > 0 or next(self.scroll.changes) ~= nil
end

-- Only restore this plugin's exact assigned position on the same surviving component.
-- A native rebuild or another writer's newer position must not be overwritten.
function Layout:restore()
    local decorations = {}
    for _, bar in ipairs(self.decorations) do
        local ok = pcall(function() bar:Destroy() end)
        if not ok then decorations[#decorations + 1] = bar end
    end
    self.decorations = decorations
    local pending = {}
    for _, change in ipairs(self.changes) do
        local ok = pcall(function()
            local current = self.api.get(change.staticID, change.index)
            if current ~= change.component then return end
            -- The client can reuse a slot for another book without replacing
            -- its object. Do not restore the previous prayer's geometry there.
            local button = self.api.get(Catalog.BUTTONS, change.index)
            if button ~= change.button or button.spriteID ~= change.spriteID then return end
            if samePosition(current.position, change.assigned) then
                local restored, reason = pcall(function()
                    current.position = ui.Pos.new(change.original)
                    assert(samePosition(current.position, change.original), "Position restore not confirmed")
                end)
                if not restored then
                    -- Keep ownership even if restoration itself only partly ran.
                    change.assigned = ui.Pos.new(current.position)
                    error(reason, 0)
                end
            end
        end)
        if not ok then pending[#pending + 1] = change end
    end
    self.changes = pending
    local scrollRestored = self.scroll:restore()
    return #pending == 0 and #decorations == 0 and scrollRestored
end

-- SECTION 4: Detect replacement positions
-- Check handles and assigned positions plus viewport dimensions, so a native reflow
-- causes a fresh capture.
function Layout:unchanged()
    local ok, result = pcall(function()
        for _, change in ipairs(self.changes) do
            local current = self.api.get(change.staticID, change.index)
            if current ~= change.component or not samePosition(current.position, change.assigned) then return false end
        end
        return true
    end)
    return ok and result and self.scroll:unchanged()
end

-- SECTION 5: Apply Fill spaces or Custom layout
-- Snapshot every original slot first. Fill spaces reuses consecutive slots; Custom uses
-- planned cells. Record each write before applying it.
-- Call only after full roster validation and restoration of previous positions.
-- Snapshot every destination before the first write: reading slots while moving
-- entries would otherwise mistake already-compacted positions for native slots.
function Layout:apply(entries, hidden, customOrder, dividerSpacing)
    local ok, problem = pcall(function()
        assert(not self:hasChanges(), "Previous positions still need restoration")
        local slots, originalBottom = {}, 0
        for i, entry in ipairs(entries) do
            assert(entry.buttonParent.x == entry.glowParent.x
                and entry.buttonParent.y == entry.glowParent.y, "Prayer layer origins differ")
            local slot = {button = ui.Pos.new(entry.button.position), glow = ui.Pos.new(entry.glow.position),
                x = entry.button.x, y = entry.button.y}
            for _, previous in ipairs(slots) do
                assert(math.abs(slot.x - previous.x) >= 30 or math.abs(slot.y - previous.y) >= 30,
                    "Native prayer slots overlap")
            end
            slots[i] = slot
            originalBottom = math.max(originalBottom,
                entry.buttonParent.y + entry.button.y + entry.button.height,
                entry.glowParent.y + entry.glow.y + entry.glow.height)
        end
        local placements, bars, bottom
        if customOrder then
            placements, bars, bottom = planCustomLayout(entries, hidden, customOrder, self.api.layoutKey, dividerSpacing)
        end
        local destination = 0
        for i, entry in ipairs(entries) do
            if not hidden[entry.index] then
                destination = destination + 1
                local assigned = placements and placements[entry.index] or slots[destination]
                if not samePosition(slots[i].button, assigned.button)
                    or not samePosition(slots[i].glow, assigned.glow) then
                    for _, kind in ipairs({"button", "glow"}) do
                        local component = entry[kind]
                        local change = {component = component, index = entry.index,
                            button = entry.button, spriteID = entry.spriteID,
                            staticID = kind == "button" and Catalog.BUTTONS or Catalog.GLOWS,
                            original = slots[i][kind], assigned = assigned[kind]}
                        self.changes[#self.changes + 1] = change
                        local written, reason = pcall(function()
                            component.position = ui.Pos.new(change.assigned)
                            assert(samePosition(component.position, change.assigned), "Position write not confirmed")
                        end)
                        if not written then
                            -- A setter can throw after a partial write. With no
                            -- yield here, the resulting position also belongs to this transaction.
                            change.assigned = ui.Pos.new(component.position)
                            error(reason, 0)
                        end
                    end
                end
            end
        end
        self.scroll:apply(entries, hidden, originalBottom, customOrder ~= nil, bottom)
        for _, spec in ipairs(bars or {}) do
            local bar = ui.Rectangle.new(self.api.get(8))
            self.decorations[#self.decorations + 1] = bar
            bar:SetPos(spec.x, spec.y); bar:SetSize(spec.width, 2)
            bar.fill, bar.rgba, bar.clickthrough = true, 0x887343FF, true
        end
    end)
    return ok, ok and nil or tostring(problem)
end

-- SECTION 6: Maintain scrolling
-- Delegate scroll-range upkeep without rearranging icons again on every update.
function Layout:maintain(entries, hidden)
    self.scroll:maintain(entries, hidden)
end

return Layout
