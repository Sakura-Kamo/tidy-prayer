-- action_bar_layout.lua
-- What this file does: Optionally removes the action-bar prayer display and arranges
-- the remaining resource displays in three columns.
-- How it connects: Meter calls this only while its replacement book meter is working.
-- Native groups move at their original size; widened bar/text copies are decorative.
-- Reading guide: START-HERE.txt lists the numbered sections below.

-- SECTION 1: Resource IDs and native component checks
-- Use the desktop resource-strip groups and bar layers. Verify type and identity before
-- treating any native component as a writable target.
local Layout = {}
Layout.__index = Layout
local COMBAT, INFO, PRAYER = 1430, 6, 14
-- PLAYER_HEALTH / PLAYER_ADRENALINE / PLAYER_SUMMONING and their BAR layers.
local DISPLAYS = {{7, 9}, {55, 57}, {20, 22}}
local POSITION_FIELDS = {"x", "y", "xParentPc", "yParentPc", "xSelfPc", "ySelfPc"}

local function samePosition(a, b)
    for _, key in ipairs(POSITION_FIELDS) do if a[key] ~= b[key] then return false end end
    return true
end

function Layout.new(get)
    return setmetatable({get = get, changes = {}}, Layout)
end

function Layout:component(id)
    local c = self.get(COMBAT, id)
    assert(c and not c.isRestricted and c.interfaceID == COMBAT and c.staticID == id
        and c.categoryID == -1 and c.dynamicID == -1 and c.type == ui.ComponentType.LAYER,
        "Resource strip component unavailable: " .. id)
    return c
end

-- SECTION 2: Restore owned positions and visibility
-- Keep original positions, including anchors, and hidden flags. Leave replaced handles
-- or newer positions alone; retain failed restores for retry.
function Layout:restore()
    local pending = {}
    for i = #self.changes, 1, -1 do
        local change = self.changes[i]
        local ok = pcall(function()
            local c = self.get(COMBAT, change.id)
            if c ~= change.component then return end
            if change.position then
                if samePosition(c.position, change.assigned) then
                    c.position = ui.Pos.new(change.position)
                    assert(samePosition(c.position, change.position), "Position restoration pending")
                end
            elseif c.hidden == true then
                c.hidden = change.hidden
                assert(c.hidden == change.hidden, "Visibility restoration pending")
            end
        end)
        if not ok then table.insert(pending, 1, change) end
    end
    self.changes = pending
    if self.root then pcall(function() self.root.hidden = true end) end
    return #pending == 0
end

function Layout:pause()
    local restored = self:restore()
    if self.root then
        local ok = pcall(function() self.root:Destroy() end)
        if ok then self.root, self.parent, self.parts = nil, nil, nil end
    end
    return restored and self.root == nil
end

-- SECTION 3: Record native writes
-- Save originals before hiding a layer or moving a group. Moving a native group also
-- moves its child controls; their sizes are not changed.
function Layout:hide(c)
    self.changes[#self.changes + 1] = {id = c.staticID, component = c, hidden = c.hidden}
    c.hidden = true
    assert(c.hidden, "Resource strip visibility change failed")
end

function Layout:move(c, x)
    local position = ui.Pos.new(c.position)
    local assigned = ui.Pos.new(x, c.y)
    self.changes[#self.changes + 1] = {id = c.staticID, component = c,
        position = position, assigned = assigned}
    c.position = assigned
    assert(samePosition(c.position, assigned), "Resource strip movement failed")
end

-- SECTION 4: Capture native bar artwork
-- Read a bounded flat set of sprites and labels. Identify fixed end caps, stretchable
-- middle sections and fills by geometry; reject unfamiliar content.
local function readBar(bar)
    assert(bar.visibleGlobal and bar.hidden == false and bar.width >= 32 and bar.height <= 48,
        "Resource bar is hidden or too small")
    local slots, seen, count = {}, {}, 0
    bar:IterateStaticComponents(function(child)
        assert(not child.visibleGlobal, "Resource bar contains unsupported static content")
        return false
    end)
    bar:IterateDynamicComponents(function(child)
        count = count + 1
        assert(count <= 32 and not child.isRestricted and child.parent == bar
            and child.categoryID == 0 and child.interfaceID == COMBAT and child.staticID == bar.staticID,
            "Resource bar structure differs")
        local slot = child.dynamicID
        assert(type(slot) == "number" and slot >= 0 and slot < 32 and slot % 1 == 0 and not seen[slot],
            "Resource bar slots differ")
        seen[slot] = true
        if child.visibleGlobal and child.width > 0 and child.height > 0 then
            local sprite = child.type == ui.ComponentType.SPRITE
            assert(sprite or child.type == ui.ComponentType.LABEL, "Resource bar content differs")
            assert(not sprite or (type(child.spriteID) == "number" and child.spriteID >= 0),
                "Resource bar artwork unavailable")
            local xy, origin = child.xyGlobal, bar.xyGlobal
            local part = {slot = slot, sprite = sprite and child.spriteID or nil,
                text = not sprite and child.content or nil, config = child:GetConfigCopy(),
                x = xy.x - origin.x, y = xy.y - origin.y, w = child.width, h = child.height}
            assert(part.x >= 0 and part.y >= 0 and part.x + part.w <= bar.width
                and part.y + part.h <= bar.height, "Resource bar artwork extends outside its layer")
            slots[slot] = part
        end
        return false
    end)
    local left, middle, right = slots[0], slots[1], slots[2]
    assert(left and middle and right and left.sprite and middle.sprite and right.sprite
        and left.x == 0 and middle.x == left.w and right.x == middle.x + middle.w
        and right.x + right.w == bar.width and left.y == middle.y and left.y == right.y
        and left.h == middle.h and left.h == right.h, "Resource bar track differs")
    local parts = {}
    for _, part in pairs(slots) do
        if part.text then
            assert(part.x == 0 and part.w == bar.width, "Resource bar text layout differs")
            part.role = "text"
        elseif part.y == left.y and part.h == left.h then
            if part.x == left.x and part.w == left.w then part.role = "left"
            elseif part.x == middle.x and part.w == middle.w then part.role = "middle"
            elseif part.x == right.x and part.w == right.w then part.role = "right" end
            assert(part.role, "Resource bar cap geometry differs")
        else
            assert(part.y >= left.y and part.y + part.h <= left.y + left.h
                and part.x < bar.width / 2 and part.w <= bar.width - 2 * part.x,
                "Resource bar fill geometry differs")
            part.role = "fill"
        end
        parts[#parts + 1] = part
    end
    table.sort(parts, function(a, b) return a.slot < b.slot end)
    return {component = bar, width = bar.width, height = bar.height,
        left = left.w, right = right.w, parts = parts}
end

-- SECTION 5: Measure three equal columns
-- Require a horizontal four-column strip. Divide its existing span into thirds,
-- preserving each resource's icon offset and trailing gap.
function Layout:read()
    local parent, prayer = self:component(INFO), self:component(PRAYER)
    assert(parent.visibleGlobal and prayer.visibleGlobal and prayer.hidden == false
        and prayer.parent == parent, "Open the horizontal combat resource strip")
    local displays = {}
    for _, ids in ipairs(DISPLAYS) do
        local group, bar = self:component(ids[1]), self:component(ids[2])
        assert(group.parent == parent and bar.parent == group and group.visibleGlobal
            and group.width >= 64 and group.height > 0 and group.height <= 64,
            "Resource display nesting or size differs")
        local data = readBar(bar)
        data.group, data.offset = group, bar.xyGlobal.x - group.xyGlobal.x
        data.y = bar.xyGlobal.y - parent.xyGlobal.y
        assert(data.offset >= 0 and data.offset + bar.width <= group.width,
            "Resource bar extends outside its display")
        data.trailing = group.width - data.offset - bar.width
        displays[#displays + 1] = data
    end
    local ordered = {displays[1].group, displays[2].group, prayer, displays[3].group}
    local first, last = ordered[1], ordered[4]
    for i, group in ipairs(ordered) do
        assert(group.y == first.y and group.height == first.height
            and math.abs(group.width - first.width) <= 2 and group.x >= 0
            and group.x + group.width <= parent.width, "Resource strip is not a horizontal four-column layout")
        if i > 1 then
            local previous = ordered[i - 1]
            assert(math.abs(group.x - previous.x - previous.width) <= 2, "Resource strip spacing differs")
        end
    end
    local width = last.x + last.width - first.x
    for i, data in ipairs(displays) do
        local start = math.floor((i - 1) * width / 3)
        local finish = math.floor(i * width / 3)
        data.x = first.x + start
        data.targetWidth = finish - start - data.offset - data.trailing
        assert(data.targetWidth >= data.left + data.right, "Resource strip is too narrow")
    end
    return parent, prayer, displays
end

-- SECTION 6: Draw widened copies and move groups
-- Reuse clickthrough copies with live text, artwork and fill widths. Draw first, then
-- move native groups and hide original bar layers and the prayer group.
-- Copies leave native bar widths untouched, so native fill animations continue
-- to use their original coordinate system. Reuse copy nodes across ticks.
function Layout:apply()
    local parent, prayer, displays = self:read()
    if self.root and self.parent ~= parent then assert(self:pause(), "Resource strip cleanup pending") end
    if not self.root then
        self.root = ui.Layer.new(parent)
        self.root.hidden, self.root.clickthrough = true, true
        self.parent, self.parts = parent, {}
    end
    self.root:SetPos(0, 0)
    self.root:SetSize(parent.width, parent.height)
    local used = {}
    for _, data in ipairs(displays) do
        for _, part in ipairs(data.parts) do
            local key = data.component.staticID .. ":" .. part.slot
            used[key] = true
            local kind = part.text and "text" or "sprite"
            local entry = self.parts[key]
            if entry and entry.kind ~= kind then entry.node:Destroy(); self.parts[key] = nil; entry = nil end
            if not entry then
                entry = {kind = kind, node = kind == "text" and ui.Text.new(self.root) or ui.Sprite.new(self.root)}
                self.parts[key] = entry
                entry.node.clickthrough = true
            end
            local node, x, width = entry.node, part.x, part.w
            if part.role == "text" then width = data.targetWidth
            elseif part.role == "middle" then width = data.targetWidth - data.left - data.right
            elseif part.role == "right" then x = data.targetWidth - part.w
            elseif part.role == "fill" then
                width = math.floor(part.w * (data.targetWidth - 2 * part.x) / (data.width - 2 * part.x) + 0.5)
            end
            node:SetConfig(part.config)
            if part.text then node.content = part.text else node.sprite = part.sprite end
            node:SetPos(data.x + data.offset + x, data.y + part.y)
            node:SetSize(width, part.h)
            node.hidden = width == 0
            node:MoveToFront()
        end
    end
    for key, entry in pairs(self.parts) do if not used[key] then entry.node.hidden = true end end
    for _, data in ipairs(displays) do
        self:move(data.group, data.x)
        self:hide(data.component)
    end
    self:hide(prayer)
    self.root.hidden = false
    self.root:MoveToFront()
end

return Layout
