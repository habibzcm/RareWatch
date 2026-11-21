-- RareWatch - Core: data, detection, sharing, slash commands.
local ADDON_NAME, ns = ...
ns.VERSION = "0.6.5"

local PREFIX  = "RareWatch"
local CHANNEL = "RareWatchSync"
local PROTO   = "3"
ns.CHANNEL = CHANNEL
ns.ICON = "Interface\\Icons\\Ability_Hunter_BeastTaming"

ns.DEFAULT_MOBS = {
    { name = "Humar the Pridelord", id = 5828, min = 8 * 3600, max = 12 * 3600 },
}

ns.SOUNDS = {
    { name = "Raid Warning", id = 8959 },
    { name = "Ready Check",  id = 8960 },
    { name = "Alarm Clock",  id = 12889 },
    { name = "Map Ping",     id = 3175 },
}

local DEFAULT_OPT = {
    alertSound = true, sound = 1, alertRaidWarn = true, alertFlash = true, alertChat = true,
    shareAlerts = true, windowAlert = true, shareGuild = true, decodeSpawn = true,
    showTracker = true, lockTracker = false, trackerScale = 1.0, windowScale = 1.0,
    minimapHide = false, minimapAngle = 200,
    alertAnyRare = true, defaultMin = 6 * 3600, defaultMax = 24 * 3600, plainFont = false,
    shareGroup = true,
}

ns.COLORS = {
    UP    = { 0.35, 1.00, 0.45 },
    OPEN  = { 1.00, 0.82, 0.10 },
    DUE   = { 1.00, 0.55, 0.20 },
    STALE = { 0.75, 0.85, 0.45 },
    WAIT  = { 0.78, 0.80, 0.86 },
    NONE  = { 0.50, 0.52, 0.58 },
}
ns.LABELS = {
    UP = "UP", OPEN = "WINDOW OPEN", DUE = "SHOULD BE UP", STALE = "SEEN EARLIER",
    WAIT = "RESPAWNING", NONE = "NO DATA",
}
local PRIO = { UP = 1, OPEN = 2, DUE = 3, STALE = 4, WAIT = 5, NONE = 9 }

ns.EVENT_INFO = {
    DOWN  = { label = "Killed",  color = { 1.00, 0.45, 0.40 } },
    TAME  = { label = "Tamed",   color = { 0.55, 0.78, 1.00 } },
    SEEN  = { label = "Sighted", color = { 0.35, 1.00, 0.45 } },
    SPAWN = { label = "Spawned", color = { 0.30, 0.90, 0.75 } },
}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
function ns.Now() return GetServerTime() end

function ns.Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff40c78fRareWatch|r " .. tostring(msg))
end

function ns.Dur(s)
    s = math.max(0, math.floor(s or 0))
    local d = math.floor(s / 86400)
    local h = math.floor((s % 86400) / 3600)
    local m = math.floor((s % 3600) / 60)
    if d > 0 then return string.format("%dd %dh", d, h) end
    if h > 0 then return string.format("%dh %02dm", h, m) end
    if m > 0 then return string.format("%dm", m) end
    return string.format("%ds", s)
end

function ns.Clock(t) return date("%H:%M", t) end
function ns.Day(t) return date("%a %H:%M", t) end
function ns.Hours(sec) return string.format("%g", math.floor(sec / 360 + 0.5) / 10) end

local function Key(name) return strtrim(name or ""):lower() end
local AddSample -- defined in the rare-database section below
ns.Key = Key

-- From game build 71037 (20 Nov 2026) every creature carries numbers of its own in its GUID: two creatures
-- standing side by side differ in both the server and the zone part, so no creature number names a layer.
-- In that mode the layer is read once, held, and only read again when the game moves the player.
ns.PRIVATE_BUILD = 71037
local privateMode
function ns.Private()
    if privateMode == nil then
        privateMode = false
        if type(GetBuildInfo) == "function" then
            local ok, _, build = pcall(GetBuildInfo)
            privateMode = (ok and (tonumber(build) or 0) >= ns.PRIVATE_BUILD) and true or false
        end
    end
    return privateMode
end
ns.SharingPaused = ns.Private

-- Creature-0-serverID-instanceID-zoneUID-npcID-spawnUID
-- Returns the npc id, the layer the creature counts for, and the spawn part. On builds where creature numbers
-- are private the layer is the one the player is holding, not the creature's own number.
function ns.ParseGUID(guid)
    if not guid then return end
    local unitType, _, _, _, zoneUID, npcID, spawnUID = strsplit("-", guid)
    if unitType ~= "Creature" and unitType ~= "Vehicle" then return end
    if ns.Private() then return tonumber(npcID), ns.currentLayer, spawnUID end
    return tonumber(npcID), zoneUID, spawnUID
end

-- The numbers a creature carries, as the id a reading is held under.
function ns.RawLayer(guid)
    if not guid then return end
    local unitType, _, server, _, zoneUID = strsplit("-", guid)
    if (unitType ~= "Creature" and unitType ~= "Vehicle") or not server or not zoneUID then return end
    return server .. "-" .. zoneUID
end

-- Low 23 bits of the spawn UID = spawn time (server epoch mod 2^23). Experimental.
local function DecodeSpawnTime(spawnUID)
    if not spawnUID or #spawnUID < 6 or not bit then return end
    local n = tonumber(strsub(spawnUID, 5), 16)
    if not n then return end
    local t = ns.Now()
    local spawn = (t - (t % 2 ^ 23)) + bit.band(n, 0x7fffff)
    if spawn > t then spawn = spawn - 2 ^ 23 end
    local age = t - spawn
    if age < 0 or age > 24 * 3600 then return end
    return spawn
end

---------------------------------------------------------------------------
-- Layers: the game gives a numeric ID; users can attach their own label.
---------------------------------------------------------------------------
local function LetterOf(id)
    return ns.db and ns.db.letters and ns.db.letters[id]
end

-- "<player>.<letter>": another player's layer as they see it (letters are per player, so this is not your layer)
local function Theirs(id)
    if ns.Private() and type(id) == "string" then
        local who, l = id:match("^([%w_%-]+)%.([%w_%-]+)$")
        if who then return who, l end
    end
end

function ns.LayerName(id, long)
    if not id or id == "?" then return "unknown layer" end
    local who, l = Theirs(id)
    if who then return (long and "layer " or "") .. l .. " (" .. who .. "'s)" end
    local label = ns.db and ns.db.layerNames[id]
    if label then return (long and "layer " or "") .. label .. " (" .. id .. ")" end
    local letter = LetterOf(id)
    if letter then return (long and "layer " or "") .. letter .. " (" .. id .. ")" end
    return (long and "layer " or "") .. tostring(id)
end

function ns.LayerShort(id)
    if not id or id == "?" then return "unknown" end
    local who, l = Theirs(id)
    if who then return l .. " (" .. who .. "'s)" end
    return (ns.db and ns.db.layerNames[id]) or LetterOf(id) or tostring(id)
end

-- Turn user input (an ID or a label they assigned) into a layer ID.
function ns.ResolveLayer(input)
    input = input and strtrim(input) or ""
    if input == "" then return nil end
    for id, label in pairs(ns.db.layerNames) do
        if label:lower() == input:lower() then return id end
    end
    for id, letter in pairs(ns.db.letters or {}) do
        if tostring(letter):lower() == input:lower() then return id end
    end
    return input
end

function ns.SetLayerName(id, label)
    if not id or id == "?" then return false, "Your layer isn't known yet - target any NPC first." end
    label = label and strtrim(label) or ""
    if label:find(":") then return false, "Label can't contain ':'." end
    if label == "" then
        ns.db.layerNames[id] = nil
    else
        for otherId, l in pairs(ns.db.layerNames) do
            if otherId ~= id and l:lower() == label:lower() then ns.db.layerNames[otherId] = nil end
        end
        ns.db.layerNames[id] = label
    end
    ns.Changed()
    return true
end

---------------------------------------------------------------------------
-- Change notification (UI subscribes)
---------------------------------------------------------------------------
local listeners = {}
function ns.OnChange(fn) table.insert(listeners, fn) end
function ns.Changed() for _, fn in ipairs(listeners) do fn() end end

-- Same, but merges a burst (a batch from another player) into one refresh.
local changedPending = false
function ns.ChangedSoon()
    if changedPending then return end
    changedPending = true
    C_Timer.After(0.3, function()
        changedPending = false
        ns.Changed()
    end)
end

---------------------------------------------------------------------------
-- Retention: how long a layer's record is kept and shown depends on the rare's own respawn time.
-- (A flat limit threw away long-respawn rares before their window even opened.)
---------------------------------------------------------------------------
local MAX_LAYERS = 40        -- layer records kept per rare
local HISTORY_MAX = 500      -- events kept in History
local MAX_DISCOVERED = 400   -- rares discovered in game, kept in the list

function ns.KeepFor(def)     -- stored this long after the last event
    return math.min(14 * 86400, math.max(7 * 86400, 3 * (def and def.max or 0)))
end
function ns.ShowFor(def)     -- listed this long after the last event (your own layer is always listed)
    return math.min(7 * 86400, math.max(48 * 3600, 2 * (def and def.max or 0) + 12 * 3600))
end

local digestVer = 0
function ns.BumpDigest() digestVer = digestVer + 1 end

local function LatestOf(r) return math.max(r.down or 0, r.seen or 0, r.spawn or 0) end

-- Drop records past their keep time; if a rare has too many layers, drop the stalest.
function ns.PruneDef(def, t)
    t = t or ns.Now()
    local keep, n = ns.KeepFor(def), 0
    for layer, r in pairs(def.layers or {}) do
        if t - LatestOf(r) > keep then def.layers[layer] = nil else n = n + 1 end
    end
    while n > MAX_LAYERS do
        local oldL, oldT
        for layer, r in pairs(def.layers) do
            local l = LatestOf(r)
            if not oldT or l < oldT then oldL, oldT = layer, l end
        end
        if not oldL then break end
        def.layers[oldL] = nil
        n = n - 1
    end
end

---------------------------------------------------------------------------
-- Database
---------------------------------------------------------------------------
function ns.RebuildIndex()
    ns.byId, ns.byName, ns.list = {}, {}, {}
    for key, def in pairs(ns.db.mobs) do
        def.layers = def.layers or {}
        ns.byName[key] = def
        if def.id then ns.byId[def.id] = def end
        table.insert(ns.list, def)
    end
    table.sort(ns.list, function(a, b) return a.name < b.name end)
end

function ns.Lookup(id, name)
    return (id and ns.byId[id]) or (name and ns.byName[Key(name)]) or nil
end

function ns.AddMob(name, id, min, max)
    name = strtrim(name or "")
    if name == "" then return nil, "Enter the mob's name." end
    if name:find(":") then return nil, "The name can't contain ':'." end
    min, max = tonumber(min), tonumber(max)
    if not min or not max then return nil, "Enter the respawn time in hours (min and max)." end
    if min <= 0 or max < min then return nil, "Respawn: min must be above 0 and max must be >= min." end
    if max > 7 * 86400 then return nil, "Respawn max is limited to 7 days." end
    id = tonumber(id)
    if id and (id <= 0 or id ~= math.floor(id)) then return nil, "NPC ID must be a whole number." end
    local key = Key(name)
    local def = ns.db.mobs[key]
    local isNew = not def
    if def then
        def.name, def.min, def.max = name, min, max
        if id then def.id = id end
    else
        def = { name = name, id = id, min = min, max = max, enabled = true, alert = true, layers = {} }
        ns.db.mobs[key] = def
        -- adopt everything recorded while this rare was untracked
        local sh = id and ns.db.shadow and ns.db.shadow[id]
        if sh then
            def.layers, def.samples = sh.layers or {}, sh.samples
            ns.db.shadow[id] = nil
        end
    end
    ns.RebuildIndex()
    digestVer = digestVer + 1
    ns.Changed()
    return def, isNew
end

function ns.RemoveMob(def)
    ns.db.mobs[Key(def.name)] = nil
    -- keep its data so timers survive untracking (and keep sharing it)
    if def.id and ns.RareInfo(def.id) then
        ns.db.shadow[def.id] = { name = def.name, id = def.id, min = def.min, max = def.max, layers = def.layers,
            samples = def.samples, shadow = true, enabled = true, alert = false }
    end
    ns.RebuildIndex()
    digestVer = digestVer + 1
    ns.Changed()
end

function ns.GetRec(def, layer)
    layer = layer or "?"
    local r = def.layers[layer]
    if not r then
        r = {}
        def.layers[layer] = r
        local n = 0
        for _ in pairs(def.layers) do n = n + 1 end
        if n > MAX_LAYERS then ns.PruneDef(def) end
    end
    return r
end

-- The same kill reported again (another player, another layer label) is one history entry.
local function InHistory(h, name, kind, t)
    for i = 1, math.min(#h, 60) do
        local e = h[i]
        if e.n == name and e.k == kind and math.abs((e.t or 0) - t) < 120 then return true end
    end
    return false
end

-- Merge duplicates already saved (keeps the first, newest-first list).
function ns.DedupeHistory()
    local h, out = ns.db.history, {}
    table.sort(h, function(x, y) return (x.t or 0) > (y.t or 0) end)
    for _, e in ipairs(h) do
        local dup = false
        for j = #out, math.max(1, #out - 80), -1 do
            local o = out[j]
            if o.n == e.n and o.k == e.k and math.abs((o.t or 0) - (e.t or 0)) < 120 then dup = true; break end
        end
        if not dup then out[#out + 1] = e end
    end
    ns.db.history = out
end

local function AddHistory(def, kind, layer, t, src)
    local h = ns.db.history
    if InHistory(h, def.name, kind, t) then return end
    table.insert(h, 1, { t = t, k = kind, l = layer, s = src, n = def.name })
    table.sort(h, function(x, y) return (x.t or 0) > (y.t or 0) end)
    for i = #h, HISTORY_MAX + 1, -1 do h[i] = nil end
end

-- Returns true if the event changed what we know.
function ns.ApplyEvent(def, kind, layer, t, src)
    if not def or not t then return false end
    if t > ns.Now() + 120 then return false end
    layer = layer or "?"
    local r = ns.GetRec(def, layer)
    if kind == "DOWN" or kind == "TAME" then
        if r.down and math.abs(r.down - t) < 120 then return false end
        if r.down and t < r.down then return false end
        r.down, r.downKind, r.downSrc = t, kind, src
        r.notifiedOpen = nil
        if r.spawn and r.spawn <= t then r.spawn, r.spawnSrc = nil, nil end
        if r.seen and r.seen <= t then r.seen, r.seenSrc = nil, nil end
        AddHistory(def, kind, layer, t, src)
        digestVer = digestVer + 1
        return true
    elseif kind == "SEEN" then
        if r.down and t <= r.down then return false end
        if r.seen and t < r.seen + 300 then return false end
        local firstSighting = not (r.seen or r.spawn)
        if firstSighting and r.down then AddSample(def, r.down, t, false) end
        r.seen, r.seenSrc = t, src
        if firstSighting then AddHistory(def, kind, layer, t, src) end
        return true
    elseif kind == "SPAWN" then
        if r.down and t <= r.down then return false end
        if r.spawn and math.abs(r.spawn - t) < 60 then return false end
        local first = not r.spawn
        if r.down then AddSample(def, r.down, t, true) end
        r.spawn, r.spawnSrc = t, src
        if first then AddHistory(def, kind, layer, t, src) end
        digestVer = digestVer + 1
        return true
    end
    return false
end

function ns.InitDB()
    RareWatchDB = RareWatchDB or {}
    local db = RareWatchDB
    ns.db = db
    db.opt = db.opt or {}
    for k, v in pairs(DEFAULT_OPT) do
        if db.opt[k] == nil then db.opt[k] = v end
    end
    ns.opt = db.opt
    db.history = db.history or {}
    db.layerNames = db.layerNames or {}
    db.letters = db.letters or {}      -- layer id -> letter, for this login (private-number builds)
    db.discovered = db.discovered or {}
    if db.history and #db.history > 1 then ns.DedupeHistory() end
    db.confirmed = db.confirmed or {}
    db.shadow = db.shadow or {}

    if db.v ~= 2 then
        -- migrate v0.1 data
        local old = db.mobs
        db.mobs = {}
        if db.decodeSpawn ~= nil then db.opt.decodeSpawn = db.decodeSpawn end
        if db.shareAlerts ~= nil then db.opt.shareAlerts = db.shareAlerts end
        if db.hidden ~= nil then db.opt.showTracker = not db.hidden end
        if db.locked ~= nil then db.opt.lockTracker = db.locked end
        if db.pos then db.trackerPos = db.pos end
        db.decodeSpawn, db.shareAlerts, db.hidden, db.locked, db.pos = nil, nil, nil, nil, nil
        db.v = 2
        ns.RebuildIndex()
        for _, d in ipairs(ns.DEFAULT_MOBS) do
            local def = ns.AddMob(d.name, d.id, d.min, d.max)
            local oldRecs = type(old) == "table" and old[d.id]
            if def and type(oldRecs) == "table" then
                for layer, r in pairs(oldRecs) do
                    if type(r) == "table" then def.layers[layer] = r end
                end
            end
        end
    end

    -- prune stale records; reset session-only fields
    local t = ns.Now()
    for _, def in pairs(db.mobs) do
        def.enabled = true -- v0.4 removed the per-mob on/off switch
        if def.alert == nil then def.alert = true end
        def.layers = def.layers or {}
        for _, r in pairs(def.layers) do r.heard = nil end
        ns.PruneDef(def, t)
    end
    for id, def in pairs(db.shadow) do
        def.shadow, def.enabled, def.alert = true, true, false
        def.layers = def.layers or {}
        for _, r in pairs(def.layers) do r.heard = nil end
        ns.PruneDef(def, t)
        if next(def.layers) == nil and not def.samples then db.shadow[id] = nil end
    end
    -- rares found in game that nobody has seen for two months
    for id, d in pairs(db.discovered) do
        if t - (d.last or d.first or 0) > 60 * 86400 then db.discovered[id] = nil end
    end
    ns.RebuildIndex()
    ns.BuildRareIndex()
    for _, d in ipairs(ns.DEFAULT_MOBS) do
        local def = ns.byId[d.id]
        if def and not def.respawnSrc then def.respawnSrc = "database estimate" end
    end
end

---------------------------------------------------------------------------
-- Rare database (built-in Forever list + rares discovered in-game)
---------------------------------------------------------------------------
ns.rareIndex = {}

local function AddDiscoveredInfo(id, d)
    if ns.rareByName then ns.rareByName[Key(d.n)] = id end
    ns.rareIndex[id] = {
        id = id, name = d.n, rank = (d.c == "rareelite") and 2 or 4, minl = d.lv, maxl = d.lv,
        zone = d.z, ui = d.ui, coords = (d.x and d.y) and { d.x, d.y } or nil, discovered = true,
    }
end

ns.rareByName = {}
function ns.BuildRareIndex()
    wipe(ns.rareIndex)
    wipe(ns.rareByName)
    for id, r in pairs(ns.RARE_DB or {}) do
        local z = ns.RARE_ZONES[r[5]]
        ns.rareIndex[id] = {
            id = id, name = r[1], rank = r[2], minl = r[3], maxl = r[4],
            zone = z and z[1], ui = z and z[2], rmin = r[6], rmax = r[7], coords = r[8], builtin = true,
        }
    end
    for id, d in pairs(ns.db.discovered) do
        if not ns.rareIndex[id] then AddDiscoveredInfo(id, d) end
    end
    for id, info in pairs(ns.rareIndex) do ns.rareByName[Key(info.name)] = id end
end

function ns.RareInfo(id) return id and ns.rareIndex[id] end

-- Rares you don't track still get timers: their data lives in "shadow" entries (db.shadow[id]).
function ns.ShadowDef(id, create)
    local d = ns.db.shadow[id]
    if d or not create then return d end
    local info = ns.RareInfo(id)
    if not info then return nil end
    local mn, mx = ns.DefaultRespawn(id)
    d = { name = info.name, id = id, min = mn, max = mx, layers = {}, shadow = true, enabled = true, alert = false }
    ns.db.shadow[id] = d
    return d
end

-- Tracked mob, or the shadow entry for any known rare (created on demand unless create == false).
function ns.LookupAny(id, name, create)
    local def = ns.Lookup(id, name)
    if def then return def end
    if not id and name then id = ns.rareByName[Key(name)] end
    if id then return ns.ShadowDef(id, create ~= false) end
end

function ns.AllDefs()
    local out = {}
    for _, d in ipairs(ns.list) do out[#out + 1] = d end
    for _, d in pairs(ns.db.shadow) do out[#out + 1] = d end
    return out
end

-- When was this rare last seen alive in Forever (by anyone we heard from)?
function ns.LastSeenInForever(id)
    local d = ns.db.discovered[id]
    local best = ns.db.confirmed[id] or (d and d.last)
    local def = ns.LookupAny(id, nil, false)
    if def then
        for _, r in pairs(def.layers) do
            local a = math.max(r.seen or 0, r.spawn or 0)
            if a > 0 and a > (best or 0) then best = a end
        end
    end
    return best
end

function ns.DefaultRespawn(id)
    local info = ns.RareInfo(id)
    if info and info.rmin and info.rmax and info.rmax > 0 then
        return math.max(info.rmin, 60), math.max(info.rmax, info.rmin, 60), "database estimate"
    end
    return ns.opt.defaultMin, math.max(ns.opt.defaultMax, ns.opt.defaultMin), "default guess"
end

function ns.TrackRare(id)
    local info = ns.RareInfo(id)
    if not info then return nil, "Unknown rare." end
    local mn, mx, src = ns.DefaultRespawn(id)
    local def, isNew = ns.AddMob(info.name, id, mn, mx)
    if def and isNew then def.respawnSrc = src end
    return def, isNew
end

-- Measured respawns: one sample per kill/tame, keyed by the kill time.
AddSample = function(def, down, spawnedAt, exact)
    local d = spawnedAt - down
    if d < 60 or d > math.min(14 * 86400, math.max(72 * 3600, 2 * (def.max or 0))) then return end
    def.samples = def.samples or {}
    local old = def.samples[down]
    if old and old.e and not exact then return end
    if old and not old.e and not exact and old.d <= d then return end
    def.samples[down] = { d = d, e = exact or nil }
    local keys = {}
    for k in pairs(def.samples) do keys[#keys + 1] = k end
    if #keys > 40 then
        table.sort(keys)
        for i = 1, #keys - 40 do def.samples[keys[i]] = nil end
    end
end

function ns.SampleStats(def)
    local all, exact = {}, 0
    for _, s in pairs(def.samples or {}) do
        all[#all + 1] = s.d
        if s.e then exact = exact + 1 end
    end
    if #all == 0 then return nil end
    table.sort(all)
    local n = #all
    local med = (n % 2 == 1) and all[(n + 1) / 2] or math.floor((all[n / 2] + all[n / 2 + 1]) / 2)
    return { n = n, exact = exact, min = all[1], max = all[n], median = med }
end

function ns.ApplyMeasured(def)
    local st = ns.SampleStats(def)
    if not st or st.n < 3 then return false, "Need at least 3 measured respawns." end
    def.min, def.max, def.respawnSrc = st.min, math.max(st.max, st.min), "measured"
    ns.Changed()
    return true, string.format("Respawn set to %s - %s from %d measurements.", ns.Dur(st.min), ns.Dur(st.max), st.n)
end

---------------------------------------------------------------------------
-- Status
---------------------------------------------------------------------------
function ns.RecStatus(def, r, t)
    t = t or ns.Now()
    local s = { latest = math.max(r.down or 0, r.seen or 0, r.spawn or 0) }
    if r.seen or r.spawn then
        s.code = (r.seen and t - r.seen < 1800) and "UP" or "STALE"
        if r.seen then
            s.text = "seen " .. ns.Dur(t - r.seen) .. " ago"
            if r.spawn then s.text = s.text .. ", spawned " .. ns.Dur(t - r.spawn) .. " ago" end
            s.src = r.seenSrc
        else
            s.text = "spawned " .. ns.Dur(t - r.spawn) .. " ago"
            s.src = r.spawnSrc
        end
        s.sort = t - (r.seen or r.spawn)
    elseif r.down then
        local el = t - r.down
        s.windowFrom, s.windowTo = r.down + def.min, r.down + def.max
        s.src = r.downSrc
        if el < def.min then
            s.code, s.text, s.sort = "WAIT", "opens in " .. ns.Dur(def.min - el), def.min - el
        elseif el < def.max then
            s.code, s.text, s.sort = "OPEN", "closes in " .. ns.Dur(def.max - el), def.max - el
        else
            s.code, s.text, s.sort = "DUE", "window ended " .. ns.Dur(el - def.max) .. " ago", el - def.max
        end
    else
        s.code, s.text, s.sort = "NONE", "no data", 0
    end
    s.prio = PRIO[s.code]
    return s
end

function ns.Layers(def, withCurrent)
    local t, out = ns.Now(), {}
    local cur = ns.LayerFor(def)
    local show, haveCur = ns.ShowFor(def), false
    for layer, r in pairs(def.layers) do
        local st = ns.RecStatus(def, r, t)
        -- your own layer stays listed however old its record is (until it is pruned)
        if st.latest > 0 and (t - st.latest < show or layer == cur) then
            st.layer, st.rec = layer, r
            table.insert(out, st)
            if layer == cur then haveCur = true end
        end
    end
    if withCurrent and cur and not haveCur then
        table.insert(out, { code = "NONE", text = "no reports yet", prio = 9, sort = 0, latest = 0, layer = cur, rec = {}, empty = true })
    end
    table.sort(out, function(a, b)
        local ac, bc = a.layer == cur, b.layer == cur
        if ac ~= bc then return ac end
        if a.prio ~= b.prio then return a.prio < b.prio end
        return a.sort < b.sort
    end)
    return out
end

local NONE_STATUS = { code = "NONE", text = "no data", prio = 9, sort = 0 }
function ns.Summary(def)
    local L = ns.Layers(def)
    return L[1] or NONE_STATUS, #L
end

---------------------------------------------------------------------------
-- Sharing: automatic, two-way, relayed. Nobody ever has to ask.
--   E  single event         B  batch of events      H  hello: version + summary of what we know
--   D  rare discovered      C  known rare confirmed  R  (manual) resync
---------------------------------------------------------------------------
local queue, queued = {}, {}
local nextSend = 0
local KIND_CODE = { DOWN = "D", TAME = "T", SEEN = "S", SPAWN = "P" }
local CODE_KIND = { D = "DOWN", T = "TAME", S = "SEEN", P = "SPAWN" }

local function Destinations()
    local d = {}
    if ns.opt.shareGuild and IsInGuild() then d[#d + 1] = { "GUILD" } end
    local id = GetChannelName(CHANNEL)
    if id and id > 0 then d[#d + 1] = { "CHANNEL", id } end
    if ns.opt.shareGroup and not IsInInstance() then
        if IsInRaid and IsInRaid() then d[#d + 1] = { "RAID" }
        elseif IsInGroup and IsInGroup() then d[#d + 1] = { "PARTY" } end
    end
    return d
end

-- Paced so we stay under the game's addon-message throttle.
local function Pump()
    if GetTime() < nextSend then return end
    local msg = table.remove(queue, 1)
    if not msg then return end
    queued[msg] = nil
    if msg == "HELLO" then
        -- built at send time so it always describes our current data
        local n, h = ns.Digest()
        msg = table.concat({ "H", PROTO, ns.VERSION, n, h }, ":")
    end
    local dests = Destinations()
    for _, dst in ipairs(dests) do
        pcall(C_ChatInfo.SendAddonMessage, PREFIX, msg, dst[1], dst[2])
    end
    nextSend = GetTime() + math.max(1, 0.8 * #dests)
end

local function Send(msg, urgent)
    if queued[msg] or #queue >= 150 then return end
    queued[msg] = true
    if urgent then table.insert(queue, 1, msg) else table.insert(queue, msg) end
end

-- On private-number builds a layer can't be matched between players, so what travels is the layer as its owner
-- sees it: "<player>.<letter>". Keys that already have that shape (relayed from someone else) pass unchanged.
local function ShareKey(layer)
    if not ns.Private() or not layer or layer == "?" or layer:find(".", 1, true) then return layer end
    local label = tostring(ns.LayerShort(layer)):gsub("[^%w_%-]", ""):sub(1, 8)
    local who = (ns.me or "me"):gsub("[^%w_%-]", ""):sub(1, 12)
    return who .. "." .. (label ~= "" and label or "?")
end

local function Broadcast(def, kind, layer, t, urgent)
    layer = ShareKey(layer)
    Send(table.concat({ "E", PROTO, def.id or 0, def.name, kind, layer or "?", math.floor(t) }, ":"), urgent)
end

function ns.IsSharing()
    return #Destinations() > 0
end

-- Everything worth passing on right now: { def, kind, layer, time, record }.
local function Shareable(t)
    local out = {}
    local function add(def, kind, layer, when, r) out[#out + 1] = { def, kind, layer, when, r } end
    for _, def in ipairs(ns.AllDefs()) do
        for layer, r in pairs(def.layers) do
            local info = ns.RareInfo(def.id)
            local win = math.min(7 * 86400, math.max(def.max or 0, info and info.rmax or 0)) + 6 * 3600
            if r.down and t - r.down < win then add(def, r.downKind or "DOWN", layer, r.down, r) end
            if r.spawn and t - r.spawn < 24 * 3600 then add(def, "SPAWN", layer, r.spawn, r) end
            if r.seen and t - r.seen < 6 * 3600 then add(def, "SEEN", layer, r.seen, r) end
        end
    end
    return out
end

local function Hash(str)
    local h = 5381
    for i = 1, #str do h = (h * 33 + str:byte(i)) % 4294967296 end
    return h
end

-- Short summary of our kills/tames/spawns. Peers compare it with theirs to notice missing data.
-- (Sightings are left out: they change every few minutes and would cause constant resyncs.)
-- The window is the rare's built-in respawn, not the local setting, so users who edited their timers still agree.
-- The result is cached: it only changes when our data does (or as events age out, so at most a minute stale).
local digestCache
function ns.Digest()
    local now = GetTime()
    if digestCache and digestCache.ver == digestVer and now - digestCache.at < 60 then
        return digestCache.n, digestCache.h
    end
    local t, keys = ns.Now(), {}
    for _, e in ipairs(Shareable(t)) do
        if e[2] ~= "SEEN" then
            local info = ns.RareInfo(e[1].id)
            local win = math.min(7 * 86400, (info and info.rmax) or (12 * 3600)) + 6 * 3600
            if t - e[4] < win then
                keys[#keys + 1] = (e[1].id or e[1].name) .. "/" .. ShareKey(e[3]) .. "/" .. KIND_CODE[e[2]] .. "/" .. math.floor(e[4] / 600)
            end
        end
    end
    table.sort(keys)
    local n, h = #keys, Hash(table.concat(keys, ";"))
    digestCache = { ver = digestVer, at = now, n = n, h = h }
    return n, h
end

local function SendDiscoveries(t)
    local m = 0
    for id, d in pairs(ns.db.discovered) do
        if m < 20 and d.last and t - d.last < 7 * 86400 then
            Send(table.concat({ "D", PROTO, id, d.n, d.c, d.z or "?", d.ui or 0, d.x or 0, d.y or 0, d.lv or 0, d.last }, ":"))
            m = m + 1
        end
    end
    for id, ct in pairs(ns.db.confirmed) do
        if m < 40 and t - ct < 7 * 86400 then
            Send(table.concat({ "C", PROTO, id, ct }, ":"))
            m = m + 1
        end
    end
end

-- Send what we know that nobody else has sent since `since` (relays other players' data too).
local function Push(since)
    local t = ns.Now()
    local list = {}
    for _, e in ipairs(Shareable(t)) do
        if (e[5].heard or 0) < since then list[#list + 1] = e end
    end
    table.sort(list, function(a, b) return a[4] > b[4] end)
    local batch, len = {}, 0
    local function flush()
        if #batch > 0 then Send("B:" .. PROTO .. ":" .. table.concat(batch, ";")) end
        batch, len = {}, 0
    end
    for i = 1, math.min(#list, 150) do
        local e = list[i]
        local def = e[1]
        if def.id then
            local item = def.id .. "/" .. KIND_CODE[e[2]] .. "/" .. ShareKey(e[3]) .. "/" .. math.floor(e[4])
            if len + #item + 1 > 225 then flush() end
            batch[#batch + 1] = item
            len = len + #item + 1
        else
            Broadcast(def, e[2], e[3], e[4])
        end
        e[5].heard = GetTime()
    end
    flush()
    SendDiscoveries(t)
    ns.lastPushAt = GetTime()
end

local pushPending, lastPush = false, -1000
local function SchedulePush()
    if pushPending or GetTime() - lastPush < 45 then return end
    pushPending = true
    local since = GetTime()
    C_Timer.After(2 + math.random() * 8, function()
        pushPending = false
        lastPush = GetTime()
        Push(since)
    end)
end

-- Hello: who we are, our version, and a summary of our data.
ns.peers = {}
local lastHello = -1000
local function SendHello()
    Send("HELLO")
    lastHello = GetTime()
end
ns.SendHello = SendHello

function ns.OnlineUsers()
    local n, now = 0, GetTime()
    for who, p in pairs(ns.peers) do
        if now - p.t < 900 then n = n + 1
        elseif now - p.t > 3600 then ns.peers[who] = nil end
    end
    return n
end

function ns.SyncNow()
    SendHello()
    Send("R:" .. PROTO)
    SchedulePush()
end
ns.RequestSync = ns.SyncNow

-- The sync channel only carries addon data. We never touch the chat windows (editing them
-- can taint the UI and trigger "blocked from an action" warnings); we just hide its join notices.
local function ChannelNoticeFilter(_, _, ...)
    local name = select(4, ...)
    local ok, hide = pcall(function()
        return type(name) == "string" and name:find(CHANNEL, 1, true) ~= nil
    end)
    return ok and hide or false
end
if ChatFrame_AddMessageEventFilter then
    pcall(ChatFrame_AddMessageEventFilter, "CHAT_MSG_CHANNEL_NOTICE", ChannelNoticeFilter)
    pcall(ChatFrame_AddMessageEventFilter, "CHAT_MSG_CHANNEL_NOTICE_USER", ChannelNoticeFilter)
end
function ns.HideChannel() end

-- Joining a channel needs a click or key press, so this only runs from one.
-- After the first join the game keeps you in the channel on every login.
function ns.SetChannel(on)
    ns.opt.channelConsent = on and true or false
    if on then
        if GetChannelName(CHANNEL) == 0 then JoinPermanentChannel(CHANNEL) end
    else
        if GetChannelName(CHANNEL) > 0 then LeaveChannelByName(CHANNEL) end
    end
    C_Timer.After(1.5, function()
        if GetChannelName(CHANNEL) > 0 then
            ns.HideChannel()
            ns.SyncNow()
        end
        ns.Changed()
    end)
end

-- Called from click/key-press handlers: quietly rejoin if the player agreed to share before.
function ns.EnsureChannel()
    if ns.opt and ns.opt.channelConsent and GetChannelName(CHANNEL) == 0 and not ns.joining then
        ns.joining = true
        JoinPermanentChannel(CHANNEL)
        C_Timer.After(1.5, function()
            ns.joining = false
            if GetChannelName(CHANNEL) > 0 then ns.HideChannel(); ns.SyncNow() end
            ns.Changed()
        end)
    end
end

---------------------------------------------------------------------------
-- Alerts
---------------------------------------------------------------------------
function ns.PlayAlertSound(idx)
    local s = ns.SOUNDS[idx or ns.opt.sound] or ns.SOUNDS[1]
    pcall(PlaySound, s.id, "Master")
end

-- Big text on screen: our own frame, so we never call Blizzard's raid-warning code (which can get us blocked).
local bigFrame, bigTimer
function ns.BigText(text)
    if not bigFrame then
        bigFrame = CreateFrame("Frame", nil, UIParent)
        bigFrame:SetSize(800, 60)
        bigFrame:SetPoint("TOP", UIParent, "TOP", 0, -170)
        bigFrame:SetFrameStrata("FULLSCREEN_DIALOG")
        bigFrame.text = bigFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
        bigFrame.text:SetPoint("CENTER")
        bigFrame.text:SetTextColor(1, 0.82, 0.2)
        bigFrame:Hide()
    end
    bigFrame.text:SetText(text)
    bigFrame:SetAlpha(1)
    bigFrame:Show()
    bigTimer = (bigTimer or 0) + 1
    local mine = bigTimer
    C_Timer.After(4, function()
        if mine == bigTimer then bigFrame:Hide() end
    end)
end

function ns.Alert(text)
    local o = ns.opt
    if o.alertRaidWarn then ns.BigText(text) end
    if o.alertSound then ns.PlayAlertSound() end
    if o.alertFlash and FlashClientIcon then FlashClientIcon() end
    if o.alertChat then ns.Print(text) end
end

-- Record something WE observed: store, share, notify UI.
local function Record(def, kind, layer, t)
    if ns.ApplyEvent(def, kind, layer, t, "you") then
        ns.GetRec(def, layer).heard = GetTime()
        Broadcast(def, kind, layer, t, true)
        if (kind == "DOWN" or kind == "TAME") and not def.shadow then
            ns.Print(string.format("%s %s on layer %s. Next window: %s - %s.", def.name,
                kind == "TAME" and "tamed" or "killed", ns.LayerName(layer),
                ns.Day(t + def.min), ns.Day(t + def.max)))
        end
        ns.Changed()
    end
end

function ns.ManualLog(def, kind, mins, layerInput)
    mins = tonumber(mins or "") or 0
    if mins < 0 or mins > 2880 then return false, "Minutes ago must be between 0 and 2880." end
    local layer = ns.ResolveLayer(layerInput) or ((mins == 0) and ns.LayerFor(def)) or "?"
    if layer:find("[:/;]") then return false, "Invalid layer." end
    local t = ns.Now() - math.floor(mins * 60)
    if ns.ApplyEvent(def, kind, layer, t, "manual") then
        ns.GetRec(def, layer).heard = GetTime()
        Broadcast(def, kind, layer, t, true)
        ns.Changed()
        return true, string.format("Logged %s on layer %s at %s.",
            ns.EVENT_INFO[kind].label:lower(), ns.LayerName(layer), ns.Day(t))
    end
    return false, "Nothing changed - duplicate, or older than what's already known."
end

---------------------------------------------------------------------------
-- Detection
---------------------------------------------------------------------------
local lastGUID, lastSeenAt, alerted, pendingTame = {}, {}, {}, {}
local lastPetName, TAME_NAME

-- Layer IDs come from creature GUIDs and differ per zone, so remember them per map.
ns.layerByMap = {}
local function PlayerMap()
    if C_Map and C_Map.GetBestMapForUnit then
        local ok, map = pcall(C_Map.GetBestMapForUnit, "player")
        if ok then return map end
    end
end
ns.PlayerMap = PlayerMap

local function SetCurrentLayer(layer)
    if not layer then return end
    local map = PlayerMap()
    if map then ns.layerByMap[map] = layer end
    if layer ~= ns.currentLayer then
        ns.currentLayer = layer
        ns.currentLayerZone = GetRealZoneText and GetRealZoneText() or nil
        ns.Changed()
    end
end

-- Private-number builds (see ns.Private). How a layer is known there, following what the game tells us:
--   * a creature read when nothing is held sets the layer, and it is then held: later creatures never replace it;
--   * SHARD_TRANSFER (the game moved the player) and ZONE_CHANGED_NEW_AREA (a zone border) make it unknown again;
--   * creatures that were in view at such a moment belong to the layer or zone just left, so they are not read;
--     after a move a creature that was NOT in view counts once SHARD_QUIET has passed, any creature after STALE_FOR;
--     after a border nothing is read for BORDER_QUIET;
--   * a /reload keeps the layer (saved at logout, restored within KEPT_AGE seconds); a login starts from nothing.
ns.layerStale = true
local SHARD_QUIET, STALE_FOR, BORDER_QUIET, KEPT_AGE = 3, 10, 15, 120
local shardAt, borderAt, loginAt = -1000, -1000, GetTime()
local shardSeen, borderSeen = {}, {}
local lastTouch = 0

local function LetterFor(n)
    if n <= 26 then return string.char(64 + n) end
    return tostring(n)
end

-- Every creature unit the client shows right now, by GUID.
local function InView()
    local seen = {}
    local function add(unit)
        local ok, g = pcall(UnitGUID, unit)
        if ok and type(g) == "string" and not (issecretvalue and issecretvalue(g)) then seen[g] = true end
    end
    for i = 1, 40 do add("nameplate" .. i) end
    add("target"); add("mouseover")
    return seen
end

local function Adopt(id)
    local map = PlayerMap()
    ns.layerStale = false
    if map then ns.layerByMap[map] = id end
    if not ns.db.letters[id] then
        ns.db.letterN = (ns.db.letterN or 0) + 1
        ns.db.letters[id] = LetterFor(ns.db.letterN)
    end
    if id ~= ns.currentLayer then
        ns.currentLayer = id
        ns.currentLayerZone = GetRealZoneText and GetRealZoneText() or nil
        ns.Changed()
    end
end

-- Returns true when a layer is held and may be used for this creature's record.
function ns.ReadLayer(unit, guid)
    if ns.currentLayer and not ns.layerStale then return true end
    local now = GetTime()
    local sinceShard = now - shardAt
    local calm = (sinceShard >= STALE_FOR or (sinceShard >= SHARD_QUIET and not shardSeen[guid]))
        and now - borderAt >= BORDER_QUIET and not borderSeen[guid]
    if not calm then return false end
    -- a player's own summons carry the place they were made, not the player's layer
    if type(UnitPlayerControlled) == "function" then
        local ok, pc = pcall(function() return UnitPlayerControlled(unit) == true end)
        if ok and pc then return false end
    end
    local id = ns.RawLayer(guid)
    if not id then return false end
    Adopt(id)
    return true
end

local function Forget()
    ns.currentLayer, ns.layerStale = nil, true
    ns.Changed()
end

-- The game moved the player to another layer.
function ns.LayerMoved()
    shardAt, shardSeen = GetTime(), InView()
    Forget()
end

-- A zone border: the world around the player is another zone's now. Within seconds of a login it is no border.
function ns.LayerBorder()
    if GetTime() - loginAt >= 10 then
        borderAt, borderSeen = GetTime(), InView()
    end
    Forget()
end

-- Saved when the interface is torn down, so a /reload can pick the layer up again.
function ns.LayerSave()
    ns.db.held = ns.currentLayer and { id = ns.currentLayer, zone = GetRealZoneText and GetRealZoneText() or nil,
        at = time(), who = ns.me } or nil
end

local function Restore()
    local k = ns.db.held
    if not k or ns.currentLayer then return end
    if GetTime() - loginAt > 10 then ns.db.held = nil; return end
    if type(k.at) ~= "number" or time() - k.at > KEPT_AGE or k.who ~= ns.me then ns.db.held = nil; return end
    local zone = GetRealZoneText and GetRealZoneText()
    if type(zone) ~= "string" or zone == "" or zone ~= k.zone then return end    -- not named yet: tried again
    ns.currentLayer, ns.layerStale = k.id, false
    ns.currentLayerZone = zone
    local map = PlayerMap()
    if map then ns.layerByMap[map] = k.id end
    ns.Changed()
end

-- A loading screen. A login starts from nothing, a /reload keeps the layer, any other one changes nothing
-- (a zone border or a move has its own event).
function ns.LayerWorldEntered(isLogin, isReload)
    if isLogin or isReload then loginAt = GetTime() end
    if isLogin then
        ns.currentLayer, ns.layerStale = nil, true
        ns.db.held = nil
        ns.db.letters, ns.db.letterN = {}, 0
    elseif isReload then
        ns.layerStale = ns.currentLayer == nil
        Restore()
        C_Timer.After(2, Restore)
    end
end

-- Your layer in the zone where this mob lives (nil if you haven't been there this session).
function ns.LayerFor(def)
    if not def then return nil end
    local info = ns.RareInfo(def.id)
    local map = (info and info.ui) or def.ui
    if map then return ns.layerByMap[map] end
    return ns.currentLayer
end

local function PlayerPos()
    if not (C_Map and C_Map.GetBestMapForUnit) then return end
    local ok, map = pcall(C_Map.GetBestMapForUnit, "player")
    if not ok or not map then return end
    local zone
    if C_Map.GetMapInfo then
        local info = C_Map.GetMapInfo(map)
        zone = info and info.name
    end
    local x, y
    local ok2, pos = pcall(C_Map.GetPlayerMapPosition, map, "player")
    if ok2 and pos and pos.x then x, y = pos.x * 100, pos.y * 100 end
    return map, zone, x and math.floor(x * 10 + 0.5) / 10, y and math.floor(y * 10 + 0.5) / 10
end

local function BroadcastDiscovery(id, d)
    Send(table.concat({ "D", PROTO, id, d.n, d.c, d.z or "?", d.ui or 0, d.x or 0, d.y or 0, d.lv or 0, d.last }, ":"), true)
end

-- A rare seen alive: confirm a known one, or record a brand-new one.
local function Discover(unit, npcId, guid)
    local class = UnitClassification(unit)
    if class ~= "rare" and class ~= "rareelite" then return end
    local t = ns.Now()
    if ns.RARE_DB and ns.RARE_DB[npcId] then
        local first = not ns.db.confirmed[npcId]
        if first or t - ns.db.confirmed[npcId] > 300 then
            ns.db.confirmed[npcId] = t
            Send(table.concat({ "C", PROTO, npcId, t }, ":"))
            if first then ns.Changed() end
        end
    else
        local d = ns.db.discovered[npcId]
        if not d then
            local map, zone, x, y = PlayerPos()
            d = { n = UnitName(unit) or "?", c = class, lv = UnitLevel(unit), z = zone, ui = map, x = x, y = y,
                first = t, last = t, src = "you" }
            if d.n:find(":") then return end
            local count = 0
            for _ in pairs(ns.db.discovered) do count = count + 1 end
            if count >= MAX_DISCOVERED then return end
            ns.db.discovered[npcId] = d
            AddDiscoveredInfo(npcId, d)
            ns.Print("New rare found: " .. d.n .. (zone and (" in " .. zone) or "") .. " - added to the Browse list.")
            BroadcastDiscovery(npcId, d)
            ns.Changed()
        elseif t - (d.last or 0) > 300 then
            d.last = t
            BroadcastDiscovery(npcId, d)
        end
    end
    if ns.opt.alertAnyRare and not alerted[guid] and not ns.Lookup(npcId, UnitName(unit)) then
        alerted[guid] = true
        ns.Alert((UnitName(unit) or "Rare") .. " spotted  (not tracked)")
    end
end

-- Kill detection without the combat log: a tracked mob we can see is dead.
-- Only counts if our latest info says it was alive (avoids re-logging an old corpse).
local deadSeen = {}
local function CheckDeath(unit, guid, npcId, layer)
    if deadSeen[guid] then return end
    local def = ns.LookupAny(npcId, UnitName(unit))
    if not def then return end
    deadSeen[guid] = true
    for u in pairs(ns.watched) do if UnitGUID(u) == guid then ns.watched[u] = nil end end
    local r = def.layers[layer or "?"]
    local aliveAt = r and math.max(r.seen or 0, r.spawn or 0) or 0
    if r and r.down and r.down >= aliveAt then return end
    ns.deathFromUnit = (ns.deathFromUnit or 0) + 1
    Record(def, "DOWN", layer, ns.Now())
end

-- RareWatch is for the open world: inside dungeons, raids and battlegrounds the elites are not world rares, and
-- the client restricts what addons may read there.
local function InInstance()
    local inside, kind = IsInInstance()
    return inside and kind ~= nil and kind ~= "none"
end

ns.watched = {}   -- nameplate units showing a known rare: polled for death (cheaper than listening to every unit's health)

local function CheckUnit(unit)
    if InInstance() then return end
    if not UnitExists(unit) then return end
    local guid = UnitGUID(unit)
    local npcId, layer, spawnUID = ns.ParseGUID(guid)
    if not npcId then return end
    if ns.Private() then
        -- the layer is held, not read off every creature; with none held yet there is nothing to file a record under
        if IsInInstance() or not ns.ReadLayer(unit, guid) then return end
        layer = ns.currentLayer
    elseif not IsInInstance() then
        SetCurrentLayer(layer)
    end

    if UnitIsDead(unit) then
        CheckDeath(unit, guid, npcId, layer)
        return
    end
    Discover(unit, npcId, guid)
    local def = ns.Lookup(npcId, UnitName(unit))
    local tracked = def ~= nil
    if not def then
        local class = UnitClassification(unit)
        if class == "rare" or class == "rareelite" or (ns.RARE_DB and ns.RARE_DB[npcId]) then
            def = ns.LookupAny(npcId, UnitName(unit))
        end
    end
    if not def or not def.enabled then return end
    if not def.id then def.id = npcId; ns.RebuildIndex() end

    if unit:find("^nameplate") then ns.watched[unit] = true end
    lastGUID[def.name] = guid
    lastSeenAt[def.name] = GetTime()
    if not def.ui and not ns.RareInfo(npcId) then def.ui = PlayerMap() end
    Record(def, "SEEN", layer, ns.Now())
    if ns.opt.decodeSpawn then
        local sp = DecodeSpawnTime(spawnUID)
        if sp then Record(def, "SPAWN", layer, sp) end
    end
    if tracked and not alerted[guid] and def.alert then
        alerted[guid] = true
        ns.Alert(def.name .. " is UP  (layer " .. ns.LayerShort(layer) .. ")")
    end
end

local function OnCombatLog()
    local _, sub, _, _, _, _, _, destGUID, destName, _, _, _, spellName = CombatLogGetCurrentEventInfo()
    if sub == "UNIT_DIED" or sub == "PARTY_KILL" then
        local npcId, layer = ns.ParseGUID(destGUID)
        if not npcId then return end
        local def = ns.LookupAny(npcId, destName)
        if def then
            pendingTame[destGUID] = nil
            Record(def, "DOWN", layer, ns.Now())
        end
    elseif TAME_NAME and spellName == TAME_NAME then
        local npcId, layer = ns.ParseGUID(destGUID)
        if not npcId then return end
        local def = ns.LookupAny(npcId, destName)
        if not def then return end
        if sub == "SPELL_AURA_APPLIED" then
            pendingTame[destGUID] = { start = GetTime(), def = def, layer = layer }
        elseif sub == "SPELL_AURA_REMOVED" then
            local p = pendingTame[destGUID]
            pendingTame[destGUID] = nil
            if p and GetTime() - p.start >= 18 then Record(p.def, "TAME", p.layer, ns.Now()) end
        end
    end
end

local function OnPetChanged()
    local name = UnitName("pet")
    local def = name and ns.LookupAny(nil, name)
    if def and name ~= lastPetName and lastSeenAt[def.name] and GetTime() - lastSeenAt[def.name] < 120 then
        local _, layer = ns.ParseGUID(lastGUID[def.name])
        Record(def, "TAME", layer or ns.currentLayer, ns.Now())
    end
    lastPetName = name
end

-- Announce when a respawn window opens.
local function CheckWindows()
    if not ns.opt.windowAlert then return end
    local t = ns.Now()
    for _, def in ipairs(ns.list) do
        if def.enabled then
            for layer, r in pairs(def.layers) do
                if r.down and not r.seen and not r.spawn and r.notifiedOpen ~= r.down then
                    local el = t - r.down
                    if el >= def.min and el < def.min + 300 then
                        r.notifiedOpen = r.down
                        ns.Print(string.format("Respawn window for %s just opened on layer %s (closes in %s).",
                            def.name, ns.LayerName(layer), ns.Dur(def.max - el)))
                        if ns.opt.alertSound then ns.PlayAlertSound() end
                    elseif el >= def.min + 300 then
                        r.notifiedOpen = r.down
                    end
                end
            end
        end
    end
end

---------------------------------------------------------------------------
-- Incoming messages
---------------------------------------------------------------------------
local lastReply = 0

local function VersionNum(v)
    local a, b, c = tostring(v or ""):match("^(%d+)%.(%d+)%.?(%d*)")
    return (tonumber(a) or 0) * 10000 + (tonumber(b) or 0) * 100 + (tonumber(c) or 0)
end

-- One event from another player (tracked or not). Returns true if it changed anything.
local function ValidLayer(l)
    return type(l) == "string" and #l <= 24 and (l == "?" or l:match("^[%w%._%-]+$") ~= nil)
end

local function ApplyRemote(id, name, kind, layer, t, who)
    if not ns.EVENT_INFO[kind] or not t or not ValidLayer(layer) then return false end
    if ns.Private() and not layer:match("^[%w_%-]+%.[%w_%-]+$") then layer = "?" end   -- only "<player>.<letter>" is understood here
    if t < ns.Now() - 14 * 86400 then return false end
    local def = ns.LookupAny(id, name)
    if not def then return false end
    if not def.id and id then def.id = id; ns.RebuildIndex() end
    local changed = ns.ApplyEvent(def, kind, layer, t, who)
    ns.GetRec(def, layer).heard = GetTime()
    if changed and not def.shadow then
        local age = ns.Now() - t
        if (kind == "SEEN" or kind == "SPAWN") and age < 600 then
            if ns.opt.shareAlerts and def.alert then ns.PlayAlertSound() end
            ns.Print(string.format("%s reports %s UP%s.", who, def.name, " on " .. ns.LayerName(layer, true)))
        elseif (kind == "DOWN" or kind == "TAME") and age < 3600 then
            ns.Print(string.format("%s reports %s %s%s (%s ago).", who, def.name,
                kind == "TAME" and "tamed" or "killed", " on " .. ns.LayerName(layer, true), ns.Dur(age)))
        end
    end
    return changed
end

local function OnAddonMessage(prefix, msg, _, sender)
    if prefix ~= PREFIX or not sender then return end
    if sender == ns.me or sender == ns.meFull then return end
    local who = Ambiguate(sender, "short")
    local tag, ver, a, b, c, d, e = strsplit(":", msg)
    if ver ~= PROTO then return end
    local peer = ns.peers[who]
    if peer then peer.t = GetTime() else peer = { t = GetTime() }; ns.peers[who] = peer end
    -- one sender can't flood us: a burst of 40 messages, then 2 per second
    local now = GetTime()
    peer.tok = math.min(40, (peer.tok or 40) + (now - (peer.tt or now)) * 2)
    peer.tt = now
    if peer.tok < 1 then return end
    peer.tok = peer.tok - 1

    if tag == "E" then
        local id = tonumber(a)
        if id == 0 then id = nil end
        if ApplyRemote(id, b, c, d, tonumber(e), who) then ns.ChangedSoon() end
    elseif tag == "B" then
        local body = msg:match("^B:[^:]+:(.*)$") or ""
        local changed, items = false, 0
        for item in body:gmatch("[^;]+") do
            items = items + 1
            if items > 30 then break end
            local id, code, layer, t = strsplit("/", item)
            if ApplyRemote(tonumber(id), nil, CODE_KIND[code or ""], layer, tonumber(t), who) then changed = true end
        end
        if changed then ns.ChangedSoon() end
    elseif tag == "H" then
        local version, theirHash = a, tonumber(c)
        ns.peers[who].v = version
        if VersionNum(version) > VersionNum(ns.VERSION) and not ns.newerVersion then
            ns.newerVersion = version
            ns.Print("A newer version of RareWatch (" .. version .. ") is out - update to stay in sync.")
        end
        local _, myHash = ns.Digest()
        if theirHash ~= myHash then
            -- We know different things: send ours, and say hello back so they send theirs.
            SchedulePush()
            if GetTime() - lastHello > 30 then C_Timer.After(1 + math.random() * 3, SendHello) end
        end
        ns.ChangedSoon()
    elseif tag == "C" then
        local id, t = tonumber(a), tonumber(b)
        if id and t and t <= ns.Now() + 120 and ns.RARE_DB and ns.RARE_DB[id] then
            if not ns.db.confirmed[id] or ns.db.confirmed[id] < t then
                local first = not ns.db.confirmed[id]
                ns.db.confirmed[id] = t
                if first then ns.ChangedSoon() end
            end
        end
    elseif tag == "D" then
        local _, _, id, name, class, zone, ui, x, y, lv, t = strsplit(":", msg)
        id, t = tonumber(id), tonumber(t)
        if not id or not t or not name or name == "" or t > ns.Now() + 120 then return end
        if class ~= "rare" and class ~= "rareelite" then return end
        if id < 1 or id > 10000000 or #name > 40 then return end
        if ns.RARE_DB and ns.RARE_DB[id] then
            if not ns.db.confirmed[id] or ns.db.confirmed[id] < t then ns.db.confirmed[id] = t end
            return
        end
        local dd = ns.db.discovered[id]
        if not dd then
            -- new rares are rare: cap how many one player can add, and how many we keep in total
            if (ns.Now() - (peer.dWin or 0)) > 600 then peer.dWin, peer.dN = ns.Now(), 0 end
            peer.dN = (peer.dN or 0) + 1
            if peer.dN > 5 then return end
            local count = 0
            for _ in pairs(ns.db.discovered) do count = count + 1 end
            if count >= MAX_DISCOVERED then return end
            x, y = tonumber(x), tonumber(y)
            dd = { n = name, c = class, lv = math.min(tonumber(lv) or 0, 90), z = (zone ~= "?" and zone and zone:sub(1, 40)) or nil, ui = tonumber(ui),
                x = (x and x > 0) and x or nil, y = (y and y > 0) and y or nil, first = t, last = t, src = who }
            if dd.ui == 0 then dd.ui = nil end
            ns.db.discovered[id] = dd
            AddDiscoveredInfo(id, dd)
            ns.Print(who .. " found a new rare: " .. name .. (dd.z and (" in " .. dd.z) or "") .. ".")
            ns.ChangedSoon()
        elseif t > (dd.last or 0) then
            dd.last = t
        end
    elseif tag == "R" then
        if GetTime() - lastReply < 60 then return end
        lastReply = GetTime()
        SchedulePush()
    end
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
local HELP = {
    "/rwatch - open/close the window",
    "/rwatch box - show/hide the status box",
    "/rwatch kill|tame|seen [minutesAgo] [layer] - log an event for Humar",
    "/rwatch layer - show your current layer",
    "/rwatch sync - resync with other users now (normally automatic)",
    "/rwatch test - test the alert",
    "/rwatch debug - show what RareWatch can detect on this client",
}

SLASH_RAREWATCH1 = "/rwatch"
SLASH_RAREWATCH2 = "/rarewatch"
SlashCmdList.RAREWATCH = function(input)
    local cmd, a, b = strsplit(" ", strtrim(input or ""))
    cmd = (cmd or ""):lower()
    if cmd == "" then
        ns.ToggleMain()
    elseif cmd == "box" then
        ns.opt.showTracker = not ns.opt.showTracker
        ns.Changed()
    elseif cmd == "kill" or cmd == "tame" or cmd == "seen" then
        local def = ns.Lookup(5828, "Humar the Pridelord") or ns.list[1]
        if not def then ns.Print("No mobs tracked."); return end
        local kind = (cmd == "kill" and "DOWN") or (cmd == "tame" and "TAME") or "SEEN"
        local _, msg = ns.ManualLog(def, kind, a, b)
        ns.Print(msg)
    elseif cmd == "layer" then
        ns.Print("Your layer: " .. (ns.currentLayer and ns.LayerName(ns.currentLayer) or "unknown - target any NPC first")
            .. (ns.currentLayerZone and (" (detected in " .. ns.currentLayerZone .. ")") or ""))
    elseif cmd == "sync" then
        ns.SyncNow()
        ns.Print("Resyncing with other RareWatch users.")
    elseif cmd == "debug" then
        ns.Print("Combat log: " .. (ns.noCombatLog and "|cffff6060not available|r" or "registered")
            .. ", events received: " .. (ns.cleuCount or 0) .. ", read errors: " .. (ns.cleuErrors or 0))
        if ns.cleuLastError then ns.Print("Last combat log error: " .. ns.cleuLastError) end
        ns.Print("Kills caught by seeing the dead mob: " .. (ns.deathFromUnit or 0))
        ns.Print("Your map: " .. tostring(ns.PlayerMap()) .. ", layer here: " .. tostring(ns.currentLayer))
        local n, h = ns.Digest()
        local tracked, shadow = #ns.list, 0
        for _ in pairs(ns.db.shadow) do shadow = shadow + 1 end
        ns.Print(string.format("Sharing: %s, users online: %d, queue: %d, data: %d entries (%d tracked + %d other rares), digest %d",
            ns.IsSharing() and "on" or "|cffff6060off|r", ns.OnlineUsers(), #queue, n, tracked, shadow, h))
    elseif cmd == "test" then
        ns.Alert("TEST: Humar the Pridelord is UP")
    else
        for _, l in ipairs(HELP) do ns.Print(l) end
    end
end

---------------------------------------------------------------------------
-- Housekeeping
---------------------------------------------------------------------------
-- Known rares on nameplates: a dead one means a kill we can log.
function ns.PollNameplates()
    for unit in pairs(ns.watched) do
        if not UnitExists(unit) then
            ns.watched[unit] = nil
        elseif UnitIsDead(unit) then
            CheckUnit(unit)
            ns.watched[unit] = nil
        end
    end
end

local function Size(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end

-- Every ten minutes: drop expired records, and keep this session's memory of mobs seen from growing forever.
function ns.Housekeeping()
    if not ns.db then return end
    local t = ns.Now()
    for _, def in pairs(ns.db.mobs) do ns.PruneDef(def, t) end
    for id, def in pairs(ns.db.shadow) do
        ns.PruneDef(def, t)
        if next(def.layers) == nil and not def.samples then ns.db.shadow[id] = nil end
    end
    ns.BumpDigest()
    if Size(alerted) > 500 then wipe(alerted) end
    if Size(deadSeen) > 500 then wipe(deadSeen) end
    ns.Changed()
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local ev = CreateFrame("Frame")
for _, e in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "NAME_PLATE_UNIT_ADDED",
    "NAME_PLATE_UNIT_REMOVED", "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT", "UNIT_TARGET", "UNIT_PET", "CHAT_MSG_ADDON",
    "ADDON_ACTION_FORBIDDEN", "ADDON_ACTION_BLOCKED" }) do
    ev:RegisterEvent(e)
end
for _, e in ipairs({ "SHARD_TRANSFER", "ZONE_CHANGED_NEW_AREA", "PLAYER_LOGOUT" }) do
    pcall(ev.RegisterEvent, ev, e)   -- SHARD_TRANSFER is the game's own word for a layer move; not on every client
end
-- Not registered: this client blocks addons from the combat log, and the attempt itself
-- triggers a "blocked from an action" warning. Kills are detected from dead units instead.
ns.noCombatLog = true
-- Health events only for the units we can act on. Listening to every unit's health fires hundreds of times a
-- second in a busy area; nameplates are polled instead (see the ticker below).
if not (ev.RegisterUnitEvent and pcall(ev.RegisterUnitEvent, ev, "UNIT_HEALTH", "target", "mouseover")) then
    pcall(ev.RegisterEvent, ev, "UNIT_HEALTH")
end

local entered = false
ev:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        if ... == ADDON_NAME then ns.InitDB() end
    elseif event == "PLAYER_LOGIN" then
        ns.me = UnitName("player")
        local realm = GetNormalizedRealmName and GetNormalizedRealmName()
        ns.meFull = realm and (ns.me .. "-" .. realm) or ns.me
        TAME_NAME = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(1515))
            or (GetSpellInfo and (GetSpellInfo(1515)))
        lastPetName = UnitName("pet")
        C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        C_Timer.NewTicker(0.25, Pump)
        C_Timer.NewTicker(5, CheckWindows)
        C_Timer.NewTicker(0.5, ns.PollNameplates)
        C_Timer.NewTicker(600, ns.Housekeeping)
        ns.BuildUI()
        ns.Print("v" .. ns.VERSION .. " loaded - /rwatch to open.")
    elseif event == "SHARD_TRANSFER" then
        if ns.Private() then ns.LayerMoved() end
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        if ns.Private() then ns.LayerBorder() end
    elseif event == "PLAYER_LOGOUT" then
        if ns.Private() then ns.LayerSave() end
    elseif event == "PLAYER_ENTERING_WORLD" then
        if ns.Private() then
            local isLogin, isReload = ...
            ns.LayerWorldEntered(isLogin == true, isReload == true)
        end
        if not entered then
            entered = true
            C_Timer.After(10, function()
                if GetChannelName(CHANNEL) > 0 then
                    ns.HideChannel()
                    if ns.opt.channelConsent == nil then ns.opt.channelConsent = true end -- joined in an older version
                end
                SendHello()
                SchedulePush()
                ns.Changed()
                if ns.opt.channelConsent == nil and GetChannelName(CHANNEL) == 0 and ns.ShowConnectPrompt then
                    ns.ShowConnectPrompt()
                end
            end)
            C_Timer.NewTicker(300, SendHello)
            -- the first chat message you send counts as a key press: use it to rejoin if needed
            for i = 1, (NUM_CHAT_WINDOWS or 10) do
                local eb = _G["ChatFrame" .. i .. "EditBox"]
                if eb and eb.HookScript then eb:HookScript("OnEnterPressed", function() ns.EnsureChannel() end) end
            end
        end
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        CheckUnit((...))
    elseif event == "PLAYER_TARGET_CHANGED" then
        CheckUnit("target")
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        CheckUnit("mouseover")
    elseif event == "UNIT_TARGET" then
        local unit = ...
        if unit and (unit:find("^party%d") or unit:find("^raid%d")) then CheckUnit(unit .. "target") end
    elseif event == "UNIT_PET" then
        if ... == "player" then OnPetChanged() end
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        ns.cleuCount = (ns.cleuCount or 0) + 1
        local ok, err = pcall(OnCombatLog)
        if not ok then
            ns.cleuErrors = (ns.cleuErrors or 0) + 1
            ns.cleuLastError = tostring(err)
        end
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        ns.watched[(...)] = nil
    elseif event == "UNIT_HEALTH" then
        local unit = ...
        if unit and (unit == "target" or unit == "mouseover" or ns.watched[unit]) and UnitIsDead(unit) then
            CheckUnit(unit)
        end
    elseif event == "CHAT_MSG_ADDON" then
        OnAddonMessage(...)
    elseif event == "ADDON_ACTION_FORBIDDEN" or event == "ADDON_ACTION_BLOCKED" then
        local who, func = ...
        if who == ADDON_NAME then
            ns.Print("|cffff4040Blocked by the game:|r " .. tostring(func) .. " - please report this.")
        end
    end
end)
