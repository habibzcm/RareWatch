-- RareWatch - Drops: what a rare drops, from the built-in loot data (DropData.lua).
local _, ns = ...

ns.FAMILIES = {
    [1] = "Wolf", [2] = "Cat", [3] = "Spider", [4] = "Bear", [5] = "Boar", [6] = "Crocolisk", [7] = "Carrion Bird",
    [8] = "Crab", [9] = "Gorilla", [11] = "Raptor", [12] = "Tallstrider", [20] = "Scorpid", [21] = "Turtle",
    [24] = "Bat", [25] = "Hyena", [26] = "Owl", [27] = "Wind Serpent",
}
local QUALITY_WORD = { [0] = "poor", "common", "uncommon", "rare", "epic", "legendary" }
local QUALITY_HEX = { [0] = "9d9d9d", "ffffff", "1eff00", "0070dd", "a335ee", "ff8000" }
function ns.QualityHex(q) return QUALITY_HEX[q or 1] or "ffffff" end

function ns.CoinText(c)
    c = math.floor((c or 0) + 0.5)
    local g, s, cc = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
    if g > 0 then return g .. "g" .. (s > 0 and (" " .. s .. "s") or "") end
    if s > 0 then return s .. "s" .. (cc > 0 and (" " .. cc .. "c") or "") end
    return cc .. "c"
end

local function Median(t)
    local n = #t
    if n == 0 then return nil end
    local c = {}
    for i = 1, n do c[i] = t[i] end
    table.sort(c)
    if n % 2 == 1 then return c[(n + 1) / 2] end
    return math.floor((c[n / 2] + c[n / 2 + 1]) / 2)
end

-- Worth of one item: auction price if the Flip addon has scanned it, else what a vendor pays.
-- Returns copper and "AH" or "vendor" (nil if unknown or worthless).
function ns.ItemWorth(id)
    local flip = _G.FlipDB
    local it = flip and flip.items and flip.items[tostring(id)]
    if it and it.p and #it.p > 0 then
        local m = Median(it.p)
        if m and m > 0 then return m, "AH" end
    end
    local d = ns.DROP_ITEMS and ns.DROP_ITEMS[id]
    if d and d[3] and d[3] > 0 then return d[3], "vendor" end
    return nil
end

-- Rows for the drops list: { kind = "gold"|"tame"|"pool"|"item"|"note", ... }
function ns.DropRows(id)
    local e = id and ns.DROPS and ns.DROPS[id]
    if not e then return nil end
    local rows = {}
    local gmin, gmax, fam, items, pools = e[1], e[2], e[3], e[4] or {}, e[5] or {}
    if gmax and gmax > 0 then rows[#rows + 1] = { kind = "gold", min = gmin, max = gmax } end
    if fam and fam > 0 then rows[#rows + 1] = { kind = "tame", family = ns.FAMILIES[fam] or "Beast" } end
    for i = 1, #pools, 3 do
        rows[#rows + 1] = { kind = "pool", pct = pools[i], n = pools[i + 1], q = pools[i + 2] }
    end
    local list = {}
    for i = 1, #items, 3 do
        local iid = items[i]
        local d = ns.DROP_ITEMS[iid]
        if d then list[#list + 1] = { kind = "item", id = iid, name = d[1], q = d[2], pct = items[i + 1], quest = items[i + 2] == 1, seen = items[i + 2] == 2, wh = items[i + 2] == 3 } end
    end
    table.sort(list, function(a, b)
        if a.quest ~= b.quest then return not a.quest end
        if a.q ~= b.q then return a.q > b.q end
        return a.pct > b.pct
    end)
    for _, r in ipairs(list) do rows[#rows + 1] = r end
    return rows
end

-- Does this rare have drop rates measured in Forever (from ForeverDB.net)?
function ns.DropsSeen(id)
    local e = ns.DROPS and ns.DROPS[id]
    local items = e and e[4]
    if not items then return false end
    for i = 3, #items, 3 do if items[i] == 2 or items[i] == 3 then return true end end
    return false
end

function ns.PoolText(p)
    return "Random " .. (QUALITY_WORD[p.q] or "") .. " item"
end

-- Does any drop of this rare match a search string?
local searchCache = {}
function ns.DropMatches(id, q)
    local e = ns.DROPS and ns.DROPS[id]
    if not e or q == "" then return false end
    local s = searchCache[id]
    if not s then
        local parts = {}
        local items = e[4] or {}
        for i = 1, #items, 3 do
            local d = ns.DROP_ITEMS[items[i]]
            if d then parts[#parts + 1] = d[1]:lower() end
        end
        s = table.concat(parts, "\n")
        searchCache[id] = s
    end
    return s:find(q, 1, true) ~= nil
end

function ns.TameFamily(id)
    local e = ns.DROPS and ns.DROPS[id]
    if e and e[3] and e[3] > 0 then return ns.FAMILIES[e[3]] or "Beast" end
end

-- Name of the first drop of this rare matching a search string (lowercase), or nil.
function ns.DropMatchName(id, q)
    local e = ns.DROPS and ns.DROPS[id]
    if not e or q == "" then return nil end
    local items = e[4] or {}
    for i = 1, #items, 3 do
        local d = ns.DROP_ITEMS[items[i]]
        if d and d[1]:lower():find(q, 1, true) then return d[1] end
    end
end
