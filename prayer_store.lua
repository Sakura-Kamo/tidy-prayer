-- prayer_store.lua
-- What this file does: Saves and reloads local preferences through PersistentDB,
-- including after plugin unloads.
-- How it connects: main.lua calls load, save and retry. Settings live in PersistentDB;
-- this Lua file contains the storage logic.
-- Reading guide: START-HERE.txt lists the numbered sections below.

-- SECTION 1: Storage key and limits
-- The stable key identifies one local profile. Changing it would stop this code finding
-- the existing saved preferences.
local Order = require("prayer_order")
local Store = {}
Store.__index = Store
local BOOKS = {"prayers", "curses"}
local MAX_KEYS = 256
-- Stable across reloads and logins; PersistentDB isolates this key per plugin.
local SETTINGS_KEY = "tidy-prayer:v1:local"

-- SECTION 2: Validate and copy preferences
-- Reject malformed input and migrate older record formats. Copy nested values so later
-- UI edits cannot alter a pending save.
local function copySet(value, markers)
    assert(type(value) == "table", "Invalid saved icon set")
    local result, count = {}, 0
    for key, enabled in pairs(value) do
        count = count + 1
        assert(count <= MAX_KEYS and type(key) == "string" and #key <= 160
            and enabled == true, "Invalid saved icon entry")
        assert(key:match(markers and "^%d+$" or "^%d+:"), "Invalid saved icon key")
        result[key] = true
    end
    return result
end

-- Validate/copy at the boundary, so the live UI cannot mutate a queued save.
function Store.snapshot(value)
    assert(type(value) == "table" and (value.version == 1 or value.version == 2 or value.version == 3), "Unsupported saved preferences")
    local result = {version = 3, books = {}, dividerSpacing = value.version == 3
        and Order.spacing(value.dividerSpacing) or Order.DEFAULT_DIVIDER_SPACING}
    -- Shared options belong to the whole plugin, not to either book profile.
    assert(value.prayerBar == nil or type(value.prayerBar) == "boolean", "Invalid prayer meter setting")
    result.prayerBar = value.prayerBar == true
    assert(value.hideActionBarPrayer == nil or type(value.hideActionBarPrayer) == "boolean", "Invalid action bar prayer setting")
    result.hideActionBarPrayer = value.hideActionBarPrayer == true
    local style = value.prayerBarStyle
    assert(style == nil or style == "edge" or style == "filter", "Invalid prayer meter style")
    result.prayerBarStyle = style or "edge"
    local side = value.prayerBarSide
    assert(side == nil or side == "left" or side == "bottom" or side == "right" or side == "top",
        "Invalid prayer meter side")
    result.prayerBarSide = side or "left"
    local corner = value.prayerCircleCorner
    assert(corner == nil or corner == "top-left" or corner == "top-right"
        or corner == "bottom-left" or corner == "bottom-right", "Invalid prayer circle corner")
    -- Older settings coupled the circle to the bar; retain that position once.
    result.prayerCircleCorner = corner or (side == "right" and "bottom-right"
        or side == "top" and "top-left" or "bottom-left")
    -- Validate each book separately; keep compact only for compatibility with older saves.
    assert(type(value.books) == "table", "Invalid saved books")
    for _, book in ipairs(BOOKS) do
        local source = value.books[book]
        assert(type(source) == "table" and type(source.compact) == "boolean", "Invalid saved book")
        if value.version >= 2 then
            assert(type(source.layoutMode) == "string" and type(source.customOrder) == "table",
                "Missing saved layout")
        end
        local mode = source.layoutMode or (source.compact and "fill" or "default")
        assert(mode == "default" or mode == "fill" or mode == "custom", "Invalid layout mode")
        result.books[book] = {compact = mode == "fill", layoutMode = mode,
            customOrder = Order.copy(source.customOrder or {}),
            hiddenIcons = copySet(source.hiddenIcons, false),
            ambiguousIcons = copySet(source.ambiguousIcons, false),
            markers = copySet(source.markers, true)}
    end
    return result
end

-- SECTION 3: Compare records and create storage state
-- Compare plain tables by value. saved is the last confirmed record; pending is a record
-- still waiting for a confirmed write.
local function equal(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= "table" then return a == b end
    for k, v in pairs(a) do if not equal(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
end

function Store.new(db)
    return setmetatable({db = db}, Store)
end

-- SECTION 4: Load the saved record
-- Prefer a pending in-memory edit during session recovery; otherwise read PersistentDB.
-- Invalid data returns an error, without replacing it.
function Store:load()
    local ok, result = pcall(function()
        local value = self.pending or self.db:Get(SETTINGS_KEY)
        if value == nil then return nil end
        return Store.snapshot(value)
    end)
    if not ok then return nil, "Saved settings could not be read; existing data was left untouched." end
    if result and not self.pending then self.saved = Store.snapshot(result) end
    return result
end

-- SECTION 5: Write and verify a pending save
-- Read the record back after writing. Only a matching result clears pending; a failure
-- leaves the same record available for retry.
function Store:flush()
    local value = self.pending
    if not value then return true end
    local ok = pcall(function()
        local key = SETTINGS_KEY
        assert(self.db:Set(key, value) ~= false, "Save refused")
        assert(equal(Store.snapshot(self.db:Get(key)), value), "Save read-back differs")
    end)
    if not ok then
        self.error = "Changes are not saved yet. Local storage will retry."
        return false
    end
    self.saved, self.pending, self.error = value, nil, nil
    return true
end

-- SECTION 6: Queue changes and retry failures
-- Skip unchanged confirmed preferences. Copy changed values into pending, then attempt a
-- write; retry repeats that same pending record.
function Store:save(value)
    value = Store.snapshot(value)
    -- A failed write may have changed disk before throwing. Even reverting to
    -- the last confirmed snapshot must be written when a save is pending.
    if not self.pending and equal(value, self.saved) then
        self.pending, self.error = nil, nil
        return true
    end
    self.pending = value
    return self:flush()
end

-- Keep failed edits in memory across logout and retry the same local record.
function Store:retry()
    return self:flush()
end

return Store
