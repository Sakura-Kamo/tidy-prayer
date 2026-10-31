-- prayer_order.lua
-- What this file does: Represents custom order as plain strings and calculates rows
-- for prayers, spaces and dividers.
-- How it connects: Books edits these lists. Both the settings editor and native layout
-- use the same row calculations; this file never writes to the game UI.
-- Reading guide: START-HERE.txt lists the numbered sections below.

-- SECTION 1: Spacing limits and layout tokens
-- A token is a saved string: a prayer Struct ID, an upgrade-family ID, a gap number, or
-- a separator number. Validate types, bounds and uniqueness.
local Order = {}
Order.DEFAULT_DIVIDER_SPACING = 17
Order.MAX_DIVIDER_SPACING = 48
function Order.spacing(value)
    assert(type(value) == "number" and value % 1 == 0 and value >= 0
        and value <= Order.MAX_DIVIDER_SPACING, "Invalid divider spacing")
    return value
end
function Order.kind(key)
    if type(key) ~= "string" then return nil end
    if key:match("^%d+:struct$") or key:match("^%d+:family$") then return "prayer" end
    if key:match("^gap:%d+$") then return "gap" end
    if key:match("^separator:%d+$") then return "separator" end
end
function Order.copy(value)
    assert(type(value) == "table", "Invalid custom layout")
    local result, seen, count = {}, {}, 0
    for index, key in pairs(value) do
        assert(type(index) == "number" and index >= 1 and index % 1 == 0 and index <= 256,
            "Invalid layout index")
        assert(Order.kind(key) and not seen[key], "Invalid or duplicate layout entry")
        seen[key], count = true, count + 1
        result[index] = key
    end
    assert(#result == count, "Sparse custom layout")
    for index = 1, count do assert(result[index] ~= nil, "Sparse custom layout") end
    return result
end
function Order.key(entry) return entry.layoutKey or entry.key end

-- SECTION 2: Combine saved order with available prayers
-- Retain saved places for absent prayers while omitting them from current cells. Add
-- newly available entries after existing ones.
function Order.sequence(entries, order, keyOf)
    keyOf = keyOf or Order.key
    local byKey, used, result = {}, {}, {}
    for _, entry in ipairs(entries) do
        local key = keyOf(entry)
        if key then assert(not byKey[key], "Ambiguous custom prayer identity"); byKey[key] = entry end
    end
    for _, key in ipairs(order) do
        local kind = Order.kind(key)
        if kind ~= "prayer" then result[#result + 1] = {key = key, kind = kind}
        elseif byKey[key] then
            result[#result + 1] = {key = key, kind = kind, entry = byKey[key]}; used[key] = true
        end
    end
    for _, entry in ipairs(entries) do
        local key = keyOf(entry)
        assert(key, "Unknown prayer cannot be custom-positioned")
        if not used[key] then
            result[#result + 1] = {key = key, kind = "prayer", entry = entry}; used[key] = true
        end
    end
    return result
end
-- SECTION 3: Add missing entries and move one item
-- Return new lists rather than editing the caller's list. A nil before target means
-- append to the end.
function Order.ensure(order, entries)
    local result, seen = Order.copy(order), {}
    for _, key in ipairs(result) do seen[key] = true end
    for _, entry in ipairs(entries) do
        local key = Order.key(entry)
        if not seen[key] then result[#result + 1] = key; seen[key] = true end
    end
    return Order.copy(result)
end
function Order.move(order, key, before)
    local result, found = {}, false
    if key == before then return Order.copy(order) end
    for _, existing in ipairs(order) do
        if existing == key then found = true else result[#result + 1] = existing end
    end
    assert(found, "Layout item is unavailable")
    local target = #result + 1
    if before then
        target = nil
        for i, existing in ipairs(result) do if existing == before then target = i; break end end
        assert(target, "Drop target is unavailable")
    end
    table.insert(result, target, key)
    return result
end

-- SECTION 4: Plan logical rows and columns
-- Normal items occupy one cell. A separator starts a fresh full-width row and sends the
-- next item to the following row.
function Order.cells(sequence, columns)
    local result, cell = {}, 0
    for _, item in ipairs(sequence) do
        local row, col = math.floor(cell / columns), cell % columns
        if item.kind == "separator" then
            if col > 0 then row = row + 1 end
            result[#result + 1] = {item = item, row = row, col = 0, span = columns}
            cell = (row + 1) * columns
        else
            result[#result + 1] = {item = item, row = row, col = col, span = 1}
            cell = cell + 1
        end
    end
    return result, math.ceil(cell / columns)
end
-- SECTION 5: Convert rows into interface positions
-- Turn row numbers into vertical offsets, including equal padding around each two-unit
-- separator line.
-- Convert logical rows to vertical geometry. Divider padding is shared by both
-- books; a two-unit line has the same requested padding on each side.
function Order.geometry(sequence, columns, pitch, spacing, trailingRowGap)
    spacing = Order.spacing(spacing == nil and Order.DEFAULT_DIVIDER_SPACING or spacing)
    local cells = Order.cells(sequence, columns)
    local offset, bottom, previous = 0, 0, nil
    for _, cell in ipairs(cells) do
        -- Native icons may be shorter than their row pitch. Trim that final
        -- row gap before a divider so its actual upper/lower padding matches.
        if cell.item.kind == "separator" and previous and previous.item.kind ~= "separator" then
            offset = offset - (trailingRowGap or 0)
        end
        cell.y = cell.row * pitch + offset
        cell.height = cell.item.kind == "separator" and 2 + 2 * spacing or pitch
        if cell.item.kind == "separator" then offset = offset + cell.height - pitch end
        bottom = math.max(bottom, cell.y + cell.height)
        previous = cell
    end
    return cells, bottom
end
return Order
