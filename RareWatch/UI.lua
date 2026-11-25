-- RareWatch - UI: main window (sidebar + pages), status box, minimap button.
local _, ns = ...
local W = ns.W
local C = W.C
local Hex = W.Hex

local main, overlay, minimapBtn
local pages, nav, refreshers = {}, {}, {}
local activePage = 1
local selectedKey

local WIN_W, WIN_H, SIDE = 760, 480, 48          -- default size; the window can be resized
local MIN_W, MIN_H, MAX_W, MAX_H = 760, 480, 1500, 1000
local CW, CH = WIN_W - SIDE, WIN_H                 -- content area, updated on resize
local LIST_W = 240
local DW = CW - LIST_W
local layouts = {}                                 -- per page: re-fit to the current size
local DOT = "  \194\183  "
local KILL_ROW_FOR = 120                           -- a kill shows in the status box this long

local STATUS_COLOR = { UP = C.green, SEEN = C.stale, KILLED = C.red, NONE = C.muted }
local function SC(code) return STATUS_COLOR[code] or C.muted end
local function Word(code) return ns.STATUS[code] or ns.STATUS.NONE end

local EVENTS = {
    DOWN  = { label = "Killed",  color = C.red },
    TAME  = { label = "Tamed",   color = C.blue },
    SEEN  = { label = "Sighted", color = C.green },
}

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function SavePos(frame, key)
    local p, _, rp, x, y = frame:GetPoint()
    ns.db[key] = { p, rp, x, y }
end

local function RestorePos(frame, key, default)
    frame:ClearAllPoints()
    local pos = ns.db[key]
    if pos then frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4]) else frame:SetPoint(unpack(default)) end
end

local function Clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function EachRow(list, fn) for _, r in ipairs(list.rows) do fn(r) end end
local function ItemKey(def) return def.id or ns.Key(def.name) end

local function PageTitle(page, text)
    local t = W.Text(page, 17, "M", text)
    t:SetPoint("TOPLEFT", 20, -20)
    return t
end

-- "Rare elite · level 41"
-- "5 - 8 h", or "14.8 h" when the database has one value
local function RespawnText(info)
    if not (info and info.rmin and info.rmax) then return nil end
    if ns.Hours(info.rmin) == ns.Hours(info.rmax) then return ns.Hours(info.rmin) .. " h" end
    return ns.Hours(info.rmin) .. " - " .. ns.Hours(info.rmax) .. " h"
end

local function RankLine(info)
    if not info then return "Rare" end
    return (info.rank == 2 and "Rare elite" or "Rare") .. (info.minl and (DOT .. "level " .. info.minl) or "")
end

-- A rare's record holder, without creating one: the tracked entry, the shadow entry, or an empty stand-in.
local function DefFor(info)
    return ns.LookupAny(info.id, info.name, false) or { name = info.name, id = info.id, layers = {}, standIn = true }
end

-- The two groups the Rares page and the minimap list: this zone's rares, and tracked rares in other zones.
-- Each item: { def, info, st, tracked }. Up first, then the newest news, then by name.
local function ByState(a, b)
    if a.st.prio ~= b.st.prio then return a.st.prio < b.st.prio end
    if a.st.at ~= b.st.at then return a.st.at > b.st.at end
    return a.def.name < b.def.name
end
local function Groups()
    local zone = ns.Zone()
    local here, elsewhere = {}, {}
    for _, info in ipairs(ns.ZoneRares(zone)) do
        local def = DefFor(info)
        here[#here + 1] = { def = def, info = info, st = ns.Status(def), tracked = ns.Lookup(info.id, info.name) ~= nil }
    end
    for _, def in ipairs(ns.list) do
        local info = ns.RareInfo(def.id)
        if not (info and info.zone and info.zone == zone) then
            elsewhere[#elsewhere + 1] = { def = def, info = info, st = ns.Status(def), tracked = true }
        end
    end
    table.sort(here, ByState)
    table.sort(elsewhere, ByState)
    return here, elsewhere, zone
end

function ns.SetWaypoint(info)
    local x, y = info.coords[1], info.coords[2]
    local where = (info.zone or "?") .. " " .. x .. ", " .. y
    if TomTom and TomTom.AddWaypoint and info.ui then
        local ok = pcall(TomTom.AddWaypoint, TomTom, info.ui, x / 100, y / 100, { title = info.name })
        if ok then return true, "TomTom waypoint set: " .. where end
    end
    if info.ui and C_Map and C_Map.SetUserWaypoint and UiMapPoint and UiMapPoint.CreateFromCoordinates then
        local ok = pcall(function()
            C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(info.ui, x / 100, y / 100))
            if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then C_SuperTrack.SetSuperTrackedUserWaypoint(true) end
        end)
        if ok then return true, "Map waypoint set: " .. where end
    end
    return false, where .. "  (install TomTom for waypoints)"
end

-- A "Join" button for a fresh sighting by another player (see Join.lua).
local function JoinButton(parent, big)
    local b = W.Button(parent, { text = "Join", icon = "users", style = big and "primary" or "accent", h = big and 28 or 22, size = big and 12 or 11 })
    b:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Join " .. (self.host or "") .. "'s layer", 1, 1, 1)
        if self.why then
            GameTooltip:AddLine(self.why, 1, 0.75, 0.3, true)
        else
            GameTooltip:AddLine("Asks " .. (self.host or "them") .. " to invite you. Once they accept, the game moves you to their layer and RareWatch leaves the group again.", 0.75, 0.77, 0.8, true)
            if ns.Join then
                GameTooltip:AddLine(string.format("Layer moves used this hour: %d of about %d", ns.Join.Used(), ns.Join.Limit()), 0.6, 0.62, 0.68)
            end
        end
        GameTooltip:Show()
    end)
    b:HookScript("OnLeave", function() GameTooltip:Hide() end)
    b:SetScript("OnClick", function(self)
        if self.disabled or not ns.Join then return end
        ns.Join.Request(self.def, self.st)
    end)
    -- returns true when shown
    function b:Bind(def, st)
        local host, _, why
        if ns.Join and def and st and not def.standIn then host, _, why = ns.Join.CanJoin(def, st) end
        if not host or why == "hide" then self:Hide(); return false end
        self.def, self.st, self.host, self.why = def, st, host, why
        self:SetDisabled(why ~= nil)
        self:Show()
        return true
    end
    b:Hide()
    return b
end

---------------------------------------------------------------------------
-- Rares page: this zone's rares and the ones you track elsewhere
---------------------------------------------------------------------------
local function BuildRares(page)
    -- left column
    local col = CreateFrame("Frame", nil, page)
    col:SetPoint("TOPLEFT", 0, 0)
    col:SetPoint("BOTTOMLEFT", 0, 0)
    col:SetWidth(LIST_W)
    W.Rect(col, C.col)

    local footer = W.Cell(col, 11, "R", LIST_W - 32, C.muted)
    footer:SetPoint("BOTTOMLEFT", 16, 14)

    local ROW_H = 46
    local cards = W.List(col, MAX_H - 20 - 40, ROW_H, function(list)
        local r = CreateFrame("Button", nil, list)
        r.bg = W.Round(r, C.card, 8)
        r.bg:SetColor(C.card, 0)
        r.name = W.Cell(r, 12, "M", 140)
        r.name:SetPoint("TOPLEFT", 12, -9)
        r.word = W.Cell(r, 11, "M", 70, C.text, "RIGHT")
        r.word:SetPoint("TOPRIGHT", -12, -10)
        r.sub = W.Cell(r, 11, "R", 190, C.muted)
        r.sub:SetPoint("TOPLEFT", 12, -26)
        r.head = W.Cell(r, 11, "M", 190, C.muted)
        r.head:SetPoint("BOTTOMLEFT", 12, 8)
        r.headCount = W.Cell(r, 11, "R", 40, C.muted, "RIGHT")
        r.headCount:SetPoint("BOTTOMRIGHT", -12, 8)
        r:SetScript("OnEnter", function(self) if self.item.def and not self.selected then self.bg:SetColor(C.card, 0.5) end end)
        r:SetScript("OnLeave", function(self) if self.item.def and not self.selected then self.bg:SetColor(C.card, 0) end end)
        r:SetScript("OnClick", function(self)
            if not self.item.def then return end
            selectedKey = ItemKey(self.item.def)
            W.HidePopovers()
            ns.RefreshMain()
        end)
        return r
    end, function(r, item)
        r.item = item
        local isHead = item.def == nil
        r.head:SetShown(isHead); r.headCount:SetShown(isHead)
        r.name:SetShown(not isHead); r.word:SetShown(not isHead); r.sub:SetShown(not isHead)
        if isHead then
            r.selected = false
            r.bg:SetColor(C.card, 0)
            r.head:SetText(item.head:upper())
            r.headCount:SetText(item.count or "")
            return
        end
        local def, st = item.def, item.st
        r.selected = ItemKey(def) == selectedKey
        r.bg:SetColor(C.card, r.selected and 1 or 0)
        local muted = ns.IsMuted(def)
        r.name:SetText(def.name)
        W.SetColor(r.name, muted and C.sec or C.text)
        r.word:SetText(Word(st.code))
        W.SetColor(r.word, SC(st.code))
        if st.code == "NONE" then
            r.sub:SetText(RankLine(item.info) .. (item.tracked and item.info and item.info.zone and (DOT .. item.info.zone) or ""))
        else
            r.sub:SetText(ns.ReportText(st) .. DOT .. ns.Ago(st.at))
        end
    end, 2)
    cards:SetPoint("TOPLEFT", 8, -10)
    cards:SetPoint("TOPRIGHT", 0, -10)

    -- detail
    local d = CreateFrame("Frame", nil, page)
    d:SetPoint("TOPLEFT", LIST_W, 0)
    d:SetPoint("BOTTOMRIGHT", 0, 0)
    local PAD = 22
    local TW = DW - PAD * 2

    local name = W.Cell(d, 17, "M", TW - 140)
    name:SetPoint("TOPLEFT", PAD, -22)
    local meta = W.Cell(d, 12, "R", TW - 40, C.sec)
    meta:SetPoint("TOPLEFT", PAD, -46)

    local pill = CreateFrame("Frame", nil, d)
    pill:SetSize(100, 22)
    pill:SetPoint("TOPRIGHT", -PAD - 30, -22)
    pill.bg = W.Round(pill, C.chip, 11)
    pill.text = W.Text(pill, 11, "M", "", C.text, "CENTER")
    pill.text:SetPoint("CENTER")

    local heroLabel = W.Text(d, 12, "R", "", C.sec)
    heroLabel:SetPoint("TOPLEFT", PAD, -86)
    local hero = W.Cell(d, 24, "S", TW - 120)
    hero:SetPoint("TOPLEFT", PAD, -104)
    local heroNote = W.Cell(d, 12, "R", TW, C.muted)
    heroNote:SetPoint("TOPLEFT", PAD, -138)
    local bigJoin = JoinButton(d, true)
    bigJoin:SetPoint("TOPRIGHT", -PAD, -104)

    -- reports / drops tabs
    local detailTab = "reports"
    local tabReports = W.Button(d, { text = "Reports", h = 24, size = 11 })
    tabReports:SetPoint("TOPLEFT", PAD, -172)
    local tabDrops = W.Button(d, { text = "Drops", icon = "sparkles", h = 24, size = 11 })
    tabDrops:SetPoint("LEFT", tabReports, "RIGHT", 6, 0)
    local dropNote = W.Text(d, 10, "R", "", C.muted, "RIGHT")
    dropNote:SetPoint("TOPRIGHT", -PAD + 8, -178)

    local LIST_Y = -206
    local reportList
    reportList = W.List(d, 24 * 30, 30, function(list)
        local r = CreateFrame("Frame", nil, list)
        r.dot = W.Dot(r, 7)
        r.dot:SetPoint("LEFT", 0, 0)
        r.text = W.Cell(r, 12, "M", 260)
        r.text:SetPoint("LEFT", 16, 0)
        r.when = W.Cell(r, 11, "R", 160, C.muted, "RIGHT")
        r.when:SetPoint("RIGHT", 0, 0)
        r.join = JoinButton(r)
        r.join:SetPoint("RIGHT", 0, 0)
        r.sep = W.Line(r)
        r.sep:SetPoint("BOTTOMLEFT")
        r.sep:SetPoint("BOTTOMRIGHT")
        return r
    end, function(r, rep, idx)
        local c = SC(rep.code)
        r.dot:SetVertexColor(c[1], c[2], c[3], 1)
        r.text:SetText(ns.ReportText(rep))
        W.SetColor(r.text, rep.code == "UP" and C.text or C.text2)
        r.when:SetText(ns.Ago(rep.at) .. DOT .. ns.Day(rep.at))
        local joinable = r.join:Bind(r.def, rep)
        r.when:ClearAllPoints()
        r.when:SetPoint("RIGHT", joinable and -(r.join:GetWidth() + 10) or 0, 0)
        r.sep:SetShown(idx < #reportList.data)
    end)
    reportList:SetPoint("TOPLEFT", PAD, LIST_Y)
    reportList:SetPoint("TOPRIGHT", -PAD + 8, LIST_Y)

    local dropList
    dropList = W.List(d, 28 * 24, 24, function(list)
        local r = CreateFrame("Frame", nil, list)
        r:EnableMouse(true)
        r.name = W.Cell(r, 12, "M", 236)
        r.name:SetPoint("LEFT", 0, 0)
        r.pct = W.Cell(r, 12, "R", 56, C.sec, "RIGHT")
        r.pct:SetPoint("LEFT", 240, 0)
        r.val = W.Cell(r, 11, "R", 124, C.muted, "RIGHT")
        r.val:SetPoint("RIGHT", 0, 0)
        r.sep = W.Line(r)
        r.sep:SetPoint("BOTTOMLEFT")
        r.sep:SetPoint("BOTTOMRIGHT")
        r.sep:SetAlpha(0.6)
        r:SetScript("OnEnter", function(self)
            local row = self.row
            if row and row.kind == "item" then
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                local ok = pcall(GameTooltip.SetHyperlink, GameTooltip, "item:" .. row.id)
                if not ok then GameTooltip:SetText(row.name, 1, 1, 1) end
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine(string.format("%g%% chance%s", row.pct, row.quest and " (quest item)" or ""), 0.6, 0.62, 0.68)
                GameTooltip:AddLine(row.seen and "Measured in WoW Forever (ForeverDB.net)" or (row.wh and "New in Forever - small sample, rate is rough" or "Vanilla value - Forever may differ"), 0.6, 0.62, 0.68)
                GameTooltip:Show()
            elseif row and row.kind == "pool" then
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                GameTooltip:SetText(ns.PoolText(row), 1, 1, 1)
                GameTooltip:AddLine("One item picked at random from a pool of " .. row.n .. ". Any single item is a long shot.", 0.75, 0.77, 0.8, true)
                GameTooltip:Show()
            end
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        return r
    end, function(r, row, idx)
        r.row = row
        r.sep:SetShown(idx < #dropList.data)
        if row.kind == "gold" then
            r.name:SetText("Gold"); W.SetColor(r.name, C.yellow)
            r.pct:SetText("")
            r.val:SetText(ns.CoinText(row.min) .. " - " .. ns.CoinText(row.max)); W.SetColor(r.val, C.text2)
        elseif row.kind == "tame" then
            r.name:SetText("Tameable"); W.SetColor(r.name, C.accent)
            r.pct:SetText("")
            r.val:SetText(row.family); W.SetColor(r.val, C.text2)
        elseif row.kind == "pool" then
            r.name:SetText("|cff" .. ns.QualityHex(row.q) .. ns.PoolText(row) .. "|r")
            r.pct:SetText(string.format("%g%%", row.pct)); W.SetColor(r.pct, C.sec)
            r.val:SetText("1 of " .. row.n); W.SetColor(r.val, C.muted)
        else
            r.name:SetText("|cff" .. ns.QualityHex(row.q) .. row.name .. "|r" .. (row.quest and ("  " .. Hex(C.muted) .. "quest|r") or "") .. ((row.seen or row.wh) and ("  " .. Hex(C.accent) .. (row.seen and "seen|r" or "new|r")) or ""))
            r.pct:SetText(string.format("%g%%", row.pct)); W.SetColor(r.pct, row.pct >= 25 and C.accent or C.sec)
            local worth, src = ns.ItemWorth(row.id)
            r.val:SetText(worth and (Hex(C.text2) .. ns.CoinText(worth) .. "|r  " .. src) or "")
            W.SetColor(r.val, C.muted)
        end
    end, 0)
    dropList:SetPoint("TOPLEFT", PAD, LIST_Y)
    dropList:SetPoint("TOPRIGHT", -PAD + 8, LIST_Y)

    tabReports:SetScript("OnClick", function() detailTab = "reports"; ns.RefreshMain() end)
    tabDrops:SetScript("OnClick", function() detailTab = "drops"; ns.RefreshMain() end)

    -- actions
    local feedback = W.Cell(d, 11, "R", TW, C.muted)
    feedback:SetPoint("BOTTOMLEFT", PAD, 58)
    local fbToken = 0
    local function Feedback(ok, msg)
        feedback:SetText((ok and Hex(C.accent) or Hex(C.red)) .. msg .. "|r")
        fbToken = fbToken + 1
        local tok = fbToken
        C_Timer.After(6, function() if tok == fbToken then feedback:SetText("") end end)
    end

    local current   -- the item shown
    local track = W.Button(d, { text = "Track", icon = "plus", style = "primary", onClick = function()
        if not current then return end
        local def = current.def
        if current.tracked then
            ns.RemoveMob(def)
            Feedback(true, "Stopped tracking " .. def.name .. ".")
        else
            local nd = ns.TrackRare(def.id)
            if nd then Feedback(true, "Tracking " .. nd.name .. ": you'll hear about it in any zone.") end
        end
        ns.RefreshMain()
    end })
    track:SetPoint("BOTTOMLEFT", PAD, 20)
    track:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(current and current.tracked and "Stop tracking" or "Track", 1, 1, 1)
        GameTooltip:AddLine("Rares in the zone you're in are always watched. Tracking keeps one watched in every zone, so you hear when another RareWatch user sees it.", 0.75, 0.77, 0.8, true)
        GameTooltip:Show()
    end)
    track:HookScript("OnLeave", function() GameTooltip:Hide() end)
    local waypoint = W.Button(d, { text = "Waypoint", icon = "pin", onClick = function()
        local info = current and current.info
        if info and info.coords and info.coords[1] then Feedback(ns.SetWaypoint(info)) end
    end })
    waypoint:SetPoint("LEFT", track, "RIGHT", 8, 0)
    local bell = W.Button(d, { icon = "bell", w = 28, h = 28, style = "ghost", onClick = function()
        if not current then return end
        local def = current.def
        local mute = not ns.IsMuted(def)
        ns.SetMuted(def, mute)
        Feedback(true, mute and ("Muted " .. def.name .. ": still listed, but no alerts.") or ("Alerts on for " .. def.name .. "."))
    end, tip = { "Mute", "Turns off the sound, text and chat alerts for this rare. It stays listed." } })
    bell:SetPoint("BOTTOMRIGHT", -PAD, 20)

    local emptyHint = W.Text(d, 12, "R", "", C.muted, "CENTER")
    emptyHint:SetPoint("CENTER", 0, 20)
    emptyHint:SetWidth(400)
    emptyHint:SetHeight(36)
    emptyHint:SetJustifyV("TOP")
    local browseBtn = W.Button(d, { text = "Browse rares", icon = "search", style = "primary", onClick = function() ns.ShowPage(2) end })
    browseBtn:SetPoint("TOP", emptyHint, "BOTTOM", 0, -14)
    local detailParts = { name, meta, pill, heroLabel, hero, heroNote, tabReports, tabDrops, dropNote,
        reportList, dropList, track, waypoint, bell, feedback }

    layouts[1] = function()
        LIST_W = Clamp(math.floor(CW * 0.3), 240, 360)
        col:SetWidth(LIST_W)
        d:ClearAllPoints()
        d:SetPoint("TOPLEFT", LIST_W, 0)
        d:SetPoint("BOTTOMRIGHT", 0, 0)
        footer:SetWidth(LIST_W - 32)
        local cw = LIST_W - 16 - 24
        EachRow(cards, function(r) r.name:SetWidth(cw - 76); r.sub:SetWidth(cw); r.head:SetWidth(cw - 44) end)
        DW = CW - LIST_W
        TW = DW - PAD * 2
        local RW = TW
        EachRow(reportList, function(r) r.text:SetWidth(math.max(200, RW - 16 - 160 - 80)) end)
        local nameW = math.max(236, RW - 56 - 124 - 12)
        EachRow(dropList, function(r)
            r.name:SetWidth(nameW)
            r.pct:ClearAllPoints(); r.pct:SetPoint("LEFT", nameW + 4, 0)
        end)
        name:SetWidth(TW - 140)
        meta:SetWidth(TW - 40)
        hero:SetWidth(TW - 120)
        heroNote:SetWidth(TW)
        feedback:SetWidth(TW)
        cards:Fit(CH - 10 - 40)
        local listH = CH + LIST_Y - 74          -- room down to the action buttons
        reportList:Fit(listH)
        dropList:Fit(listH)
    end
    layouts[1]()

    refreshers[1] = function()
        local here, elsewhere, zone = Groups()
        local items = {}
        items[#items + 1] = { head = zone or "This zone", count = #here > 0 and tostring(#here) or "" }
        for _, it in ipairs(here) do items[#items + 1] = it end
        if #elsewhere > 0 then
            items[#items + 1] = { head = "Tracked elsewhere", count = tostring(#elsewhere) }
            for _, it in ipairs(elsewhere) do items[#items + 1] = it end
        end
        -- keep the selection on the same rare; otherwise pick the first
        current = nil
        for _, it in ipairs(items) do if it.def and ItemKey(it.def) == selectedKey then current = it; break end end
        if not current then
            for _, it in ipairs(items) do if it.def then current = it; break end end
            selectedKey = current and ItemKey(current.def)
        end
        cards:SetData(items, "")

        local online = ns.OnlineUsers()
        if GetChannelName(ns.CHANNEL) > 0 or ns.IsSharing() then
            footer:SetText(Hex(C.accent) .. "Live|r" .. DOT .. (online == 1 and "1 other user online" or (online .. " other users online")))
        else
            footer:SetText(Hex(C.orange) .. "Not connected|r - click Connect in Settings")
        end

        for _, f in ipairs(detailParts) do f:SetShown(current ~= nil) end
        emptyHint:SetShown(current == nil)
        browseBtn:SetShown(current == nil)
        if not current then
            bigJoin:Hide()
            emptyHint:SetText((zone and ("No known rares in " .. zone .. ".") or "No known rares here.")
                .. "\nRares you track show here from any zone.")
            return
        end

        local def, info, st = current.def, current.info, current.st
        name:SetText(def.name)
        local parts = { RankLine(info) }
        if info and info.zone then
            parts[#parts + 1] = info.zone .. ((info.coords and info.coords[1]) and (" " .. info.coords[1] .. ", " .. info.coords[2]) or "")
        end
        if ns.IsMuted(def) then parts[#parts + 1] = Hex(C.muted) .. "Muted|r" end
        meta:SetText(table.concat(parts, DOT))

        local c = SC(st.code)
        pill.text:SetText(Word(st.code))
        W.SetColor(pill.text, c)
        pill.bg:SetColor(W.Mix(C.bg, c, 0.18))
        pill:SetWidth(math.floor(pill.text:GetStringWidth() + 24.5))

        if st.code == "NONE" then
            heroLabel:SetText("No reports yet")
            hero:SetText("--")
            W.SetColor(hero, C.muted)
            heroNote:SetText("When you or another RareWatch user sees or kills it, it shows here.")
        else
            heroLabel:SetText(st.code == "UP" and "Up now" or (st.code == "SEEN" and "Last seen alive" or (st.kind == "TAME" and "Last tamed" or "Last killed")))
            hero:SetText(ns.ReportText(st))
            W.SetColor(hero, st.code == "UP" and C.green or C.text)
            local note = ns.Ago(st.at) .. DOT .. ns.Day(st.at)
            if st.code == "SEEN" then
                note = note .. DOT .. "it may have been killed since"
            elseif st.code == "KILLED" and info and info.rmin and info.rmax and info.rmax > 0 then
                note = note .. DOT .. "respawns in about " .. RespawnText(info)
            end
            heroNote:SetText(note)
        end
        if not bigJoin:Bind(def, st) then bigJoin:Hide() end

        local reps = (st.code == "NONE") and {} or select(2, ns.Status(def))
        for _, rep in ipairs(reps) do rep.def = def end
        EachRow(reportList, function(r) r.def = def end)
        tabReports:SetLabel("Reports" .. (#reps > 0 and ("  " .. #reps) or ""))
        tabReports:SetStyle(detailTab == "reports" and "accent" or "default")
        tabDrops:SetStyle(detailTab == "drops" and "accent" or "default")
        reportList:SetShown(detailTab == "reports")
        dropList:SetShown(detailTab == "drops")
        local rows = ns.DropRows(def.id)
        dropNote:SetText(ns.DropsSeen(def.id) and "Forever rates: ForeverDB.net data + small samples" or "Vanilla loot data. Forever may differ.")
        dropNote:SetShown(detailTab == "drops" and rows ~= nil)
        if detailTab == "reports" then
            reportList:SetData(reps, "")
        else
            dropList:SetData(rows or {}, "No drop data for this rare.")
        end

        if current.tracked then
            track:SetLabel("Tracking"); track:SetIcon("check"); track:SetStyle("default")
        else
            track:SetLabel("Track"); track:SetIcon("plus"); track:SetStyle("primary")
        end
        track:SetShown(def.id ~= nil and ns.RareInfo(def.id) ~= nil or current.tracked)
        waypoint:SetShown(info and info.coords and info.coords[1] and true or false)
        W.SetColor(bell.icon, ns.IsMuted(def) and C.muted or C.accent)
    end
end

---------------------------------------------------------------------------
-- Browse page
---------------------------------------------------------------------------
-- What the Browse list and its tooltip say about a rare's state.
local function BrowseState(info)
    local any = ns.LookupAny(info.id, info.name, false)
    local st = any and ns.Status(any)
    if st and st.code ~= "NONE" then
        return Word(st.code) .. DOT .. ns.Ago(st.at), SC(st.code)
    end
    local seen = ns.LastSeenInForever(info.id)
    if seen then return "Seen in Forever " .. ns.Ago(seen), C.sec end
    return "Not seen yet", C.muted
end

local function BuildBrowse(page)
    local title = PageTitle(page, "Browse rares")
    local count = W.Text(page, 12, "R", "", C.muted)
    count:SetPoint("LEFT", title, "RIGHT", 12, -1)

    local search = W.Edit(page, 230, 30, "Search name, zone or drop")
    search:SetPoint("TOPRIGHT", -56, -16)
    local sIcon = W.Icon(search, "search", 14, C.muted)
    sIcon:SetPoint("RIGHT", -10, 0)

    local filt = { elite = false, seen = false, untracked = false, tame = false }
    local x = 20
    for _, f in ipairs({ { "elite", "Rare elites" }, { "seen", "Seen in Forever" }, { "untracked", "Not tracked" }, { "tame", "Tameable" } }) do
        local c = W.ToggleChip(page, f[2], function() return filt[f[1]] end, function(v) filt[f[1]] = v; refreshers[2]() end)
        c:SetPoint("TOPLEFT", x, -62)
        x = x + c:GetWidth() + 6
    end

    local list = W.List(page, MAX_H - 104 - 12, 44, function(lst)
        local r = CreateFrame("Frame", nil, lst)
        r.bg = W.Round(r, C.chip, 8)
        r.bg:SetColor(C.chip, 0)
        r:EnableMouse(true)
        r.name = W.Cell(r, 12, "M", 290)
        r.name:SetPoint("TOPLEFT", 14, -8)
        r.sub = W.Cell(r, 11, "R", 314, C.muted)
        r.sub:SetPoint("TOPLEFT", 14, -26)
        r.resp = W.Cell(r, 12, "R", 90, C.sec)
        r.resp:SetPoint("LEFT", 330, 0)
        r.seen = W.Cell(r, 12, "R", 130, C.muted)
        r.seen:SetPoint("LEFT", 430, 0)
        r.btn = W.Button(r, { text = "Track", w = 92, h = 26, size = 11 })
        r.btn:SetPoint("RIGHT", -10, 0)
        r.btn:SetScript("OnClick", function()
            local info = r.info
            local tracked = ns.Lookup(info.id, info.name)
            if tracked then ns.RemoveMob(tracked) else ns.TrackRare(info.id) end
            refreshers[2]()
        end)
        r.btn:HookScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            local tracked = r.info and ns.Lookup(r.info.id, r.info.name)
            GameTooltip:SetText(tracked and "Stop tracking" or "Track", 1, 1, 1)
            GameTooltip:AddLine("Rares in the zone you're in are always watched. Tracking keeps one watched in every zone.", 0.75, 0.77, 0.8, true)
            GameTooltip:Show()
        end)
        r.btn:HookScript("OnLeave", function() GameTooltip:Hide() end)
        r:SetScript("OnEnter", function(self)
            self.bg:SetColor(C.chip, 1)
            local info = self.info
            if not info then return end
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            GameTooltip:SetText(info.name, 1, 1, 1)
            GameTooltip:AddLine(RankLine(info) .. "   NPC " .. info.id, 0.75, 0.77, 0.8)
            if info.coords and info.coords[1] then
                local pts = {}
                for k = 1, #info.coords, 2 do pts[#pts + 1] = info.coords[k] .. ", " .. info.coords[k + 1] end
                GameTooltip:AddLine((info.zone or "?") .. ":  " .. table.concat(pts, "   "), 0.75, 0.77, 0.8, true)
            end
            local any = ns.LookupAny(info.id, info.name, false)
            if any then
                for i, rep in ipairs(select(2, ns.Status(any))) do
                    if i > 5 then break end
                    local c = SC(rep.code)
                    GameTooltip:AddDoubleLine(ns.ReportText(rep), ns.Ago(rep.at), c[1], c[2], c[3], 0.6, 0.62, 0.68)
                end
            end
            local drops = ns.DropRows(info.id)
            if drops then
                local shown = 0
                for _, dr in ipairs(drops) do
                    if dr.kind == "item" and shown < 5 then
                        if shown == 0 then GameTooltip:AddLine(" "); GameTooltip:AddLine("Drops", 0.6, 0.62, 0.68) end
                        GameTooltip:AddDoubleLine("|cff" .. ns.QualityHex(dr.q) .. dr.name .. "|r", string.format("%g%%", dr.pct), 1, 1, 1, 0.75, 0.77, 0.8)
                        shown = shown + 1
                    end
                end
            end
            if info.discovered then
                GameTooltip:AddLine("Not in the built-in list - discovered in Forever.", 0.37, 0.84, 0.66, true)
            end
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function(self) self.bg:SetColor(C.chip, 0); GameTooltip:Hide() end)
        return r
    end, function(r, info)
        r.info = info
        local tracked = ns.Lookup(info.id, info.name)
        r.name:SetText(info.name .. (info.discovered and ("   " .. Hex(C.accent) .. "NEW|r") or ""))
        local fam = ns.TameFamily(info.id)
        if info.dropHit then
            r.sub:SetText(Hex(C.accent) .. "Drops " .. info.dropHit .. "|r" .. DOT .. (info.zone or "Unknown zone"))
        else
            r.sub:SetText((info.zone or "Unknown zone") .. DOT .. RankLine(info)
                .. (fam and (DOT .. Hex(C.accent) .. "Tame: " .. fam .. "|r") or ""))
        end
        r.resp:SetText(RespawnText(info) or "Unknown")
        local text, col = BrowseState(info)
        r.seen:SetText(text)
        W.SetColor(r.seen, col)
        if tracked then
            r.btn:SetStyle("ghost"); r.btn:SetIcon("check"); r.btn:SetLabel("Tracking")
        else
            r.btn:SetStyle("default"); r.btn:SetIcon(nil); r.btn:SetLabel("Track")
        end
    end, 4)
    list:SetPoint("TOPLEFT", 12, -104)
    list:SetPoint("TOPRIGHT", -12, -104)
    layouts[2] = function()
        local RW = CW - 24 - 8
        local nameW = 290 + math.floor(math.max(0, RW - 680) * 0.35)
        local respX = nameW + 40
        local seenX = respX + 100
        EachRow(list, function(r)
            r.name:SetWidth(nameW); r.sub:SetWidth(nameW + 24)
            r.resp:ClearAllPoints(); r.resp:SetPoint("LEFT", respX, 0)
            r.seen:ClearAllPoints(); r.seen:SetPoint("LEFT", seenX, 0)
            r.seen:SetWidth(math.max(150, RW - seenX - 92 - 24))
        end)
        list:Fit(CH - 104 - 12)
    end
    layouts[2]()

    local lastQuery
    search.onChange = function() if refreshers[2] then refreshers[2]() end end
    refreshers[2] = function()
        local q = strtrim(search:GetText() or ""):lower()
        if q ~= lastQuery then list.offset = 0; lastQuery = q end
        local out, total = {}, 0
        for _, info in pairs(ns.rareIndex) do
            total = total + 1
            local ok = true
            info.dropHit = nil
            if q ~= "" and not (info.name:lower():find(q, 1, true) or (info.zone and info.zone:lower():find(q, 1, true))) then
                info.dropHit = ns.DropMatchName(info.id, q)
                if not info.dropHit then ok = false end
            end
            if ok and filt.tame and not ns.TameFamily(info.id) then ok = false end
            if ok and filt.elite and info.rank ~= 2 then ok = false end
            if ok and filt.seen and not ns.LastSeenInForever(info.id) then ok = false end
            if ok and filt.untracked and ns.Lookup(info.id, info.name) then ok = false end
            if ok then out[#out + 1] = info end
        end
        table.sort(out, function(a, b)
            local ad, bd = a.discovered and true or false, b.discovered and true or false
            if ad ~= bd then return ad end
            local az, bz = a.zone or "~", b.zone or "~"
            if az ~= bz then return az < bz end
            return a.name < b.name
        end)
        count:SetText(#out == total and (total .. " rares") or (#out .. " of " .. total))
        list:SetData(out, "No rares match your search.")
    end
end

---------------------------------------------------------------------------
-- History page
---------------------------------------------------------------------------
local function BuildHistory(page)
    local title = PageTitle(page, "History")
    local count = W.Text(page, 12, "R", "", C.muted)
    count:SetPoint("LEFT", title, "RIGHT", 12, -1)
    local clear = W.ConfirmButton(page, { text = "Clear", icon = "trash", style = "ghost", h = 28 }, function()
        wipe(ns.db.history)
        ns.Changed()
    end)
    clear:SetPoint("TOPRIGHT", -56, -16)

    local search = W.Edit(page, 200, 30, "Search rare or player")
    search:SetPoint("RIGHT", clear, "LEFT", -10, 0)
    local sIcon = W.Icon(search, "search", 14, C.muted)
    sIcon:SetPoint("RIGHT", -10, 0)

    local list = W.List(page, MAX_H - 70 - 12, 36, function(lst)
        local r = CreateFrame("Frame", nil, lst)
        r.dot = W.Dot(r, 7)
        r.dot:SetPoint("LEFT", 12, 0)
        r.event = W.Cell(r, 12, "M", 70)
        r.event:SetPoint("LEFT", 28, 0)
        r.mob = W.Cell(r, 12, "R", 240)
        r.mob:SetPoint("LEFT", 104, 0)
        r.src = W.Cell(r, 12, "R", 140, C.muted)
        r.src:SetPoint("LEFT", 350, 0)
        r.time = W.Cell(r, 11, "R", 150, C.muted, "RIGHT")
        r.time:SetPoint("RIGHT", -12, 0)
        r.join = JoinButton(r)
        r.join:SetPoint("RIGHT", -12, 0)
        r.sep = W.Line(r)
        r.sep:SetPoint("BOTTOMLEFT", 12, 0)
        r.sep:SetPoint("BOTTOMRIGHT", -12, 0)
        return r
    end, function(r, h)
        local e = EVENTS[h.k] or { label = h.k, color = C.text }
        r.dot:SetVertexColor(e.color[1], e.color[2], e.color[3], 1)
        r.event:SetText(e.label)
        W.SetColor(r.event, e.color)
        r.mob:SetText(h.n)
        local who = ns.Reporter(h.l, h.s)
        r.src:SetText("by " .. (who == "You" and "you" or who))
        r.time:SetText(ns.Ago(h.t) .. DOT .. ns.Day(h.t))
        local joinable = false
        if h.k == "SEEN" and ns.Now() - h.t < ns.FRESH then
            local def = ns.LookupAny(nil, h.n, false)
            local rec = def and def.layers and def.layers[h.l]
            if rec then joinable = r.join:Bind(def, { layer = h.l, rec = rec }) else r.join:Hide() end
        else
            r.join:Hide()
        end
        r.time:ClearAllPoints()
        r.time:SetPoint("RIGHT", joinable and -(r.join:GetWidth() + 22) or -12, 0)
        r.time:SetWidth(joinable and 120 or 150)
    end)
    list:SetPoint("TOPLEFT", 8, -70)
    list:SetPoint("TOPRIGHT", -12, -70)
    layouts[3] = function()
        local extra = math.max(0, (CW - 20 - 8) - 684)
        local mobW = 240 + math.floor(extra * 0.4)
        local srcX = 104 + mobW + 6
        local srcW = 140 + math.floor(extra * 0.4)
        EachRow(list, function(r)
            r.mob:SetWidth(mobW)
            r.src:ClearAllPoints(); r.src:SetPoint("LEFT", srcX, 0); r.src:SetWidth(srcW)
        end)
        list:Fit(CH - 70 - 12)
    end
    layouts[3]()

    -- newest event first, by when it happened (not by when it reached us)
    local function Newest(a, b) return (a.t or 0) > (b.t or 0) end
    refreshers[3] = function()
        local all = ns.db.history
        local q = strtrim(search:GetText() or ""):lower()
        local out = {}
        for _, h in ipairs(all) do
            if q == "" then
                out[#out + 1] = h
            else
                local e = EVENTS[h.k]
                local hay = ((h.n or "") .. " " .. ns.Reporter(h.l, h.s) .. " " .. (e and e.label or "")):lower()
                if hay:find(q, 1, true) then out[#out + 1] = h end
            end
        end
        table.sort(out, Newest)
        local n = #all
        if q == "" then
            count:SetText(n > 0 and (n .. (n == 1 and " event" or " events")) or "")
        else
            count:SetText(#out .. " of " .. n)
        end
        list:SetData(out, q == "" and "Nothing yet. Kills, tames and sightings from you\nand other RareWatch users are listed here."
            or "No events match your search.")
    end
    search.onChange = function() if refreshers[3] then refreshers[3]() end end
end

---------------------------------------------------------------------------
-- Settings page
---------------------------------------------------------------------------
local function BuildSettings(page)
    PageTitle(page, "Settings")
    local o = ns.opt
    local refreshables = {}
    local PADX = 16
    -- Each section is a card. The layout deals the cards into 2 or 3 columns
    -- depending on the window width, and stretches them to fill it.
    local sections, cur = {}, nil

    local function Section(text)
        local card = CreateFrame("Frame", nil, page)
        W.Round(card, C.card, 10)
        local t = W.Text(card, 11, "M", text:upper(), C.muted)
        t:SetPoint("TOPLEFT", PADX, -14)
        cur = { card = card, rows = {} }
        sections[#sections + 1] = cur
    end
    local function Row(label, control, tip)
        local card = cur.card
        local row = CreateFrame("Frame", nil, card)   -- placed by Layout
        if tip then row:EnableMouse(true) end
        local l = W.Cell(row, 12, "R", 200, C.text2)
        l:SetPoint("LEFT", 0, 0)
        l:SetText(label)
        if control then
            control:SetParent(row)
            control:ClearAllPoints()
            control:SetPoint("RIGHT", 0, 0)
            if control.Refresh then refreshables[#refreshables + 1] = control end
        end
        if tip then W.Tip(row, label, tip) end
        local sep = W.Line(row)
        sep:SetPoint("BOTTOMLEFT")
        sep:SetPoint("BOTTOMRIGHT")
        sep:SetAlpha(0.6)
        row.label, row.control = l, control
        cur.rows[#cur.rows + 1] = row
        return row
    end

    local function Layout()
        local avail = CW - 40
        local ncol = avail >= 1040 and 3 or 2
        local GAP = 14
        local colW = Clamp(math.floor((avail - GAP * (ncol - 1)) / ncol), 300, 480)
        -- which column each section goes in: Alerts, Display, Sharing, Advanced
        local plan = ncol == 3 and { 1, 2, 3, 3 } or { 1, 1, 2, 2 }
        -- row height: as roomy as the window height allows
        local HEAD, FOOT, TOP = 36, 12, 60
        local rows, secs = { 0, 0, 0 }, { 0, 0, 0 }
        for i, sec in ipairs(sections) do
            local c = plan[i]
            rows[c] = rows[c] + #sec.rows
            secs[c] = secs[c] + 1
        end
        local function Fits()
            local rh = 28
            for c = 1, ncol do
                if rows[c] > 0 then
                    local free = CH - TOP - 12 - secs[c] * (HEAD + FOOT) - (secs[c] - 1) * GAP
                    rh = math.min(rh, math.floor(free / rows[c]))
                end
            end
            return rh
        end
        local rh = Fits()
        if rh < 25 then HEAD, FOOT, GAP, TOP = 32, 8, 10, 56; rh = Fits() end
        rh = math.max(22, rh)
        local ys = { -TOP, -TOP, -TOP }
        for i, sec in ipairs(sections) do
            local c = plan[i]
            for k, row in ipairs(sec.rows) do
                local y = -HEAD - (k - 1) * rh
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", PADX, y)
                row:SetPoint("TOPRIGHT", -PADX, y)
                row:SetHeight(rh)
            end
            sec.card:SetHeight(HEAD + #sec.rows * rh + FOOT)
            sec.card:ClearAllPoints()
            sec.card:SetPoint("TOPLEFT", 20 + (c - 1) * (colW + GAP), ys[c])
            sec.card:SetWidth(colW)
            ys[c] = ys[c] - sec.card:GetHeight() - GAP
            for _, row in ipairs(sec.rows) do
                local cw = row.control and row.control:GetWidth() or 0
                row.label:SetWidth(math.max(80, colW - PADX * 2 - cw - (cw > 0 and 12 or 0)))
            end
        end
    end
    layouts[4] = Layout
    local function Opt(key) return W.Switch(page, function() return o[key] end, function(v) o[key] = v; ns.Changed() end) end

    Section("Alerts")
    local alertTip = "Alerts are for rares in the zone you're in and rares you track: once when one is spotted, by you or another RareWatch user. Mute a rare on its page to silence just that one."
    Row("Play a sound", Opt("alertSound"), alertTip)
    local soundBtn
    soundBtn = W.Button(page, { text = "", icon = "volume", h = 24, size = 11, onClick = function()
        o.sound = (o.sound % #ns.SOUNDS) + 1
        soundBtn:SetLabel(ns.SOUNDS[o.sound].name)
        ns.PlayAlertSound()
    end, tip = { "Alert sound", "Click to cycle sounds. Plays a preview." } })
    soundBtn.Refresh = function(self) self:SetLabel((ns.SOUNDS[o.sound] or ns.SOUNDS[1]).name) end
    Row("Sound", soundBtn)
    Row("Big text on screen", Opt("alertRaidWarn"), "For rares in the zone you're in.")
    Row("Flash the taskbar icon", Opt("alertFlash"), "For rares in the zone you're in.")
    Row("Message in chat", Opt("alertChat"), "Sightings, and kills of rares you're watching.")
    Row("Try it out", W.Button(page, { text = "Test alert", icon = "bell", h = 24, size = 11, onClick = function()
        ns.Alert("TEST: a rare is up!")
    end }))

    Section("Display")
    Row("Status box", Opt("showTracker"), "The small box that lists rares spotted in your zone in the last 10 minutes, with a Join button.")
    Row("Hide the box when nothing is up", Opt("boxHideEmpty"), "The box shows itself again when a rare in your zone is spotted.")
    Row("Lock status box", Opt("lockTracker"))
    Row("Minimap button", W.Switch(page, function() return not o.minimapHide end,
        function(v) o.minimapHide = not v; ns.Changed() end))
    local pct = function(v) return math.floor(v * 100 + 0.5) .. "%" end
    Row("Status box size", W.Stepper(page, function() return o.trackerScale end,
        function(v) o.trackerScale = v; ns.Changed() end, 0.6, 1.6, 0.1, pct))
    Row("Window size", W.Stepper(page, function() return o.windowScale end,
        function(v) o.windowScale = v; main:SetScale(v) end, 0.7, 1.4, 0.1, pct))

    Section("Sharing")
    Row("Share with my guild", Opt("shareGuild"))
    Row("Share with RareWatch users", W.Switch(page, function() return GetChannelName(ns.CHANNEL) > 0 end,
        function(v) ns.SetChannel(v) end),
        "Kills, tames and sightings are shared automatically with everyone running RareWatch, through a hidden chat channel. Members can see your character name in the channel list.")
    Row("Share with my group", Opt("shareGroup"), "Also share with your party or raid.")
    local onlineRow = Row("Users online", W.Button(page, { text = "Resync", icon = "refresh", h = 24, size = 11,
        onClick = function() ns.SyncNow() end }), "Syncing is automatic. Resync just does it right now.")
    local hostRow = Row("Let others join my layer", W.Switch(page, function() return o.hostJoin and not (ns.Join and ns.Join.PausedFor() > 0) end,
        function(v) o.hostJoin = v; if v and ns.Join then ns.Join.Resume() end; ns.Changed() end),
        "When you see a rare, other RareWatch users can ask to join your layer for it. You always click Accept or Decline first, and nobody whose layer moves are nearly used up can ask (that could move you off the rare). At most 3 requests every 5 minutes; anyone you decline waits 10 minutes. Turning this back on ends a pause.")
    local movesRow = Row("Layer moves this hour", nil,
        "The game allows about 10 layer moves an hour. Every move counts, from RareWatch, Layer-Swap or joining any group. Join requests stop at 8, so a host is never moved to you instead.")

    Section("Advanced")
    Row("Clear kills, sightings and history", W.ConfirmButton(page, { text = "Clear", icon = "trash", h = 24, size = 11, style = "ghost" },
        function()
            for _, def in pairs(ns.db.mobs) do wipe(def.layers) end
            wipe(ns.db.shadow)
            wipe(ns.db.history)
            ns.BumpDigest()
            ns.Changed()
        end), "Other RareWatch users' recent kills and sightings come back with the next sync.")
    Row("Reset window size", W.Button(page, { text = "Reset", icon = "refresh", h = 24, size = 11,
        onClick = function() ns.ResetMainSize() end }),
        "Drag the bottom-right corner of the window to resize it. Reset puts it back to the default size.")
    Row("Use the game's font (after /reload)", W.Switch(page, function() return o.plainFont end, function(v)
        o.plainFont = v
        ns.Print("Font change applies after /reload.")
    end))

    Layout()

    refreshers[4] = function()
        for _, c in ipairs(refreshables) do c:Refresh() end
        local n = ns.OnlineUsers()
        if ns.Join then
            local paused = ns.Join.PausedFor()
            hostRow.label:SetText("Let others join my layer" .. (paused > 0 and (Hex(C.muted) .. "  paused " .. ns.Dur(paused) .. "|r") or ""))
            local used, limit, safe, warn = ns.Join.Used(), ns.Join.Limit(), ns.Join.SafeUsed(), ns.Join.WarnUsed()
            local col = used >= safe and C.red or (used >= warn and C.yellow or C.accent)
            movesRow.label:SetText("Layer moves this hour: " .. Hex(col) .. used .. "|r of about " .. limit)
        end
        onlineRow.label:SetText("Users online: " .. Hex(n > 0 and C.accent or C.muted) .. (n + 1) .. "|r (incl. you)")
    end
end

---------------------------------------------------------------------------
-- Main window
---------------------------------------------------------------------------
local PAGE_DEFS = {
    { icon = "target", name = "Rares", build = BuildRares },
    { icon = "search", name = "Browse rares", build = BuildBrowse },
    { icon = "history", name = "History", build = BuildHistory },
    { icon = "settings", name = "Settings", build = BuildSettings },
}

function ns.ShowPage(i)
    activePage = i
    W.HidePopovers()
    for j, b in ipairs(nav) do
        local on = (j == i)
        b.bg:SetColor(C.chip, on and 1 or 0)
        W.SetColor(b.icon, on and C.text or C.muted)
        pages[j]:SetShown(on)
    end
    ns.RefreshMain()
end

function ns.RefreshMain()
    if not main or not main:IsShown() then return end
    if refreshers[activePage] then refreshers[activePage]() end
end

function ns.ToggleMain(page)
    if not main then return end
    if main:IsShown() and not page then
        main:Hide()
    else
        main:Show()
        ns.ShowPage(page or activePage)
    end
end

local function BuildMain()
    main = CreateFrame("Frame", "RareWatchMainFrame", UIParent)
    main:HookScript("OnMouseDown", function() ns.EnsureChannel() end)
    main:SetSize(WIN_W, WIN_H)
    main:SetFrameStrata("HIGH")
    main:SetToplevel(true)
    main:SetClampedToScreen(true)
    main:EnableMouse(true)
    main:SetMovable(true)
    main:RegisterForDrag("LeftButton")
    main:SetScript("OnDragStart", function(self) self:StartMoving() end)
    main:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePos(self, "mainPos") end)
    main:SetScale(ns.opt.windowScale)
    W.Round(main, C.bg, 10)
    RestorePos(main, "mainPos", { "CENTER", UIParent, "CENTER", 0, 40 })
    local sz = ns.db.mainSize
    if sz and sz[1] and sz[2] then
        main:SetSize(math.max(MIN_W, math.min(MAX_W, sz[1])), math.max(MIN_H, math.min(MAX_H, sz[2])))
    end
    main:SetResizable(true)
    if main.SetResizeBounds then pcall(main.SetResizeBounds, main, MIN_W, MIN_H, MAX_W, MAX_H)
    else
        if main.SetMinResize then pcall(main.SetMinResize, main, MIN_W, MIN_H) end
        if main.SetMaxResize then pcall(main.SetMaxResize, main, MAX_W, MAX_H) end
    end
    main:Hide()
    W.EscClose(main)
    main:SetScript("OnHide", function() W.HidePopovers() end)

    -- sidebar
    local side = CreateFrame("Frame", nil, main)
    side:SetPoint("TOPLEFT")
    side:SetPoint("BOTTOMLEFT")
    side:SetWidth(SIDE)
    W.Round(side, C.side, 10)
    local sq = side:CreateTexture(nil, "BACKGROUND", nil, 1)
    sq:SetColorTexture(C.side[1], C.side[2], C.side[3], 1)
    sq:SetPoint("TOPRIGHT")
    sq:SetPoint("BOTTOMRIGHT")
    sq:SetWidth(SIDE / 2)

    local logo = CreateFrame("Frame", nil, side)
    logo:SetSize(30, 30)
    logo:SetPoint("TOP", 0, -14)
    W.Round(logo, W.Mix(C.side, C.accent, 0.22), 8)
    if W.iconsOK then
        W.Icon(logo, "paw", 17, C.accent):SetPoint("CENTER", 0, 0)
    else
        local pt = logo:CreateTexture(nil, "ARTWORK")
        pt:SetTexture(ns.ICON)
        pt:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        pt:SetPoint("TOPLEFT", 4, -4)
        pt:SetPoint("BOTTOMRIGHT", -4, 4)
    end
    logo:EnableMouse(true)
    W.Tip(logo, "RareWatch v" .. ns.VERSION, "Drag the window by any empty area.")

    local content = CreateFrame("Frame", nil, main)
    content:SetPoint("TOPLEFT", SIDE, 0)
    content:SetPoint("BOTTOMRIGHT", 0, 0)

    for i, pd in ipairs(PAGE_DEFS) do
        local b = CreateFrame("Button", nil, side)
        b:SetSize(34, 34)
        if i == #PAGE_DEFS then
            b:SetPoint("BOTTOM", 0, 14)
        else
            b:SetPoint("TOP", 0, -58 - (i - 1) * 40)
        end
        b.bg = W.Round(b, C.chip, 8)
        b.icon = W.Icon(b, pd.icon, 18, C.muted)
        b.icon:SetPoint("CENTER")
        if not W.iconsOK then
            b.icon:SetFontObject(W.Font(11, "M"))
            b.icon:SetText(pd.name:sub(1, 2))
        end
        b:SetScript("OnClick", function() ns.EnsureChannel(); ns.ShowPage(i) end)
        b:SetScript("OnEnter", function(self)
            if activePage ~= i then self.bg:SetColor(C.chip, 0.6) end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(pd.name, 1, 1, 1)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function(self)
            if activePage ~= i then self.bg:SetColor(C.chip, 0) end
            GameTooltip:Hide()
        end)
        nav[i] = b

        local p = CreateFrame("Frame", nil, content)
        p:SetAllPoints()
        p:Hide()
        pd.build(p)
        pages[i] = p
    end

    local close = W.Button(main, { icon = "x", w = 28, h = 28, style = "ghost", onClick = function() main:Hide() end })
    close:SetPoint("TOPRIGHT", -12, -14)
    if not W.iconsOK then close:SetLabel("X") end

    -- resize grip in the bottom-right corner
    local grip = CreateFrame("Button", nil, main)
    grip:SetSize(20, 20)
    grip:SetPoint("BOTTOMRIGHT", -3, 3)
    grip:SetFrameLevel((main:GetFrameLevel() or 1) + 20)
    grip.dots = {}
    for _, p in ipairs({ { 0, 0 }, { -5, 0 }, { -10, 0 }, { 0, 5 }, { -5, 5 }, { 0, 10 } }) do
        local dot = grip:CreateTexture(nil, "OVERLAY")
        dot:SetColorTexture(1, 1, 1, 1)
        dot:SetSize(2, 2)
        dot:SetPoint("BOTTOMRIGHT", p[1] - 4, p[2] + 4)
        dot:SetVertexColor(C.muted[1], C.muted[2], C.muted[3], 1)
        grip.dots[#grip.dots + 1] = dot
    end
    local function GripColor(c) for _, dot in ipairs(grip.dots) do dot:SetVertexColor(c[1], c[2], c[3], 1) end end
    grip:SetScript("OnEnter", function(self)
        GripColor(C.text)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Resize", 1, 1, 1)
        GameTooltip:AddLine("Drag to make the window bigger or smaller.", 0.75, 0.77, 0.8, true)
        GameTooltip:Show()
    end)
    grip:SetScript("OnLeave", function() GripColor(C.muted); GameTooltip:Hide() end)
    grip:SetScript("OnMouseDown", function() main:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        main:StopMovingOrSizing()
        ns.db.mainSize = { math.floor(main:GetWidth() + 0.5), math.floor(main:GetHeight() + 0.5) }
        SavePos(main, "mainPos")
        ns.ReflowMain()
    end)

    -- re-fit the pages whenever the size changes (at most once per frame)
    local reflowPending = false
    main:SetScript("OnSizeChanged", function()
        if reflowPending then return end
        reflowPending = true
        C_Timer.After(0, function() reflowPending = false; ns.ReflowMain() end)
    end)

    main:SetScript("OnShow", function() ns.RefreshMain() end)
    ns.ReflowMain()
end

-- Work out the content area from the window's size and let each page fit itself to it.
function ns.ReflowMain()
    if not main then return end
    local w, h = main:GetWidth() or WIN_W, main:GetHeight() or WIN_H
    if w < 100 then w = WIN_W end
    if h < 100 then h = WIN_H end
    CW, CH = w - SIDE, h
    for _, fn in pairs(layouts) do fn() end
    ns.RefreshMain()
end

function ns.ResetMainSize()
    if not main then return end
    ns.db.mainSize = nil
    main:SetSize(WIN_W, WIN_H)
    ns.ReflowMain()
end

---------------------------------------------------------------------------
-- Status box: rares in this zone that are up right now (or were just killed), with Join.
---------------------------------------------------------------------------
local MAX_ROWS, BOX_W, ROW_H = 4, 290, 40

-- Rows for the box: every current sighting of a rare in this zone (one per layer someone sees it on, yours
-- included), and kills in the last couple of minutes, so you know a sighting is over.
local function BoxRows()
    local zone = ns.Zone()
    local out, n = {}, 0
    local t = ns.Now()
    for _, info in ipairs(ns.ZoneRares(zone)) do
        n = n + 1
        local def = ns.LookupAny(info.id, info.name, false)
        if def then
            for _, rep in ipairs(select(2, ns.Status(def))) do
                if rep.code == "UP" or (rep.code == "KILLED" and t - rep.at <= KILL_ROW_FOR) then
                    out[#out + 1] = { def = def, rep = rep }
                end
            end
        end
    end
    table.sort(out, function(a, b)
        if (a.rep.code == "UP") ~= (b.rep.code == "UP") then return a.rep.code == "UP" end
        if a.rep.at ~= b.rep.at then return a.rep.at > b.rep.at end
        return a.def.name < b.def.name
    end)
    return out, n, zone
end

local function BuildOverlay()
    overlay = CreateFrame("Button", "RareWatchStatusBox", UIParent)
    overlay:SetSize(BOX_W, 40)
    overlay:SetFrameStrata("MEDIUM")
    overlay:SetClampedToScreen(true)
    overlay:SetMovable(true)
    overlay:RegisterForDrag("LeftButton")
    overlay:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    overlay.bg = W.Round(overlay, C.bg, 8)
    overlay.bg:SetColor(C.bg, 0.92)
    RestorePos(overlay, "trackerPos", { "TOP", UIParent, "TOP", 0, -140 })
    overlay:SetScript("OnDragStart", function(self) if not ns.opt.lockTracker then self:StartMoving() end end)
    overlay:SetScript("OnDragStop", function(self) self:StopMovingOrSizing(); SavePos(self, "trackerPos") end)
    overlay:SetScript("OnClick", function(_, button)
        ns.EnsureChannel()
        if button == "RightButton" then ns.ToggleMain(4) else ns.ToggleMain(1) end
    end)
    W.Tip(overlay, "RareWatch", "Rares in this zone that you or another RareWatch user saw in the last 10 minutes. Join puts you on that player's layer.\n\nLeft-click: open RareWatch\nRight-click: settings\nDrag: move")

    if W.iconsOK then W.Icon(overlay, "paw", 12, C.accent):SetPoint("TOPLEFT", 10, -9) end
    local head = W.Text(overlay, 11, "M", "RareWatch", C.sec)
    head:SetPoint("TOPLEFT", W.iconsOK and 27 or 10, -9)
    overlay.zone = W.Cell(overlay, 11, "R", BOX_W - 110, C.muted, "RIGHT")
    overlay.zone:SetPoint("TOPRIGHT", -10, -9)
    overlay.rows = {}
    for i = 1, MAX_ROWS do
        local y = -28 - (i - 1) * ROW_H
        local row = {}
        row.dot = W.Dot(overlay, 6)
        row.dot:SetPoint("TOPLEFT", 11, y - 6)
        row.name = W.Cell(overlay, 12, "M", BOX_W - 100, C.text)
        row.name:SetPoint("TOPLEFT", 24, y - 1)
        row.sub = W.Cell(overlay, 11, "R", BOX_W - 100, C.muted)
        row.sub:SetPoint("TOPLEFT", 24, y - 17)
        row.join = JoinButton(overlay)
        row.join:SetPoint("TOPRIGHT", -10, y - 4)
        overlay.rows[i] = row
    end
    -- shown when nothing is up
    overlay.empty = W.Cell(overlay, 12, "R", BOX_W - 34, C.muted)
    overlay.empty:SetPoint("TOPLEFT", 24, -29)
    overlay.emptyDot = W.Dot(overlay, 6)
    overlay.emptyDot:SetPoint("TOPLEFT", 11, -34)
    overlay.emptyDot:SetVertexColor(C.muted[1], C.muted[2], C.muted[3], 1)
end

local function RefreshOverlay()
    if not overlay then return end
    if not ns.opt.showTracker then overlay:Hide(); return end
    overlay:SetScale(ns.opt.trackerScale)
    local list, watched, zone = BoxRows()
    if #list == 0 and ns.opt.boxHideEmpty then overlay:Hide(); return end
    overlay:Show()
    overlay.zone:SetText(zone or "")
    local shown = 0
    for i, row in ipairs(overlay.rows) do
        local s = list[i]
        if s then
            shown = i
            local rep = s.rep
            local c = SC(rep.code)
            row.dot:SetVertexColor(c[1], c[2], c[3], 1)
            row.name:SetText(s.def.name)
            W.SetColor(row.name, rep.code == "UP" and C.text or C.sec)
            row.sub:SetText(ns.ReportText(rep) .. DOT .. ns.Ago(rep.at))
            row.dot:Show(); row.name:Show(); row.sub:Show()
            if rep.code ~= "UP" or not row.join:Bind(s.def, rep) then row.join:Hide() end
        else
            row.dot:Hide(); row.name:Hide(); row.sub:Hide(); row.join:Hide()
        end
    end
    if shown == 0 then
        overlay.empty:SetText(watched == 0 and "No known rares in this zone"
            or ("Watching " .. watched .. (watched == 1 and " rare" or " rares") .. ", none up"))
        overlay.empty:Show(); overlay.emptyDot:Show()
        overlay:SetHeight(54)
    else
        overlay.empty:Hide(); overlay.emptyDot:Hide()
        if #list > MAX_ROWS then
            overlay.rows[MAX_ROWS].sub:SetText(overlay.rows[MAX_ROWS].sub:GetText() .. DOT .. "+" .. (#list - MAX_ROWS) .. " more")
        end
        overlay:SetHeight(30 + shown * ROW_H)
    end
end

---------------------------------------------------------------------------
-- Minimap button
---------------------------------------------------------------------------
local function PlaceMinimap()
    local a = math.rad(ns.opt.minimapAngle or 200)
    minimapBtn:ClearAllPoints()
    minimapBtn:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * 80, math.sin(a) * 80)
end

local function BuildMinimap()
    local b = CreateFrame("Button", "RareWatchMinimapButton", Minimap)
    minimapBtn = b
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetSize(20, 20)
    bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    bg:SetPoint("TOPLEFT", 7, -5)
    local icon = b:CreateTexture(nil, "ARTWORK")
    icon:SetSize(17, 17)
    icon:SetTexture(ns.ICON)
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)
    icon:SetPoint("TOPLEFT", 7, -6)
    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetPoint("TOPLEFT")
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", function()
            local mx, my = Minimap:GetCenter()
            local px, py = GetCursorPosition()
            local s = Minimap:GetEffectiveScale()
            px, py = px / s, py / s
            local atan2 = math.atan2 or function(y, x) return math.atan(y, x) end
            ns.opt.minimapAngle = math.deg(atan2(py - my, px - mx))
            PlaceMinimap()
        end)
    end)
    b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    b:SetScript("OnClick", function(_, button)
        ns.EnsureChannel()
        if button == "RightButton" then
            ns.opt.showTracker = not ns.opt.showTracker
            ns.Changed()
        else
            ns.ToggleMain()
        end
    end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("RareWatch", 1, 1, 1)
        local here, elsewhere, zone = Groups()
        local function add(items, title)
            if #items == 0 then return end
            GameTooltip:AddLine(title, 0.55, 0.57, 0.63)
            for i, item in ipairs(items) do
                if i > 12 then GameTooltip:AddLine("  +" .. (#items - 12) .. " more", 0.55, 0.57, 0.63); break end
                local c = SC(item.st.code)
                GameTooltip:AddDoubleLine(item.def.name, Word(item.st.code), 0.9, 0.9, 0.9, c[1], c[2], c[3])
            end
        end
        add(here, zone or "This zone")
        add(elsewhere, "Tracked elsewhere")
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Left-click: open   Right-click: status box   Drag: move", 0.55, 0.57, 0.63, true)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    PlaceMinimap()
end

---------------------------------------------------------------------------
function ns.BuildUI()
    BuildMain()
    BuildOverlay()
    BuildMinimap()
    local function All()
        RefreshOverlay()
        if minimapBtn then minimapBtn:SetShown(not ns.opt.minimapHide) end
        ns.RefreshMain()
    end
    ns.OnChange(All)
    -- times ("2m ago") tick on: the box and the Rares and Settings pages every second, the long lists every 10
    local n = 0
    C_Timer.NewTicker(1, function()
        n = n + 1
        RefreshOverlay()
        if activePage == 1 or activePage == 4 or n % 10 == 0 then ns.RefreshMain() end
    end)
    All()
end

---------------------------------------------------------------------------
-- One-time prompt: joining the sync channel needs a click, so we ask once.
---------------------------------------------------------------------------
function ns.ShowConnectPrompt()
    if ns.connectPrompt then ns.connectPrompt:Show(); return end
    local p = W.Popover("RareWatchConnectPrompt", 380, 172)
    ns.connectPrompt = p
    local icon = W.Icon(p, "users", 20, C.accent)
    icon:SetPoint("TOPLEFT", 18, -18)
    local title = W.Text(p, 14, "S", "Share rare sightings automatically?")
    title:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    local body = W.Text(p, 12, "R", "RareWatch users share kills, tames and sightings with each other in the background, so you hear when a rare in your zone is up on someone else's layer and can join them.\n\nThis joins a hidden chat channel. Other members can see your character name in it.")
    body:SetPoint("TOPLEFT", 18, -48)
    body:SetWidth(344)
    body:SetJustifyH("LEFT")
    W.SetColor(body, C.sec)
    local yes = W.Button(p, { text = "Connect", icon = "check", style = "primary", w = 110, h = 28,
        onClick = function() p:Hide(); ns.SetChannel(true); ns.Print("Connected. Sightings now sync automatically.") end })
    yes:SetPoint("BOTTOMRIGHT", -16, 14)
    local later = W.Button(p, { text = "Not now", style = "ghost", h = 28, onClick = function() p:Hide() end })
    later:SetPoint("RIGHT", yes, "LEFT", -8, 0)
    local never = W.Button(p, { text = "No thanks", style = "ghost", h = 28, onClick = function()
        p:Hide(); ns.opt.channelConsent = false
        ns.Print("Not sharing. You can turn it on any time in Settings.")
    end })
    never:SetPoint("BOTTOMLEFT", 16, 14)
    p:ClearAllPoints()
    p:SetPoint("CENTER", UIParent, "CENTER", 0, 160)
    p:Show()
end
