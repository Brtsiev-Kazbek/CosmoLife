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

function ui.load()
    ui.fonts.small = newFont(13)
    ui.fonts.normal = newFont(16)
    ui.fonts.large = newFont(22)
    ui.fonts.huge = newFont(38)
    ui.fonts.title = newFont(64)
    for _, f in pairs(ui.fonts) do f:setFilter("nearest", "nearest") end
end

--- Rebuilds the fonts (called when the language changes).
function ui.reloadFonts() ui.load() end

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

--- items: array of { label, value, hint, disabled, action }
function ui.menu(items, opts)
    opts = opts or {}
    return setmetatable({
        items = items or {},
        cursor = opts.cursor or 1,
        scroll = 0,
        visible = opts.visible or 12,
        wrap = opts.wrap ~= false,
        accent = opts.accent or palette.colors.uiPrimary,
        onSelect = opts.onSelect,
        onChange = opts.onChange,
    }, Menu)
end

function Menu:setItems(items, keepCursor)
    self.items = items or {}
    if not keepCursor then self.cursor = 1; self.scroll = 0 end
    self.cursor = util.clamp(self.cursor, 1, math.max(1, #self.items))
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
    -- keep the cursor inside the visible window
    if self.cursor - self.scroll > self.visible then
        self.scroll = self.cursor - self.visible
    elseif self.cursor - self.scroll < 1 then
        self.scroll = self.cursor - 1
    end
    self.scroll = util.clamp(self.scroll, 0, math.max(0, #self.items - self.visible))
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
    if key == "home" then self.cursor = 1; self.scroll = 0 return true end
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
        ui.text(it.label, x, yy, color, font)
        if it.value then
            ui.textRight(tostring(it.value), x + w, yy, it.valueColor or color, font)
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
