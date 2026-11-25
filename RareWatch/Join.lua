-- RareWatch - Join: get onto the layer of a player who just saw a rare, by joining their group.
--
-- The game moves you to another layer when you join the group of a player who stands on it. That makes every
-- join a favour from the player who saw the rare (the host), so this is built around protecting them:
--   * The game allows only about 10 layer moves an hour. Past that it refuses, and it then tends to move the
--     HOST to the guest's layer instead - the host loses the rare and does not come back. So every move is
--     counted (account-wide, rolling hour), the count travels with each request, and requests from a guest with
--     SAFE_USED or more moves are refused by the guest's own addon and again by the host's.
--   * The host always clicks to accept. The prompt waits PROMPT_FOR seconds, so they can finish a fight first.
--   * No joining in combat (or just after), while dead, in an instance, or while already in a group.
--   * The host only gets requests for a rare they saw themselves in the last FRESH seconds, on the layer they
--     are still on, from someone in the same zone; at most HOST_MAX joins per HOST_WINDOW seconds.
--   * If the host is moved anyway, they are told, that guest is blocked for an hour, and the guest's count is
--     set to full.
local _, ns = ...
local W = ns.W
local C = W.C
local Hex = W.Hex
local DOT = "  \194\183  "

local PREFIX, PROTO = "RareWatch", "3"
local LIMIT, SAFE_USED, WARN_USED = 10, 8, 7     -- game limit per hour (Layer-Swap's reading), our cut-off, warn from
local FRESH = ns.FRESH or 600                    -- a sighting can be joined for 10 minutes
local PROMPT_FOR = 120                           -- host has 2 minutes to accept
local ASK_TIMEOUT = 8                            -- no reply at all in this time: offline or older RareWatch
local INVITE_WAIT = 20                           -- accepted, but no invite arrived
local MOVE_WAIT = 8                              -- after joining: a layer move should come within this
local LEAVE_AFTER = 4                            -- stay at least this long in the group (shorter can lose the move)
local HOST_MAX, HOST_WINDOW = 6, 600
local COMBAT_GRACE = 6
local DECLINE_COOL = 600                         -- a declined player can't ask you again for 10 minutes
local PROMPT_MAX, PROMPT_WINDOW = 3, 300         -- at most 3 prompts every 5 minutes
local PAUSE_FOR = 900                            -- "Pause 15 min" on the prompt
local BLOCK_FOR = 3600

local J = {}
ns.Join = J
local state = { mode = "idle" }   -- guest: asking | waiting | accepted | joined;  host: prompt | hosting
local lastCombat = 0
local invites = {}                -- host: times we invited someone
local blocked = {}                -- host: guest -> until (time())
local declined = {}               -- host: guest -> until (time())
local prompts = {}                -- host: times a prompt was shown
local pausedUntil = 0             -- host: no requests until then

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------
local function Now() return ns.Now() end

-- Names: Forever names have two parts ("Bluubs Tanockers"); UnitName gives only the first, but messages,
-- whispers and invites need the full name. The helpers live in Core.
local Clean, SameName = ns.Clean, ns.SameName

local function InGroup() return (IsInGroup and IsInGroup()) or (GetNumGroupMembers and GetNumGroupMembers() > 0) end

local function Dead() return UnitIsDeadOrGhost and UnitIsDeadOrGhost("player") end

local function InCombat()
    if (UnitAffectingCombat and UnitAffectingCombat("player")) or (InCombatLockdown and InCombatLockdown()) then return true end
    return GetTime() - lastCombat < COMBAT_GRACE
end

-- The zone the player is in (a city or subzone map is walked up to its zone).
local function ZoneMap()
    local map = ns.PlayerMap and ns.PlayerMap()
    local guard = 0
    while map and C_Map and C_Map.GetMapInfo and guard < 6 do
        local info = C_Map.GetMapInfo(map)
        if not info or not info.mapType or info.mapType <= 3 or not info.parentMapID or info.parentMapID == 0 then break end
        map, guard = info.parentMapID, guard + 1
    end
    return map
end

local function Whisper(to, ...)
    local msg = table.concat({ ... }, ":")
    pcall(C_ChatInfo.SendAddonMessage, PREFIX, msg, "WHISPER", to)
end

local function Invite(name)
    if C_PartyInfo and C_PartyInfo.InviteUnit then return pcall(C_PartyInfo.InviteUnit, name) end
    if InviteUnit then return pcall(InviteUnit, name) end
end
local function Leave()
    if C_PartyInfo and C_PartyInfo.LeaveParty then pcall(C_PartyInfo.LeaveParty) elseif LeaveParty then pcall(LeaveParty) end
end
local function Uninvite(name)
    if C_PartyInfo and C_PartyInfo.UninviteUnit then pcall(C_PartyInfo.UninviteUnit, name) elseif UninviteUnit then pcall(UninviteUnit, name) end
end
local function InGroupWith(name)
    if not name then return false end
    for i = 1, 4 do
        local n = UnitName("party" .. i)
        if n and SameName(n, name) then return true end
    end
    return false
end

---------------------------------------------------------------------------
-- Layer moves this hour (account-wide, rolling)
---------------------------------------------------------------------------
local function Moves()
    ns.db.swaps = ns.db.swaps or {}
    local cut, keep = Now() - 3600, {}
    for _, t in ipairs(ns.db.swaps) do if t > cut then keep[#keep + 1] = t end end
    ns.db.swaps = keep
    return keep
end

function J.Used() return #Moves() end
function J.PausedFor() return math.max(0, pausedUntil - Now()) end
function J.Resume() pausedUntil = 0; ns.Changed() end
function J.Limit() return LIMIT end
function J.SafeUsed() return SAFE_USED end
function J.WarnUsed() return WARN_USED end

-- Seconds until one more move is allowed (0 when one is).
function J.WaitFor()
    local m = Moves()
    if #m < SAFE_USED then return 0 end
    table.sort(m)
    return math.max(0, m[#m - SAFE_USED + 1] + 3600 - Now())
end

local lastMoveAt = 0
local function RecordMove()
    if Now() - lastMoveAt < 10 then return end     -- one move can raise more than one signal
    lastMoveAt = Now()
    local m = Moves()
    m[#m + 1] = Now()
    if #m >= WARN_USED then
        ns.Print(string.format("You were moved to another layer: %d of about %d layer moves used this hour.", #m, LIMIT))
    end
    ns.Changed()
end

-- The game refused a move: from now on, count the hour as full.
local function MarkFull()
    local m = Moves()
    while #m < LIMIT do m[#m + 1] = Now() end
    ns.Changed()
end

---------------------------------------------------------------------------
-- The bar: one small panel for both sides (asking, the host's prompt, results)
---------------------------------------------------------------------------
local bar
local function BuildBar()
    bar = CreateFrame("Frame", "RareWatchJoinBar", UIParent)
    bar:SetSize(440, 92)
    bar:SetFrameStrata("DIALOG")
    bar:SetToplevel(true)
    bar:EnableMouse(true)
    bar:SetMovable(true)
    bar:SetClampedToScreen(true)
    bar:RegisterForDrag("LeftButton")
    bar:SetScript("OnDragStart", bar.StartMoving)
    bar:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, _, rp, x, y = self:GetPoint()
        ns.db.joinBarPos = { p, rp, x, y }
    end)
    W.Round(bar, C.popEdge, 10)
    W.Round(bar, C.pop, 9, "BACKGROUND", 1, 1)
    bar.stripe = bar:CreateTexture(nil, "ARTWORK")
    bar.stripe:SetPoint("TOPLEFT", 1, -12)
    bar.stripe:SetPoint("BOTTOMLEFT", 1, 12)
    bar.stripe:SetWidth(3)

    bar.icon = W.Icon(bar, "users", 18, C.accent)
    bar.icon:SetPoint("TOPLEFT", 18, -16)
    bar.title = W.Cell(bar, 13, "S", 300)
    bar.title:SetPoint("TOPLEFT", 44, -16)
    bar.clock = W.Cell(bar, 11, "M", 60, C.muted, "RIGHT")
    bar.clock:SetPoint("TOPRIGHT", -36, -18)
    bar.close = W.Button(bar, { icon = "x", style = "ghost", w = 24, h = 24, onClick = function() J.Dismiss() end })
    bar.close:SetPoint("TOPRIGHT", -8, -10)
    bar.body = W.Text(bar, 12, "R", "", C.sec)
    bar.body:SetPoint("TOPLEFT", 44, -38)
    bar.body:SetWidth(372)
    bar.body:SetJustifyH("LEFT")
    bar.body:SetJustifyV("TOP")

    bar.b1 = W.Button(bar, { text = "", style = "primary", h = 26, size = 11 })
    bar.b2 = W.Button(bar, { text = "", style = "ghost", h = 26, size = 11 })
    bar.b3 = W.Button(bar, { text = "", style = "ghost", h = 26, size = 11 })
    bar.b1:SetPoint("BOTTOMRIGHT", -14, 12)
    bar.b2:SetPoint("RIGHT", bar.b1, "LEFT", -8, 0)
    bar.b3:SetPoint("RIGHT", bar.b2, "LEFT", -4, 0)

    local pos = ns.db.joinBarPos
    if pos then bar:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4]) else bar:SetPoint("TOP", UIParent, "TOP", 0, -150) end
    bar:SetScript("OnUpdate", function(self, el)
        self.acc = (self.acc or 0) + el
        if self.acc < 0.2 then return end
        self.acc = 0
        if self.untilT then
            local left = math.ceil(self.untilT - GetTime())
            self.clock:SetText(left > 0 and string.format("%d:%02d", math.floor(left / 60), left % 60) or "")
        else
            self.clock:SetText("")
        end
        if self.hideAt and GetTime() >= self.hideAt then self.hideAt = nil; self:Hide() end
    end)
    bar:Hide()
end

local TONES = { info = C.accent, wait = C.blue, warn = C.yellow, bad = C.red }

-- opts: title, body, tone, icon, untilT (GetTime), hideIn (s), b1 = { text, onClick, style }, b2 = {...}
local function Show(opts)
    if not bar then BuildBar() end
    local tone = TONES[opts.tone or "info"]
    bar.stripe:SetColorTexture(tone[1], tone[2], tone[3], 1)
    bar.icon:SetIcon(opts.icon or "users")
    W.SetColor(bar.icon, tone)
    bar.title:SetText(opts.title or "")
    bar.body:SetText(opts.body or "")
    bar.untilT = opts.untilT
    bar.hideAt = opts.hideIn and (GetTime() + opts.hideIn) or nil
    for _, k in ipairs({ "b1", "b2", "b3" }) do
        local spec, b = opts[k], bar[k]
        if spec then
            b:SetLabel(spec.text)
            b:SetIcon(spec.icon)
            b:SetStyle(spec.style or (k == "b1" and "primary" or "ghost"))
            b:SetScript("OnClick", function() spec.onClick() end)
            b:Show()
        else
            b:Hide()
        end
    end
    -- body height: measured, and at least what its length needs when wrapped at the bar's width
    local plain = (opts.body or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    local lines = 0
    for part in (plain .. "\n"):gmatch("(.-)\n") do lines = lines + math.max(1, math.ceil(#part * 5.9 / 372)) end
    local bodyH = math.max(math.ceil(bar.body:GetStringHeight() or 0), lines * 15)
    local h = math.max(80, 40 + bodyH + ((opts.b1 or opts.b2) and 46 or 16))
    bar:SetHeight(h)
    bar:SetScale((ns.opt and ns.opt.windowScale) or 1)
    bar:Show()
end
local function Result(title, body, tone, icon) Show({ title = title, body = body, tone = tone, icon = icon or "info", hideIn = 14 }) end

local function Reset()
    state = { mode = "idle" }
    ns.Changed()
end

---------------------------------------------------------------------------
-- Guest side
---------------------------------------------------------------------------
-- Who to ask for a layer record, or nil: the key is "<player>.<letter>" and the record's source names them.
local function HostOf(st)
    local owner, letter = ns.KeyOwner(st.layer)
    if not owner then return end
    local r = st.rec or {}
    return ns.FullName(owner, r.seenSrc, r.downSrc) or owner, letter
end

-- Whether a layer record can be joined right now. Returns host, letter, or nil and why not.
function J.CanJoin(def, st)
    if not def or not st or not st.rec then return nil, nil, "hide" end
    local r = st.rec
    local seen = r.seen or 0
    if seen == 0 or (r.down and r.down >= seen) or Now() - seen > FRESH then return nil, nil, "hide" end
    local host, letter = HostOf(st)
    if not host or SameName(host, ns.me) then return nil, nil, "hide" end
    if state.mode ~= "idle" then return host, letter, "Already asking someone." end
    if InGroup() then return host, letter, "Leave your group first." end
    if ns.InInstance() then return host, letter, "Not inside an instance." end
    if Dead() then return host, letter, "Not while you're dead." end
    if InCombat() then return host, letter, "Not in combat." end
    local wait = J.WaitFor()
    if wait > 0 then
        return host, letter, string.format("You've used %d of about %d layer moves this hour. Wait %s, or the game could move %s off the rare instead of you.",
            J.Used(), LIMIT, ns.Dur(wait), host)
    end
    local info = ns.RareInfo and ns.RareInfo(def.id)
    local zone = info and info.zone
    local here = GetRealZoneText and GetRealZoneText()
    if zone and here and here ~= "" and zone ~= here then return host, letter, "Go to " .. zone .. " first." end
    return host, letter, nil
end

local REASONS = {
    NO     = "%s declined.",
    EXP    = "%s didn't answer in time.",
    OFF    = "%s doesn't take join requests.",
    GROUP  = "%s is in a group right now.",
    INST   = "%s is in an instance.",
    MOVED  = "%s has changed layer since that sighting.",
    NOLAYER = "%s's RareWatch doesn't know their layer right now.",
    OLD    = "%s's sighting is too old to join.",
    DEAD   = "%s says it has been killed already.",
    ZONE   = "You need to be in the same zone as %s.",
    SWAPS  = "Your layer moves are nearly used up for this hour, so %s's RareWatch refused: joining could move them off the rare.",
    LIMIT  = "%s has had several joins recently. Try again in a few minutes.",
    BUSY   = "%s is answering another request. Try again in a minute.",
    BLOCK  = "%s isn't taking requests from you right now.",
    COOL   = "%s declined your last request. You can ask again in %s.",
    PAUSED = "%s has paused join requests for a while.",
}

function J.Request(def, st)
    local host, letter, why = J.CanJoin(def, st)
    if not host then return end
    if why then Result("Can't join yet", why, "warn", "info"); return end
    local nonce = tostring(math.random(100000, 999999))
    state = { mode = "asking", host = host, nonce = nonce, def = def, letter = letter, at = GetTime() }
    Whisper(host, "J", PROTO, def.id or 0, Clean(letter), J.Used(), ZoneMap() or 0, nonce)
    Show({ title = "Asking " .. host, tone = "wait", icon = "hourglass",
        body = "Asking to join " .. host .. "'s layer for " .. def.name .. ".",
        b2 = { text = "Cancel", onClick = function() J.Cancel() end } })
    ns.Changed()
    C_Timer.After(ASK_TIMEOUT, function()
        if state.mode == "asking" and state.nonce == nonce then
            Reset()
            Result("No answer", host .. " didn't answer. They may be offline or on an older RareWatch.", "warn")
        end
    end)
end

function J.Cancel()
    if (state.mode == "asking" or state.mode == "waiting" or state.mode == "accepted") and state.host then
        Whisper(state.host, "Q", PROTO, state.nonce)
    end
    Reset()
    if bar then bar:Hide() end
end

local function GuestReply(who, nonce, code, extra)
    if not state.host or state.nonce ~= nonce or not SameName(who, state.host) then return end
    local host, def = state.host, state.def
    if code == "WAIT" and state.mode == "asking" then
        state.mode = "waiting"
        state.untilT = GetTime() + PROMPT_FOR
        Show({ title = "Waiting for " .. host, tone = "wait", icon = "hourglass", untilT = state.untilT,
            body = host .. " got your request for " .. def.name .. ". They may be fighting it, so it can take a minute.",
            b2 = { text = "Cancel", onClick = function() J.Cancel() end } })
        C_Timer.After(PROMPT_FOR + 5, function()
            if state.nonce == nonce and state.mode == "waiting" then Reset(); Result("No answer", host .. " didn't answer in time.", "warn") end
        end)
    elseif code == "OK" and (state.mode == "asking" or state.mode == "waiting") then
        state.mode = "accepted"
        Show({ title = host .. " accepted", tone = "info", icon = "check", body = "Joining their group..." })
        C_Timer.After(INVITE_WAIT, function()
            if state.nonce == nonce and state.mode == "accepted" then Reset(); Result("No invite came", "No group invite arrived from " .. host .. ".", "warn") end
        end)
    elseif code == "PULLED" then
        -- the game moved the host instead of us: our moves are used up, whatever our count said
        MarkFull()
        Reset()
        Result("The game moved " .. host .. " instead",
            "Your layer moves for this hour were used up, so the game moved " .. host .. " to your layer. RareWatch now counts your hour as full.", "bad", "info")
        if InGroupWith(host) then Leave() end
    elseif REASONS[code] then
        Reset()
        local wait = tonumber(extra)
        Result("Can't join", string.format(REASONS[code], host, ns.Dur(math.max(60, wait or 0))), "warn")
    end
end

-- After joining: watch for the move, then leave the group again.
local function WatchGuestMove()
    local s = state
    s.mode, s.joinedAt, s.moved = "joined", GetTime(), false
    s.view = ns.InView and ns.InView() or {}
    Show({ title = "Joined " .. s.host .. "'s group", tone = "wait", icon = "hourglass", body = "Waiting for the game to move you to their layer..." })
    local ticker
    ticker = C_Timer.NewTicker(0.5, function()
        if state ~= s then ticker:Cancel(); return end
        local el = GetTime() - s.joinedAt
        if not s.moved and s.view then
            -- everything in view vanishing at once is a move too (in case the game's own signal is missed)
            local now, had, kept = ns.InView and ns.InView() or {}, 0, 0
            for g in pairs(s.view) do had = had + 1; if now[g] then kept = kept + 1 end end
            if had >= 3 and kept <= had * 0.3 then s.moved = GetTime(); RecordMove() end
            s.view = now
        end
        if s.moved and el >= LEAVE_AFTER and GetTime() - s.moved >= 1.5 then
            ticker:Cancel()
            local host, def = s.host, s.def
            if InGroupWith(host) then Leave() end
            Reset()
            Show({ title = "You're on " .. host .. "'s layer", tone = "info", icon = "check", hideIn = 20,
                body = "Left their group again. Go get " .. def.name .. "!" })
        elseif not s.moved and el >= MOVE_WAIT then
            ticker:Cancel()
            local host = s.host
            if InGroupWith(host) then Leave() end
            Reset()
            Result("No layer change", "The game didn't move you, so you were most likely on " .. host
                .. "'s layer already. You've left their group again.", "warn")
        end
    end)
end

---------------------------------------------------------------------------
-- Host side
---------------------------------------------------------------------------
local function RecentInvites()
    local cut, keep = Now() - HOST_WINDOW, {}
    for _, t in ipairs(invites) do if t > cut then keep[#keep + 1] = t end end
    invites = keep
    return #keep
end

local function RecentPrompts()
    local cut, keep = Now() - PROMPT_WINDOW, {}
    for _, t in ipairs(prompts) do if t > cut then keep[#keep + 1] = t end end
    prompts = keep
    return #keep
end

-- Why we can't host this request, or nil.
local function HostCheck(who, id, letter, used, zone)
    if not ns.opt.hostJoin then return "OFF" end
    if (blocked[who] or 0) > Now() then return "BLOCK" end
    if pausedUntil > Now() then return "PAUSED" end
    if (declined[who] or 0) > Now() then return "COOL", declined[who] - Now() end
    if not used or used >= SAFE_USED then return "SWAPS" end
    if ns.InInstance() then return "INST" end
    if InGroup() then return "GROUP" end
    if state.mode ~= "idle" then return "BUSY" end
    if RecentInvites() >= HOST_MAX then return "LIMIT" end
    if RecentPrompts() >= PROMPT_MAX then return "LIMIT" end
    local def = id and id > 0 and ns.LookupAny(id, nil, false)
    if not def then return "OLD" end
    local cur = ns.currentLayer
    if not cur or ns.layerStale then return "NOLAYER" end
    if Clean(ns.LayerShort(cur)):sub(1, 8) ~= letter then return "MOVED" end
    local r = def.layers and def.layers[cur]
    local seen = r and r.seen or 0
    if r and r.down and r.down >= seen and Now() - r.down < FRESH then return "DEAD" end
    if seen == 0 or Now() - seen > FRESH + 60 then return "OLD" end
    local mine = ZoneMap()
    if zone and zone > 0 and mine and zone ~= mine then return "ZONE" end
    return nil, def
end

local function WatchHostMove(guest)
    local s = state
    s.mode, s.joinedAt = "hosting", GetTime()
    s.guestIn = true
    local ticker
    ticker = C_Timer.NewTicker(1, function()
        if state ~= s then ticker:Cancel(); return end
        local el = GetTime() - s.joinedAt
        if s.pulled then ticker:Cancel(); return end
        if not InGroupWith(guest) then
            ticker:Cancel()
            Reset()
            Show({ title = guest .. " joined your layer", tone = "info", icon = "check", hideIn = 8,
                body = "They've left your group again. Nothing else to do." })
        elseif el >= 30 then
            ticker:Cancel()
            Show({ title = guest .. " is still in your group", tone = "warn", icon = "users",
                body = "They should be on your layer by now.",
                b1 = { text = "Remove " .. guest, onClick = function() Uninvite(guest); if bar then bar:Hide() end; Reset() end },
                b2 = { text = "Keep", onClick = function() if bar then bar:Hide() end; Reset() end } })
        end
    end)
end

-- The host was moved within seconds of the guest joining: the guest's moves were used up.
local function HostPulled(s)
    s.pulled = true
    local guest = s.guest
    blocked[guest] = Now() + BLOCK_FOR
    Whisper(guest, "j", PROTO, s.nonce, "PULLED")
    Reset()
    Show({ title = "The game moved you to " .. guest .. "'s layer", tone = "bad", icon = "info",
        body = guest .. "'s layer moves for this hour were used up, so the game moved you instead of them. "
            .. "Sorry - " .. guest .. " can't ask you again for an hour.",
        b1 = InGroupWith(guest) and { text = "Remove " .. guest, onClick = function() Uninvite(guest); if bar then bar:Hide() end end } or nil,
        b2 = { text = "Close", onClick = function() if bar then bar:Hide() end end } })
end

local function HostRequest(who, id, letter, used, zone, nonce)
    local why, def = HostCheck(who, id, letter, used, zone)
    if why then
        Whisper(who, "j", PROTO, nonce, why, why == "COOL" and math.floor(def) or 0)
        return
    end
    prompts[#prompts + 1] = Now()
    state = { mode = "prompt", guest = who, nonce = nonce, def = def, untilT = GetTime() + PROMPT_FOR }
    Whisper(who, "j", PROTO, nonce, "WAIT")
    if ns.opt.alertSound then pcall(PlaySound, 8960) end   -- ready check
    local s = state
    local function Decline()
        if state ~= s then return end
        declined[who] = Now() + DECLINE_COOL
        Whisper(who, "j", PROTO, nonce, "NO")
        Reset()
        if bar then bar:Hide() end
    end
    local function Pause()
        if state ~= s then return end
        pausedUntil = Now() + PAUSE_FOR
        Whisper(who, "j", PROTO, nonce, "PAUSED")
        Reset()
        Result("Join requests paused", "No one can ask to join your layer for 15 minutes.", "info", "hourglass")
        ns.Changed()
    end
    local function Accept()
        if state ~= s then return end
        if InGroup() then
            Whisper(who, "j", PROTO, nonce, "GROUP"); Reset()
            Result("Not sent", "You're in a group now, so " .. who .. " can't be invited.", "warn")
            return
        end
        invites[#invites + 1] = Now()
        Whisper(who, "j", PROTO, nonce, "OK")
        Invite(who)
        s.mode = "invited"
        Show({ title = "Invited " .. who, tone = "wait", icon = "hourglass",
            body = "They'll leave your group again a few seconds after they arrive." })
        C_Timer.After(INVITE_WAIT + 5, function()
            if state == s and s.mode == "invited" then Reset(); if bar then bar:Hide() end end
        end)
    end
    local left = LIMIT - used
    local risk
    if used >= WARN_USED then
        risk = Hex(C.yellow) .. "Caution: " .. who .. " has " .. left .. " layer moves remaining. If the game refuses their move, "
            .. "accepting could move you to their layer instead.|r"
    else
        risk = "Low risk: " .. who .. " has " .. left .. " of " .. LIMIT .. " layer moves remaining."
    end
    Show({ title = who .. " would like to join your layer", tone = used >= WARN_USED and "warn" or "info", icon = "users", untilT = s.untilT,
        body = Hex(C.text2) .. def.name .. "|r" .. DOT .. risk .. "\nIf you're in combat, you can accept after the kill.",
        b1 = { text = "Accept", icon = "check", onClick = Accept },
        b2 = { text = "Decline", onClick = Decline },
        b3 = { text = "Pause 15 min", onClick = Pause } })
    C_Timer.After(PROMPT_FOR, function()
        if state == s and s.mode == "prompt" then
            Whisper(who, "j", PROTO, nonce, "EXP")
            Reset()
            Result("Request expired", who .. "'s request to join your layer timed out.", "warn")
        end
    end)
end

-- The X on the bar. On the host's prompt it says no to this request only: unlike Decline, the player can ask
-- again straight away.
function J.Dismiss()
    if state.mode == "prompt" and state.guest then
        Whisper(state.guest, "j", PROTO, state.nonce, "NO")
        Reset()
    elseif state.mode == "asking" or state.mode == "waiting" then
        J.Cancel()
        return
    end
    if bar then bar:Hide() end
end

---------------------------------------------------------------------------
-- Messages (called from Core's addon-message handler) and events
---------------------------------------------------------------------------
function ns.JoinMessage(tag, who, channel, a, b, c, d, e)
    if channel ~= "WHISPER" then return end
    who = Ambiguate(who, "short")
    if tag == "J" then
        HostRequest(who, tonumber(a), b, tonumber(c), tonumber(d), e)
    elseif tag == "j" then
        GuestReply(who, a, b, c)
    elseif tag == "Q" then
        if SameName(state.guest, who) and state.nonce == a and (state.mode == "prompt" or state.mode == "invited") then
            Reset()
            Result("Request withdrawn", who .. " cancelled their request.", "warn")
        end
    end
end

-- A layer move, whoever caused it.
function J.OnMoved()
    RecordMove()
    if state.mode == "joined" and not state.moved then state.moved = GetTime() end
    if state.mode == "hosting" and state.joinedAt and GetTime() - state.joinedAt < 12 then HostPulled(state) end
end

local ev = CreateFrame("Frame")
for _, e in ipairs({ "PARTY_INVITE_REQUEST", "GROUP_ROSTER_UPDATE", "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "SHARD_TRANSFER" }) do
    pcall(ev.RegisterEvent, ev, e)
end
ev:SetScript("OnEvent", function(_, event, ...)
    if event == "SHARD_TRANSFER" then
        J.OnMoved()
    elseif event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        lastCombat = GetTime()
    elseif event == "PARTY_INVITE_REQUEST" then
        local from = ...
        if state.mode == "accepted" and from and SameName(from, state.host) then
            if InCombat() or Dead() then
                J.Cancel()
                Result("Didn't join", "You were in combat or dead when the invite came.", "warn")
                return
            end
            pcall(AcceptGroup)
            if StaticPopup_Hide then pcall(StaticPopup_Hide, "PARTY_INVITE") end
        end
    elseif event == "GROUP_ROSTER_UPDATE" then
        if state.mode == "accepted" and InGroupWith(state.host) then
            WatchGuestMove()
        elseif state.mode == "invited" and InGroupWith(state.guest) then
            WatchHostMove(state.guest)
        end
    end
end)

---------------------------------------------------------------------------
-- /rwatch swaps
---------------------------------------------------------------------------
function J.PrintSwaps()
    local m = Moves()
    table.sort(m)
    ns.Print(string.format("Layer moves in the last hour: %d of about %d (this account, all characters).", #m, LIMIT))
    for i, t in ipairs(m) do ns.Print(string.format("  %d. %s (%s ago)", i, date("%H:%M:%S", t), ns.Dur(Now() - t))) end
    local w = J.WaitFor()
    if w > 0 then ns.Print("Join requests are paused for " .. ns.Dur(w) .. ".") end
end
