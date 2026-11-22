-- RareWatch - Widgets: flat, rounded, self-drawn controls (no Blizzard templates).
local ADDON_NAME, ns = ...
local W = {}
ns.W = W

local MEDIA = "Interface\\AddOns\\" .. ADDON_NAME .. "\\media\\"
W.MEDIA = MEDIA

---------------------------------------------------------------------------
-- Palette
---------------------------------------------------------------------------
W.C = {
    bg      = { 0.059, 0.067, 0.082 },  -- window
    side    = { 0.043, 0.047, 0.063 },  -- sidebar
    col     = { 0.075, 0.082, 0.102 },  -- list column
    card    = { 0.110, 0.125, 0.157 },  -- selected card / raised
    chip    = { 0.102, 0.114, 0.141 },  -- chips, default buttons
    hover   = { 0.140, 0.157, 0.196 },
    input   = { 0.035, 0.039, 0.051 },
    track   = { 0.149, 0.165, 0.200 },
    track2  = { 0.165, 0.188, 0.251 },
    line    = { 0.110, 0.125, 0.157 },
    pop     = { 0.125, 0.141, 0.176 },
    popEdge = { 0.200, 0.220, 0.270 },
    text    = { 0.902, 0.910, 0.925 },
    text2   = { 0.788, 0.804, 0.839 },
    sec     = { 0.604, 0.627, 0.678 },
    muted   = { 0.420, 0.443, 0.502 },
    accent  = { 0.373, 0.839, 0.659 },
    primary = { 0.169, 0.420, 0.333 },
    green   = { 0.373, 0.839, 0.659 },
    stale   = { 0.620, 0.760, 0.560 },
    yellow  = { 0.949, 0.788, 0.298 },
    orange  = { 0.910, 0.541, 0.290 },
    red     = { 0.937, 0.431, 0.431 },
    blue    = { 0.490, 0.640, 0.960 },
}
local C = W.C

function W.Hex(c)
    return string.format("|cff%02x%02x%02x", math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5))
end
local Hex = W.Hex

function W.Mix(a, b, t)
    return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t }
end

---------------------------------------------------------------------------
-- Fonts (Inter + Tabler icon font, with fallback to the game font)
---------------------------------------------------------------------------
local FONT_FILES = { R = "Inter-Regular.ttf", M = "Inter-Medium.ttf", S = "Inter-SemiBold.ttf" }
local fontCache, iconCache = {}, {}
local fallback = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"

local function SetFontSafe(obj, file, size)
    local custom = not (ns.opt and ns.opt.plainFont)
    if custom then
        obj:SetFont(file, size, "")
        if obj:GetFont() then return true end
    end
    obj:SetFont(fallback, size, "")
    return false
end

function W.Font(size, weight)
    weight = weight or "R"
    local key = weight .. size
    local obj = fontCache[key]
    if not obj then
        obj = CreateFont("RareWatchFont" .. key)
        SetFontSafe(obj, MEDIA .. FONT_FILES[weight], size)
        obj:SetTextColor(C.text[1], C.text[2], C.text[3])
        fontCache[key] = obj
    end
    return obj
end

W.ICON = {
    paw = 61433, clock = 60016, search = 60188, history = 60394, settings = 60192, x = 60245,
    pin = 60136, plus = 60171, check = 59998, refresh = 60179, bell = 59957, crown = 60690,
    sparkles = 63191, skull = 62098, target = 62746, eye = 60058, chevron = 60001, trash = 60225,
    pencil = 60164, users = 60402, bolt = 59960, volume = 60241, info = 60101, hourglass = 61331,
}

local function U8(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then return string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64) end
    return string.char(0xE0 + math.floor(cp / 4096), 0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
end

W.iconsOK = true
local function IconFont(size)
    local obj = iconCache[size]
    if not obj then
        obj = CreateFont("RareWatchIcon" .. size)
        obj:SetFont(MEDIA .. "icons.ttf", size, "")
        if not obj:GetFont() then
            W.iconsOK = false
            obj:SetFont(fallback, size, "")
        end
        iconCache[size] = obj
    end
    return obj
end

-- Fontstring helper. weight: "R" | "M" | "S"
function W.Text(parent, size, weight, text, color, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFontObject(W.Font(size or 12, weight or "R"))
    fs:SetJustifyH(justify or "LEFT")
    local c = color or C.text
    fs:SetTextColor(c[1], c[2], c[3])
    fs:SetText(text or "")
    return fs
end

-- Single-line truncating text of fixed width.
function W.Cell(parent, size, weight, width, color, justify)
    local fs = W.Text(parent, size, weight, "", color, justify)
    fs:SetWidth(width)
    fs:SetWordWrap(false)
    return fs
end

function W.Icon(parent, name, size, color)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFontObject(IconFont(size or 16))
    local c = color or C.sec
    fs:SetTextColor(c[1], c[2], c[3])
    function fs:SetIcon(n)
        local cp = W.ICON[n]
        if W.iconsOK and cp then self:SetText(U8(cp)) else self:SetText("") end
    end
    fs:SetIcon(name)
    return fs
end

function W.SetColor(fs, c) fs:SetTextColor(c[1], c[2], c[3]) end

---------------------------------------------------------------------------
-- Shapes
---------------------------------------------------------------------------
function W.Rect(frame, c, layer, a)
    local t = frame:CreateTexture(nil, layer or "BACKGROUND")
    t:SetAllPoints()
    t:SetColorTexture(c[1], c[2], c[3], a or c[4] or 1)
    return t
end

-- 9-slice rounded rectangle from media\round.tga. Returns a handle with :SetColor(c, a), :SetShown().
function W.Round(frame, c, r, layer, inset, sublevel)
    r = r or 6
    inset = inset or 0
    local tex = {}
    local function piece(l, rgt, t, b)
        local x = frame:CreateTexture(nil, layer or "BACKGROUND", nil, sublevel or 0)
        x:SetTexture(MEDIA .. "round")
        x:SetTexCoord(l, rgt, t, b)
        tex[#tex + 1] = x
        return x
    end
    local i = inset
    local tl = piece(0, 0.25, 0, 0.25); tl:SetPoint("TOPLEFT", i, -i); tl:SetSize(r, r)
    local tr = piece(0.75, 1, 0, 0.25); tr:SetPoint("TOPRIGHT", -i, -i); tr:SetSize(r, r)
    local bl = piece(0, 0.25, 0.75, 1); bl:SetPoint("BOTTOMLEFT", i, i); bl:SetSize(r, r)
    local br = piece(0.75, 1, 0.75, 1); br:SetPoint("BOTTOMRIGHT", -i, i); br:SetSize(r, r)
    local t = piece(0.25, 0.75, 0, 0.25); t:SetPoint("TOPLEFT", i + r, -i); t:SetPoint("TOPRIGHT", -i - r, -i); t:SetHeight(r)
    local b = piece(0.25, 0.75, 0.75, 1); b:SetPoint("BOTTOMLEFT", i + r, i); b:SetPoint("BOTTOMRIGHT", -i - r, i); b:SetHeight(r)
    local lft = piece(0, 0.25, 0.25, 0.75); lft:SetPoint("TOPLEFT", i, -i - r); lft:SetPoint("BOTTOMLEFT", i, i + r); lft:SetWidth(r)
    local rgt = piece(0.75, 1, 0.25, 0.75); rgt:SetPoint("TOPRIGHT", -i, -i - r); rgt:SetPoint("BOTTOMRIGHT", -i, i + r); rgt:SetWidth(r)
    local ctr = piece(0.25, 0.75, 0.25, 0.75); ctr:SetPoint("TOPLEFT", i + r, -i - r); ctr:SetPoint("BOTTOMRIGHT", -i - r, i + r)
    local h = { tex = tex }
    function h:SetColor(col, a)
        for _, x in ipairs(self.tex) do x:SetVertexColor(col[1], col[2], col[3], a or col[4] or 1) end
    end
    function h:SetShown(v) for _, x in ipairs(self.tex) do x:SetShown(v) end end
    h:SetColor(c or C.chip)
    return h
end

function W.Dot(parent, size, c)
    local t = parent:CreateTexture(nil, "ARTWORK")
    t:SetTexture(MEDIA .. "circle")
    t:SetSize(size or 7, size or 7)
    c = c or C.muted
    t:SetVertexColor(c[1], c[2], c[3], 1)
    return t
end

function W.Line(parent, c, a)
    local t = parent:CreateTexture(nil, "ARTWORK")
    c = c or C.line
    t:SetColorTexture(c[1], c[2], c[3], a or 1)
    t:SetHeight(1)
    return t
end

function W.Tip(frame, title, body)
    frame:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(title, 1, 1, 1)
        if body then GameTooltip:AddLine(body, 0.75, 0.77, 0.8, true) end
        GameTooltip:Show()
    end)
    frame:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

---------------------------------------------------------------------------
-- Buttons
---------------------------------------------------------------------------
local STYLES = {
    default = { bg = C.chip, hover = C.hover, text = C.text2 },
    primary = { bg = C.primary, hover = { 0.21, 0.51, 0.41 }, text = { 0.90, 1.00, 0.96 } },
    ghost   = { bg = C.chip, bgA = 0, hover = C.chip, text = C.sec },
    danger  = { bg = { 0.250, 0.100, 0.110 }, hover = { 0.330, 0.130, 0.140 }, text = C.red },
    accent  = { bg = W.Mix(C.chip, C.accent, 0.22), hover = W.Mix(C.chip, C.accent, 0.32), text = C.accent },
}
W.STYLES = STYLES

-- opts: text, icon, w, h, style, onClick, tip, iconSize, size
function W.Button(parent, opts)
    local b = CreateFrame("Button", nil, parent)
    local h = opts.h or 28
    b:SetHeight(h)
    b.style = STYLES[opts.style or "default"]
    b.bg = W.Round(b, b.style.bg, math.min(6, math.floor(h / 2)))
    b.bg:SetColor(b.style.bg, b.style.bgA)
    b.icon = W.Icon(b, opts.icon, opts.iconSize or 14, b.style.text)
    b.label = W.Text(b, opts.size or 12, "M", opts.text or "", b.style.text, "CENTER")
    b.fixedW = opts.w

    function b:Layout()
        local hasIcon = self.icon:GetText() ~= nil and self.icon:GetText() ~= ""
        local hasText = self.label:GetText() ~= nil and self.label:GetText() ~= ""
        local iw = hasIcon and self.icon:GetStringWidth() or 0
        local lw = hasText and self.label:GetStringWidth() or 0
        local gap = (hasIcon and hasText) and 6 or 0
        local total = iw + gap + lw
        local w = self.fixedW or math.floor(total + 24 + 0.5)
        self:SetWidth(w)
        local x = (w - total) / 2
        self.icon:ClearAllPoints()
        self.icon:SetPoint("LEFT", x, 0)
        self.label:ClearAllPoints()
        self.label:SetPoint("LEFT", x + iw + gap, 0)
    end
    function b:SetLabel(t) self.label:SetText(t or ""); self:Layout() end
    function b:SetIcon(n) self.icon:SetIcon(n); self:Layout() end
    function b:SetStyle(name)
        self.style = STYLES[name] or STYLES.default
        self.bg:SetColor(self.style.bg, self.style.bgA)
        W.SetColor(self.icon, self.style.text)
        W.SetColor(self.label, self.style.text)
    end
    function b:SetDisabled(d)
        self.disabled = d
        self:SetAlpha(d and 0.4 or 1)
    end
    b:SetScript("OnEnter", function(self)
        if not self.disabled then self.bg:SetColor(self.style.hover, 1) end
    end)
    b:SetScript("OnLeave", function(self) self.bg:SetColor(self.style.bg, self.style.bgA) end)
    b:SetScript("OnClick", function(self, ...)
        if ns.EnsureChannel then ns.EnsureChannel() end
        if self.disabled then return end
        if opts.onClick then opts.onClick(self, ...) end
    end)
    if opts.tip then W.Tip(b, opts.tip[1], opts.tip[2]) end
    b:Layout()
    return b
end

-- Two-step button: first click arms it ("Sure?"), second click confirms.
function W.ConfirmButton(parent, opts, onConfirm)
    local base = { text = opts.text, icon = opts.icon, style = opts.style }
    local b
    opts.onClick = function(self)
        if self.armed then
            self.armed = false
            self:SetStyle(base.style or "default")
            self:SetLabel(base.text)
            onConfirm(self)
        else
            self.armed = true
            self:SetStyle("danger")
            self:SetLabel(opts.confirmText or "Sure?")
            C_Timer.After(3, function()
                if b.armed then
                    b.armed = false
                    b:SetStyle(base.style or "default")
                    b:SetLabel(base.text)
                end
            end)
        end
    end
    b = W.Button(parent, opts)
    return b
end

-- Pill chip (static).
function W.Chip(parent, text, textColor, bgColor)
    local f = CreateFrame("Frame", nil, parent)
    f:SetHeight(22)
    f.bg = W.Round(f, bgColor or C.chip, 6)
    f.text = W.Text(f, 11, "R", text, textColor or C.sec)
    f.text:SetPoint("LEFT", 8, 0)
    function f:SetText(t, c, bgc)
        self.text:SetText(t or "")
        if c then W.SetColor(self.text, c) end
        if bgc then self.bg:SetColor(bgc) end
        self:SetWidth(math.floor(self.text:GetStringWidth() + 16.5))
    end
    f:SetText(text)
    return f
end

-- Toggle chip (filters).
function W.ToggleChip(parent, text, get, set)
    local b = W.Button(parent, { text = text, h = 26, size = 11 })
    function b:Refresh()
        self:SetStyle(get() and "accent" or "default")
    end
    b:SetScript("OnClick", function(self) set(not get()); self:Refresh() end)
    b:Refresh()
    return b
end

-- iOS-style switch.
function W.Switch(parent, get, set)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(30, 16)
    b.track = W.Round(b, C.track, 8)
    b.knob = b:CreateTexture(nil, "ARTWORK")
    b.knob:SetTexture(MEDIA .. "circle")
    b.knob:SetSize(12, 12)
    function b:Refresh()
        local on = get() and true or false
        self.track:SetColor(on and C.primary or C.track)
        self.knob:ClearAllPoints()
        self.knob:SetPoint(on and "RIGHT" or "LEFT", on and -2 or 2, 0)
        local k = on and { 0.85, 1, 0.94 } or C.sec
        self.knob:SetVertexColor(k[1], k[2], k[3], 1)
    end
    b:SetScript("OnClick", function(self) set(not get()); self:Refresh() end)
    b:Refresh()
    return b
end

---------------------------------------------------------------------------
-- Inputs
---------------------------------------------------------------------------
function W.Edit(parent, w, h, placeholder)
    local e = CreateFrame("EditBox", nil, parent)
    e:SetSize(w, h or 28)
    e:SetAutoFocus(false)
    e:SetFontObject(W.Font(12, "R"))
    e:SetTextColor(C.text[1], C.text[2], C.text[3])
    e:SetTextInsets(10, 10, 0, 0)
    e:SetMaxLetters(48)
    e.bg = W.Round(e, C.input, 6)
    e.ph = W.Text(e, 12, "R", placeholder or "", C.muted)
    e.ph:SetPoint("LEFT", 10, 0)
    local function upd()
        e.ph:SetShown(e:GetText() == "" and not e:HasFocus())
        e.bg:SetColor(e:HasFocus() and C.chip or C.input)
    end
    e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    e:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        if self.onEnter then self.onEnter(self) end
    end)
    e:SetScript("OnEditFocusGained", upd)
    e:SetScript("OnEditFocusLost", upd)
    e:SetScript("OnTextChanged", function(self)
        upd()
        if self.onChange then self.onChange(self) end
    end)
    function e:SetPlaceholder(t) self.ph:SetText(t or "") end
    upd()
    return e
end

-- Caption above an input.
function W.Field(parent, caption, w, placeholder)
    local e = W.Edit(parent, w, 28, placeholder)
    e.caption = W.Text(parent, 11, "R", caption, C.muted)
    e.caption:SetPoint("BOTTOMLEFT", e, "TOPLEFT", 2, 5)
    return e
end

function W.Stepper(parent, get, set, minV, maxV, step, fmt)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(110, 24)
    local value = W.Text(f, 12, "M", "", C.text, "CENTER")
    local function upd() value:SetText(fmt(get())) end
    local function change(d)
        local v = math.floor((get() + d) * 100 + 0.5) / 100
        set(math.max(minV, math.min(maxV, v)))
        upd()
    end
    local plus = W.Button(f, { text = "+", w = 24, h = 24, style = "default" , onClick = function() change(step) end })
    plus:SetPoint("RIGHT", 0, 0)
    value:SetPoint("RIGHT", plus, "LEFT", -4, 0)
    value:SetWidth(54)
    local minus = W.Button(f, { text = "-", w = 24, h = 24, style = "default", onClick = function() change(-step) end })
    minus:SetPoint("RIGHT", value, "LEFT", -4, 0)
    f.Refresh = upd
    upd()
    return f
end

---------------------------------------------------------------------------
-- Virtual list (give it an explicit height)
---------------------------------------------------------------------------
function W.List(parent, height, rowH, makeRow, fillRow, gap)
    local L = CreateFrame("Frame", nil, parent)
    L:SetHeight(height)
    gap = gap or 0
    L.rowH, L.rows, L.data, L.offset = rowH, {}, {}, 0
    L.visible = math.max(1, math.floor((height + gap) / (rowH + gap)))
    L:EnableMouseWheel(true)

    L.thumb = L:CreateTexture(nil, "OVERLAY")
    L.thumb:SetColorTexture(C.track2[1], C.track2[2], C.track2[3], 1)
    L.thumb:SetWidth(4)

    -- the scroll bar: click anywhere on it to jump, drag to scroll
    L.track = CreateFrame("Frame", nil, L)
    L.track:SetWidth(12)
    L.track:SetPoint("TOPRIGHT", 0, 0)
    L.track:SetPoint("BOTTOMRIGHT", 0, 0)
    L.track:EnableMouse(true)
    L.track:SetFrameLevel((L:GetFrameLevel() or 0) + 5)
    local function SetFromCursor()
        local n = #L.data
        local maxOff = math.max(0, n - L.visible)
        if maxOff == 0 then return end
        local _, cy = GetCursorPosition()
        local top, h = L:GetTop(), L:GetHeight()
        if not (cy and top and h) then return end
        cy = cy / L:GetEffectiveScale()
        local th = L.thumbH or 24
        local frac = (top - cy - th / 2) / math.max(1, h - th)
        frac = math.max(0, math.min(1, frac))
        local off = math.floor(frac * maxOff + 0.5)
        if off ~= L.offset then L.offset = off; L:Refresh() end
    end
    L.track:SetScript("OnMouseDown", function(self, btn)
        if btn == "LeftButton" then self.drag = true; SetFromCursor() end
    end)
    L.track:SetScript("OnMouseUp", function(self) self.drag = false end)
    L.track:SetScript("OnHide", function(self) self.drag = false end)
    L.track:SetScript("OnUpdate", function(self) if self.drag then SetFromCursor() end end)

    L.empty = W.Text(L, 12, "R", "", C.muted, "CENTER")
    L.empty:SetPoint("CENTER")
    L.empty:SetWidth(320)

    for i = 1, L.visible do
        local r = makeRow(L, i)
        r:SetHeight(rowH)
        local y = -(i - 1) * (rowH + gap)
        r:SetPoint("TOPLEFT", 0, y)
        r:SetPoint("TOPRIGHT", -8, y)
        L.rows[i] = r
    end

    -- Show as many rows as fit in a new height (up to the rows built at creation).
    function L:Fit(h)
        h = math.max(rowH, h)
        if self.fitH == h then return end
        self.fitH = h
        self:SetHeight(h)
        self.visible = math.max(1, math.min(#self.rows, math.floor((h + gap) / (rowH + gap))))
        self:Refresh()
    end

    function L:SetData(data, emptyText)
        self.data = data or {}
        self.empty:SetText(emptyText or "")
        self:Refresh()
    end

    function L:Refresh()
        local n = #self.data
        local maxOff = math.max(0, n - self.visible)
        if self.offset > maxOff then self.offset = maxOff end
        for i, r in ipairs(self.rows) do
            local idx = i + self.offset
            local item = (i <= self.visible) and self.data[idx] or nil
            if item then r:Show(); fillRow(r, item, idx) else r:Hide() end
        end
        self.empty:SetShown(n == 0)
        if maxOff > 0 then
            local h = self:GetHeight()
            local th = math.max(24, h * self.visible / n)
            self.thumb:SetHeight(th)
            self.thumbH = th
            self.thumb:ClearAllPoints()
            self.thumb:SetPoint("TOPRIGHT", 0, -((h - th) * self.offset / maxOff))
            self.thumb:Show()
        else
            self.thumb:Hide()
        end
    end

    L:SetScript("OnMouseWheel", function(self, delta)
        self.offset = math.max(0, self.offset - delta)
        self:Refresh()
    end)
    L.track:EnableMouseWheel(true)
    L.track:SetScript("OnMouseWheel", function(_, delta)
        L.offset = math.max(0, L.offset - delta)
        L:Refresh()
    end)
    return L
end

---------------------------------------------------------------------------
-- Popover: a small floating panel anchored to a button.
---------------------------------------------------------------------------
-- Close on Escape without touching Blizzard's UISpecialFrames list (writing to it taints the UI).
function W.EscClose(f)
    -- Keys must keep reaching the game while a window is open. The game forbids changing the key-passing
    -- setting during combat (it logs a blocked action), so it is set once, out of combat, and left alone.
    local function Pass(v)
        if not (InCombatLockdown and InCombatLockdown()) then
            pcall(f.SetPropagateKeyboardInput, f, v)
        end
    end
    f:EnableKeyboard(true)
    Pass(true)
    f:HookScript("OnShow", function() Pass(true) end)
    f:SetScript("OnKeyDown", function(self, key)
        if key ~= "ESCAPE" then return end
        if InCombatLockdown and InCombatLockdown() then
            self:Hide()                       -- in combat: just close; the Esc menu may open too
        else
            Pass(false)                       -- swallow this Esc so the game menu stays shut
            self:Hide()
            C_Timer.After(0, function() Pass(true) end)
        end
    end)
end

local popovers = {}
function W.Popover(name, w, h)
    local p = CreateFrame("Frame", name, UIParent)
    p:SetSize(w, h)
    p:SetFrameStrata("DIALOG")
    p:SetToplevel(true)
    p:EnableMouse(true)
    p:SetClampedToScreen(true)
    W.Round(p, C.popEdge, 8)
    W.Round(p, C.pop, 7, "BACKGROUND", 1, 1)
    p:Hide()
    W.EscClose(p)
    table.insert(popovers, p)
    function p:Open(anchor, point, relPoint, x, y)
        for _, o in ipairs(popovers) do if o ~= self then o:Hide() end end
        self:SetScale((ns.opt and ns.opt.windowScale) or 1)
        self:ClearAllPoints()
        self:SetPoint(point or "BOTTOMLEFT", anchor, relPoint or "TOPLEFT", x or 0, y or 6)
        self:Show()
        if self.onOpen then self.onOpen(self) end
    end
    return p
end

function W.HidePopovers()
    for _, o in ipairs(popovers) do o:Hide() end
end
