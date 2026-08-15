-- Settings screen: options on the left, key bindings on the right.
--
-- Every option comes from `settings.schema`, so this screen never needs
-- editing to expose a new one, and rebinding writes through `input`, which
-- rebuilds the baton player immediately -- the new key works on the next
-- frame, without a restart.

local class = require("src.lib.class")
local util = require("src.lib.util")
local palette = require("src.render.palette")
local ui = require("src.ui.widgets")
local settings = require("src.settings")
local input = require("src.input")
local lighting = require("src.render.lighting")
local i18n = require("src.i18n")
local audio = require("src.audio")

local Settings = class("SettingsState")

local C = palette.colors
local L = i18n.format

-- Pane geometry, shared by the builders and the draw code. The options list
-- is 28 rows and the bindings list 43, so both genuinely scroll; sizing them
-- from the window is what stops them running into the help pane below.
local PANE_TOP = 140
local PANE_LINE = 21
local HELP_SPACE = 116          -- rule, help paragraph and the status row

local function paneRows()
    local h = love.graphics and love.graphics.getHeight() or 720
    return ui.rowsFor(h - PANE_TOP - HELP_SPACE, PANE_LINE)
end

function Settings:init() self.drawUnderlying = true end

function Settings:enter(caller)
    self.caller = caller
    self.pane = 1                 -- 1 = options, 2 = bindings
    self.rebinding = nil
    self.status = nil
    self:buildOptions()
    self:buildBindings()
end

function Settings:buildOptions()
    local items = {}
    for _, group in ipairs(settings.schema) do
        items[#items + 1] = { label = L(group.section:upper()), disabled = true, color = C.uiDim }
        for _, item in ipairs(group.items) do
            items[#items + 1] = {
                label = "  " .. L(item.name),
                value = L(settings.display(item.id)),
                settingId = item.id,
                help = L(item.help or ""),
            }
        end
    end
    items[#items + 1] = { label = "", disabled = true }
    items[#items + 1] = {
        label = "  " .. L("Reset all to defaults"), color = C.uiWarn,
        action = function()
            settings.reset()
            input.resetBindings()
            self:apply()
            self:buildOptions()
            self:buildBindings()
            self.status = L("Defaults restored.")
        end,
    }
    local cursor = self.optionMenu and self.optionMenu.cursor or 2
    self.optionMenu = ui.menu(items, { visible = paneRows(), cursor = cursor })
end

function Settings:buildBindings()
    local items = {}
    for _, group in ipairs(input.actionOrder) do
        items[#items + 1] = { label = L(group[1]:upper()), disabled = true, color = C.uiDim }
        for _, action in ipairs(group[2]) do
            items[#items + 1] = {
                label = "  " .. L(input.labels[action] or action),
                value = input.bindingList(action),
                action_id = action,
            }
        end
    end
    local cursor = self.bindMenu and self.bindMenu.cursor or 2
    self.bindMenu = ui.menu(items, { visible = paneRows(), cursor = cursor })
end

function Settings:menu()
    return self.pane == 1 and self.optionMenu or self.bindMenu
end

--- Pushes the current settings into the live systems.
function Settings:apply()
    local game = self.game
    if not game then return end
    local r = game.renderer
    r.settings.post = settings.get("post")
    r.settings.shadows = settings.get("shadows") ~= false and settings.q().shadows ~= false
    audio.setVolume(settings.get("volumeMaster"), settings.get("volumeEffects"),
        settings.get("volumeAmbience"))
    r.settings.scanline = settings.get("scanline")
    r.settings.vignette = settings.get("vignette")
    r.settings.aberration = settings.get("aberration")
    r.env.bands = settings.get("lightBands")
    r.lightingPreset = settings.get("lightingPreset")
    game.camera.fov = math.rad(settings.get("fov"))
    settings.save()
end

function Settings:keypressed(key)
    -- capture mode: the next key becomes the binding
    if self.rebinding then
        if key ~= "escape" then
            input.rebind(self.rebinding, key)
            self.status = L("{action} bound to {key}", {
                action = L(input.labels[self.rebinding] or self.rebinding), key = key:upper() })
            self:buildBindings()
            settings.save()
        end
        self.rebinding = nil
        return
    end

    if key == "escape" then
        self:apply()
        self.manager:pop()
        return
    end
    if key == "tab" then
        self.pane = (self.pane == 1) and 2 or 1
        return
    end

    local menu = self:menu()
    local item = menu:current()

    if self.pane == 1 and item and item.settingId then
        if key == "left" then
            settings.step(item.settingId, -1)
            self:apply(); self:buildOptions(); return
        elseif key == "right" or key == "return" or key == "space" then
            settings.step(item.settingId, 1)
            self:apply(); self:buildOptions(); return
        end
    elseif self.pane == 2 and item and item.action_id then
        if key == "return" or key == "space" then
            self.rebinding = item.action_id
            self.status = L("Press a key, or ESC to cancel.")
            return
        elseif key == "delete" or key == "backspace" then
            input.resetBindings()
            self:buildBindings()
            self.status = L("Bindings reset.")
            return
        end
    end

    menu:keypressed(key)
end

function Settings:wheelmoved(x, y)
    self:menu():move(-y)
end

function Settings:update(dt) end

function Settings:draw()
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    love.graphics.setColor(0, 0, 0, 0.82)
    love.graphics.rectangle("fill", 0, 0, w, h)
    love.graphics.setColor(1, 1, 1, 1)

    ui.text(L("SETTINGS"), 48, 34, C.uiPrimary, "large")
    ui.text(L("TAB switches pane   LEFT/RIGHT change   ENTER rebind   ESC close"),
        48, 68, C.uiDim, "small")

    local paneW = (w - 140) * 0.5
    local left, right = 60, 80 + paneW

    -- pane headers
    ui.text(L("OPTIONS"), left, 100, self.pane == 1 and C.uiPrimary or C.uiDim, "normal")
    ui.text(L("KEY BINDINGS"), right, 100, self.pane == 2 and C.uiPrimary or C.uiDim, "normal")
    ui.rule(left, 124, paneW - 20, self.pane == 1 and C.uiPrimary or C.uiLine, self.pane == 1 and 0.8 or 0.3)
    ui.rule(right, 124, paneW - 20, self.pane == 2 and C.uiPrimary or C.uiLine, self.pane == 2 and 0.8 or 0.3)

    self.optionMenu.accent = self.pane == 1 and C.uiPrimary or C.uiDim
    self.bindMenu.accent = self.pane == 2 and C.uiPrimary or C.uiDim
    local rows = paneRows()
    self.optionMenu:setVisible(rows)
    self.bindMenu:setVisible(rows)
    -- the cursor arrow hangs 14px left and the scrollbar 13px right of the
    -- width passed here, so the pane's usable width allows for both
    local menuW = paneW - 40 - ui.MENU_BLEED_RIGHT
    self.optionMenu:draw(left + ui.MENU_BLEED_LEFT, PANE_TOP, menuW, PANE_LINE, "small")
    self.bindMenu:draw(right + ui.MENU_BLEED_LEFT, PANE_TOP, menuW, PANE_LINE, "small")

    -- help text for the highlighted option
    local item = self:menu():current()
    local hy = h - 96
    ui.rule(48, hy - 10, w - 96, C.uiLine, 0.3)
    if item and item.help and item.help ~= "" then
        ui.paragraph(item.help, 48, hy, w - 96, C.uiText, "small")
    elseif item and item.settingId == "lightingPreset" then
        ui.paragraph(L(lighting.get(settings.get("lightingPreset")).blurb),
            48, hy, w - 96, C.uiText, "small")
    elseif self.pane == 2 then
        ui.paragraph(L("ENTER rebinds the highlighted action. DELETE restores every default binding."),
            48, hy, w - 96, C.uiText, "small")
    end

    if self.rebinding then
        local bw, bh = 380, 90
        local bx, by = (w - bw) * 0.5, (h - bh) * 0.5
        ui.panel(bx, by, bw, bh, L("REBIND"))
        ui.textCenter(L(input.labels[self.rebinding] or self.rebinding),
            bx + bw * 0.5, by + 26, C.uiPrimary, "normal")
        ui.textCenter(L("Press a key  (ESC cancels)"), bx + bw * 0.5, by + 54, C.uiText, "small")
    end

    if self.status then
        ui.textRight(self.status, w - 48, h - 40, C.uiPrimary, "small")
    end
    if input.joystick then
        ui.text(L("Gamepad: {name}", { name = input.joystick:getName() }), 48, h - 40, C.uiDim, "small")
    end
end

return Settings
