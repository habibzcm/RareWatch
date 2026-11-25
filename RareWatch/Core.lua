-- RareWatch - Core: data, detection, sharing, alerts, slash commands.
--
-- What RareWatch answers: is a rare up in my zone, on any layer another RareWatch user is on, and can I get
-- there? Layers can't be read from the player any more (game build 71037 gives every creature numbers of its
-- own), so a layer is something a creature is on. RareWatch keeps the layer behind the scenes, so Join can put
-- you on the layer of the player who sees the rare. Nothing in the window shows layers.
local ADDON_NAME, ns = ...
ns.VERSION = "0.8.0"

local PREFIX  = "RareWatch"
local CHANNEL = "RareWatchSync"
local PROTO   = "3"            -- unchanged since 0.6.5, so 0.7.x users and 0.8 users still hear each other
ns.CHANNEL = CHANNEL
ns.ICON = "Interface\\Icons\\Ability_Hunter_BeastTaming"

ns.FRESH    = 600              -- a sighting this recent means "up now" (and can be joined)
local SEEN_FOR = 6 * 3600      -- older sightings are listed this long, as "Seen"
local KILL_FOR = 24 * 3600     -- kills are listed this long, as "Killed"
local KEEP     = 3 * 86400     -- records are kept this long after their last event

ns.SOUNDS = {
    { name = "Raid Warning", id = 8959 },
    { name = "Ready Check",  id = 8960 },
    { name = "Alarm Clock",  id = 12889 },
    { name = "Map Ping",     id = 3175 },
}

local DEFAULT_OPT = {
    alertSound = true, sound = 1, alertRaidWarn = true, alertFlash = true, alertChat = true,
    shareGuild = true, shareGroup = true, hostJoin = true,
    showTracker = true, boxHideEmpty = false, lockTracker = false, trackerScale = 1.0, windowScale = 1.0,
    minimapHide = false, minimapAngle = 200, plainFont = false,
}
-- settings that no longer exist (respawn windows, layer names, spawn decoding, untracked-rare alerts)
local OLD_OPT = { "shareAlerts", "windowAlert", "decodeSpawn", "alertAnyRare", "defaultMin", "defaultMax" }

-- One word per state, used everywhere (window, status box, Browse, minimap).
ns.STATUS = {
    UP     = "Up",
    SEEN   = "Seen",
    KILLED = "Killed",
    NONE   = "No reports",
}
local PRIO = { UP = 1, SEEN = 2, KILLED = 3, NONE = 9 }

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

-- "just now", "4m ago", "2h ago", "3d ago": short enough for a list row.
function ns.Ago(t)
    local age = math.max(0, ns.Now() - (t or 0))
    if age < 60 then return "just now" end
    if age < 3600 then return math.floor(age / 60) .. "m ago" end
    if age < 86400 then return math.floor(age / 3600) .. "h ago" end
    return math.floor(age / 86400) .. "d ago"
end

function ns.Day(t) return date("%a %H:%M", t) end
function ns.Hours(sec) return string.format("%g", math.floor(sec / 360 + 0.5) / 10) end

local function Key(name) return strtrim(name or ""):lower() end
ns.Key = Key

-- Player names. Forever names have two parts ("Bluubs Tanockers"); UnitName gives only the first, while
-- messages, whispers and invites need the full name. Names are compared on their first part.
local function Clean(name) return (tostring(name or ""):gsub("[^%w_%-]", "")) end
local function Short(name) return Ambiguate(tostring(name or ""), "short") end
local function First(name) return Short(name):match("^[^%s]+") or "" end
function ns.SameName(a, b)
    if not a or not b then return false end
    a, b = Short(a), Short(b)
    return a == b or First(a) == First(b)
end
-- Does a full name belong to the owner part of a layer key? (the first name, or in older versions the whole
-- name squeezed to 12 characters)
function ns.OwnerIs(name, owner)
    if not name or not owner or owner == "" then return false end
    return Clean(First(name)) == owner or Clean(Short(name)):sub(1, 12) == owner
end
ns.Clean, ns.Short = Clean, Short

-- The full name of the player a layer key's owner part stands for: one of `names` (sources of a record) if it
-- matches, otherwise the most recently heard RareWatch user who matches. nil if nobody does.
function ns.FullName(owner, ...)
    for i = 1, select("#", ...) do
        local name = select(i, ...)
        if ns.OwnerIs(name, owner) then return Short(name) end
    end
    local best, bestT
    for name, p in pairs(ns.peers or {}) do
        if ns.OwnerIs(name, owner) and (not bestT or (p.t or 0) > bestT) then best, bestT = name, p.t or 0 end
    end
    return best and Short(best)
end

-- RareWatch is for the open world: inside dungeons, raids and battlegrounds the elites are not world rares, and
-- the client restricts what addons may read there.
function ns.InInstance()
    local inside, kind = IsInInstance()
    return inside and kind ~= nil and kind ~= "none"
end

---------------------------------------------------------------------------
-- Layers (behind the scenes)
--   Our own layer is read once from a creature and held, and only read again when the game moves us
--   (SHARD_TRANSFER), at a zone border or a login. It gets a letter for this login: A, B, C...
--   What travels between players is the layer as its owner sees it: "<player>.<letter>".
---------------------------------------------------------------------------
-- Creature-0-serverID-instanceID-zoneUID-npcID-spawnUID
function ns.ParseGUID(guid)
    if type(guid) ~= "string" then return end
    local unitType, _, _, _, _, npcID, spawnUID = strsplit("-", guid)
    if unitType ~= "Creature" and unitType ~= "Vehicle" then return end
    return tonumber(npcID), spawnUID
end

-- The numbers a creature carries, as the id our own layer is held under.
function ns.RawLayer(guid)
    if type(guid) ~= "string" then return end
    local unitType, _, server, _, zoneUID = strsplit("-", guid)
    if (unitType ~= "Creature" and unitType ~= "Vehicle") or not server or not zoneUID then return end
    return server .. "-" .. zoneUID
end

-- "<player>.<letter>": the owner and letter of a shared layer key.
function ns.KeyOwner(key)
    if type(key) ~= "string" then return end
    return key:match("^([%w_%-]+)%.([%w_%-]+)$")
end

-- Our letter for a layer id (or the id itself before it has one).
function ns.LayerShort(id)
    if not id or id == "?" then return "?" end
    local owner, letter = ns.KeyOwner(id)
    if owner then return letter end
    return (ns.db and ns.db.letters and ns.db.letters[id]) or tostring(id)
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
-- Records: per rare, one record per layer key, holding the last kill and the last sighting.
---------------------------------------------------------------------------
local MAX_LAYERS = 40        -- layer records kept per rare
local HISTORY_MAX = 500      -- events kept in History
local MAX_DISCOVERED = 400   -- rares discovered in game, kept in the list

local digestVer = 0
function ns.BumpDigest() digestVer = digestVer + 1 end

local function LatestOf(r) return math.max(r.down or 0, r.seen or 0) end

-- Drop records past KEEP; if a rare has too many layers, drop the stalest.
-- `protect` is a record being created right now: it is still empty, so it would look like the stalest.
function ns.PruneDef(def, t, protect)
    t = t or ns.Now()
    local n = 0
    for layer, r in pairs(def.layers or {}) do
        if layer ~= protect and t - LatestOf(r) > KEEP then def.layers[layer] = nil else n = n + 1 end
    end
    while n > MAX_LAYERS do
        local oldL, oldT
        for layer, r in pairs(def.layers) do
            local l = LatestOf(r)
            if layer ~= protect and (not oldT or l < oldT) then oldL, oldT = layer, l end
        end
        if not oldL then break end
        def.layers[oldL] = nil
        n = n - 1
    end
end

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

-- Tracked rares only.
function ns.Lookup(id, name)
    return (id and ns.byId[id]) or (name and ns.byName[Key(name)]) or nil
end

local function AddMob(name, id)
    name = strtrim(name or "")
    if name == "" or name:find(":") then return nil end
    local key = Key(name)
    local def = ns.db.mobs[key]
    if def then return def, false end
    def = { name = name, id = id, layers = {} }
    ns.db.mobs[key] = def
    -- adopt everything recorded while this rare was untracked
    local sh = id and ns.db.shadow[id]
    if sh then
        def.layers = sh.layers or {}
        ns.db.shadow[id] = nil
    end
    ns.RebuildIndex()
    digestVer = digestVer + 1
    ns.Changed()
    return def, true
end

function ns.TrackRare(id)
    local info = ns.RareInfo(id)
    if not info then return nil, "Unknown rare." end
    return AddMob(info.name, id)
end

function ns.RemoveMob(def)
    ns.db.mobs[Key(def.name)] = nil
    -- keep its data, so it is still listed when you're in its zone (and still shared)
    if def.id and ns.RareInfo(def.id) then
        ns.db.shadow[def.id] = { name = def.name, id = def.id, layers = def.layers, shadow = true }
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
        if n > MAX_LAYERS then ns.PruneDef(def, nil, layer) end
    end
    return r
end

-- The same kill reported again (another player, another layer key) is one history entry.
local function InHistory(h, name, kind, t)
    for i = 1, math.min(#h, 60) do
        local e = h[i]
        if e.n == name and e.k == kind and math.abs((e.t or 0) - t) < 120 then return true end
    end
    return false
end

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

-- Returns true if the event changed what we know. Kinds: DOWN (killed), TAME (tamed), SEEN (alive).
function ns.ApplyEvent(def, kind, layer, t, src)
    if not def or not t then return false end
    if kind ~= "DOWN" and kind ~= "TAME" and kind ~= "SEEN" then return false end
    if t > ns.Now() + 120 then return false end
    layer = layer or "?"
    if not def.layers[layer] then
        -- a full rare only takes a new layer record for news newer than the stalest one it holds
        local n, oldest = 0, nil
        for _, x in pairs(def.layers) do
            n = n + 1
            local l = LatestOf(x)
            if not oldest or l < oldest then oldest = l end
        end
        if n >= MAX_LAYERS and oldest and t <= oldest then return false end
    end
    local r = ns.GetRec(def, layer)
    if kind == "DOWN" or kind == "TAME" then
        if r.down and math.abs(r.down - t) < 120 then return false end
        if r.down and t < r.down then return false end
        r.down, r.downKind, r.downSrc = t, kind, src
        if r.seen and r.seen <= t then r.seen, r.seenSrc = nil, nil end
        AddHistory(def, kind, layer, t, src)
        digestVer = digestVer + 1
        return true
    else
        if r.down and t <= r.down then return false end
        if r.seen and t < r.seen + 300 then return false end    -- refreshed every 5 minutes while it stays up
        local newSighting = not r.seen or t - r.seen > 1800
        r.seen, r.seenSrc = t, src
        if newSighting then AddHistory(def, kind, layer, t, src) end
        return true
    end
end

---------------------------------------------------------------------------
-- Saved data
---------------------------------------------------------------------------
-- 0.7 and older kept respawn windows, measured respawns and layer names. 0.8 only keeps kills and sightings.
local function Upgrade(db)
    if (db.v or 0) >= 3 then return end
    db.muted = db.muted or {}
    for key, def in pairs(db.mobs or {}) do
        if def.alert == false then db.muted[def.id or key] = true end
        def.alert, def.enabled, def.min, def.max, def.samples, def.respawnSrc = nil, nil, nil, nil, nil, nil
    end
    for _, def in pairs(db.shadow or {}) do
        def.alert, def.enabled, def.min, def.max, def.samples = nil, nil, nil, nil, nil
    end
    for _, set in ipairs({ db.mobs or {}, db.shadow or {} }) do
        for _, def in pairs(set) do
            for _, r in pairs(def.layers or {}) do
                r.spawn, r.spawnSrc, r.notifiedOpen = nil, nil, nil
            end
        end
    end
    -- history from spawn-time reads; it only ever repeated a sighting
    local keep = {}
    for _, e in ipairs(db.history or {}) do if e.k ~= "SPAWN" then keep[#keep + 1] = e end end
    db.history = keep
    db.layerNames, db.decodeSpawn, db.shareAlerts, db.hidden, db.locked, db.pos = nil, nil, nil, nil, nil, nil
    db.v = 3
end

function ns.InitDB()
    RareWatchDB = RareWatchDB or {}
    local db = RareWatchDB
    ns.db = db
    db.mobs = (type(db.mobs) == "table" and (db.v or 0) >= 2) and db.mobs or {}
    db.opt = db.opt or {}
    db.history = db.history or {}
    db.letters = db.letters or {}      -- layer id -> letter, for this login
    db.discovered = db.discovered or {}
    db.confirmed = db.confirmed or {}
    db.shadow = db.shadow or {}
    db.muted = db.muted or {}
    Upgrade(db)
    for k, v in pairs(DEFAULT_OPT) do
        if db.opt[k] == nil then db.opt[k] = v end
    end
    for _, k in ipairs(OLD_OPT) do db.opt[k] = nil end
    ns.opt = db.opt
    if #db.history > 1 then ns.DedupeHistory() end

    -- prune stale records; reset session-only fields
    local t = ns.Now()
    for _, def in pairs(db.mobs) do
        def.layers = def.layers or {}
        for _, r in pairs(def.layers) do r.heard = nil end
        ns.PruneDef(def, t)
    end
    for id, def in pairs(db.shadow) do
        def.shadow = true
        def.layers = def.layers or {}
        for _, r in pairs(def.layers) do r.heard = nil end
        ns.PruneDef(def, t)
        if next(def.layers) == nil then db.shadow[id] = nil end
    end
    -- rares found in game that nobody has seen for two months
    for id, d in pairs(db.discovered) do
        if t - (d.last or d.first or 0) > 60 * 86400 then db.discovered[id] = nil end
    end
    ns.RebuildIndex()
    ns.BuildRareIndex()
end

---------------------------------------------------------------------------
-- Rare database (built-in Forever list + rares discovered in game)
---------------------------------------------------------------------------
ns.rareIndex = {}
ns.rareByName = {}
local zoneCache = {}

local function AddDiscoveredInfo(id, d)
    ns.rareByName[Key(d.n)] = id
    ns.rareIndex[id] = {
        id = id, name = d.n, rank = (d.c == "rareelite") and 2 or 4, minl = d.lv, maxl = d.lv,
        zone = d.z, ui = d.ui, coords = (d.x and d.y) and { d.x, d.y } or nil, discovered = true,
    }
    wipe(zoneCache)
end

function ns.BuildRareIndex()
    wipe(ns.rareIndex)
    wipe(ns.rareByName)
    wipe(zoneCache)
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

function ns.Zone()
    local z = GetRealZoneText and GetRealZoneText()
    return (type(z) == "string" and z ~= "") and z or nil
end

-- Every known rare that lives in a zone, by name.
function ns.ZoneRares(zone)
    zone = zone or ns.Zone()
    if not zone then return {} end
    local list = zoneCache[zone]
    if not list then
        list = {}
        for _, info in pairs(ns.rareIndex) do
            if info.zone == zone then list[#list + 1] = info end
        end
        table.sort(list, function(a, b) return a.name < b.name end)
        zoneCache[zone] = list
    end
    return list
end

-- The rare's zone, for tracked rares too.
function ns.ZoneOf(def)
    local info = def and ns.RareInfo(def.id)
    return info and info.zone
end

-- Watched: tracked, or living in the zone you're in. Watched rares get alerts and show in the status box.
function ns.IsWatched(def)
    if not def then return false end
    if ns.Lookup(def.id, def.name) then return true end
    local z = ns.ZoneOf(def)
    return z ~= nil and z == ns.Zone()
end

local function MuteKey(def) return def.id or Key(def.name) end
function ns.IsMuted(def) return def and ns.db.muted[MuteKey(def)] == true end
function ns.SetMuted(def, on)
    ns.db.muted[MuteKey(def)] = on and true or nil
    ns.Changed()
end

-- Rares you don't track still get their kills and sightings recorded: in "shadow" entries (db.shadow[id]).
function ns.ShadowDef(id, create)
    local d = ns.db.shadow[id]
    if d or not create then return d end
    local info = ns.RareInfo(id)
    if not info then return nil end
    d = { name = info.name, id = id, layers = {}, shadow = true }
    ns.db.shadow[id] = d
    return d
end

-- Tracked rare, or the shadow entry for any known rare (created on demand unless create == false).
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
            if r.seen and r.seen > (best or 0) then best = r.seen end
        end
    end
    return best
end

---------------------------------------------------------------------------
-- Reports and status
---------------------------------------------------------------------------
-- Who a record's news came from, for showing: "You", or the player whose layer it is.
function ns.Reporter(layer, src)
    local owner = ns.KeyOwner(layer)
    if not owner then
        if src == "you" then return "You" end
        return (src and src ~= "" and Short(src)) or "Someone"
    end
    if ns.me and ns.OwnerIs(ns.me, owner) then return "You" end
    return ns.FullName(owner, src) or owner
end

-- One layer record, as what it tells you. nil when it is too old to mean anything.
function ns.Report(def, layer, r, t)
    t = t or ns.Now()
    local seen, down = r.seen or 0, r.down or 0
    local rep
    if seen > 0 and seen > down then
        local age = t - seen
        if age > SEEN_FOR then return nil end
        rep = { code = age <= ns.FRESH and "UP" or "SEEN", at = seen, kind = "SEEN", who = ns.Reporter(layer, r.seenSrc) }
    elseif down > 0 then
        if t - down > KILL_FOR then return nil end
        rep = { code = "KILLED", at = down, kind = r.downKind or "DOWN", who = ns.Reporter(layer, r.downSrc) }
    else
        return nil
    end
    rep.layer, rep.rec, rep.prio = layer, r, PRIO[rep.code]
    return rep
end

-- Every report for a rare: up first, then newest first.
function ns.Reports(def)
    local t, out = ns.Now(), {}
    if not def or not def.layers then return out end
    for layer, r in pairs(def.layers) do
        local rep = ns.Report(def, layer, r, t)
        if rep then out[#out + 1] = rep end
    end
    table.sort(out, function(a, b)
        if (a.code == "UP") ~= (b.code == "UP") then return a.code == "UP" end
        return a.at > b.at
    end)
    return out
end

local NONE = { code = "NONE", prio = 9, at = 0 }
-- The rare's state: up if anyone sees it now, otherwise the newest news (a sighting or a kill).
function ns.Status(def)
    local reps = ns.Reports(def)
    return reps[1] or NONE, reps
end

-- "Up · Bob sees it", "Killed by Bob", "Seen by you" ... without the time.
function ns.ReportText(rep)
    if not rep or rep.code == "NONE" then return "No reports" end
    local who = rep.who or "Someone"
    local you = who == "You"
    if rep.code == "UP" then return you and "You see it" or (who .. " sees it") end
    if rep.code == "SEEN" then return "Seen by " .. (you and "you" or who) end
    return (rep.kind == "TAME" and "Tamed by " or "Killed by ") .. (you and "you" or who)
end

---------------------------------------------------------------------------
-- Sharing: automatic, two-way, relayed. Nobody ever has to ask.
--   E  single event         B  batch of events      H  hello: version + summary of what we know
--   D  rare discovered      C  known rare confirmed  R  resync
--   J/j/Q  join requests (whispers, see Join.lua)
---------------------------------------------------------------------------
local queue, queued = {}, {}
local nextSend = 0
local KIND_CODE = { DOWN = "D", TAME = "T", SEEN = "S" }
local CODE_KIND = { D = "DOWN", T = "TAME", S = "SEEN" }   -- "P" (spawn times, 0.7 and older) is ignored

local function Destinations()
    local d = {}
    if ns.opt.shareGuild and IsInGuild() then d[#d + 1] = { "GUILD" } end
    local id = GetChannelName(CHANNEL)
    if id and id > 0 then d[#d + 1] = { "CHANNEL", id } end
    if ns.opt.shareGroup and not ns.InInstance() then
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

-- Our own layer goes out as "<player>.<letter>". Keys that already have that shape (relayed) pass unchanged.
local function ShareKey(layer)
    if not layer or layer == "?" or layer:find(".", 1, true) then return layer end
    local label = tostring(ns.LayerShort(layer)):gsub("[^%w_%-]", ""):sub(1, 8)
    local who = Clean(First(ns.me or "me")):sub(1, 12)
    return who .. "." .. (label ~= "" and label or "?")
end

local function Broadcast(def, kind, layer, t, urgent)
    Send(table.concat({ "E", PROTO, def.id or 0, def.name, kind, ShareKey(layer) or "?", math.floor(t) }, ":"), urgent)
end

function ns.IsSharing()
    return #Destinations() > 0
end

-- Everything worth passing on right now: { def, kind, layer, time, record }.
local function Shareable(t)
    local out = {}
    for _, def in ipairs(ns.AllDefs()) do
        for layer, r in pairs(def.layers) do
            if r.down and t - r.down < KILL_FOR then out[#out + 1] = { def, r.downKind or "DOWN", layer, r.down, r } end
            if r.seen and t - r.seen < SEEN_FOR then out[#out + 1] = { def, "SEEN", layer, r.seen, r } end
        end
    end
    return out
end

local function Hash(str)
    local h = 5381
    for i = 1, #str do h = (h * 33 + str:byte(i)) % 4294967296 end
    return h
end

-- Short summary of our kills and tames. Peers compare it with theirs to notice missing data.
-- (Sightings are left out: they change every few minutes and would cause constant resyncs.)
-- Cached: it only changes when our data does (or as kills age out, so at most a minute stale).
local digestCache
function ns.Digest()
    local now = GetTime()
    if digestCache and digestCache.ver == digestVer and now - digestCache.at < 60 then
        return digestCache.n, digestCache.h
    end
    local t, keys = ns.Now(), {}
    for _, e in ipairs(Shareable(t)) do
        if e[2] ~= "SEEN" then
            keys[#keys + 1] = (e[1].id or e[1].name) .. "/" .. ShareKey(e[3]) .. "/" .. KIND_CODE[e[2]] .. "/" .. math.floor(e[4] / 600)
        end
    end
    table.sort(keys)
    local n, h = #keys, Hash(table.concat(keys, ";"))
    digestCache = { ver = digestVer, at = now, n = n, h = h }
    return n, h
end

local function DiscoveryMsg(id, d)
    return table.concat({ "D", PROTO, id, d.n, d.c, d.z or "?", d.ui or 0, d.x or 0, d.y or 0, d.lv or 0, d.last }, ":")
end

-- Rares discovered in game and confirmed rares: only sent once after login and when someone asks for a resync.
-- (They used to go out with every sync, up to 40 messages each time.)
local discoveriesDue = true
local function SendDiscoveries(t)
    local m = 0
    for id, d in pairs(ns.db.discovered) do
        if m < 20 and d.last and t - d.last < 7 * 86400 then Send(DiscoveryMsg(id, d)); m = m + 1 end
    end
    for id, ct in pairs(ns.db.confirmed) do
        if m < 40 and t - ct < 7 * 86400 then Send(table.concat({ "C", PROTO, id, ct }, ":")); m = m + 1 end
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
    if discoveriesDue then
        discoveriesDue = false
        SendDiscoveries(t)
    end
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

function ns.OnlineUsers()
    local n, now = 0, GetTime()
    for who, p in pairs(ns.peers) do
        if now - p.t < 900 then n = n + 1
        elseif now - p.t > 3600 then ns.peers[who] = nil end
    end
    return n
end

function ns.SyncNow()
    discoveriesDue = true
    SendHello()
    Send("R:" .. PROTO)
    SchedulePush()
end

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
        if GetChannelName(CHANNEL) > 0 then ns.SyncNow() end
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
            if GetChannelName(CHANNEL) > 0 then ns.SyncNow() end
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

-- The one way RareWatch gets your attention; every switch in Settings > Alerts applies to it.
-- big == false: chat line and sound only (a kill, a rare in another zone).
function ns.Alert(text, big)
    local o = ns.opt
    if big ~= false then
        if o.alertRaidWarn then ns.BigText(text) end
        if o.alertFlash and FlashClientIcon then FlashClientIcon() end
    end
    if o.alertSound then ns.PlayAlertSound() end
    if o.alertChat then ns.Print(text) end
end

-- A sighting is announced once. While the rare stays up (it is reported again every few minutes, by everyone
-- near it) nothing more is said; only after it has gone quiet for ns.FRESH does a sighting count as news again.
local upActivity = {}       -- rare -> last time anyone reported it alive
local killSaid = {}         -- rare -> kill time we last announced
local function RareKey(def) return def.id or Key(def.name) end

-- Returns true if this sighting is news.
local function SightingIsNews(def, t)
    local k = RareKey(def)
    local last = upActivity[k]
    if not last or t > last then upActivity[k] = t end
    return not last or t - last > ns.FRESH
end

local function WhereText(def)
    local z = ns.ZoneOf(def)
    if z and z ~= ns.Zone() then return " in " .. z end
    return ""
end

-- Someone else reported a rare alive (age: seconds since).
local function AnnounceSighting(def, who, t)
    if not SightingIsNews(def, t) then return end
    if ns.Now() - t > ns.FRESH or not ns.IsWatched(def) or ns.IsMuted(def) then return end
    local here = WhereText(def) == ""
    local hint = (here and ns.opt.showTracker) and ", Join in the RareWatch box" or ""
    ns.Alert(def.name .. " is up" .. WhereText(def) .. "  -  " .. who .. " sees it" .. hint, here)
end

local function AnnounceKill(def, kind, who, t)
    local k = RareKey(def)
    if killSaid[k] and math.abs(killSaid[k] - t) < 300 then return end
    killSaid[k] = t
    if ns.Now() - t > ns.FRESH or not ns.IsWatched(def) or ns.IsMuted(def) then return end
    if ns.opt.alertChat then
        ns.Print(def.name .. (kind == "TAME" and " was tamed by " or " was killed by ") .. who .. WhereText(def) .. ".")
    end
end

-- Record something WE observed: store, share, notify UI.
local function Record(def, kind, layer, t)
    if ns.ApplyEvent(def, kind, layer, t, "you") then
        ns.GetRec(def, layer).heard = GetTime()
        Broadcast(def, kind, layer, t, true)
        if kind == "SEEN" then SightingIsNews(def, t) else killSaid[RareKey(def)] = t end
        ns.Changed()
    end
end

---------------------------------------------------------------------------
-- Detection
---------------------------------------------------------------------------
local alerted, aliveSeen, deadSeen = {}, {}, {}
local lastGUID, lastSeenAt = {}, {}
local lastPetGUID

local function PlayerMap()
    if C_Map and C_Map.GetBestMapForUnit then
        local ok, map = pcall(C_Map.GetBestMapForUnit, "player")
        if ok then return map end
    end
end
ns.PlayerMap = PlayerMap

-- How our layer is held, following what the game tells us:
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
ns.InView = InView

local function Adopt(id)
    ns.layerStale = false
    if not ns.db.letters[id] then
        ns.db.letterN = (ns.db.letterN or 0) + 1
        ns.db.letters[id] = LetterFor(ns.db.letterN)
    end
    if id ~= ns.currentLayer then
        ns.currentLayer = id
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
    ns.db.held = ns.currentLayer and { id = ns.currentLayer, zone = ns.Zone(), at = time(), who = ns.me } or nil
end

local function Restore()
    local k = ns.db.held
    if not k or ns.currentLayer then return end
    if GetTime() - loginAt > 10 then ns.db.held = nil; return end
    if type(k.at) ~= "number" or time() - k.at > KEPT_AGE or k.who ~= ns.me then ns.db.held = nil; return end
    local zone = ns.Zone()
    if not zone or zone ~= k.zone then return end    -- not named yet: tried again
    ns.currentLayer, ns.layerStale = k.id, false
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

local function PlayerPos()
    local map = PlayerMap()
    if not map then return end
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

-- A rare seen alive: confirm a known one, or record a brand-new one.
local function Discover(unit, npcId)
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
        return
    end
    local d = ns.db.discovered[npcId]
    if not d then
        local name = UnitName(unit)
        if not name or name:find(":") then return end
        local count = 0
        for _ in pairs(ns.db.discovered) do count = count + 1 end
        if count >= MAX_DISCOVERED then return end
        local map, zone, x, y = PlayerPos()
        -- the zone a rare lives in is what the status box matches on, so use the zone's name, not a subzone's
        zone = ns.Zone() or zone
        d = { n = name, c = class, lv = UnitLevel(unit), z = zone, ui = map, x = x, y = y, first = t, last = t, src = "you" }
        ns.db.discovered[npcId] = d
        AddDiscoveredInfo(npcId, d)
        ns.Print("New rare found: " .. d.n .. (zone and (" in " .. zone) or "") .. " - added to Browse.")
        Send(DiscoveryMsg(npcId, d), true)
        ns.Changed()
    elseif t - (d.last or 0) > 300 then
        d.last = t
        Send(DiscoveryMsg(npcId, d), true)
    end
end

-- Kill detection without the combat log: a rare we saw alive is now dead.
-- Only a creature seen alive this session counts, so walking past an old corpse logs nothing.
local function CheckDeath(unit, guid, npcId)
    if deadSeen[guid] or not aliveSeen[guid] then return end
    local def = ns.LookupAny(npcId, UnitName(unit))
    if not def then return end
    deadSeen[guid] = true
    for u in pairs(ns.watched) do if UnitGUID(u) == guid then ns.watched[u] = nil end end
    Record(def, "DOWN", ns.currentLayer, ns.Now())
end

ns.watched = {}   -- nameplate units showing a known rare: polled for death (cheaper than listening to every unit's health)

local function CheckUnit(unit)
    if ns.InInstance() or not UnitExists(unit) then return end
    local guid = UnitGUID(unit)
    local npcId = ns.ParseGUID(guid)
    if not npcId then return end
    -- the layer is held, not read off every creature; with none held yet there is nothing to file a record under
    if not ns.ReadLayer(unit, guid) then return end

    if UnitIsDead(unit) then
        CheckDeath(unit, guid, npcId)
        return
    end
    Discover(unit, npcId)
    local name = UnitName(unit)
    local def = ns.Lookup(npcId, name)
    if not def then
        local class = UnitClassification(unit)
        if class == "rare" or class == "rareelite" or (ns.RARE_DB and ns.RARE_DB[npcId]) then
            def = ns.LookupAny(npcId, name)
        end
    end
    if not def then return end
    if not def.id then def.id = npcId; ns.RebuildIndex() end

    local k = RareKey(def)
    aliveSeen[guid] = true
    if unit:find("^nameplate") then ns.watched[unit] = true end
    lastGUID[k] = guid
    lastSeenAt[k] = GetTime()
    -- already announced from someone else's report in the last few minutes: no second alert for the same rare
    local knownUp = upActivity[k] and ns.Now() - upActivity[k] <= ns.FRESH
    Record(def, "SEEN", ns.currentLayer, ns.Now())
    if not alerted[guid] then
        alerted[guid] = true
        if not knownUp and ns.IsWatched(def) and not ns.IsMuted(def) then ns.Alert(def.name .. " is up!") end
    end
end

-- A tame: a new pet that is this rare (the pet carries the creature's npc id), while the rare we saw a moment
-- ago is gone from view. Calling a pet you tamed before does nothing: the rare itself would still be in view.
local function OnPetChanged()
    local guid = UnitGUID("pet")
    if guid == lastPetGUID then return end
    lastPetGUID = guid
    if type(guid) ~= "string" then return end
    local kind, _, _, _, _, npcId = strsplit("-", guid)
    npcId = tonumber(npcId)
    if kind ~= "Pet" or not npcId then return end
    local def = ns.LookupAny(npcId, nil, false)
    if not def then return end
    local k = RareKey(def)
    if not lastSeenAt[k] or GetTime() - lastSeenAt[k] > 60 then return end
    if lastGUID[k] and InView()[lastGUID[k]] then return end
    if lastGUID[k] then deadSeen[lastGUID[k]] = true end
    Record(def, "TAME", ns.currentLayer, ns.Now())
end

---------------------------------------------------------------------------
-- Incoming messages
---------------------------------------------------------------------------
local lastReply = 0

local function VersionNum(v)
    local a, b, c = tostring(v or ""):match("^(%d+)%.(%d+)%.?(%d*)")
    return (tonumber(a) or 0) * 10000 + (tonumber(b) or 0) * 100 + (tonumber(c) or 0)
end

local function ValidLayer(l)
    return type(l) == "string" and #l <= 24 and (l == "?" or l:match("^[%w%._%-]+$") ~= nil)
end

-- One event from another player (tracked or not). Returns true if it changed anything.
local function ApplyRemote(id, name, kind, layer, t, who)
    if not kind or not t or not ValidLayer(layer) then return false end
    if not ns.KeyOwner(layer) then layer = "?" end     -- only "<player>.<letter>" is understood
    if t < ns.Now() - 14 * 86400 then return false end
    local def = ns.LookupAny(id, name)
    if not def then return false end
    if not def.id and id then def.id = id; ns.RebuildIndex() end
    local changed = ns.ApplyEvent(def, kind, layer, t, who)
    local r = def.layers[layer]
    if r then r.heard = GetTime() end
    if changed then
        local reporter = ns.Reporter(layer, who)
        if kind == "SEEN" then AnnounceSighting(def, reporter, t) else AnnounceKill(def, kind, reporter, t) end
    elseif kind == "SEEN" and r and not (r.down and t <= r.down) then
        SightingIsNews(def, t)    -- a repeat (not saved: too soon after the last one) still means it is up
    end
    return changed
end

local function OnAddonMessage(prefix, msg, channel, sender)
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

    if tag == "J" or tag == "j" or tag == "Q" then
        if ns.JoinMessage then ns.JoinMessage(tag, sender, channel, a, b, c, d, e) end
    elseif tag == "E" then
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
        peer.v = version
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
            ns.ChangedSoon()
        elseif t > (dd.last or 0) then
            dd.last = t
        end
    elseif tag == "R" then
        if GetTime() - lastReply < 60 then return end
        lastReply = GetTime()
        discoveriesDue = true
        SchedulePush()
    end
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
local HELP = {
    "/rwatch - open/close the window",
    "/rwatch box - show/hide the status box",
    "/rwatch sync - resync with other users now (normally automatic)",
    "/rwatch test - test the alert",
    "/rwatch swaps - layer moves used this hour (join requests stop at 8 of about 10)",
    "/rwatch debug - show what RareWatch can detect on this client",
}

local function Size(t) local n = 0; for _ in pairs(t) do n = n + 1 end; return n end

SLASH_RAREWATCH1 = "/rwatch"
SLASH_RAREWATCH2 = "/rarewatch"
SlashCmdList.RAREWATCH = function(input)
    local cmd = strsplit(" ", strtrim(input or ""))
    cmd = (cmd or ""):lower()
    if cmd == "" then
        ns.ToggleMain()
    elseif cmd == "box" then
        ns.opt.showTracker = not ns.opt.showTracker
        ns.Changed()
    elseif cmd == "sync" then
        ns.SyncNow()
        ns.Print("Resyncing with other RareWatch users.")
    elseif cmd == "test" then
        ns.Alert("TEST: a rare is up!")
    elseif cmd == "swaps" then
        if ns.Join then ns.Join.PrintSwaps() end
    elseif cmd == "debug" then
        local n, h = ns.Digest()
        ns.Print(string.format("Zone: %s (%d known rares), layer held: %s",
            tostring(ns.Zone()), #ns.ZoneRares(), ns.currentLayer and ns.LayerShort(ns.currentLayer) or "no"))
        ns.Print(string.format("Sharing: %s, users online: %d, queue: %d, kills shared: %d, tracked: %d, other rares with data: %d, digest %d",
            ns.IsSharing() and "on" or "|cffff6060off|r", ns.OnlineUsers(), #queue, n, #ns.list, Size(ns.db.shadow), h))
    else
        for _, l in ipairs(HELP) do ns.Print(l) end
    end
end

---------------------------------------------------------------------------
-- Housekeeping
---------------------------------------------------------------------------
-- Known rares on nameplates: a dead one means a kill we can log. A live one that stays in view is checked again
-- once a minute, so it keeps counting as up for everyone (a sighting older than 10 minutes isn't "up" any more).
local polledAt = {}
function ns.PollNameplates()
    local now = GetTime()
    for unit in pairs(ns.watched) do
        if not UnitExists(unit) then
            ns.watched[unit], polledAt[unit] = nil, nil
        elseif UnitIsDead(unit) then
            CheckUnit(unit)
            ns.watched[unit], polledAt[unit] = nil, nil
        elseif now - (polledAt[unit] or now) >= 60 then
            polledAt[unit] = now
            CheckUnit(unit)
        elseif not polledAt[unit] then
            polledAt[unit] = now
        end
    end
end

-- Every ten minutes: drop expired records, and keep this session's memory of mobs seen from growing forever.
function ns.Housekeeping()
    if not ns.db then return end
    local t = ns.Now()
    for _, def in pairs(ns.db.mobs) do ns.PruneDef(def, t) end
    for id, def in pairs(ns.db.shadow) do
        ns.PruneDef(def, t)
        if next(def.layers) == nil then ns.db.shadow[id] = nil end
    end
    ns.BumpDigest()
    for _, set in ipairs({ alerted, aliveSeen, deadSeen }) do
        if Size(set) > 500 then wipe(set) end
    end
    for k, v in pairs(upActivity) do if t - v > 3600 then upActivity[k] = nil end end
    for k, v in pairs(killSaid) do if t - v > 3600 then killSaid[k] = nil end end
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
-- The combat log is not registered: this client blocks addons from it, and the attempt itself triggers a
-- "blocked from an action" warning. Kills are detected from dead units instead.
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
        lastPetGUID = UnitGUID("pet")
        C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
        C_Timer.NewTicker(0.25, Pump)
        C_Timer.NewTicker(0.5, ns.PollNameplates)
        C_Timer.NewTicker(600, ns.Housekeeping)
        ns.BuildUI()
        ns.Print("v" .. ns.VERSION .. " loaded - /rwatch to open.")
    elseif event == "SHARD_TRANSFER" then
        ns.LayerMoved()
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        ns.LayerBorder()
    elseif event == "PLAYER_LOGOUT" then
        ns.LayerSave()
    elseif event == "PLAYER_ENTERING_WORLD" then
        local isLogin, isReload = ...
        ns.LayerWorldEntered(isLogin == true, isReload == true)
        if not entered then
            entered = true
            C_Timer.After(10, function()
                if GetChannelName(CHANNEL) > 0 and ns.opt.channelConsent == nil then
                    ns.opt.channelConsent = true    -- joined in an older version
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
