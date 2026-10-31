-- main.lua
-- What this file does: Starts the plugin and connects saved settings, prayer books,
-- the settings window and meters.
-- How it connects: The client runs this file. Event callbacks keep the display
-- updated; PluginShutdown releases it.
-- Reading guide: START-HERE.txt lists the numbered sections below.

-- SECTION 1: Dependencies and shared state
-- Create the storage and meter objects, and the small API adapter used to find native
-- prayer components.
local Catalog = require("prayer_catalog")
local Books = require("prayer_books")
local Definitions = require("prayer_definitions")
local Store = require("prayer_store")
local SelectionUI = require("selection_ui")
local Meter = require("prayer_meter")
local meter = Meter.new(function(interface, staticID)
    return ui.Interfaces:GetComponent(interface, staticID)
end, function()
    return ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__GAME_AREA)
end)
local store = Store.new(PersistentDB)
local api = {
    spriteType = ui.ComponentType.SPRITE, layerType = ui.ComponentType.LAYER,
    get = function(staticID, index)
        if index == nil then return ui.Interfaces:GetComponent(Catalog.INTERFACE, staticID) end
        return ui.Interfaces:GetComponent(Catalog.INTERFACE, staticID, 0, index)
    end,
}
local views, books = {}, nil
local stopped, suspended, opened = false, false, false
local ticks, lastNotice = 0, nil

-- SECTION 2: Messages, windows and saving
-- Keep messages from repeating, refresh open settings views, and pass plain preference
-- snapshots to Store.
local function notice(message)
    if message ~= lastNotice then print("Tidy prayers: " .. message); lastNotice = message end
end

local function destroyView(key)
    local view = views[key]
    if not view then return end
    if view.selection then pcall(function() view.selection:Destroy() end) end
    pcall(function() view.host:Destroy() end)
    views[key] = nil
end

local function refreshViews()
    if books then
        for _, filter in pairs(books.filters) do filter.saveError = store.error end
    end
    for _, view in pairs(views) do
        if view.selection then
            local ok = pcall(function() view.selection:refresh() end)
            if not ok then notice("Settings could not refresh. Reopen Tidy prayers.") end
        end
    end
end

local function save()
    if not books then return end
    local ok, saved = pcall(function() return store:save(books:snapshot()) end)
    -- A successful call either confirms the write or queues its copied record for retry.
    -- Clear the filter flags in either case; a thrown call still needs a fresh snapshot.
    if ok then
        for _, filter in pairs(books.filters) do filter.preferencesChanged = false end
    end
    if not ok or not saved then notice("Changes are not saved yet. Local storage will retry.") end
end

-- Shared callback for settings edits: persist first, then refresh all mounted views.
local function changed()
    save()
    refreshViews()
end

-- SECTION 3: Session loading and restoration
-- Save before releasing native changes. A session starts only after settings,
-- definitions and an earned Prayer level are available.
local function releaseSession()
    save() -- Save before releasing UI; shutdown/logout is not Show all.
    local meterRestored = meter:pause()
    local booksRestored = not books or books:pause()
    if not meterRestored or not booksRestored then
        notice("Restoration is pending. Restart the beta client if it cannot finish.")
        return false
    end
    for _, key in ipairs({"window", "settings", "content"}) do destroyView(key) end
    books, opened = nil, false
    return true
end

-- Capped XP level respects world limits and ignores temporary drains/boosts.
-- No tracking ID or identity permission is read or requested.
local function prayerLevel()
    local ok, level = pcall(function()
        if Player.IsAvailable() then return Player.GetLevelCapped(SkillType.PRAYER) end
    end)
    if ok and type(level) == "number" and level >= 1 and level % 1 == 0 then return level end
    notice("Waiting for your Prayer level. Saved choices are retained.")
end

local function refreshPrayerLevel()
    local level = prayerLevel()
    if level and books:setPrayerLevel(level) then refreshViews() end
end

-- PersistentDB already isolates this plugin's local data. A single profile is
-- deliberately shared by characters on this device; no identity access is needed.
local function loadSession()
    if books then return true end
    local level = prayerLevel()
    if not level then return false end
    local saved, problem = store:load()
    if problem then notice(problem); return false end
    local definitions, definitionProblem = Definitions.read(config)
    if not definitions then notice(definitionProblem); return false end
    api.definitions = definitions
    books = Books.new(api, saved)
    books:setPrayerLevel(level)
    books:open()
    notice(string.format("Local preferences loaded: %d Prayers and %d Curses. Both lists are ready.",
        #books:choicesFor("prayers"), #books:choicesFor("curses")))
    return true
end

-- SECTION 4: Opening the settings window
-- Build one movable window, or show the existing one. Settings and ribbon panels receive
-- a button that opens this window.
local function openWindow()
    if suspended or not books then return false end
    if views.window then views.window.host:Show(); return true end
    local parent = ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__GAME_AREA)
    if not parent then return false end
    books:open()
    local host = prettyui.Window.new(parent, {
        title = "Tidy prayers", x = 40, y = 40,
        width = SelectionUI.WIDTH, height = SelectionUI.HEIGHT, scrollable = false,
        onClose = function()
            if views.window and views.window.selection then views.window.selection:stopEditing() end
        end,
    })
    views.window = {host = host}
    views.window.selection = SelectionUI.new(host, books, changed)
    opened = true
    return true
end

local function mount(key, parent)
    destroyView(key)
    local host = prettyui.SimpleView.new(parent, {width = parent.width, height = parent.height})
    views[key] = {host = host}
    host:AddSimpleButton("Open Tidy prayers", function()
        if not loadSession() then return end
        local ok = pcall(openWindow)
        if not ok then destroyView("window"); notice("Could not open settings.") end
    end)
end

-- SECTION 5: Client events and regular updates
-- Draw maintains the prayer filter and meter hover. Logic processes queued edits and
-- meters; slower retries run every 50 Logic callbacks.
-- Only the active book can write to the native panel. Draw catches replacement
-- handles while Logic advances recovery and local storage retries.
local function updateFilter(advanceRecovery)
    if stopped or suspended or not books then return end
    local displayChanged = books:tick(advanceRecovery)
    -- Discovery can invalidate an ambiguous hidden choice. Save that correction,
    -- but do not copy/validate preferences for ordinary resizes or book switches.
    for _, filter in pairs(books.filters) do
        if filter.preferencesChanged then changed(); return end
    end
    if displayChanged then refreshViews() end
end

Event.Draw.Subscribe("tidy-prayer-draw", function()
    updateFilter(false)
    if not stopped and not suspended then meter:hover() end
end)
Event.Logic.Subscribe("tidy-prayer-logic", function()
    if stopped then return end
    if suspended then meter:pause() end
    ticks = ticks + 1
    if ticks % 50 == 0 then store:retry(); refreshViews() end
    if not books and ticks % 50 ~= 0 then return end
    if suspended or not loadSession() then return end
    if ticks % 50 == 0 then refreshPrayerLevel() end
    for _, view in pairs(views) do
        if view.selection then view.selection:tick() end
    end
    updateFilter(true)
    meter:update(books.prayerBar, books.prayerBarSide, books.prayerCircleCorner, books.prayerBarStyle, books.hideActionBarPrayer)
    books.meterStatus = meter.status
    if not opened and ticks % 50 == 0 then
        local ok = pcall(openWindow)
        if not ok then destroyView("window"); notice("Could not open settings.") end
    end
end)
-- Context menu actions affect only settings copies and local visibility choices.
Event.MiniMenuReady.Subscribe("tidy-prayer-menu", function(event)
    if stopped or suspended then return end
    for _, view in pairs(views) do
        if view.selection then view.selection:prepareMenu(event.miniMenu) end
    end
end)
-- Confirm that a menu actually opened before permitting its queued settings action.
Event.MiniMenuOpened.Subscribe("tidy-prayer-menu-open", function()
    if stopped or suspended then return end
    for _, view in pairs(views) do
        if view.selection then view.selection:menuOpened() end
    end
end)
-- Mount entry buttons in the client-provided settings and ribbon content layers.
Event.SettingsLayerReady.Subscribe("tidy-prayer-settings", function(event) mount("settings", event.component) end)
Event.ContentLayerReady.Subscribe("tidy-prayer-content", function(event) mount("content", event.component) end)
-- Loading/reconnecting pauses native changes; leaving the game releases the session.
Event.GameStateChanged.Subscribe("tidy-prayer-state", function(event)
    if event.newState == GameState.GAME then suspended = false; return end
    suspended = true
    meter:pause()
    if event.newState == GameState.LOADING or event.newState == GameState.RECONNECTING
        or event.newState == GameState.RECONNECTING_FULL or event.newState == GameState.SWITCH_WORLD then
        save()
        if books then books:pause() end
    else
        releaseSession()
    end
    refreshViews()
end)

-- SECTION 6: Plugin shutdown
-- Stop updates, save preferences, restore surviving native components and remove every
-- event subscription.
function PluginShutdown()
    stopped = true
    releaseSession()
    store:retry()
    for _, key in ipairs({"window", "settings", "content"}) do destroyView(key) end
    for _, event in ipairs({"Draw", "Logic", "SettingsLayerReady", "ContentLayerReady", "GameStateChanged", "MiniMenuReady", "MiniMenuOpened"}) do
        local suffix = ({Draw = "draw", Logic = "logic", SettingsLayerReady = "settings",
            ContentLayerReady = "content", GameStateChanged = "state",
            MiniMenuReady = "menu", MiniMenuOpened = "menu-open"})[event]
        Event[event].Unsubscribe("tidy-prayer-" .. suffix)
    end
end

print("Tidy prayers 0.6.26 loaded.")
