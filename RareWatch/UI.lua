-- RareWatch - UI: main window (sidebar + pages), status box, minimap button.
local ADDON_NAME, ns = ...
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

local STATUS = {
    UP    = { label = "Up",           color = C.green },
    OPEN  = { label = "Window open",  color = C.yellow },
    DUE   = { label = "Should be up", color = C.orange },
    STALE = { label = "Seen earlier", color = C.stale },
    WAIT  = { label = "Respawning",   color = C.blue },
    NONE  = { label = "No data",      color = C.muted },
}
local function SC(code) return (STATUS[code] or STATUS.NONE).color end

local EVENTS = {
    DOWN  = { label = "Killed",  color = C.red },
    TAME  = { label = "Tamed",   color = C.blue },
    SEEN  = { label = "Sighted", color = C.green },
    SPAWN = { label = "Spawned", color = C.accent },
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

local function SortedMobs()
    local out = {}
    for _, def in ipairs(ns.list) do
        local st, n = ns.Summary(def)
        out[#out + 1] = { def = def, st = st, n = n }
    end
    table.sort(out, function(a, b)
        if a.st.prio ~= b.st.prio then return a.st.prio < b.st.prio end
        if a.st.sort ~= b.st.sort then return a.st.sort < b.st.sort end
        return a.def.name < b.def.name
    end)
    return out
end

local function SelectedDef()
    local def = selectedKey and ns.byName[selectedKey]
    if not def then
        local first = SortedMobs()[1]
        def = first and first.def
        selectedKey = def and ns.Key(def.name)
    end
    return def
end

-- Progress (0..1) through the current respawn phase, for cards and bars.
local function Progress(def, st)
    local t = ns.Now()
    if st.code == "WAIT" then
        local down = st.windowFrom - def.min
        return math.max(0, math.min(1, (t - down) / def.min))
    elseif st.code == "OPEN" then
        return math.max(0, math.min(1, (t - st.windowFrom) / math.max(1, st.windowTo - st.windowFrom)))
    elseif st.code == "NONE" then
        return 0
    end
    return 1
end

local function ShortStatus(st)
    if st.code == "WAIT" then return ns.Dur(st.sort)
    elseif st.code == "OPEN" then return "Open"
    elseif st.code == "DUE" then return "Due"
    elseif st.code == "UP" then return "Up"
    elseif st.code == "STALE" then return "Seen"
    end
    return "No data"
end

local function InfoLine(def, st)
    local info = ns.RareInfo(def.id)
    local parts = {}
    if info and info.zone then parts[#parts + 1] = info.zone end
    if st and st.layer then parts[#parts + 1] = "layer " .. ns.LayerShort(st.layer) end
    if st and (st.code == "UP" or st.code == "STALE") and st.rec and st.rec.seen then
        parts[#parts + 1] = ns.Dur(ns.Now() - st.rec.seen) .. " ago"
    end
    return table.concat(parts, DOT)
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

-- A small "Join" button for a fresh sighting by another player (see Join.lua).
local function JoinButton(parent)
    local b = W.Button(parent, { text = "Join", icon = "users", style = "accent", h = 22, size = 11 })
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
        if ns.Join and def and st then host, _, why = ns.Join.CanJoin(def, st) end
        if not host or why == "hide" then self:Hide(); return false end
        self.def, self.st, self.host, self.why = def, st, host, why
        self:SetDisabled(why ~= nil)
        self:Show()
        return true
    end
    b:Hide()
    return b
end

local function Clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function EachRow(list, fn) for _, r in ipairs(list.rows) do fn(r) end end

local function PageTitle(page, text)
    local t = W.Text(page, 17, "M", text)
    t:SetPoint("TOPLEFT", 20, -20)
    return t
end

---------------------------------------------------------------------------
-- Tracker page
---------------------------------------------------------------------------
local function BuildTracker(page)
    -- left column
    local col = CreateFrame("Frame", nil, page)
    col:SetPoint("TOPLEFT", 0, 0)
    col:SetPoint("BOTTOMLEFT", 0, 0)
    col:SetWidth(LIST_W)
    W.Rect(col, C.col)

    local head = W.Text(col, 13, "M", "Tracking")
    head:SetPoint("TOPLEFT", 16, -20)
    local headCount = W.Text(col, 12, "R", "", C.muted, "RIGHT")
    headCount:SetPoint("TOPRIGHT", -16, -21)

    local footer = W.Cell(col, 11, "R", LIST_W - 32, C.muted)
    local LW, SX = 110, 134   -- layer column width / status x, set by the layout
    footer:SetPoint("BOTTOMLEFT", 16, 14)

    local cards = W.List(col, MAX_H - 56 - 40, 62, function(list)
        local r = CreateFrame("Button", nil, list)
        r.bg = W.Round(r, C.card, 8)
        r.bg:SetColor(C.card, 0)
        r.name = W.Cell(r, 12, "M", 140)
        r.name:SetPoint("TOPLEFT", 12, -11)
        r.timer = W.Cell(r, 12, "M", 70, C.text, "RIGHT")
        r.timer:SetPoint("TOPRIGHT", -12, -11)
        r.sub = W.Cell(r, 11, "R", 190, C.muted)
        r.sub:SetPoint("TOPLEFT", 12, -28)
        r.track = r:CreateTexture(nil, "ARTWORK")
        r.track:SetColorTexture(C.track[1], C.track[2], C.track[3], 1)
        r.track:SetPoint("BOTTOMLEFT", 12, 11)
        r.track:SetPoint("BOTTOMRIGHT", -12, 11)
        r.track:SetHeight(3)
        r.fill = r:CreateTexture(nil, "OVERLAY")
        r.fill:SetPoint("BOTTOMLEFT", r.track, "BOTTOMLEFT")
        r.fill:SetHeight(3)
        r:SetScript("OnEnter", function(self) if not self.selected then self.bg:SetColor(C.card, 0.5) end end)
        r:SetScript("OnLeave", function(self) if not self.selected then self.bg:SetColor(C.card, 0) end end)
        r:SetScript("OnClick", function(self)
            selectedKey = ns.Key(self.item.def.name)
            W.HidePopovers()
            ns.RefreshMain()
        end)
        return r
    end, function(r, item)
        r.item = item
        local def, st = item.def, item.st
        local c = SC(st.code)
        r.selected = (ns.Key(def.name) == selectedKey)
        r.bg:SetColor(C.card, r.selected and 1 or 0)
        r.name:SetText(def.name)
        r.timer:SetText(ShortStatus(st))
        W.SetColor(r.timer, c)
        local line = InfoLine(def, st)
        if item.n > 1 then line = line .. "  +" .. (item.n - 1) end
        r.sub:SetText(line ~= "" and line or "No reports yet")
        local p = Progress(def, st)
        local w = math.max(0, (LIST_W - 16 - 24) * p)
        r.fill:SetShown(w >= 1)
        r.fill:SetWidth(math.max(1, w))
        r.fill:SetColorTexture(c[1], c[2], c[3], st.code == "STALE" and 0.5 or 1)
    end, 4)
    cards:SetPoint("TOPLEFT", 8, -48)
    cards:SetPoint("TOPRIGHT", 0, -48)

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
    heroLabel:SetPoint("TOPLEFT", PAD, -84)
    local hero = W.Text(d, 30, "S", "")
    hero:SetPoint("TOPLEFT", PAD, -102)
    local heroNote = W.Cell(d, 12, "R", TW, C.muted)
    heroNote:SetPoint("TOPLEFT", PAD, -148)

    -- timeline
    local tl = CreateFrame("Frame", nil, d)
    tl:SetPoint("TOPLEFT", PAD, -148)
    tl:SetSize(TW, 8)
    tl.track = W.Round(tl, C.track2, 4)
    tl.win = CreateFrame("Frame", nil, tl)
    tl.win:SetHeight(8)
    tl.win.bg = W.Round(tl.win, C.yellow, 4, "ARTWORK")
    tl.now = tl:CreateTexture(nil, "OVERLAY")
    tl.now:SetColorTexture(C.text[1], C.text[2], C.text[3], 1)
    tl.now:SetSize(2, 18)
    tl.l1 = W.Text(tl, 11, "R", "", C.muted)
    tl.l1:SetPoint("TOPLEFT", tl, "BOTTOMLEFT", 0, -8)
    tl.l2 = W.Text(tl, 11, "R", "", C.muted, "CENTER")
    tl.l3 = W.Text(tl, 11, "R", "", C.muted, "RIGHT")
    tl.l3:SetPoint("TOPRIGHT", tl, "BOTTOMRIGHT", 0, -8)

    -- chips
    local chip1 = W.Chip(d, "")
    chip1:SetPoint("TOPLEFT", PAD, -192)
    chip1:EnableMouse(true)
    local chip2 = W.Chip(d, "")
    chip2:SetPoint("LEFT", chip1, "RIGHT", 8, 0)
    chip2:EnableMouse(true)
    local editResp = W.Button(d, { icon = "pencil", w = 22, h = 22, style = "ghost",
        tip = { "Edit respawn time", "Set the min/max respawn, or use the measured times." } })
    editResp:SetPoint("LEFT", chip2, "RIGHT", 4, 0)
    chip1:SetScript("OnLeave", function() GameTooltip:Hide() end)
    chip2:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Measured respawns", 1, 1, 1)
        GameTooltip:AddLine("Time from a reported kill or tame to the next spawn on the same layer. Upper bounds come from sightings, exact ones from spawn times.", 0.75, 0.77, 0.8, true)
        GameTooltip:Show()
    end)
    chip2:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- layers
    -- layers / drops tabs
    local detailTab = "layers"
    local tabLayers = W.Button(d, { text = "Layers", h = 24, size = 11 })
    tabLayers:SetPoint("TOPLEFT", PAD, -232)
    local tabDrops = W.Button(d, { text = "Drops", icon = "sparkles", h = 24, size = 11 })
    tabDrops:SetPoint("LEFT", tabLayers, "RIGHT", 6, 0)
    local layersHead = tabLayers
    local dropNote = W.Text(d, 10, "R", "Vanilla loot data. Forever may differ.", C.muted, "RIGHT")
    local layerList
    layerList = W.List(d, 24 * 28, 28, function(list)
        local r = CreateFrame("Frame", nil, list)
        r.dot = W.Dot(r, 7)
        r.dot:SetPoint("LEFT", 0, 0)
        r.layer = W.Cell(r, 12, "M", 80)
        r.layer:SetPoint("LEFT", 16, 0)
        r.status = W.Cell(r, 12, "R", 200, C.sec)
        r.status:SetPoint("LEFT", 136, 0)
        r.src = W.Cell(r, 11, "R", 80, C.muted, "RIGHT")
        r.src:SetPoint("RIGHT", 0, 0)
        r.join = JoinButton(r)
        r.join:SetPoint("RIGHT", 0, 0)
        r.sep = W.Line(r)
        r.sep:SetPoint("BOTTOMLEFT")
        r.sep:SetPoint("BOTTOMRIGHT")
        return r
    end, function(r, st, idx)
        local c = SC(st.code)
        r.dot:SetVertexColor(c[1], c[2], c[3], 1)
        local isMe = st.layer == ns.LayerFor(SelectedDef())
        r.layer:SetText(ns.LayerShort(st.layer) .. (isMe and ("  " .. Hex(C.accent) .. "your layer|r") or ""))
        r.layer:SetWidth(LW)
        local txt = st.text:sub(1, 1):upper() .. st.text:sub(2)
        if st.code == "WAIT" or st.code == "OPEN" then
            txt = txt .. Hex(C.muted) .. "   " .. ns.Clock(st.windowFrom) .. " - " .. ns.Clock(st.windowTo) .. "|r"
        end
        r.status:SetText(txt)
        r.src:SetText(st.src and ("by " .. st.src) or "")
        local joinable = r.join:Bind(SelectedDef(), st)
        r.src:ClearAllPoints()
        r.src:SetPoint("RIGHT", joinable and -(r.join:GetWidth() + 10) or 0, 0)
        r.sep:SetShown(idx < #layerList.data)
    end)
    layerList:SetPoint("TOPLEFT", PAD, -248)
    layerList:SetPoint("TOPRIGHT", -PAD + 8, -248)

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
            if worth then
                r.val:SetText(Hex(C.text2) .. ns.CoinText(worth) .. "|r  " .. src)
            else
                r.val:SetText("")
            end
            W.SetColor(r.val, C.muted)
        end
    end, 0)
    dropList:SetPoint("TOPLEFT", PAD, -248)
    dropList:SetPoint("TOPRIGHT", -PAD + 8, -248)

    local function SetTab(t)
        detailTab = t
        ns.RefreshMain()
    end
    ns.SetDetailTab = SetTab
    tabLayers:SetScript("OnClick", function() SetTab("layers") end)
    tabDrops:SetScript("OnClick", function() SetTab("drops") end)

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

    local logKill = W.Button(d, { text = "Log kill", icon = "skull", style = "primary" })
    logKill:SetPoint("BOTTOMLEFT", PAD, 20)
    local logSeen = W.Button(d, { text = "Log sighting", icon = "eye" })
    logSeen:SetPoint("LEFT", logKill, "RIGHT", 8, 0)
    local waypoint = W.Button(d, { text = "Waypoint", icon = "pin", onClick = function()
        local def = SelectedDef()
        local info = def and ns.RareInfo(def.id)
        if info and info.coords and info.coords[1] then Feedback(ns.SetWaypoint(info)) end
    end })
    waypoint:SetPoint("LEFT", logSeen, "RIGHT", 8, 0)

    local untrack = W.ConfirmButton(d, { icon = "trash", w = 28, h = 28, style = "ghost", confirmText = "",
        tip = { "Stop tracking", "Click twice to remove this mob from your list." } }, function()
        local def = SelectedDef()
        if def then
            ns.RemoveMob(def)
            selectedKey = nil
            ns.RefreshMain()
        end
    end)
    untrack:SetPoint("BOTTOMRIGHT", -PAD, 20)
    local bell = W.Button(d, { icon = "bell", w = 28, h = 28, style = "ghost", onClick = function()
        local def = SelectedDef()
        if not def then return end
        def.alert = not def.alert
        Feedback(true, def.alert and ("Alerts on for " .. def.name) or ("Alerts off for " .. def.name))
        ns.Changed()
    end, tip = { "Alerts", "Toggle pop-up, sound and flash when this mob is spotted." } })
    bell:SetPoint("RIGHT", untrack, "LEFT", -4, 0)

    -- log popover
    local pop = W.Popover("RareWatchLogPopover", 280, 156)
    local popTitle = W.Text(pop, 13, "M", "Log kill")
    popTitle:SetPoint("TOPLEFT", 16, -16)
    local kind = "DOWN"
    local kindKill, kindTame
    kindTame = W.ToggleChip(pop, "Tame", function() return kind == "TAME" end, function() kind = "TAME"; pop.Sync() end)
    kindKill = W.ToggleChip(pop, "Kill", function() return kind == "DOWN" end, function() kind = "DOWN"; pop.Sync() end)
    kindTame:SetPoint("TOPRIGHT", -16, -10)
    kindKill:SetPoint("RIGHT", kindTame, "LEFT", -4, 0)
    local mins = W.Field(pop, "Minutes ago", 116, "0 = now")
    mins:SetPoint("TOPLEFT", 16, -66)
    mins:SetMaxLetters(5)
    local layerIn = W.Field(pop, "Layer", 116, "?")
    layerIn:SetPoint("LEFT", mins, "RIGHT", 16, 0)
    local popSave = W.Button(pop, { text = "Save", style = "primary", w = 80, onClick = function()
        local def = SelectedDef()
        if not def then return end
        local ok, msg = ns.ManualLog(def, kind, mins:GetText(), layerIn:GetText())
        Feedback(ok, msg)
        if ok then pop:Hide() end
    end })
    popSave:SetPoint("BOTTOMRIGHT", -16, 14)
    local popCancel = W.Button(pop, { text = "Cancel", style = "ghost", w = 70, onClick = function() pop:Hide() end })
    popCancel:SetPoint("RIGHT", popSave, "LEFT", -6, 0)
    mins.onEnter = function() popSave:Click() end
    layerIn.onEnter = mins.onEnter
    function pop.Sync()
        popTitle:SetText(kind == "DOWN" and "Log kill" or kind == "TAME" and "Log tame" or "Log sighting")
        kindKill:SetShown(kind ~= "SEEN")
        kindTame:SetShown(kind ~= "SEEN")
        kindKill:Refresh()
        kindTame:Refresh()
    end
    pop.onOpen = function()
        mins:SetText("")
        layerIn:SetText("")
        local lf = ns.LayerFor(SelectedDef())
        layerIn:SetPlaceholder(lf and ns.LayerShort(lf) or "?")
        pop.Sync()
    end
    logKill:SetScript("OnClick", function(self)
        if pop:IsShown() and kind ~= "SEEN" then pop:Hide() return end
        kind = "DOWN"
        pop:Open(self, "BOTTOMLEFT", "TOPLEFT", 0, 8)
    end)
    logSeen:SetScript("OnClick", function(self)
        if pop:IsShown() and kind == "SEEN" then pop:Hide() return end
        kind = "SEEN"
        pop:Open(self, "BOTTOMLEFT", "TOPLEFT", 0, 8)
    end)

    -- respawn popover
    local rp = W.Popover("RareWatchRespawnPopover", 280, 170)
    W.Text(rp, 13, "M", "Respawn time"):SetPoint("TOPLEFT", 16, -16)
    local rMin = W.Field(rp, "Min hours", 116, "8")
    rMin:SetPoint("TOPLEFT", 16, -62)
    local rMax = W.Field(rp, "Max hours", 116, "12")
    rMax:SetPoint("LEFT", rMin, "RIGHT", 16, 0)
    local rNote = W.Cell(rp, 11, "R", 248, C.muted)
    rNote:SetPoint("TOPLEFT", 16, -100)
    local useMeasured = W.Button(rp, { text = "Use measured", onClick = function()
        local def = SelectedDef()
        if not def then return end
        local ok, msg = ns.ApplyMeasured(def)
        Feedback(ok, msg)
        if ok then rp:Hide() end
    end })
    useMeasured:SetPoint("BOTTOMLEFT", 16, 14)
    local rSave = W.Button(rp, { text = "Save", style = "primary", w = 70, onClick = function()
        local def = SelectedDef()
        if not def then return end
        local a, b = tonumber(rMin:GetText()), tonumber(rMax:GetText())
        local res, err = ns.AddMob(def.name, def.id, a and a * 3600, b and b * 3600)
        if res then
            res.respawnSrc = "your setting"
            Feedback(true, "Respawn updated.")
            rp:Hide()
        else
            rNote:SetText(Hex(C.red) .. err .. "|r")
        end
    end })
    rSave:SetPoint("BOTTOMRIGHT", -16, 14)
    rMax.onEnter = function() rSave:Click() end
    rp.onOpen = function()
        local def = SelectedDef()
        if not def then rp:Hide() return end
        rMin:SetText(ns.Hours(def.min))
        rMax:SetText(ns.Hours(def.max))
        local ms = ns.SampleStats(def)
        useMeasured:SetDisabled(not ms or ms.n < 3)
        rNote:SetText(ms and string.format("Measured %dx: %s - %s", ms.n, ns.Dur(ms.min), ns.Dur(ms.max))
            or "No measured respawns yet.")
    end
    editResp:SetScript("OnClick", function(self)
        if rp:IsShown() then rp:Hide() else rp:Open(self, "TOPLEFT", "BOTTOMLEFT", 0, -6) end
    end)

    local emptyHint = W.Text(d, 12, "R", "", C.muted, "CENTER")
    emptyHint:SetPoint("CENTER", 0, 20)
    emptyHint:SetWidth(400)
    emptyHint:SetHeight(36)
    emptyHint:SetJustifyV("TOP")
    local browseBtn = W.Button(d, { text = "Browse rares", icon = "search", style = "primary", onClick = function() ns.ShowPage(2) end })
    browseBtn:SetPoint("TOP", emptyHint, "BOTTOM", 0, -14)
    local detailParts = { name, meta, pill, heroLabel, hero, heroNote, tl, chip1, chip2, editResp, layersHead,
        layerList, dropList, dropNote, tabDrops, logKill, logSeen, waypoint, untrack, bell, feedback }

    layouts[1] = function()
        LIST_W = Clamp(math.floor(CW * 0.27), 240, 340)
        col:SetWidth(LIST_W)
        d:ClearAllPoints()
        d:SetPoint("TOPLEFT", LIST_W, 0)
        d:SetPoint("BOTTOMRIGHT", 0, 0)
        footer:SetWidth(LIST_W - 32)
        local cw = LIST_W - 16 - 24
        EachRow(cards, function(r) r.name:SetWidth(cw - 76); r.sub:SetWidth(cw) end)
        DW = CW - LIST_W
        TW = DW - PAD * 2
        local RW = TW + 8 - 8               -- layer/drop row width
        LW = Clamp(math.floor(RW * 0.24), 110, 220)
        SX = 16 + LW + 10
        local statusW = Clamp(math.floor((RW - SX) * 0.6), 180, 420)
        EachRow(layerList, function(r)
            r.status:ClearAllPoints(); r.status:SetPoint("LEFT", SX, 0); r.status:SetWidth(statusW)
            r.src:SetWidth(math.max(80, RW - SX - statusW - 12))
        end)
        local nameW = math.max(236, RW - 56 - 124 - 12)
        EachRow(dropList, function(r)
            r.name:SetWidth(nameW)
            r.pct:ClearAllPoints(); r.pct:SetPoint("LEFT", nameW + 4, 0)
        end)
        name:SetWidth(TW - 140)
        meta:SetWidth(TW - 40)
        heroNote:SetWidth(TW)
        tl:SetWidth(TW)
        feedback:SetWidth(TW)
        cards:Fit(CH - 56 - 40)
    end
    layouts[1]()

    refreshers[1] = function()
        local mobs = SortedMobs()
        cards:SetData(mobs, "")
        headCount:SetText(#mobs > 0 and tostring(#mobs) or "")
        local online = ns.OnlineUsers()
        local syncText
        if GetChannelName(ns.CHANNEL) > 0 or ns.IsSharing() then
            syncText = Hex(C.accent) .. "Live|r" .. DOT .. (online == 1 and "1 other user online" or (online .. " other users online"))
        else
            syncText = Hex(C.orange) .. "Not connected|r - click Connect in Settings"
        end
        footer:SetText("Layer " .. (ns.currentLayer and ns.LayerShort(ns.currentLayer) or "?")
            .. (ns.currentLayerZone and (" (" .. ns.currentLayerZone .. ")") or "") .. DOT .. syncText)

        local def = SelectedDef()
        for _, f in ipairs(detailParts) do f:SetShown(def ~= nil) end
        emptyHint:SetShown(def == nil)
        browseBtn:SetShown(def == nil)
        if not def then
            emptyHint:SetText("You're not tracking anything yet.\nPick rares from the built-in list to get timers and alerts.")
            return
        end

        name:SetText(def.name)
        local info = ns.RareInfo(def.id)
        local parts = {}
        if info then
            parts[#parts + 1] = (info.rank == 2 and "Rare elite" or "Rare") .. (info.minl and (DOT .. "level " .. info.minl) or "")
            if info.zone then
                parts[#parts + 1] = info.zone .. ((info.coords and info.coords[1]) and (" " .. info.coords[1] .. ", " .. info.coords[2]) or "")
            end
        else
            parts[#parts + 1] = def.id and ("NPC " .. def.id) or "Custom mob"
        end
        meta:SetText(table.concat(parts, DOT))

        local st = ns.Summary(def)
        local c = SC(st.code)
        pill.text:SetText(STATUS[st.code].label)
        W.SetColor(pill.text, c)
        pill.bg:SetColor(W.Mix(C.bg, c, 0.18))
        pill:SetWidth(math.floor(pill.text:GetStringWidth() + 24.5))

        local t = ns.Now()
        local showTimeline = st.windowFrom ~= nil
        tl:SetShown(showTimeline)
        heroNote:SetShown(not showTimeline)
        W.SetColor(hero, C.text)
        local layerTag = st.layer and (DOT .. "layer " .. ns.LayerShort(st.layer)) or ""
        if st.code == "WAIT" then
            heroLabel:SetText("Window opens in" .. layerTag)
            hero:SetText(ns.Dur(st.sort))
        elseif st.code == "OPEN" then
            heroLabel:SetText("Window closes in" .. layerTag)
            hero:SetText(ns.Dur(st.sort))
            W.SetColor(hero, C.yellow)
        elseif st.code == "DUE" then
            heroLabel:SetText("Respawn window ended" .. layerTag)
            hero:SetText(ns.Dur(st.sort) .. " ago")
            W.SetColor(hero, C.orange)
        elseif st.code == "UP" or st.code == "STALE" then
            heroLabel:SetText("Last seen alive" .. layerTag)
            hero:SetText(st.rec and st.rec.seen and (ns.Dur(t - st.rec.seen) .. " ago") or "Up")
            W.SetColor(hero, c)
            heroNote:SetText(st.rec and st.rec.spawn and ("Spawned " .. ns.Dur(t - st.rec.spawn) .. " ago")
                or (st.code == "STALE" and "It may have been killed since." or ""))
        else
            heroLabel:SetText("No reports yet")
            hero:SetText("--")
            W.SetColor(hero, C.muted)
            heroNote:SetText("Kills, tames and sightings from you or other users show up here.")
        end

        if showTimeline then
            local down = st.windowFrom - def.min
            local span = def.max * ((st.code == "DUE") and 1.12 or 1)
            local function X(tt) return math.max(0, math.min(TW, (tt - down) / span * TW)) end
            local wx, wr = X(st.windowFrom), X(st.windowTo)
            tl.win:ClearAllPoints()
            tl.win:SetPoint("LEFT", tl, "LEFT", wx, 0)
            tl.win:SetWidth(math.max(8, wr - wx))
            local wc = (st.code == "OPEN") and C.yellow or (st.code == "DUE" and C.orange or C.blue)
            tl.win.bg:SetColor(W.Mix(C.track2, wc, 0.45))
            tl.now:ClearAllPoints()
            tl.now:SetPoint("CENTER", tl, "LEFT", X(t), 0)
            tl.l1:SetText(((st.rec and st.rec.downKind == "TAME") and "Tamed " or "Killed ") .. ns.Clock(down))
            tl.l2:SetText("Opens " .. ns.Clock(st.windowFrom))
            tl.l2:ClearAllPoints()
            tl.l2:SetPoint("TOP", tl, "BOTTOMLEFT", math.max(90, math.min(TW - 90, wx)), -8)
            tl.l3:SetText("Closes " .. ns.Clock(st.windowTo))
        end

        chip1:SetText("Respawn " .. ns.Hours(def.min) .. " - " .. ns.Hours(def.max) .. " h")
        local ms = ns.SampleStats(def)
        if ms then
            chip2:SetText("Measured " .. ms.n .. "x" .. DOT .. ns.Dur(ms.min) .. " - " .. ns.Dur(ms.max), C.text2)
        else
            chip2:SetText("Not measured yet", C.muted)
        end

        local y0 = showTimeline and -192 or ((heroNote:GetText() or "") ~= "" and -178 or -156)
        chip1:ClearAllPoints()
        chip1:SetPoint("TOPLEFT", PAD, y0)
        layersHead:ClearAllPoints()
        layersHead:SetPoint("TOPLEFT", PAD, y0 - 40)
        local listH = CH + (y0 - 72) - 74          -- room down to the action buttons
        for _, lst in ipairs({ layerList, dropList }) do
            lst:ClearAllPoints()
            lst:SetPoint("TOPLEFT", PAD, y0 - 72)
            lst:SetPoint("TOPRIGHT", -PAD + 8, y0 - 72)
            lst:Fit(listH)
        end
        dropNote:ClearAllPoints()
        dropNote:SetPoint("TOPRIGHT", -PAD + 8, y0 - 46)

        local L = ns.Layers(def, true)
        local real = 0
        for _, st in ipairs(L) do if not st.empty then real = real + 1 end end
        tabLayers:SetLabel("Layers" .. (real > 0 and ("  " .. real) or ""))
        tabLayers:SetStyle(detailTab == "layers" and "accent" or "default")
        tabDrops:SetStyle(detailTab == "drops" and "accent" or "default")
        layerList:SetShown(detailTab == "layers")
        dropList:SetShown(detailTab == "drops")
        dropNote:SetText(ns.DropsSeen(def.id) and "Forever rates: ForeverDB.net data + small samples" or "Vanilla loot data. Forever may differ.")
        dropNote:SetShown(detailTab == "drops" and ns.DropRows(def.id) ~= nil)
        if detailTab == "layers" then
            layerList:SetData(L, "No layer reports yet")
        else
            local rows = ns.DropRows(def.id)
            dropList:SetData(rows or {}, rows and "No drop data." or "No drop data for this mob.")
        end
        waypoint:SetShown(info and info.coords and info.coords[1] and true or false)
        W.SetColor(bell.icon, def.alert and C.accent or C.muted)
    end
end

---------------------------------------------------------------------------
-- Browse page
---------------------------------------------------------------------------
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
    local addCustom = W.Button(page, { text = "Custom mob", icon = "plus", h = 26, size = 11 })
    addCustom:SetPoint("TOPRIGHT", -20, -62)

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
            if tracked then
                selectedKey = ns.Key(tracked.name)
                ns.ShowPage(1)
            else
                local def = ns.TrackRare(info.id)
                if def then selectedKey = ns.Key(def.name) end
            end
        end)
        r:SetScript("OnEnter", function(self)
            self.bg:SetColor(C.chip, 1)
            local info = self.info
            if not info then return end
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            GameTooltip:SetText(info.name, 1, 1, 1)
            GameTooltip:AddLine((info.rank == 2 and "Rare elite" or "Rare") .. ", level " .. (info.minl or "?") .. "   NPC " .. info.id, 0.75, 0.77, 0.8)
            if info.coords and info.coords[1] then
                local pts = {}
                for k = 1, #info.coords, 2 do pts[#pts + 1] = info.coords[k] .. ", " .. info.coords[k + 1] end
                GameTooltip:AddLine((info.zone or "?") .. ":  " .. table.concat(pts, "   "), 0.75, 0.77, 0.8, true)
            end
            local any = ns.LookupAny(info.id, info.name, false)
            if any then
                for _, st in ipairs(ns.Layers(any)) do
                    GameTooltip:AddDoubleLine("Layer " .. ns.LayerName(st.layer), st.text .. (st.src and (" (" .. st.src .. ")") or ""),
                        0.9, 0.9, 0.9, 0.37, 0.84, 0.66)
                end
            end
            local drops = ns.DropRows(info.id)
            if drops then
                local shown = 0
                for _, d in ipairs(drops) do
                    if d.kind == "item" and shown < 5 then
                        if shown == 0 then GameTooltip:AddLine(" "); GameTooltip:AddLine("Drops", 0.6, 0.62, 0.68) end
                        GameTooltip:AddDoubleLine("|cff" .. ns.QualityHex(d.q) .. d.name .. "|r", string.format("%g%%", d.pct), 1, 1, 1, 0.75, 0.77, 0.8)
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
            r.sub:SetText((info.zone or "Unknown zone") .. DOT .. "level " .. (info.minl or "?") .. DOT
                .. (info.rank == 2 and "Rare elite" or "Rare") .. (fam and (DOT .. Hex(C.accent) .. "Tame: " .. fam .. "|r") or ""))
        end
        r.resp:SetText(info.rmin and (ns.Hours(info.rmin) .. " - " .. ns.Hours(info.rmax) .. " h") or "Unknown")
        local any = ns.LookupAny(info.id, info.name, false)
        local st = any and ns.Summary(any)
        if st and st.code ~= "NONE" then
            local col = (st.code == "UP" or st.code == "OPEN") and C.accent or (st.code == "WAIT" and C.yellow or C.sec)
            local word = ({ UP = "Up", STALE = "Seen", WAIT = "Dead", OPEN = "Window open", DUE = "Due" })[st.code] or ""
            r.seen:SetText(word .. " (" .. ns.LayerShort(st.layer) .. ")")
            W.SetColor(r.seen, col)
        else
            local seen = ns.LastSeenInForever(info.id)
            r.seen:SetText(seen and ("Seen " .. ns.Dur(ns.Now() - seen) .. " ago") or "Not seen yet")
            W.SetColor(r.seen, seen and C.accent or C.muted)
        end
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
            r.seen:SetWidth(math.max(130, RW - seenX - 92 - 24))
        end)
        list:Fit(CH - 104 - 12)
    end
    layouts[2]()

    -- custom mob popover
    local cp = W.Popover("RareWatchCustomPopover", 340, 214)
    W.Text(cp, 13, "M", "Track a custom mob"):SetPoint("TOPLEFT", 16, -16)
    local fName = W.Field(cp, "Name", 200, "Exact in-game name")
    fName:SetPoint("TOPLEFT", 16, -60)
    local fId = W.Field(cp, "NPC ID", 92, "Optional")
    fId:SetPoint("LEFT", fName, "RIGHT", 16, 0)
    local fMin = W.Field(cp, "Min hours", 92, "6")
    fMin:SetPoint("TOPLEFT", 16, -112)
    local fMax = W.Field(cp, "Max hours", 92, "24")
    fMax:SetPoint("LEFT", fMin, "RIGHT", 16, 0)
    local fNote = W.Cell(cp, 11, "R", 308, C.muted)
    fNote:SetPoint("TOPLEFT", 16, -150)
    local useTarget = W.Button(cp, { text = "Use target", icon = "target", onClick = function()
        if not UnitExists("target") or UnitIsPlayer("target") then
            fNote:SetText(Hex(C.red) .. "Target an NPC first.|r")
            return
        end
        local id = ns.ParseGUID(UnitGUID("target"))
        fName:SetText(UnitName("target") or "")
        fId:SetText(id and tostring(id) or "")
        local mn, mx = ns.DefaultRespawn(id)
        fMin:SetText(ns.Hours(mn))
        fMax:SetText(ns.Hours(mx))
        fNote:SetText("Filled from your target.")
    end })
    useTarget:SetPoint("BOTTOMLEFT", 16, 14)
    local fSave = W.Button(cp, { text = "Track", style = "primary", w = 80, onClick = function()
        local a, b = tonumber(fMin:GetText()), tonumber(fMax:GetText())
        local def, res = ns.AddMob(fName:GetText(), fId:GetText(), a and a * 3600, b and b * 3600)
        if def then
            def.respawnSrc = "your setting"
            selectedKey = ns.Key(def.name)
            cp:Hide()
        else
            fNote:SetText(Hex(C.red) .. res .. "|r")
        end
    end })
    fSave:SetPoint("BOTTOMRIGHT", -16, 14)
    fMax.onEnter = function() fSave:Click() end
    cp.onOpen = function()
        for _, e in ipairs({ fName, fId }) do e:SetText("") end
        fMin:SetText(ns.Hours(ns.opt.defaultMin))
        fMax:SetText(ns.Hours(ns.opt.defaultMax))
        fNote:SetText("For mobs that aren't in the list. Target it for the name and ID.")
    end
    addCustom:SetScript("OnClick", function(self)
        if cp:IsShown() then cp:Hide() else cp:Open(self, "TOPRIGHT", "BOTTOMRIGHT", 0, -6) end
    end)

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

    local search = W.Edit(page, 200, 30, "Search rare, player or layer")
    search:SetPoint("RIGHT", clear, "LEFT", -10, 0)
    local sIcon = W.Icon(search, "search", 14, C.muted)
    sIcon:SetPoint("RIGHT", -10, 0)

    local list = W.List(page, MAX_H - 70 - 12, 36, function(lst)
        local r = CreateFrame("Frame", nil, lst)
        r.dot = W.Dot(r, 7)
        r.dot:SetPoint("LEFT", 12, 0)
        r.event = W.Cell(r, 12, "M", 70)
        r.event:SetPoint("LEFT", 28, 0)
        r.mob = W.Cell(r, 12, "R", 220)
        r.mob:SetPoint("LEFT", 104, 0)
        r.layer = W.Cell(r, 12, "R", 90, C.sec)
        r.layer:SetPoint("LEFT", 330, 0)
        r.src = W.Cell(r, 12, "R", 90, C.muted)
        r.src:SetPoint("LEFT", 424, 0)
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
        r.layer:SetText("Layer " .. ns.LayerShort(h.l))
        r.src:SetText(h.s or "")
        r.time:SetText(ns.Dur(ns.Now() - h.t) .. " ago" .. DOT .. ns.Day(h.t))
        local joinable = false
        if (h.k == "SEEN" or h.k == "SPAWN") and ns.Now() - h.t < 600 then
            local def = ns.LookupAny(nil, h.n, false)
            local rec = def and def.layers and def.layers[h.l]
            if rec then joinable = r.join:Bind(def, { layer = h.l, rec = rec }) else r.join:Hide() end
        else
            r.join:Hide()
        end
        r.time:ClearAllPoints()
        r.time:SetPoint("RIGHT", joinable and -(r.join:GetWidth() + 22) or -12, 0)
        r.time:SetWidth(joinable and 120 or 150)
        r.src:SetWidth(math.max(60, (r.srcW or 90) - (joinable and 60 or 0)))
    end)
    list:SetPoint("TOPLEFT", 8, -70)
    list:SetPoint("TOPRIGHT", -12, -70)
    layouts[3] = function()
        local extra = math.max(0, (CW - 20 - 8) - 684)
        local mobW = 220 + math.floor(extra * 0.25)
        local layerX = 104 + mobW + 6
        local layerW = 90 + math.floor(extra * 0.4)
        local srcX = layerX + layerW + 4
        local srcW = 90 + math.floor(extra * 0.35)
        EachRow(list, function(r)
            r.mob:SetWidth(mobW)
            r.layer:ClearAllPoints(); r.layer:SetPoint("LEFT", layerX, 0); r.layer:SetWidth(layerW)
            r.src:ClearAllPoints(); r.src:SetPoint("LEFT", srcX, 0); r.src:SetWidth(srcW); r.srcW = srcW
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
                local hay = ((h.n or "") .. " " .. (h.s or "") .. " " .. ns.LayerName(h.l) .. " " .. (e and e.label or "")):lower()
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

    local function Section(ci, text)
        local card = CreateFrame("Frame", nil, page)
        W.Round(card, C.card, 10)
        local t = W.Text(card, 11, "M", text:upper(), C.muted)
        t:SetPoint("TOPLEFT", PADX, -14)
        cur = { card = card, rows = {}, col2 = ci }
        sections[#sections + 1] = cur
    end
    local function Row(ci, label, control, tip)
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
        -- which column each section goes in
        local plan = ncol == 3 and { 1, 2, 3, 2 } or { 1, 1, 2, 2 }
        -- row height: as roomy as the window height allows
        local HEAD, FOOT, TOP = 36, 12, 60
        local rows, secs = { 0, 0, 0 }, { 0, 0, 0 }
        for i, sec in ipairs(sections) do
            local c = plan[i] or sec.col2
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
            local c = plan[i] or sec.col2
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

    -- column 1
    Section(1, "Alerts")
    Row(1, "Play a sound", Opt("alertSound"))
    local soundBtn
    soundBtn = W.Button(page, { text = "", icon = "volume", h = 24, size = 11, onClick = function()
        o.sound = (o.sound % #ns.SOUNDS) + 1
        soundBtn:SetLabel(ns.SOUNDS[o.sound].name)
        ns.PlayAlertSound()
    end, tip = { "Alert sound", "Click to cycle sounds. Plays a preview." } })
    soundBtn.Refresh = function(self) self:SetLabel((ns.SOUNDS[o.sound] or ns.SOUNDS[1]).name) end
    Row(1, "Sound", soundBtn)
    Row(1, "Big text on screen", Opt("alertRaidWarn"))
    Row(1, "Flash the taskbar icon", Opt("alertFlash"))
    Row(1, "Message in chat", Opt("alertChat"))
    Row(1, "Sound for other users' sightings", Opt("shareAlerts"))
    Row(1, "Notify when a window opens", Opt("windowAlert"))
    Row(1, "Alert for untracked rares", Opt("alertAnyRare"), "Also alert once for rares you aren't tracking.")
    Row(1, "Try it out", W.Button(page, { text = "Test alert", icon = "bell", h = 24, size = 11, onClick = function()
        ns.Alert("TEST: Humar the Pridelord is UP")
    end }))

    Section(1, "Display")
    Row(1, "Status box", Opt("showTracker"), "The small box that shows fresh sightings of your tracked rares in your zone, with a Join button.")
    Row(1, "Lock status box", Opt("lockTracker"))
    Row(1, "Minimap button", W.Switch(page, function() return not o.minimapHide end,
        function(v) o.minimapHide = not v; ns.Changed() end))
    local pct = function(v) return math.floor(v * 100 + 0.5) .. "%" end
    Row(1, "Status box size", W.Stepper(page, function() return o.trackerScale end,
        function(v) o.trackerScale = v; ns.Changed() end, 0.6, 1.6, 0.1, pct))
    Row(1, "Window size", W.Stepper(page, function() return o.windowScale end,
        function(v) o.windowScale = v; main:SetScale(v) end, 0.7, 1.4, 0.1, pct))


    -- column 2
    Section(2, "Sharing")
    Row(2, "Share with my guild", Opt("shareGuild"))
    Row(2, "Share with RareWatch users", W.Switch(page, function() return GetChannelName(ns.CHANNEL) > 0 end,
        function(v) ns.SetChannel(v) end),
        "Kills, tames and sightings are shared automatically with everyone running RareWatch, through a hidden chat channel. Members can see your character name in the channel list.")
    Row(2, "Share with my group", Opt("shareGroup"), "Also share with your party or raid.")
    local onlineRow = Row(2, "Users online", W.Button(page, { text = "Resync", icon = "refresh", h = 24, size = 11,
        onClick = function() ns.SyncNow() end }),
        ns.Private() and "Syncing is automatic. Resync just does it right now. On this game build layers can't be matched between players, so a report shows the layer as that player sees it, like \"C (Bob's)\"."
            or "Syncing is automatic. Resync just does it right now.")

    ns.settingsOnlineRow = onlineRow
    local hostRow = Row(2, "Let others join my layer", W.Switch(page, function() return o.hostJoin and not (ns.Join and ns.Join.PausedFor() > 0) end,
        function(v) o.hostJoin = v; if v and ns.Join then ns.Join.Resume() end; ns.Changed() end),
        "When you see a rare, other RareWatch users can ask to join your layer for it. You always click Accept or Decline first, and nobody whose layer moves are nearly used up can ask (that could move you off the rare). At most 3 requests every 5 minutes; anyone you decline waits 10 minutes. Turning this back on ends a pause.")
    local movesRow = Row(2, "Layer moves this hour", nil,
        "The game allows about 10 layer moves an hour. Every move counts, from RareWatch, Layer-Swap or joining any group. Join requests stop at 8, so a host is never moved to you instead.")
    local layerRow = Row(2, "", nil)
    local named = CreateFrame("Frame", nil, page)
    named:SetSize(150, 24)
    local labelIn = W.Edit(named, 70, 24, "A")
    labelIn:SetPoint("LEFT")
    labelIn:SetMaxLetters(12)
    local layerErr
    local function SaveLabel()
        local ok, err = ns.SetLayerName(ns.currentLayer, labelIn:GetText())
        if ok then labelIn:SetText(""); layerErr = nil else layerErr = err end
        refreshers[4]()
    end
    local labelBtn = W.Button(named, { text = "Name it", h = 24, size = 11, onClick = SaveLabel })
    labelBtn:SetPoint("RIGHT")
    labelIn.onEnter = SaveLabel
    Row(2, "Name your current layer", named,
        "The game only gives a number per layer. If another addon calls it e.g. layer A, type A so RareWatch uses the same name. Empty clears it.")

    Section(2, "Advanced")
    Row(2, "Read spawn time from mob ID", Opt("decodeSpawn"),
        "Experimental. Some clients encode the spawn time in the mob's ID. Turn off if spawn times look wrong.")
    local hfmt = function(v) return ns.Hours(v) .. " h" end
    Row(2, "Unknown mobs: min respawn", W.Stepper(page, function() return o.defaultMin end,
        function(v) o.defaultMin = v end, 3600, 72 * 3600, 3600, hfmt))
    Row(2, "Unknown mobs: max respawn", W.Stepper(page, function() return o.defaultMax end,
        function(v) o.defaultMax = v end, 3600, 72 * 3600, 3600, hfmt))
    Row(2, "Clear timers, history, measurements", W.ConfirmButton(page, { text = "Reset", icon = "trash", h = 24, size = 11, style = "ghost" },
        function()
            for _, def in pairs(ns.db.mobs) do wipe(def.layers); def.samples = nil end
            wipe(ns.db.history)
            ns.Changed()
        end))
    Row(2, "Reset window size", W.Button(page, { text = "Reset", icon = "refresh", h = 24, size = 11,
        onClick = function() ns.ResetMainSize() end }),
        "Drag the bottom-right corner of the window to resize it. Reset puts it back to the default size.")
    Row(2, "Use the game's font (after /reload)", W.Switch(page, function() return o.plainFont end, function(v)
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
            local used = ns.Join.Used()
            local col = used >= 8 and C.red or (used >= 7 and C.yellow or C.accent)
            movesRow.label:SetText("Layer moves this hour: " .. Hex(col) .. used .. "|r of about " .. ns.Join.Limit())
        end
        onlineRow.label:SetText("Users online: " .. Hex(n > 0 and C.accent or C.muted) .. (n + 1) .. "|r (incl. you)")
        if layerErr then
            layerRow.label:SetText(Hex(C.red) .. layerErr .. "|r")
        else
            layerRow.label:SetText("Your layer: " .. (ns.currentLayer and (Hex(C.accent) .. ns.LayerName(ns.currentLayer) .. "|r") or "unknown - target any NPC")
                .. (ns.currentLayerZone and (Hex(C.muted) .. DOT .. ns.currentLayerZone .. "|r") or ""))
        end
    end
end

---------------------------------------------------------------------------
-- Main window
---------------------------------------------------------------------------
local PAGE_DEFS = {
    { icon = "clock", name = "Tracker", build = BuildTracker },
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
ns.ShowTab = ns.ShowPage

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
-- Status box: fresh sightings of your tracked rares in this zone, each with a Join button.
-- (Respawn windows stopped meaning much once Forever removed layering, so the box shows sightings instead.)
---------------------------------------------------------------------------
local MAX_ROWS, BOX_W, ROW_H = 4, 270, 40

-- Tracked rares that live in the zone you're in, and the sightings of them you could join.
local function Sightings()
    local here = GetRealZoneText and GetRealZoneText() or ""
    local watched, out = 0, {}
    for _, def in ipairs(ns.list) do
        local info = ns.RareInfo(def.id)
        if info and info.zone and info.zone == here then
            watched = watched + 1
            for _, st in ipairs(ns.Layers(def)) do
                local host, _, why
                if ns.Join then host, _, why = ns.Join.CanJoin(def, st) end
                if host and why ~= "hide" then
                    local r = st.rec or {}
                    out[#out + 1] = { def = def, st = st, host = host, at = math.max(r.seen or 0, r.spawn or 0) }
                end
            end
        end
    end
    table.sort(out, function(a, b)
        if a.at ~= b.at then return a.at > b.at end
        return a.def.name < b.def.name
    end)
    return out, watched, here
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
    W.Tip(overlay, "RareWatch", "Shows your tracked rares that another RareWatch user spotted in this zone in the last 10 minutes. Join puts you on their layer.\n\nLeft-click: open tracker\nRight-click: settings\nDrag: move")

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
        row.dot:SetVertexColor(C.accent[1], C.accent[2], C.accent[3], 1)
        row.name = W.Cell(overlay, 12, "M", BOX_W - 110, C.text)
        row.name:SetPoint("TOPLEFT", 24, y - 1)
        row.sub = W.Cell(overlay, 11, "R", BOX_W - 110, C.muted)
        row.sub:SetPoint("TOPLEFT", 24, y - 17)
        row.join = JoinButton(overlay)
        row.join:SetPoint("TOPRIGHT", -10, y - 4)
        overlay.rows[i] = row
    end
    -- shown when there is nothing to join
    overlay.empty = W.Cell(overlay, 12, "R", BOX_W - 34, C.muted)
    overlay.empty:SetPoint("TOPLEFT", 24, -29)
    overlay.emptyDot = W.Dot(overlay, 6)
    overlay.emptyDot:SetPoint("TOPLEFT", 11, -34)
    overlay.emptyDot:SetVertexColor(C.muted[1], C.muted[2], C.muted[3], 1)
end

local function RefreshOverlay()
    if not overlay then return end
    overlay:SetShown(ns.opt.showTracker)
    if not ns.opt.showTracker then return end
    overlay:SetScale(ns.opt.trackerScale)
    local list, watched, here = Sightings()
    overlay.zone:SetText(here or "")
    local shown = 0
    for i, row in ipairs(overlay.rows) do
        local s = list[i]
        if s then
            shown = i
            row.name:SetText(s.def.name)
            row.sub:SetText(s.host .. DOT .. (ns.Now() - s.at < 60 and "just now" or (ns.Dur(ns.Now() - s.at) .. " ago")))
            row.dot:Show(); row.name:Show(); row.sub:Show()
            if not row.join:Bind(s.def, s.st) then row.join:Hide() end
        else
            row.dot:Hide(); row.name:Hide(); row.sub:Hide(); row.join:Hide()
        end
    end
    if shown == 0 then
        overlay.empty:SetText(watched == 0 and "None of your tracked rares live here"
            or ("Watching " .. watched .. " here, nothing spotted yet"))
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
        for _, item in ipairs(SortedMobs()) do
            local c = SC(item.st.code)
            GameTooltip:AddDoubleLine(item.def.name, ShortStatus(item.st), 0.9, 0.9, 0.9, c[1], c[2], c[3])
        end
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
    C_Timer.NewTicker(1, function()
        RefreshOverlay()
        ns.RefreshMain()
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
    local title = W.Text(p, 14, "S", "Share rare timers automatically?")
    title:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    local body = W.Text(p, 12, "R", "RareWatch users share kills, tames and sightings with each other in the background, so you see every rare's timer on every layer without asking anyone.\n\nThis joins a hidden chat channel. Other members can see your character name in it.")
    body:SetPoint("TOPLEFT", 18, -48)
    body:SetWidth(344)
    body:SetJustifyH("LEFT")
    W.SetColor(body, C.sec)
    local yes = W.Button(p, { text = "Connect", icon = "check", style = "primary", w = 110, h = 28,
        onClick = function() p:Hide(); ns.SetChannel(true); ns.Print("Connected. Timers now sync automatically.") end })
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
