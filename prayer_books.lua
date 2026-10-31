-- prayer_books.lua
-- What this file does: Keeps Prayers and Curses preferences separate while
-- coordinating their shared game panel.
-- How it connects: main.lua owns this object. selection_ui.lua requests edits here;
-- this file delegates native changes to Filter.
-- Reading guide: START-HERE.txt lists the numbered sections below.

-- SECTION 1: Dependencies and book names
-- Each book has its own Filter. Definitions identify prayers; Order manages custom
-- arrangement tokens.
local Catalog = require("prayer_catalog")
local Filter = require("prayer_filter")
local Definitions = require("prayer_definitions")
local Order = require("prayer_order")
local Books = {}
Books.__index = Books
local ORDER = {"prayers", "curses"}
local LABELS = {prayers = "Prayers", curses = "Curses"}

-- SECTION 2: Create books and restore preferences
-- Build artwork lookups and per-book adapters, load saved choices, and retain older
-- visibility keys where they can be matched.
function Books.new(api, saved)
    local self = setmetatable({api = api, filters = {}, markers = {}, active = nil,
        dividerSpacing = saved and saved.dividerSpacing or Order.DEFAULT_DIVIDER_SPACING,
        prayerBar = saved and saved.prayerBar == true or false,
        hideActionBarPrayer = saved and saved.hideActionBarPrayer == true or false,
        prayerBarStyle = saved and saved.prayerBarStyle or "edge",
        prayerBarSide = saved and saved.prayerBarSide or "left",
        prayerCircleCorner = saved and (saved.prayerCircleCorner
            or (saved.prayerBarSide == "right" and "bottom-right"
                or saved.prayerBarSide == "top" and "top-left" or "bottom-left")) or "bottom-left",
        definitions = assert(api.definitions, "Prayer definitions are required"), spriteMaps = {}}, Books)
    for _, book in ipairs(ORDER) do
        local entries = self.definitions[book]
        local sprites = Definitions.spriteMap(entries)
        self.spriteMaps[book], self.markers[book] = sprites, {}
        for sprite in pairs(sprites) do self.markers[book][tostring(sprite)] = true end
        local adapter = {get = function(...) return self.api.get(...) end,
            spriteType = api.spriteType, layerType = api.layerType, label = LABELS[book],
            layoutKey = function(entry)
                local definition = sprites[entry.spriteID]
                return definition and definition.layoutKey or nil
            end,
            acceptBook = function() return self:detect() == book end,
            resolveKey = function(entry)
                local definition = sprites[entry.spriteID]
                return definition and definition.key or nil
            end}
        local filter = Filter.new(adapter)
        self.filters[book] = filter
        filter.dividerSpacing = self.dividerSpacing
        if saved then
            local profile = saved.books[book]
            filter.hiddenIcons, filter.ambiguousIcons = profile.hiddenIcons, profile.ambiguousIcons
            filter.layoutMode = profile.layoutMode or (profile.compact and "fill" or "default")
            filter.customOrder = Order.copy(profile.customOrder or {})
            -- Preserve 0.4.1 selections when their artwork maps unambiguously.
            -- Keep unmatched legacy keys too; never discard an unknown preference.
            local migrated = {}
            for key in pairs(filter.hiddenIcons) do
                if not key:match(":struct$") then
                    local definition = sprites[tonumber(key:match("^(%d+):"))]
                    if definition then migrated[definition.key] = true end
                end
            end
            for key in pairs(migrated) do filter.hiddenIcons[key] = true end
        end
    end
    -- Shared artwork cannot identify the current book on its own.
    for sprite in pairs(self.markers.prayers) do
        if self.markers.curses[sprite] then
            self.markers.prayers[sprite], self.markers.curses[sprite] = nil, nil
        end
    end
    return self
end

-- SECTION 3: Choose entries and recognise the open book
-- Level filtering affects the settings lists. Distinctive native artwork identifies
-- which book is open; settings tabs do not select it.
-- Keep the complete catalogue for native matching and preference migration.
-- Refresh only the chooser lists when the earned level changes.
function Books:setPrayerLevel(level)
    if self.prayerLevel == level then return false end
    local choices = {}
    for _, book in ipairs(ORDER) do
        choices[book] = Definitions.available(self.definitions[book], level)
    end
    self.choices, self.prayerLevel = choices, level
    return true
end

function Books:choicesFor(book)
    return self.choices and self.choices[book] or {}
end

function Books:detect()
    -- Include this plugin's Lua-hidden icons for recognition, but never display or modify
    -- native-hidden entries. The editable catalogue is a separate visible read.
    local sprites = Catalog.observedSprites(self.api)
    if not sprites then return nil end
    local matches = {}
    for sprite in pairs(sprites) do
        for _, book in ipairs(ORDER) do
            if self.markers[book][sprite] then matches[book] = true end
        end
    end
    if matches.prayers and not matches.curses then return "prayers" end
    if matches.curses and not matches.prayers then return "curses" end
    return nil -- Unknown/mixed content must not inherit another book's choices.
end

-- SECTION 4: Restore the active panel
-- Release the active book's native changes without deleting its saved visibility or
-- arrangement.
function Books:pause()
    if self.active then
        local filter = self.filters[self.active]
        filter.valid = false
        if not filter:releaseFlags() then return false end
        filter.status = "Choices saved for " .. LABELS[self.active] .. "."
        self.active = nil
    end
    return true
end

-- SECTION 5: Apply settings edits
-- Keep the previous preference values until an active panel can accept the change.
-- Closed-book edits remain ready for its next appearance.
-- Settings refer to the complete config catalogue, independently of whichever
-- subset the game currently displays. Native writes still require a recognised,
-- validated open panel. Inactive-book edits are saved for its next appearance.
function Books:change(book, hidden, mode, order)
    local filter = self.filters[book]
    if self.active and self:detect() ~= self.active and not self:pause() then return false end
    local previousHidden = filter.hiddenIcons
    local previousMode, previousOrder = filter.layoutMode, filter.customOrder
    filter.hiddenIcons = hidden
    filter.layoutMode, filter.customOrder = mode or filter.layoutMode, order or filter.customOrder
    if self.active == book and filter.valid then
        if not filter:recover() then
            filter.hiddenIcons, filter.valid = previousHidden, false
            filter.layoutMode, filter.customOrder = previousMode, previousOrder
            return false
        end
    end
    return true
end

function Books:setShown(book, key, shown)
    local filter = self.filters[book]
    local hidden, definition = {}, nil
    for _, entry in ipairs(self:choicesFor(book)) do if entry.key == key then definition = entry end end
    if not definition then return false end
    for existing in pairs(filter.hiddenIcons) do hidden[existing] = true end
    hidden[key] = not shown or nil
    -- Clear earlier sprite/name aliases too, otherwise Show could be undone by
    -- legacy migration the next time the plugin reloads.
    for existing in pairs(hidden) do
        if not existing:match(":struct$") and
            self.spriteMaps[book][tonumber(existing:match("^(%d+):"))] == definition then hidden[existing] = nil end
    end
    return self:change(book, hidden)
end

function Books:setAll(book, shown)
    local hidden = {}
    if not shown then
        -- Hide the current choices; retain selections for absent tiers without
        -- pre-hiding future unlocks. Show all remains the whole-book reset.
        for key in pairs(self.filters[book].hiddenIcons) do hidden[key] = true end
        for _, entry in ipairs(self:choicesFor(book)) do hidden[entry.key] = true end
    end
    return self:change(book, hidden)
end

function Books:setLayout(book, mode)
    if mode ~= "default" and mode ~= "fill" and mode ~= "custom" then return false end
    local filter = self.filters[book]
    local ok, order = pcall(Order.ensure, filter.customOrder, self:choicesFor(book))
    if not ok then filter.status = tostring(order); return false end
    return self:change(book, filter.hiddenIcons, mode, order)
end

function Books:editOrder(book, operation, key, before)
    local filter = self.filters[book]
    if filter.layoutMode ~= "custom" then return false end
    local ok, order = pcall(function()
        local order = Order.ensure(filter.customOrder, self:choicesFor(book))
        if operation == "move" then return Order.move(order, key, before) end
        if operation == "remove" then
            assert(Order.kind(key) ~= "prayer", "Only spaces and separators can be removed")
            local result = {}; for _, item in ipairs(order) do if item ~= key then result[#result + 1] = item end end
            return result
        end
        assert(operation == "gap" or operation == "separator", "Invalid layout edit")
        local used = {}; for _, item in ipairs(order) do used[item] = true end
        local number = 1; while used[operation .. ":" .. number] do number = number + 1 end
        order[#order + 1] = operation .. ":" .. number
        return Order.copy(order)
    end)
    if not ok then filter.status = tostring(order); return false end
    return self:change(book, filter.hiddenIcons, "custom", order)
end

-- SECTION 6: Shared spacing and runtime updates
-- Apply one spacing value to both books, detect book switches, and retry capture when
-- the native panel becomes available.
-- A single saved preference drives both books. Only the active native book
-- needs immediate reapplication; failure rolls the shared setting back too.
function Books:setDividerSpacing(value)
    local ok = pcall(Order.spacing, value)
    if not ok then return false end
    if value == self.dividerSpacing then return true end
    if self.active and self:detect() ~= self.active and not self:pause() then return false end
    local previous = self.dividerSpacing
    self.dividerSpacing = value
    for _, filter in pairs(self.filters) do filter.dividerSpacing = value end
    local filter = self.active and self.filters[self.active]
    if filter and filter.valid and filter.layoutMode == "custom" and not filter:recover() then
        self.dividerSpacing = previous
        for _, bookFilter in pairs(self.filters) do bookFilter.dividerSpacing = previous end
        return false
    end
    return true
end

function Books:tick(advanceRecovery)
    local detected = self:detect()
    if detected ~= self.active then
        if not self:pause() then return true end
        if detected then
            self.active = detected
            self.filters[detected]:recover()
        end
        return true
    end
    if not self.active then return false end
    local filter = self.filters[self.active]
    -- Freshly loaded settings have preferences but no live component handles.
    local changed
    if #filter.entries == 0 then
        if not advanceRecovery then return false end
        self.retryTicks = (self.retryTicks or 50) - 1
        if self.retryTicks > 0 then return false end
        self.retryTicks = 50
        changed = filter:recover()
    else changed = filter:tick(advanceRecovery) end
    return changed
end

function Books:open()
    self:tick(true)
end

-- SECTION 7: Prepare the saved record
-- Return preferences for Store to validate and copy. Native component references and
-- temporary editor selection are excluded.
function Books:snapshot()
    local result = {version = 3, dividerSpacing = self.dividerSpacing, prayerBar = self.prayerBar,
        hideActionBarPrayer = self.hideActionBarPrayer, prayerBarStyle = self.prayerBarStyle, prayerBarSide = self.prayerBarSide, prayerCircleCorner = self.prayerCircleCorner, books = {}}
    for _, book in ipairs(ORDER) do
        local filter = self.filters[book]
        result.books[book] = {hiddenIcons = filter.hiddenIcons, ambiguousIcons = filter.ambiguousIcons,
            compact = filter.layoutMode == "fill", layoutMode = filter.layoutMode, customOrder = filter.customOrder, markers = self.markers[book]}
    end
    return result
end

return Books
