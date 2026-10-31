-- prayer_meter.lua
-- What this file does: Draws the optional prayerbook meter and coordinates its
-- replacement of the original footer counter.
-- How it connects: main.lua calls update and hover. ActionBarLayout optionally hides
-- the source prayer display only after a working book meter has been drawn.
-- Reading guide: START-HERE.txt lists the numbered sections below.

-- SECTION 1: Component IDs and safe reading helpers
-- Check the named book and combat components, clean numeric text, and convert absolute
-- positions into local boxes. Unknown structures retain the original counter.
local ActionBarLayout = require("action_bar_layout")
local Meter = {}
Meter.__index = Meter
-- Static component IDs for the desktop prayer book and combat prayer display.
-- Names identify candidates; type, ancestry, visibility and geometry are checked live.
local BOOK, COMBAT = 1458, 1430
local MAIN, BORDER, COUNTER, COUNTER_TEXT = 4, 7, 51, 52
local POINTS, GLOBE, ICON = 14, 18, 19
local PRAYER_BACKGROUND = 15
-- TOPLEVEL_V2_COMBAT_BAR__PLAYER_PRAYER_BAR identifies the combat prayer bar layer.
local PRAYER_BAR = 16
local QUICK_PRAYER, FILTER, FOOTER = 24, 30, 36
local TRACK_WIDTH = 8
-- The painted desktop border extends beyond its inner component bounds.
local EDGE_LEFT, EDGE_TOP, EDGE_RIGHT, EDGE_BOTTOM = -3, -4, 2, 2

local function typeName(value)
    for _, name in ipairs({"LAYER", "LABEL", "SPRITE", "RECTANGLE", "PANEL", "GROUP_BOX", "BUTTON",
        "MODEL", "MODEL_GROUP", "CANVAS", "LINE", "RADIAL_PROGRESS_OVERLAY"}) do
        if ui.ComponentType[name] ~= nil and value == ui.ComponentType[name] then return name end
    end
    return tostring(value)
end

local function plain(text)
    assert(type(text) == "string" and #text <= 160, "Prayer text unavailable")
    return text:gsub("<[^>]*>", ""):gsub(",", "")
end

local function inside(component, ancestor)
    for _ = 1, 16 do
        if not component or component.isRestricted then return false end
        if component == ancestor then return true end
        component = component.parent
    end
    return false
end

local function pointsOf(label)
    local current, maximum = plain(label.content):match("^%s*(%d+)%s*/%s*(%d+)%s*$")
    current, maximum = tonumber(current), tonumber(maximum)
    if current and maximum and maximum > 0 and current <= 1000000 and maximum <= 1000000 then
        return current, maximum
    end
end

-- The combat prayer display is a container. Search only its visible descendants
-- for one exact points label; ambiguous, oversized or restricted trees fail closed.
local function combatPoints(root)
    local current, maximum, matches, visited, seen = nil, nil, 0, 0, {}
    local function visit(component, depth)
        if seen[component] then return false end
        seen[component], visited = true, visited + 1
        assert(visited <= 32 and depth <= 4, "Combat prayer display nesting differs")
        if component.isRestricted or not component.visibleGlobal then return false end
        assert(inside(component, root), "Combat prayer display ancestry differs")
        if component.type == ui.ComponentType.LABEL then
            local value, cap = pointsOf(component)
            if value then current, maximum, matches = value, cap, matches + 1 end
        elseif component.type == ui.ComponentType.LAYER then
            local function child(entry) return visit(entry, depth + 1) end
            component:IterateStaticComponents(child)
            component:IterateDynamicComponents(child)
        end
        return false
    end
    visit(root, 0)
    assert(matches == 1, "One readable combat prayer points label is required")
    return current, maximum
end

local function bounds(component, origin)
    local xy = component.xyGlobal
    return {x = xy.x - origin.x, y = xy.y - origin.y,
        w = component.width, h = component.height}
end

local function place(component, box)
    component:SetPos(box.x, box.y)
    component:SetSize(box.w, box.h)
end

-- SECTION 2: Meter state and cleanup
-- Track the overlay and owned footer flag. Restore before reading native visibility, and
-- release both the meter and resource layout on pause.
function Meter.new(get, overlayHost)
    return setmetatable({get = get, overlayHost = overlayHost, actionBar = ActionBarLayout.new(get), status = "Off. The original counter is shown."}, Meter)
end

function Meter:component(interface, staticID, expectedType)
    local component = self.get(interface, staticID)
    assert(component and not component.isRestricted and component.interfaceID == interface
        and component.staticID == staticID and component.categoryID == -1 and component.dynamicID == -1,
        "Required prayer components unavailable")
    assert(not expectedType or component.type == expectedType,
        string.format("Component %d:%d is %s; expected %s", interface, staticID,
            typeName(component.type), typeName(expectedType)))
    return component
end

-- Release the hidden flag before reading native visibility. This runs without
-- yielding, so the normal counter is not rendered between release and reapply.
function Meter:restoreCounter()
    local owned = self.counter
    if not owned then return true end
    local ok = pcall(function()
        if self.get(BOOK, FOOTER) == owned.component and owned.component.hidden == true then
            owned.component.hidden = owned.original
            assert(owned.component.hidden == owned.original, "Counter restoration pending")
        end
    end)
    if ok then self.counter = nil end
    return ok
end

function Meter:pause()
    local restored = self:restoreCounter()
    local actionBarRestored = self.actionBar:pause()
    if self.root then
        local root = self.root
        -- Hide first if possible; keep a failed destruction available for retry.
        pcall(function() root.hidden = true end)
        local ok = pcall(function() root:Destroy() end)
        if ok then self.root, self.parts, self.parent, self.host, self.paintCache, self.globeSprites, self.barSprites = nil, nil, nil, nil, nil, nil, nil end
    end
    return restored and actionBarRestored and self.root == nil
end

-- SECTION 3: Read native circle and bar artwork
-- Copy the live background and star separately. The Filter menu bar uses native track,
-- fill and overlay sprites; source artwork is read, not replaced.
-- The native circle is the separate PRAYER_BG sprite (1430:15), not a child
-- of PRAYER_GLOBE_LAYER. Copy that background first, then the star, preserving
-- their live assets, tint and dimensions without moving either native control.
function Meter:readGlobe(icon)
    local globe = self:component(COMBAT, GLOBE, ui.ComponentType.LAYER)
    local background = self:component(COMBAT, PRAYER_BACKGROUND, ui.ComponentType.SPRITE)
    assert(globe.visibleGlobal and globe.width == globe.height and globe.width >= 16 and globe.width <= 48,
        "Native prayer globe geometry unavailable")
    local specs = {}
    for i, component in ipairs({background, icon}) do
        assert(component.visibleGlobal, "Native prayer globe artwork is hidden")
        local box = bounds(component, globe.xyGlobal)
        assert(box.x >= 0 and box.y >= 0 and box.w > 0 and box.h > 0
            and box.x + box.w <= globe.width and box.y + box.h <= globe.height,
            "Prayer globe artwork extends outside its bounds")
        if i == 1 then
            assert(box.x == 0 and box.y == 0 and box.w == globe.width and box.h == globe.height,
                "Prayer globe background geometry differs")
        end
        assert(type(component.spriteID) == "number" and component.spriteID >= 0 and component.spriteID % 1 == 0,
            "Prayer globe artwork unavailable")
        specs[i] = {box = box, sprite = component.spriteID,
            config = component:GetConfigCopy(), glyph = i == 2}
    end
    return {size = globe.width, parts = specs}
end

-- Native bar children 0..2 draw the track, 3 draws its highlighted fill,
-- and 4..6 draw the overlay. Read their live sprite configs rather than baking
-- sprite IDs or colours into the plugin. Children 7/8 are an empty sprite/label.
function Meter:readBar()
    local root = self:component(COMBAT, PRAYER_BAR, ui.ComponentType.LAYER)
    assert(root.visibleGlobal and root.width >= 32, "Native prayer bar unavailable")
    local slots, count = {}, 0
    root:IterateDynamicComponents(function(child)
        count = count + 1
        assert(count <= 16, "Native prayer bar children differ")
        if child.isRestricted then error("Native prayer bar artwork restricted") end
        local slot = child.dynamicID
        if child.categoryID == 0 and type(slot) == "number" and slot >= 0 and slot <= 6 then
            assert(child.parent == root and child.interfaceID == COMBAT and child.staticID == PRAYER_BAR
                and child.type == ui.ComponentType.SPRITE and child.visibleGlobal and not slots[slot],
                "Native prayer bar artwork differs")
            assert(type(child.spriteID) == "number" and child.spriteID >= 0 and child.spriteID % 1 == 0,
                "Native prayer bar sprite unavailable")
            slots[slot] = {box = bounds(child, root.xyGlobal), sprite = child.spriteID, config = child:GetConfigCopy()}
        end
        return false
    end)
    for slot = 0, 6 do assert(slots[slot], "Native prayer bar artwork missing") end
    local left, middle, right = slots[0].box, slots[1].box, slots[2].box
    assert(left.x == 0 and left.w > 0 and right.w > 0 and left.h > 0
        and middle.x == left.w and middle.w >= 0 and right.x == middle.x + middle.w
        and right.x + right.w == root.width and middle.y == left.y and right.y == left.y
        and middle.h == left.h and right.h == left.h and left.y >= 0 and left.y + left.h <= root.height,
        "Native prayer bar track geometry differs")
    for slot = 4, 6 do
        local front, back = slots[slot].box, slots[slot - 4].box
        assert(front.x == back.x and front.y == back.y and front.w == back.w and front.h == back.h,
            "Native prayer bar overlay geometry differs")
    end
    local fill = slots[3].box
    local inset = fill.x
    assert(inset >= 0 and root.width > 2 * inset and fill.w >= 0 and fill.w <= root.width - 2 * inset
        and fill.y >= left.y and fill.h > 0 and fill.y + fill.h <= left.y + left.h,
        "Native prayer bar fill geometry differs")
    return {slots = slots, width = root.width, height = left.h, y = left.y, inset = inset}
end

-- SECTION 4: Calculate placement and validate the book
-- Calculate independent bar-edge and circle-corner positions, or fit a horizontal meter
-- in the footer. Validate points and space before drawing.
-- Bar edge and circle corner are independent. Vertical fills grow upward;
-- horizontal fills grow rightward. The circle covers the bar where they meet.
-- Both positions follow the native frame when the book moves or resizes.
local function meterGeometry(frame, iconSize, side, corner)
    local left, right = frame.x + EDGE_LEFT, frame.x + frame.w + EDGE_RIGHT
    local top, bottom = frame.y + EDGE_TOP, frame.y + frame.h + EDGE_BOTTOM
    local horizontal = side == "bottom" or side == "top"
    local circleRight = corner == "top-right" or corner == "bottom-right"
    local circleTop = corner == "top-left" or corner == "top-right"
    local x, y = circleRight and right or left, circleTop and top or bottom
    local icon = {x = math.floor(x - iconSize / 2), y = math.floor(y - iconSize / 2),
        w = iconSize, h = iconSize}
    local track = horizontal
        and {x = left, y = (side == "top" and top or bottom) - TRACK_WIDTH / 2, w = right - left, h = TRACK_WIDTH}
        or {x = (side == "right" and right or left) - TRACK_WIDTH / 2, y = top, w = TRACK_WIDTH, h = bottom - top}
    return icon, track, horizontal
end

-- Fit the action-bar arrangement into the footer's free left-hand area.
-- Keep native artwork at its original size and never cover the footer controls.
local function footerGeometry(frame, footer, right, iconSize, barHeight)
    local x = frame.x + 6
    local y = math.floor(footer.y + (footer.h - math.max(17 + barHeight, iconSize)) / 2)
    local textX = x + iconSize + 4
    local width = math.min(120, right - textX)
    assert(width >= 64, "Widen the prayer book to show the Filter menu meter")
    assert(y >= frame.y and y + math.max(17 + barHeight, iconSize) <= frame.y + frame.h,
        "Not enough footer height for the Filter menu meter")
    local icon = {x = x, y = y, w = iconSize, h = iconSize}
    local number = {x = textX, y = y, w = width, h = 16}
    local track = {x = textX, y = y + 17, w = width, h = barHeight}
    return icon, track, number
end

function Meter:read(side, corner, style)
    local types = ui.ComponentType
    local main = self:component(BOOK, MAIN, types.LAYER)
    local border = self:component(BOOK, BORDER)
    local counter = self:component(BOOK, COUNTER, types.LAYER)
    local label = self:component(BOOK, COUNTER_TEXT, types.LABEL)
    local footer = self:component(BOOK, FOOTER, types.LAYER)
    assert(inside(border, main) and inside(footer, main) and inside(counter, footer) and inside(label, counter),
        "Prayer counter nesting differs")
    assert(main.visibleGlobal and border.visibleGlobal and counter.visibleGlobal and label.visibleGlobal
        and footer.hidden == false and footer.visibleGlobal, "Open the prayer book with its counter visible")
    assert(border.type == types.LAYER or border.type == types.SPRITE or border.type == types.RECTANGLE,
        "Prayer border type differs")
    local icon = self:component(COMBAT, ICON, types.SPRITE)
    assert(icon.visibleGlobal, "Keep the existing combat prayer display visible")
    -- Wide footers already expose the exact ratio. Compact footers expose only
    -- the current points, so use the combat display and require both to agree.
    local current, maximum = pointsOf(label)
    if not current then
        local scalar = tonumber(plain(label.content):match("^%s*(%d+)%s*$"))
        assert(scalar, "Exact prayer counter text unavailable")
        local points = self:component(COMBAT, POINTS)
        assert(points.visibleGlobal, "Keep the existing combat prayer display visible")
        current, maximum = combatPoints(points)
        assert(scalar == current, "Waiting for the prayer displays to agree")
    end
    assert(type(icon.spriteID) == "number" and icon.spriteID >= 0 and icon.spriteID % 1 == 0,
        "Prayer icon unavailable")

    local globe = self:readGlobe(icon)
    local iconSize = globe.size
    local frame, box = bounds(border, main.xyGlobal), bounds(counter, main.xyGlobal)
    assert(frame.w >= 70 and frame.h >= 100 and frame.x >= 0 and frame.y >= 0
        and frame.x + frame.w <= main.width and frame.y + frame.h <= main.height,
        "Prayer frame geometry unavailable")
    assert(box.w >= 18 and box.h >= 18 and box.h <= 48
        and box.x >= frame.x
        and box.y >= frame.y + frame.h - 60
        and box.x + box.w <= frame.x + frame.w and box.y + box.h <= main.height,
        string.format("Counter outside footer: counter %d,%d %dx%d; frame %d,%d %dx%d; root %dx%d",
            box.x, box.y, box.w, box.h, frame.x, frame.y, frame.w, frame.h, main.width, main.height))
    local footerBox = bounds(footer, main.xyGlobal)
    assert(footerBox.w >= 18 and footerBox.h >= 18 and footerBox.h <= 48
        and footerBox.x >= frame.x and footerBox.x + footerBox.w <= frame.x + frame.w
        and footerBox.y >= frame.y + frame.h - 60 and footerBox.y + footerBox.h <= main.height,
        "Footer display is outside the bottom of the book")
    assert(box.x >= footerBox.x and box.y >= footerBox.y
        and box.x + box.w <= footerBox.x + footerBox.w and box.y + box.h <= footerBox.y + footerBox.h,
        "Prayer counter extends outside its footer display")
    -- Hide only the counter's display group. Its transparent layout bounds may
    -- span the footer, but quick-prayer/filter controls must be outside its tree.
    local footerRight = frame.x + frame.w - 6
    for _, staticID in ipairs({QUICK_PRAYER, FILTER}) do
        local control = self:component(BOOK, staticID)
        assert(inside(control, main) and not inside(control, footer), "Footer controls share the counter display")
        local other = bounds(control, main.xyGlobal)
        assert(other.w > 0 and other.h > 0, "Footer control geometry unavailable")
        footerRight = math.min(footerRight, other.x - 4)
        -- Only the removed counter must be disjoint from native controls.
        -- Edge decorations are clickthrough, including the bottom-right globe.
        assert(box.x + box.w <= other.x or other.x + other.w <= box.x
            or box.y + box.h <= other.y or other.y + other.h <= box.y,
            "Prayer counter overlaps footer controls")
    end
    -- A host outside the book's clipping region lets the circle straddle its
    -- corner. All positions remain measured from the native frame each tick.
    local host = assert(self.overlayHost and self.overlayHost(), "Prayer meter overlay host unavailable")
    assert(not host.isRestricted and host.visibleGlobal, "Prayer meter overlay host unavailable")
    local origin, hostOrigin = main.xyGlobal, host.xyGlobal
    local padding = math.ceil(iconSize / 2) + 4
    local overlay = {x = origin.x - hostOrigin.x - padding,
        y = origin.y - hostOrigin.y - padding, w = main.width + 2 * padding, h = main.height + 2 * padding}
    frame.x, frame.y = frame.x + padding, frame.y + padding
    local iconBox, track, horizontal = meterGeometry(frame, iconSize, side, corner)
    -- Filter menu substitutes footer placement and native bar art; Edge keeps the
    -- independent frame-edge and corner coordinates calculated above.
    local number, bar
    if style == "filter" then
        bar = self:readBar()
        footerBox.x, footerBox.y = footerBox.x + padding, footerBox.y + padding
        iconBox, track, number = footerGeometry(frame, footerBox, footerRight + padding, iconSize, bar.height)
        horizontal = true
    end
    assert((horizontal and track.w or track.h) >= 40, "Not enough room for the prayer meter")
    return {main = main, counter = footer, label = label, frame = frame, host = host, overlay = overlay,
        current = current, maximum = maximum, globe = globe, icon = iconBox, track = track, horizontal = horizontal, side = side, corner = corner, number = number, style = style, bar = bar}
end

-- SECTION 5: Create and draw meter decorations
-- Reuse plugin-owned components. Edge bar uses canvas pills; Filter menu uses copied
-- native sprites. All decorations let clicks pass through.
function Meter:build(data)
    self.root = ui.Layer.new(data.host)
    self.root.hidden, self.root.clickthrough = true, true
    self.parent, self.host, self.parts = data.main, data.host, {}
    local function rectangle(name, colour)
        local part = ui.Rectangle.new(self.root)
        self.parts[name] = part
        part.fill, part.rgba, part.clickthrough = true, colour, true
    end
    for _, name in ipairs({"edge", "track", "fill"}) do
        self.parts[name] = ui.Canvas.new(self.root)
        self.parts[name].clickthrough = true
    end
    self.parts.nativeBar = ui.Layer.new(self.root)
    self.parts.nativeBar.clickthrough = true
    self.barSprites = {}
    for slot = 0, 6 do
        local sprite = ui.Sprite.new(self.parts.nativeBar)
        sprite.clickthrough = true
        self.barSprites[slot] = sprite
    end
    self.parts.orb = ui.Layer.new(self.root)
    self.parts.orb.clickthrough = true
    self.globeSprites = {}
    self.parts.number = ui.Text.new(self.root)
    self.parts.number:SetConfig(data.label:GetConfigCopy())
    self.parts.number:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
    self.parts.number.clickthrough = true
    rectangle("tooltipBackground", 0x171611F5)
    self.parts.tooltip = ui.Text.new(self.root)
    self.parts.tooltip:SetConfig(data.label:GetConfigCopy())
    self.parts.tooltip.clickthrough = true
    self.parts.tooltip:AlignTo(ui.AlignMode.CENTRE)
end

-- Canvas has triangles rather than a circle primitive. A short triangle fan
-- draws rounded caps without new assets; cache geometry to avoid rebuilding it
-- on unchanged ticks. Coordinates are integer interface units.
local function circle(canvas, x, y, radius, colour)
    local function rounded(value) return math.floor(value + 0.5) end
    local previousX, previousY = rounded(x + radius), rounded(y)
    for step = 1, 32 do
        local angle = step * math.pi / 16
        local nextX, nextY = rounded(x + math.cos(angle) * radius), rounded(y + math.sin(angle) * radius)
        canvas:AddTriangle(rounded(x), rounded(y), previousX, previousY, nextX, nextY, colour)
        previousX, previousY = nextX, nextY
    end
end

function Meter:paintPill(name, box, colour)
    local canvas = self.parts[name]
    place(canvas, box)
    local signature = box.w .. ":" .. box.h .. ":" .. colour
    self.paintCache = self.paintCache or {}
    if self.paintCache[name] == signature then return end
    canvas:Clear()
    local w, h = box.w, box.h
    if h >= w then
        local radius = w / 2
        canvas:AddRectangle(0, math.ceil(radius), w, h - w, colour)
        circle(canvas, radius, radius, radius, colour)
        circle(canvas, radius, h - radius, radius, colour)
    else
        local radius = h / 2
        canvas:AddRectangle(math.ceil(radius), 0, w - h, h, colour)
        circle(canvas, radius, radius, radius, colour)
        circle(canvas, w - radius, radius, radius, colour)
    end
    self.paintCache[name] = signature
end

-- Preserve cap widths and native height; stretch only the middle segments.
-- Scale the live fill's width within the same symmetric inset so its current
-- amount and any native animation follow the original display.
function Meter:drawNativeBar(data)
    local bar, track = data.bar, data.track
    place(self.parts.nativeBar, track)
    local leftWidth, rightWidth = bar.slots[0].box.w, bar.slots[2].box.w
    assert(track.w >= leftWidth + rightWidth, "Not enough room for native prayer bar caps")
    for slot = 0, 6 do
        local spec, sprite = bar.slots[slot], self.barSprites[slot]
        local source = spec.box
        local x, width = source.x, source.w
        if slot == 3 then
            width = math.floor(source.w * (track.w - 2 * bar.inset) / (bar.width - 2 * bar.inset) + 0.5)
        else
            local segment = slot < 3 and slot or slot - 4
            if segment == 1 then width = track.w - leftWidth - rightWidth end
            if segment == 2 then x = track.w - rightWidth end
        end
        sprite:SetConfig(spec.config)
        sprite.sprite = spec.sprite
        place(sprite, {x = x, y = source.y - bar.y, w = width, h = source.h})
        sprite.hidden = width == 0
    end
end

function Meter:draw(data)
    local parts, track = self.parts, data.track
    place(self.root, data.overlay)
    -- Choose the renderer from the validated data: native sprites for the footer,
    -- canvas track/fill for an edge. Both use live current/maximum prayer points.
    parts.nativeBar.hidden = data.bar == nil
    if data.bar then
        parts.edge.hidden, parts.track.hidden, parts.fill.hidden = true, true, true
        self:drawNativeBar(data)
    else
        parts.edge.hidden, parts.track.hidden = false, false
        self:paintPill("edge", track, 0x77717FFF)
        self:paintPill("track", {x = track.x + 1, y = track.y + 1, w = track.w - 2, h = track.h - 2}, 0x181420FF)
        local length = (data.horizontal and track.w or track.h) - 2
        local filled = math.floor(length * math.min(1, data.current / data.maximum) + 0.5)
        local fill = data.horizontal
            and {x = track.x + 1, y = track.y + 1, w = math.max(1, filled), h = track.h - 2}
            or {x = track.x + 1, y = track.y + track.h - 1 - filled, w = track.w - 2, h = math.max(1, filled)}
        self:paintPill("fill", fill, 0x4B236AFF)
        parts.fill.hidden = filled == 0
    end
    place(parts.orb, data.icon)
    -- Reuse child sprites by slot. Extra slots are hidden if the native theme
    -- changes; they remain owned by the orb layer and are destroyed with it.
    for i, spec in ipairs(data.globe.parts) do
        local sprite = self.globeSprites[i]
        if not sprite then
            sprite = ui.Sprite.new(parts.orb)
            self.globeSprites[i] = sprite
            sprite.clickthrough = true
        end
        sprite:SetConfig(spec.config)
        sprite.sprite = spec.sprite
        place(sprite, spec.box)
        sprite.hidden = false
    end
    for i = #data.globe.parts + 1, #self.globeSprites do self.globeSprites[i].hidden = true end
    for i, spec in ipairs(data.globe.parts) do
        if spec.glyph then self.globeSprites[i]:MoveToFront() end
    end
    parts.number.hidden = data.number == nil
    if data.number then
        place(parts.number, data.number)
        parts.number.content = data.current .. "/" .. data.maximum
    end
    parts.tooltip.content = data.current .. " / " .. data.maximum
    local tooltipWidth = math.min(120, data.frame.w - 6)
    local corner = data.style == "filter" and "bottom-left" or data.corner
    local tooltip = {x = (corner == "top-right" or corner == "bottom-right") and data.frame.x + data.frame.w - tooltipWidth - 3 or data.frame.x + 3,
        y = (corner == "top-left" or corner == "top-right") and data.icon.y + data.icon.h + 3 or data.icon.y - 25,
        w = tooltipWidth, h = 22}
    place(parts.tooltipBackground, tooltip)
    place(parts.tooltip, tooltip)
    parts.tooltipBackground.hidden, parts.tooltip.hidden = true, true
    self.data = data
    self.root.hidden = false
    self.root:MoveToFront()
end

-- SECTION 6: Apply settings and handle failure
-- Restore owned source changes, read fresh values, draw the replacement and hide the
-- original footer. Apply optional action-bar layout last, with separate recovery.
-- Poll named components and, for compact footers, the bounded combat prayer
-- subtree. Release the optional resource layout first so native prayer assets
-- remain readable, then hide its source only after the book meter is ready.
function Meter:update(enabled, side, corner, style, hideActionBarPrayer)
    if not enabled then
        self.status = self:pause() and "Off. The original counter is shown." or "Counter restoration is pending."
        return
    end
    local ok, problem = pcall(function()
        assert(self.actionBar:restore(), "Resource strip restoration is pending")
        assert(self:restoreCounter(), "Counter restoration is pending")
        side = side or "left"
        assert(side == "left" or side == "bottom" or side == "right" or side == "top", "Invalid prayer meter side")
        corner = corner or (side == "right" and "bottom-right" or side == "top" and "top-left" or "bottom-left")
        assert(corner == "top-left" or corner == "top-right" or corner == "bottom-left" or corner == "bottom-right",
            "Invalid prayer circle corner")
        style = style or "edge"
        assert(style == "edge" or style == "filter", "Invalid prayer meter style")
        local data = self:read(side, corner, style)
        if self.root and (self.parent ~= data.main or self.host ~= data.host or self.cleanupPending) then
            assert(self:pause(), "Meter cleanup is pending")
        end
        if not self.root then self:build(data) end
        self:draw(data)
        -- Record ownership before a setter that could throw after writing.
        self.counter = {component = data.counter, original = data.counter.hidden}
        data.counter.hidden = true
        assert(data.counter.hidden == true, "Counter replacement unavailable")
    end)
    if ok then
        self.cleanupPending = false
        self.status = "On. Hover over the meter or icon for exact prayer points."
        if hideActionBarPrayer then
            local applied, reason = pcall(function() self.actionBar:apply() end)
            if applied then
                self.status = "On. Action bar prayer hidden; remaining displays use three columns."
            else
                local restored = self.actionBar:pause()
                self.status = restored and ("Meter on; action bar unchanged. " .. tostring(reason):gsub("^.-:%d+: ", ""))
                    or "Resource strip restoration pending; disable the plugin and restart if it persists."
            end
        elseif not self.actionBar:pause() then
            self.status = "Resource strip restoration is pending."
        end
    else
        self.cleanupPending = not self:pause()
        self.status = self.cleanupPending and "Restoration is pending; disable the plugin and restart if it persists."
            or "Original counter retained. " .. tostring(problem):gsub("^.-:%d+: ", "")
    end
end

-- SECTION 7: Show exact points on hover
-- Poll the pointer over the decorative meter or circle to show a tooltip without adding
-- a clickable control.
-- Hover is decorative too: polling avoids adding a click target over the book.
function Meter:hover()
    if not self.root or not self.data then return end
    local ok = pcall(function()
        local mouse = Mouse.IsAvailable() and Mouse.GetPosition()
        local data, hovered = self.data, false
        if mouse and self.root.visibleGlobal then
            local origin = self.root.xyGlobal
            for _, box in ipairs({data.track, data.icon}) do
                if mouse.x >= origin.x + box.x and mouse.x < origin.x + box.x + box.w
                    and mouse.y >= origin.y + box.y and mouse.y < origin.y + box.y + box.h then hovered = true end
            end
        end
        self.parts.tooltip.hidden, self.parts.tooltipBackground.hidden = not hovered, not hovered
    end)
    if not ok then pcall(function()
        self.parts.tooltip.hidden, self.parts.tooltipBackground.hidden = true, true
    end) end
end

return Meter
