-- prayer_filter.lua
-- What this file does: Applies one book's saved hiding choices and asks Layout to
-- arrange the remaining native icons.
-- How it connects: Books owns one Filter per book. Catalog validates native
-- components; Layout owns their positions and scrolling.
-- Reading guide: START-HERE.txt lists the numbered sections below.

-- SECTION 1: Dependencies, retry timing and state
-- hiddenIcons uses saved prayer keys. entries and applied describe live slots; changes
-- records native values that may need restoration.
local Catalog = require("prayer_catalog")
local Layout = require("prayer_layout")
local RECOVERY_TICKS = 50 -- Bounded collection retry; no full UI-tree scans.
local VISIBILITY_CHECK_TICKS = 50 -- Check native visibility masked by this plugin's flags.
local Filter = {}
Filter.__index = Filter

function Filter.new(api)
    return setmetatable({
        api = api,
        entries = {},
        applied = {},
        hiddenIcons = {},
        ambiguousIcons = {},
        changes = {},
        layout = Layout.new(api),
        layoutMode = "default",
        customOrder = {},
        label = api.label or "Curses",
        valid = false,
        status = "Open your " .. (api.label or "Curses") .. " panel to apply your saved choices.",
    }, Filter)
end

function Filter:hasChanges()
    return #self.changes > 0 or self.layout:hasChanges()
end

-- SECTION 2: Release changes and roll back failures
-- Restore layout and visibility before replacing a capture. Keep failed restores for
-- another attempt instead of losing their original values.
function Filter:releaseFlags()
    local positionsRestored = self.layout:restore()
    local pending = {}
    for _, change in ipairs(self.changes) do
        local ok = pcall(function()
            local current = self.api.get(change.staticID, change.index)
            if not current or current ~= change.component then return end
            assert(type(current.hidden) == "boolean", "Visibility unavailable")
            if current.hidden == true then
                current.hidden = change.original
                assert(current.hidden == change.original, "Restore not confirmed")
            end
        end)
        if not ok then pending[#pending + 1] = change end
    end
    self.changes = pending
    if #pending > 0 or not positionsRestored then
        self.valid = false
        self.status = "Restoration is pending. If it does not finish, restart the beta client."
        return false
    end
    self.status = "Original visibility and positions restored for surviving components."
    return true
end

-- Roll back a failed batch without discarding saved visibility preferences.
-- Failed restoration remains owned and blocks replacement writes until retried.
function Filter:rollback()
    self.applied = {}
    self.valid = false
    self.recoveryTicks = 0
    return self:releaseFlags()
end

-- SECTION 3: Match preferences and apply hiding
-- Remember ambiguous identities, hide validated button/glow pairs, then apply Fill
-- spaces or Custom layout if selected.
-- Remember ambiguity within this book: if two entries share an identity,
-- removing one through the native filter must not make the other inherit its
-- old hidden preference. Mark only actual preference changes for saving; ordinary
-- interface recovery changes display state without needing a new snapshot.
function Filter:acceptEntries(entries)
    for _, entry in ipairs(entries) do
        if entry.key and not entry.selectable and not self.ambiguousIcons[entry.key] then
            self.ambiguousIcons[entry.key] = true
            self.preferencesChanged = true
        end
    end
    for _, entry in ipairs(entries) do
        if self.ambiguousIcons[entry.key] then
            if self.hiddenIcons[entry.key] then
                self.hiddenIcons[entry.key] = nil
                self.preferencesChanged = true
            end
            entry.key, entry.selectable = nil, false
        end
    end
    self.entries, self.valid = entries, true
end

-- All callers validate targets first. Save originals before each mutation so a
-- setter failure can roll back the whole batch, including a partially set pair.
function Filter:hideTargets(targets)
    for _, entry in ipairs(targets) do
        -- No yield occurs between validation, restoration and these writes.
        for _, pair in ipairs({{entry.button, Catalog.BUTTONS}, {entry.glow, Catalog.GLOWS}}) do
            local change = {component = pair[1], staticID = pair[2], index = entry.index, original = false}
            self.changes[#self.changes + 1] = change
            local ok = pcall(function()
                change.component.hidden = true
                assert(change.component.hidden == true, "Hide not confirmed")
            end)
            if not ok then
                local restored = self:rollback()
                if restored then self.status = "Apply failed; partial changes were restored." end
                return false
            end
        end
        self.applied[entry.index] = true
    end
    if self.layoutMode == "fill" or self.layoutMode == "custom" then
        local ok, reason = self.layout:apply(self.entries, self.applied,
            self.layoutMode == "custom" and self.customOrder or nil, self.dividerSpacing)
        if not ok then
            if self:rollback() then self.status = "Position change failed; changes restored: " .. reason end
            return false
        end
    end
    self.status = string.format("%d icons hidden. %s", #targets,
        self.layoutMode == "custom" and "Custom layout applied." or (self.layoutMode == "fill" and "Empty spaces filled." or "Original positions kept."))
    return true
end

-- SECTION 4: Pause and recapture the panel
-- Retain preferences when native components disappear or change. Recovery reads fresh
-- entries and reapplies saved keys to their new slots.
function Filter:pause(reason)
    local restored = self:releaseFlags()
    self.valid = false
    self.recoveryTicks = RECOVERY_TICKS
    if restored then self.status = "Filtering paused: " .. reason .. ". Waiting for " .. self.label .. "." end
end

function Filter:recover()
    if not self:releaseFlags() then return false end
    local entries, reason = Catalog.capture(self.api)
    if not entries then
        self.status = "Filtering paused: " .. reason .. ". Choices retained."
        return false
    end
    self:acceptEntries(entries)
    self.applied = {}
    local targets = {}
    for _, entry in ipairs(entries) do
        if entry.key and self.hiddenIcons[entry.key] then
            targets[#targets + 1] = entry
        end
    end
    -- Recovery uses saved identities, never an old slot index.
    return self:hideTargets(targets)
end

-- SECTION 5: Detect changes behind plugin hiding
-- Temporarily release only plugin-owned hiding inside one callback to check whether the
-- game's own filter has changed.
-- `visible` includes both native visibility and Lua's hidden flag. Every 50
-- Logic ticks, briefly release only this plugin's button flag to read the native result, then
-- reinstate it in this same non-yielding callback. This cannot make a natively
-- filtered icon visible. It detects filter changes that retain every handle and
-- affect only icons already hidden by this plugin, without rebuilding/reflowing every tick.
function Filter:nativeFilterChanged(targets)
    for _, entry in ipairs(targets) do
        local button = entry.button
        if button.hidden then
            local read, visible = pcall(function()
                button.hidden = false
                assert(button.hidden == false, "Visibility release not confirmed")
                return button.visible
            end)
            button.hidden = true
            assert(button.hidden == true, "Visibility reinstatement not confirmed")
            assert(read and type(visible) == "boolean", "Native visibility unavailable")
            if not visible then return true end
        elseif not button.visible then
            return true
        end
    end
    return false
end

-- SECTION 6: Maintain the current layout
-- Validate the collection before maintenance writes. Retry only on Logic ticks; restore
-- and recapture after rebuilds, resizes or visibility changes.
function Filter:tick(advanceRecovery)
    if #self.entries == 0 then return false end
    if not self.valid then
        if advanceRecovery == false then return false end
        self.recoveryTicks = (self.recoveryTicks or RECOVERY_TICKS) - 1
        if self.recoveryTicks > 0 then return false end
        self.recoveryTicks = RECOVERY_TICKS
        local previousStatus = self.status
        self:recover()
        return self.status ~= previousStatus or self.valid
    end
    if advanceRecovery ~= false and not Catalog.unchanged(self.api, self.entries, self.applied) then
        self:pause("Native prayer list changed")
        if not self:hasChanges() then self:recover() end
        return true
    end
    -- Check every pair before making any maintenance write. Client
    -- refreshes can clear Lua visibility flags without changing the prayer.
    local targets = {}
    for _, entry in ipairs(self.entries) do
        local ok, reason = Catalog.validate(self.api, entry, true, true)
        if not ok then
            self:pause(reason)
            -- Dragging can replace all handles on consecutive updates.
            -- Try a freshly validated book capture immediately; waiting a
            -- second here leaves every hidden icon visible during a drag.
            -- Failed cleanup must finish before any replacement is written.
            if not self:hasChanges() then self:recover() end
            return true
        end
        if self.applied[entry.index] then targets[#targets + 1] = entry end
    end
    if advanceRecovery ~= false then
        self.visibilityTicks = (self.visibilityTicks or 0) + 1
        if self.visibilityTicks >= VISIBILITY_CHECK_TICKS then
            self.visibilityTicks = 0
            local ok, changed = pcall(function() return self:nativeFilterChanged(targets) end)
            if not ok or changed then
                self:pause(ok and "Native prayer filter changed" or "Native visibility unavailable")
                if not self:hasChanges() then self:recover() end
                return true
            end
        end
    end
    -- Re-read original slots after a native reflow instead of forcing an old
    -- column layout back onto a resized/rebuilt panel.
    if not self.layout:unchanged() then
        self:pause("Prayer positions changed")
        if not self:hasChanges() then self:recover() end
        return true
    end
    local ok = pcall(function()
        self.layout:maintain(self.entries, self.applied)
        for _, entry in ipairs(targets) do
            for _, component in ipairs({entry.button, entry.glow}) do
                if not component.hidden then
                    component.hidden = true
                    assert(component.hidden == true, "Hide not confirmed")
                end
            end
        end
    end)
    if not ok then self:pause("Visibility or scrolling could not be maintained"); return true end
    return false
end

return Filter
