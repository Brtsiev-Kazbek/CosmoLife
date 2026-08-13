-- Immediate mode drawing helpers plus a keyboard driven menu widget.
--
-- The whole UI is vector art in one accent colour: bracketed panels, thin
-- rules and bar gauges.  No images are loaded anywhere in the project.

local palette = require("src.render.palette")
local util = require("src.lib.util")

local ui = {}

ui.fonts = {}

--- Loads the interface fonts.
--
-- LOVE's built-in font is Latin only, so with it every Cyrillic string renders
-- as a row of empty boxes.  DejaVu covers Latin, Cyrillic and Greek; if the
-- file is missing we fall back to the built-in font rather than failing to
-- start, which degrades the game to Latin-only instead of breaking it.
local FONT_PATH = "assets/DejaVuSans.ttf"

local function newFont(size)
    if love.filesystem.getInfo(FONT_PATH) then
        local ok, font = pcall(love.graphics.newFont, FONT_PATH, size)
        if ok then return font end
    end
    return love.graphics.newFont(size)
end

--- Base font sizes, in pixels at the 1280x720 reference window.
local BASE_SIZES = { small = 13, normal = 16, large = 22, huge = 38, title = 64 }

--- Scale factor applied to every font.
--
-- The sizes above were tuned at 1280x720. Left as literal pixels they are
-- unreadable on a 4K display and overflow their panels on a 960x540 one, so
-- they track the window's smaller relative dimension. Clamped, because a
-- letterboxed ultra-wide should not shrink the text to nothing and a huge
-- monitor should not scale the HUD into the middle of the screen.
ui.scale = 1

local function computeScale()
    if not (love and love.graphics) then return 1 end
    local w, h = love.graphics.getDimensions()
    if not w or w == 0 then return 1 end
    local s = math.min(w / 1280, h / 720)
    -- DPI scaling is already baked into the reported size on most platforms;
    -- where it is not, this picks it up
    local dpi = (love.window and love.window.getDPIScale and love.window.getDPIScale()) or 1
    return util.clamp(s * math.max(dpi, 1) ^ 0.5, 0.8, 2.2)
end

function ui.load()
    ui.scale = computeScale()
    for name, size in pairs(BASE_SIZES) do
        ui.fonts[name] = newFont(math.max(8, math.floor(size * ui.scale + 0.5)))
    end
    for _, f in pairs(ui.fonts) do f:setFilter("nearest", "nearest") end
end

--- Rebuilds the fonts (called when the language or the window size changes).
function ui.reloadFonts() ui.load() end

--- Rebuilds only if the scale actually moved, so `love.resize` can call this
--- on every event without rebuilding five fonts per frame during a drag.
function ui.resize()
    local s = computeScale()
    if math.abs(s - ui.scale) > 0.01 then ui.load() end
end

function ui.font(name) return ui.fonts[name] or ui.fonts.normal end

function ui.setColor(c, alpha)
    love.graphics.setColor(c[1], c[2], c[3], (c[4] or 1) * (alpha or 1))
end

-- ---------------------------------------------------------------------------
-- Frames
-- ---------------------------------------------------------------------------

--- Panel with cut corners and an optional title tab.
function ui.panel(x, y, w, h, title, accent)
    accent = accent or palette.colors.uiPrimary
    local c = 10
    love.graphics.setColor(palette.colors.uiPanel)
    love.graphics.polygon("fill",
        x + c, y, x + w, y, x + w, y + h - c, x + w - c, y + h, x, y + h, x, y + c)
    love.graphics.setLineWidth(1)
    ui.setColor(accent, 0.75)
    love.graphics.polygon("line",
        x + c, y, x + w, y, x + w, y + h - c, x + w - c, y + h, x, y + h, x, y + c)
    if title then
        love.graphics.setFont(ui.font("small"))
        local tw = ui.font("small"):getWidth(title) + 16
        ui.setColor(accent, 0.9)
        love.graphics.rectangle("fill", x + 18, y - 1, tw, 2)
        love.graphics.setColor(palette.colors.uiPanel[1], palette.colors.uiPanel[2], palette.colors.uiPanel[3], 1)
        love.graphics.rectangle("fill", x + 18, y - 9, tw, 16)
        ui.setColor(accent, 1)
        love.graphics.print(title, x + 26, y - 9)
    end
    love.graphics.setColor(1, 1, 1, 1)
end

--- Corner brackets only -- used for HUD framing where a filled panel would
--- obscure the view.
function ui.brackets(x, y, w, h, size, accent, alpha)
    accent = accent or palette.colors.uiPrimary
    size = size or 14
    ui.setColor(accent, alpha or 0.8)
    love.graphics.setLineWidth(1)
    love.graphics.line(x, y + size, x, y, x + size, y)
    love.graphics.line(x + w - size, y, x + w, y, x + w, y + size)
    love.graphics.line(x + w, y + h - size, x + w, y + h, x + w - size, y + h)
    love.graphics.line(x + size, y + h, x, y + h, x, y + h - size)
    love.graphics.setColor(1, 1, 1, 1)
end

function ui.rule(x, y, w, accent, alpha)
    ui.setColor(accent or palette.colors.uiLine, alpha or 0.6)
    love.graphics.setLineWidth(1)
    love.graphics.line(x, y, x + w, y)
    love.graphics.setColor(1, 1, 1, 1)
end

-- ---------------------------------------------------------------------------
-- Text
-- ---------------------------------------------------------------------------

function ui.text(str, x, y, color, font)
    love.graphics.setFont(ui.font(font or "normal"))
    ui.setColor(color or palette.colors.uiText)
    love.graphics.print(str, math.floor(x), math.floor(y))
    love.graphics.setColor(1, 1, 1, 1)
end

function ui.textRight(str, x, y, color, font)
    local f = ui.font(font or "normal")
    love.graphics.setFont(f)
    ui.setColor(color or palette.colors.uiText)
    love.graphics.print(str, math.floor(x - f:getWidth(str)), math.floor(y))
    love.graphics.setColor(1, 1, 1, 1)
end

function ui.textCenter(str, cx, y, color, font)
    local f = ui.font(font or "normal")
    love.graphics.setFont(f)
    ui.setColor(color or palette.colors.uiText)
    love.graphics.print(str, math.floor(cx - f:getWidth(str) * 0.5), math.floor(y))
    love.graphics.setColor(1, 1, 1, 1)
end

--- Truncates a string to fit `maxW`, appending an ellipsis.
--
-- Procedural names have no length bound -- "Заводы Наковальня" is as likely as
-- "Сад" -- and Russian runs 20-30% longer than the English these panels were
-- measured against. Without this, a long name silently paints over whatever
-- sits beside it.
function ui.fit(str, maxW, font)
    local f = ui.font(font or "normal")
    str = tostring(str)
    if maxW <= 0 or f:getWidth(str) <= maxW then return str end
    local ellipsis = "..."
    local room = maxW - f:getWidth(ellipsis)
    if room <= 0 then return "" end
    -- binary search on byte length, then walk back off any UTF-8 continuation
    -- byte so a multi-byte character is never cut in half
    local lo, hi = 0, #str
    while lo < hi do
        local mid = math.floor((lo + hi + 1) * 0.5)
        if f:getWidth(str:sub(1, mid)) <= room then lo = mid else hi = mid - 1 end
    end
    while lo > 0 and str:byte(lo + 1) and str:byte(lo + 1) >= 0x80 and str:byte(lo + 1) < 0xC0 do
        lo = lo - 1
    end
    return str:sub(1, lo) .. ellipsis
end

--- Left aligned text, truncated to `maxW`.
function ui.textFit(str, x, y, maxW, color, font)
    ui.text(ui.fit(str, maxW, font), x, y, color, font)
end

--- Right aligned text, truncated to `maxW` (it grows leftwards from `x`).
function ui.textRightFit(str, x, y, maxW, color, font)
    ui.textRight(ui.fit(str, maxW, font), x, y, color, font)
end

--- Draws `fn` clipped to a rectangle.
--
-- Nothing in this project used a scissor before, so every panel whose content
-- outgrew it -- a hold with fifteen commodities, a colony with a long history
-- -- painted straight over its neighbours and the footer.
function ui.clip(x, y, w, h, fn)
    local sx, sy, sw, sh = love.graphics.getScissor()
    -- intersect with any scissor already in force, so nesting works
    local nx, ny = math.floor(x), math.floor(y)
    local nw, nh = math.ceil(w), math.ceil(h)
    if sx then
        local x2 = math.min(nx + nw, sx + sw)
        local y2 = math.min(ny + nh, sy + sh)
        nx, ny = math.max(nx, sx), math.max(ny, sy)
        nw, nh = x2 - nx, y2 - ny
    end
    if nw > 0 and nh > 0 then
        love.graphics.setScissor(nx, ny, nw, nh)
        fn()
    end
    if sx then love.graphics.setScissor(sx, sy, sw, sh)
    else love.graphics.setScissor() end
end

--- Word wrapped paragraph, returns the height consumed.
function ui.paragraph(str, x, y, w, color, font)
    local f = ui.font(font or "small")
    love.graphics.setFont(f)
    ui.setColor(color or palette.colors.uiText)
    love.graphics.printf(str, math.floor(x), math.floor(y), w)
    love.graphics.setColor(1, 1, 1, 1)
    local _, lines = f:getWrap(str, w)
    return #lines * f:getHeight()
end

-- ---------------------------------------------------------------------------
-- Gauges
-- ---------------------------------------------------------------------------

function ui.bar(x, y, w, h, frac, color, bg)
    frac = util.clamp(frac or 0, 0, 1)
    love.graphics.setColor(bg and bg[1] or 0.08, bg and bg[2] or 0.12, bg and bg[3] or 0.12, 0.7)
    love.graphics.rectangle("fill", x, y, w, h)
    ui.setColor(color or palette.colors.uiPrimary, 0.95)
    love.graphics.rectangle("fill", x, y, w * frac, h)
    ui.setColor(color or palette.colors.uiPrimary, 0.45)
    love.graphics.setLineWidth(1)
    love.graphics.rectangle("line", x + 0.5, y + 0.5, w - 1, h - 1)
    love.graphics.setColor(1, 1, 1, 1)
end

--- Segmented bar -- reads more "instrument panel" than a solid fill.
function ui.segmentBar(x, y, w, h, frac, segments, color)
    segments = segments or 12
    frac = util.clamp(frac or 0, 0, 1)
    local gap = 2
    local sw = (w - gap * (segments - 1)) / segments
    local lit = frac * segments
    for i = 0, segments - 1 do
        local f = util.clamp(lit - i, 0, 1)
        ui.setColor(color or palette.colors.uiPrimary, 0.16 + f * 0.84)
        love.graphics.rectangle("fill", x + i * (sw + gap), y, sw, h)
    end
    love.graphics.setColor(1, 1, 1, 1)
end

--- Vertical gauge with a needle, used for pitch/altitude readouts.
function ui.gauge(x, y, w, h, frac, color, label)
    ui.setColor(color or palette.colors.uiDim, 0.5)
    love.graphics.setLineWidth(1)
    love.graphics.rectangle("line", x + 0.5, y + 0.5, w, h)
    local ny = y + h * (1 - util.clamp(frac, 0, 1))
    ui.setColor(color or palette.colors.uiPrimary, 1)
    love.graphics.polygon("fill", x, ny, x + w * 0.5, ny - 4, x + w * 0.5, ny + 4)
    love.graphics.rectangle("fill", x, ny - 0.5, w, 1)
    if label then ui.textCenter(label, x + w * 0.5, y + h + 2, color, "small") end
    love.graphics.setColor(1, 1, 1, 1)
end

-- ---------------------------------------------------------------------------
-- Menu
-- ---------------------------------------------------------------------------

local Menu = {}
Menu.__index = Menu

--- How many rows fit in `height` at `lineHeight`, at least one.
function ui.rowsFor(height, lineHeight)
    return math.max(1, math.floor((height or 0) / math.max(lineHeight or 22, 1)))
end

--- The horizontal room a menu really occupies beyond the `w` it is drawn with:
--- the cursor arrow hangs 14px to the left, the scrollbar 13px to the right.
ui.MENU_BLEED_LEFT = 14
ui.MENU_BLEED_RIGHT = 13

--- items: array of { label, value, hint, disabled, action }
--
-- `opts.height` with `opts.lineHeight` derives how many rows are visible, which
-- is what callers actually know. Passing `visible` directly still works, but
-- every caller that did so had to keep two magic numbers in sync by hand with
-- a container height neither of them could see -- and several were wrong,
-- overrunning their own footers at the minimum window size.
function ui.menu(items, opts)
    opts = opts or {}
    local visible = opts.visible
    if not visible and opts.height then
        visible = ui.rowsFor(opts.height, opts.lineHeight or 22)
    end
    local m = setmetatable({
        items = items or {},
        cursor = opts.cursor or 1,
        scroll = 0,
        visible = visible or 12,
        wrap = opts.wrap ~= false,
        accent = opts.accent or palette.colors.uiPrimary,
        onSelect = opts.onSelect,
        onChange = opts.onChange,
    }, Menu)
    -- a cursor restored from a rebuild can sit below the window; without this
    -- the list draws with no highlight at all until the player presses a key
    m:clampScroll()
    return m
end

--- Brings the window back around the cursor and inside the list.
function Menu:clampScroll()
    local n = #self.items
    self.cursor = util.clamp(self.cursor, 1, math.max(1, n))
    if self.cursor - self.scroll > self.visible then
        self.scroll = self.cursor - self.visible
    elseif self.cursor - self.scroll < 1 then
        self.scroll = self.cursor - 1
    end
    self.scroll = util.clamp(self.scroll, 0, math.max(0, n - self.visible))
end

--- Changes how many rows are shown, keeping the cursor visible.
function Menu:setVisible(n)
    self.visible = math.max(1, math.floor(n or self.visible))
    self:clampScroll()
end

function Menu:setItems(items, keepCursor)
    self.items = items or {}
    if not keepCursor then self.cursor = 1; self.scroll = 0 end
    self:clampScroll()
end

function Menu:current() return self.items[self.cursor] end

function Menu:move(delta)
    local n = #self.items
    if n == 0 then return end
    local c = self.cursor
    for _ = 1, n do
        c = c + delta
        if c > n then
            if not self.wrap then c = n break end
            c = 1
        elseif c < 1 then
            if not self.wrap then c = 1 break end
            c = n
        end
        if not self.items[c].disabled then break end
    end
    if self.cursor ~= c then
        self.cursor = c
        if self.onChange then self.onChange(self:current(), c) end
    end
    self:clampScroll()
end

function Menu:select()
    local it = self:current()
    if not it or it.disabled then return nil end
    if it.action then it.action(it) end
    if self.onSelect then self.onSelect(it, self.cursor) end
    return it
end

--- Standard key handling: arrows/WASD to move, enter/space to pick.
function Menu:keypressed(key)
    if key == "up" or key == "w" then self:move(-1) return true end
    if key == "down" or key == "s" then self:move(1) return true end
    if key == "pageup" then self:move(-self.visible) return true end
    if key == "pagedown" then self:move(self.visible) return true end
    if key == "home" then self.cursor = 1; self:clampScroll() return true end
    if key == "end" then self.cursor = #self.items; self:clampScroll() return true end
    if key == "return" or key == "kpenter" or key == "space" then self:select() return true end
    return false
end

function Menu:draw(x, y, w, lineHeight, font)
    lineHeight = lineHeight or 22
    local first = self.scroll + 1
    local last = math.min(#self.items, self.scroll + self.visible)
    local yy = y
    for i = first, last do
        local it = self.items[i]
        local selected = (i == self.cursor)
        local color = it.color or palette.colors.uiText
        if it.disabled then color = palette.colors.uiDim end
        if selected then
            ui.setColor(self.accent, 0.18)
            love.graphics.rectangle("fill", x - 6, yy - 2, w + 12, lineHeight)
            ui.setColor(self.accent, 1)
            love.graphics.polygon("fill", x - 14, yy + 3, x - 14, yy + lineHeight - 5, x - 8, yy + lineHeight * 0.5 - 1)
            color = it.disabled and palette.colors.uiDim or self.accent
        end
        -- label and value share the row, so measure the value first and give
        -- the label whatever is left; a long procedural name used to run
        -- straight through the price beside it
        if it.value then
            local text = tostring(it.value)
            local vw = math.min(ui.font(font or "normal"):getWidth(text), w * 0.6)
            ui.textRightFit(text, x + w, yy, vw, it.valueColor or color, font)
            ui.textFit(it.label, x, yy, w - vw - 12, color, font)
        else
            ui.textFit(it.label, x, yy, w, color, font)
        end
        yy = yy + lineHeight
    end
    if #self.items > self.visible then
        -- scrollbar
        local trackH = (last - first + 1) * lineHeight
        local frac = self.visible / #self.items
        local pos = self.scroll / #self.items
        ui.setColor(self.accent, 0.2)
        love.graphics.rectangle("fill", x + w + 10, y, 3, trackH)
        ui.setColor(self.accent, 0.8)
        love.graphics.rectangle("fill", x + w + 10, y + trackH * pos, 3, trackH * frac)
        love.graphics.setColor(1, 1, 1, 1)
    end
    return yy
end

--- Blinking helper for alert text.
function ui.blink(period)
    return (math.floor((love.timer.getTime() / (period or 0.5))) % 2) == 0
end

return ui
