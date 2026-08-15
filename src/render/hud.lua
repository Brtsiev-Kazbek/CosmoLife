-- The flight HUD: a vector instrument panel drawn over the 3D view.
--
-- Layout follows the genre's grammar -- gauges bottom left and right, a
-- 3D scanner in the middle, target information top left, contacts bracketed
-- in the world -- because that grammar is genuinely good at answering the four
-- questions a pilot has: where am I, what is near me, what is it, and is it
-- shooting at me.

local util = require("src.lib.util")
local config = require("src.config")
local palette = require("src.render.palette")
local ui = require("src.ui.widgets")
local factions = require("src.sim.factions")
local i18n = require("src.i18n")
local audio = require("src.audio")
local L = i18n.format

local hud = {}

local C = palette.colors
local cos, sin, pi, floor, min, max = math.cos, math.sin, math.pi, math.floor, math.min, math.max

hud.messages = {}

function hud.message(text, kind)
    table.insert(hud.messages, 1, { text = text, kind = kind or "info", life = 6.5 })
    for i = #hud.messages, 7, -1 do hud.messages[i] = nil end
    -- Only the two that mean something bad get a sound. A bleep on every line
    -- of chatter trains the player to ignore it, which is the opposite of what
    -- an alert is for.
    if kind == "warn" then
        audio.play("warn")
    elseif kind == "alert" then
        audio.play("alert")
    end
end

function hud.update(dt)
    for i = #hud.messages, 1, -1 do
        hud.messages[i].life = hud.messages[i].life - dt
        if hud.messages[i].life <= 0 then table.remove(hud.messages, i) end
    end
end

function hud.clear() hud.messages = {} end

-- ---------------------------------------------------------------------------
-- Scanner: the classic elliptical 3D radar
-- ---------------------------------------------------------------------------

local function drawScanner(cx, cy, rx, ry, ship, contacts, range)
    ui.setColor(C.uiDim, 0.55)
    love.graphics.setLineWidth(1)
    love.graphics.ellipse("line", cx, cy, rx, ry, 40)
    love.graphics.ellipse("line", cx, cy, rx * 0.66, ry * 0.66, 32)
    love.graphics.ellipse("line", cx, cy, rx * 0.33, ry * 0.33, 24)
    love.graphics.line(cx - rx, cy, cx + rx, cy)
    love.graphics.line(cx, cy - ry, cx, cy + ry)

    for _, c in ipairs(contacts) do
        -- into ship-local coordinates
        local dx = c.pos.x - ship.pos.x
        local dy = c.pos.y - ship.pos.y
        local dz = c.pos.z - ship.pos.z
        local d = math.sqrt(dx * dx + dy * dy + dz * dz)
        if d < range then
            local fx = dx * ship.fwd.x + dy * ship.fwd.y + dz * ship.fwd.z
            local rxl = dx * ship.right.x + dy * ship.right.y + dz * ship.right.z
            local uy = dx * ship.up.x + dy * ship.up.y + dz * ship.up.z
            local sx = cx + (rxl / range) * rx
            local sy = cy - (fx / range) * ry
            local stem = -(uy / range) * ry * 0.9

            local col = c.color or C.uiPrimary
            ui.setColor(col, 0.45)
            love.graphics.line(sx, sy, sx, sy + stem)
            ui.setColor(col, 1)
            local size = c.hostile and 4 or 3
            if c.hostile then
                love.graphics.polygon("fill", sx, sy + stem - size, sx + size, sy + stem + size, sx - size, sy + stem + size)
            else
                love.graphics.rectangle("fill", sx - size * 0.5, sy + stem - size * 0.5, size, size)
            end
            if c.selected then
                ui.setColor(C.uiWarn, 1)
                love.graphics.circle("line", sx, sy + stem, size + 4)
            end
        end
    end
    love.graphics.setColor(1, 1, 1, 1)
end

-- ---------------------------------------------------------------------------
-- Message strip
-- ---------------------------------------------------------------------------

--- Draws the message log centred on `cx`, filling the band from `top` to
--- `bottom` and stopping rather than spilling past it.
--
-- Two problems this solves. Messages were printed as single lines, and several
-- of them name a place and two keys -- at 960px those ran off both edges of
-- the screen, so they are word wrapped now. And the strip was anchored at a
-- fixed fraction of the height, which at 540px put the last four messages
-- inside the scanner ellipse; it is now bounded by what sits below it, and
-- drops the oldest messages when there is not enough room.
local function drawMessages(cx, top, bottom, screenW)
    local f = ui.font("small")
    local maxW = math.min(screenW - 120, 520)
    local lineH = f:getHeight() + 2

    -- newest first, so when the band is short the recent messages survive
    local heights, total = {}, 0
    for i, m in ipairs(hud.messages) do
        local _, lines = f:getWrap(m.text, maxW)
        heights[i] = math.max(#lines, 1) * lineH
    end
    local last = 0
    for i = 1, #hud.messages do
        if total + heights[i] > (bottom - top) then break end
        total = total + heights[i]
        last = i
    end
    if last == 0 then return end

    love.graphics.setFont(f)
    local y = top
    for i = 1, last do
        local m = hud.messages[i]
        local alpha = util.clamp(m.life / 1.5, 0, 1)
        local col = C.uiText
        if m.kind == "good" then col = C.uiPrimary
        elseif m.kind == "alert" then col = C.uiDanger
        elseif m.kind == "warn" then col = C.uiWarn end
        love.graphics.setColor(col[1], col[2], col[3], alpha)
        love.graphics.printf(m.text, floor(cx - maxW * 0.5), floor(y), maxW, "center")
        y = y + heights[i]
    end
    love.graphics.setColor(1, 1, 1, 1)
end

-- ---------------------------------------------------------------------------
-- World-space markers
-- ---------------------------------------------------------------------------

local function drawContactMarker(camera, w, h, c, selected)
    local x, y, dist = camera:project(c.pos.x, c.pos.y, c.pos.z, w, h)
    local col = c.color or C.uiPrimary
    if x and x > -60 and x < w + 60 and y > -60 and y < h + 60 then
        local s = util.clamp(2400 / math.max(dist, 1), 6, 34)
        ui.setColor(col, selected and 1 or 0.65)
        love.graphics.setLineWidth(selected and 2 or 1)
        love.graphics.rectangle("line", x - s, y - s, s * 2, s * 2)
        if selected then
            ui.setColor(col, 0.9)
            local t = s * 1.6
            love.graphics.line(x - t, y, x - s * 1.1, y)
            love.graphics.line(x + s * 1.1, y, x + t, y)
            love.graphics.line(x, y - t, x, y - s * 1.1)
            love.graphics.line(x, y + s * 1.1, x, y + t)
        end
        -- Navigation contacts are labelled at any distance. They used to be
        -- named only within 6 km, so from an arrival point tens of thousands
        -- of kilometres out the player saw a scattering of identical unlabelled
        -- boxes with no way to tell a station from a moon.
        local navigable = c.station or c.place or c.body or c.poi
        if c.label and (selected or navigable or dist < 6000) then
            -- The HUD owns the corners: the target panel top left, the system
            -- banner top right, the gauges along the bottom. A world label
            -- landing in one of those bands is unreadable and makes the panel
            -- underneath unreadable too, so it is simply dropped.
            local lx, ly = x + s + 6, y - 8
            -- measured, not guessed: the label's own width decides whether it
            -- reaches the banner, and a short one starting left of it still
            -- does if the name is long
            local lw = ui.font("small"):getWidth(c.label)
            local topBand = ly < 112
            local free = not (topBand and (lx < 300 or lx + lw > w - 310))
                and ly < h - 170
            if free then
                ui.text(c.label, lx, ly, col, "small")
                if selected or navigable then
                    ui.text(util.distance(dist), lx, y + 6, col, "small")
                end
            end
        end
    elseif selected then
        -- off screen: point at it from the edge of the view
        local dx = c.pos.x - camera.pos.x
        local dy = c.pos.y - camera.pos.y
        local dz = c.pos.z - camera.pos.z
        local rxl = dx * camera.right.x + dy * camera.right.y + dz * camera.right.z
        local uy = dx * camera.up.x + dy * camera.up.y + dz * camera.up.z
        local ang = math.atan2 and math.atan2(-uy, rxl) or 0
        local cx, cy = w * 0.5, h * 0.5
        local r = min(w, h) * 0.36
        local px, py = cx + cos(ang) * r, cy + sin(ang) * r
        ui.setColor(C.uiWarn, 0.9)
        love.graphics.push()
        love.graphics.translate(px, py)
        love.graphics.rotate(ang)
        love.graphics.polygon("fill", 12, 0, -6, 7, -6, -7)
        love.graphics.pop()
    end
    love.graphics.setColor(1, 1, 1, 1)
end

-- ---------------------------------------------------------------------------
-- Artificial horizon
-- ---------------------------------------------------------------------------

--- Attitude indicator: the ladder every pilot reads without being taught.
-- `roll` and `pitch` are the ship's attitude relative to the local horizontal;
-- `alt` and `vs` drive the tapes either side.
local function drawHorizon(cx, cy, r, roll, pitch, alt, vs, landable)
    local accent = landable and C.uiPrimary or C.uiWarn

    love.graphics.push()
    love.graphics.translate(cx, cy)

    -- fixed aircraft reference
    ui.setColor(C.uiWarn, 1)
    love.graphics.setLineWidth(2)
    love.graphics.line(-r * 0.55, 0, -r * 0.2, 0)
    love.graphics.line(r * 0.2, 0, r * 0.55, 0)
    love.graphics.line(0, -4, 0, 4)
    love.graphics.setLineWidth(1)

    -- rotating ladder
    love.graphics.push()
    love.graphics.rotate(-roll)
    local pitchPx = r * 0.9
    local offset = (pitch / (math.pi * 0.5)) * pitchPx
    ui.setColor(accent, 0.85)
    love.graphics.line(-r, offset, -r * 0.25, offset)
    love.graphics.line(r * 0.25, offset, r, offset)
    for _, step in ipairs({ -30, -20, -10, 10, 20, 30 }) do
        local y = offset - (math.rad(step) / (math.pi * 0.5)) * pitchPx
        if math.abs(y) < r * 1.1 then
            local w = (step % 20 == 0) and r * 0.34 or r * 0.18
            ui.setColor(accent, 0.4)
            love.graphics.line(-w, y, w, y)
        end
    end
    love.graphics.pop()

    -- roll scale
    ui.setColor(accent, 0.5)
    love.graphics.circle("line", 0, 0, r)
    for _, a in ipairs({ -60, -30, 0, 30, 60 }) do
        local rad = math.rad(a) - math.pi * 0.5
        local x1, y1 = math.cos(rad) * r, math.sin(rad) * r
        local x2, y2 = math.cos(rad) * (r * 0.9), math.sin(rad) * (r * 0.9)
        love.graphics.line(x1, y1, x2, y2)
    end
    -- roll pointer
    local rad = -roll - math.pi * 0.5
    ui.setColor(C.uiWarn, 1)
    love.graphics.polygon("fill",
        math.cos(rad) * r, math.sin(rad) * r,
        math.cos(rad + 0.07) * (r * 0.88), math.sin(rad + 0.07) * (r * 0.88),
        math.cos(rad - 0.07) * (r * 0.88), math.sin(rad - 0.07) * (r * 0.88))

    love.graphics.pop()

    -- tapes
    ui.textRight(util.distance(alt or 0), cx - r - 14, cy - 9,
        (alt or 0) < 300 and C.uiWarn or C.uiText, "small")
    ui.text(string.format("%+.0f m/s", vs or 0), cx + r + 14, cy - 9,
        (vs or 0) < -30 and C.uiDanger or C.uiText, "small")
    ui.textRight(L("ALT"), cx - r - 14, cy + 6, C.uiDim, "small")
    ui.text(L("V/S"), cx + r + 14, cy + 6, C.uiDim, "small")
    love.graphics.setColor(1, 1, 1, 1)
end

-- ---------------------------------------------------------------------------
-- Main draw
-- ---------------------------------------------------------------------------

--- `ctx` carries everything the HUD reads:
--   ship, player, world, camera, contacts, target, speed, throttle,
--   altitude, gearDown, warp, heat, mode
function hud.draw(ctx, w, h)
    local ship = ctx.ship
    local player = ctx.player
    local stats = player.stats
    local accent = C.uiPrimary

    -- ---- reticle --------------------------------------------------------
    local cx, cy = w * 0.5, h * 0.5
    ui.setColor(accent, 0.85)
    love.graphics.setLineWidth(1)
    love.graphics.circle("line", cx, cy, 12)
    love.graphics.line(cx - 26, cy, cx - 15, cy)
    love.graphics.line(cx + 15, cy, cx + 26, cy)
    love.graphics.line(cx, cy - 26, cx, cy - 15)
    love.graphics.line(cx, cy + 15, cx, cy + 26)
    love.graphics.points(cx, cy)

    -- velocity vector: where the ship is actually going
    if ctx.speed and ctx.speed > 2 then
        local vx = ship.vel.x / ctx.speed
        local vy = ship.vel.y / ctx.speed
        local vz = ship.vel.z / ctx.speed
        local px, py = ctx.camera:project(
            ship.pos.x + vx * 1000, ship.pos.y + vy * 1000, ship.pos.z + vz * 1000, w, h)
        if px then
            ui.setColor(C.uiWarn, 0.75)
            love.graphics.circle("line", px, py, 7)
            love.graphics.line(px - 11, py, px - 7, py)
            love.graphics.line(px + 7, py, px + 11, py)
        end
    end

    -- ---- contacts in the world -----------------------------------------
    for _, c in ipairs(ctx.contacts) do
        if c.marker then
            drawContactMarker(ctx.camera, w, h, c, c == ctx.target)
        end
    end

    -- ---- left gauges ----------------------------------------------------
    local gx, gy = 26, h - 150
    ui.brackets(gx - 8, gy - 12, 210, 140, 12, accent, 0.5)

    ui.text(L("SHIELD"), gx, gy, C.uiDim, "small")
    ui.segmentBar(gx, gy + 16, 190, 9, (ship.shield or 0) / max(stats.maxShield, 1), 14, C.cyan)
    ui.text(L("HULL"), gx, gy + 32, C.uiDim, "small")
    local hullFrac = (ship.hull or 0) / max(stats.maxHull, 1)
    ui.segmentBar(gx, gy + 48, 190, 9, hullFrac, 14, hullFrac < 0.3 and C.uiDanger or C.uiPrimary)
    ui.text(L("FUEL"), gx, gy + 64, C.uiDim, "small")
    ui.segmentBar(gx, gy + 80, 190, 7, (player.fuel or 0) / max(stats.fuel, 1), 12, C.amber)
    ui.text(L("HEAT"), gx, gy + 94, C.uiDim, "small")
    local heat = util.clamp((ctx.heat or 0) / max(stats.heatCapacity or 100, 1), 0, 1)
    ui.segmentBar(gx, gy + 110, 190, 7, heat, 12, heat > 0.8 and C.uiDanger or C.orange)

    -- ---- right gauges ---------------------------------------------------
    local rx = w - 236
    ui.brackets(rx - 8, gy - 12, 210, 140, 12, accent, 0.5)
    ui.text(L("THROTTLE"), rx, gy, C.uiDim, "small")
    ui.bar(rx, gy + 16, 190, 9, ctx.throttle or 0, C.uiPrimary)
    ui.textRight(string.format("%d%%", floor((ctx.throttle or 0) * 100)), rx + 190, gy - 2, C.uiText, "small")

    -- inside a station's approach the closing speed is what the docking gate
    -- actually measures, so that is what is shown
    if ctx.relativeSpeed then
        ui.text(L("CLOSING"), rx, gy + 32, C.uiDim, "small")
        ui.textRight(util.speed(ctx.relativeSpeed), rx + 190, gy + 32,
            ctx.relativeSpeed > 120 and C.uiWarn or C.uiPrimary, "small")
    else
        ui.text(L("SPEED"), rx, gy + 32, C.uiDim, "small")
        ui.textRight(util.speed(ctx.speed or 0), rx + 190, gy + 32, C.uiText, "small")
    end

    if ctx.warpState and ctx.warpState ~= "off" then
        ui.text(L("FRAME SHIFT"), rx, gy + 52, C.uiDim, "small")
        local label = ctx.warpState == "spool" and L("SPOOLING") or L("CRUISE")
        ui.textRight(label, rx + 190, gy + 52, C.cyan, "small")
        ui.bar(rx, gy + 70, 190, 6, ctx.warpFraction or 0, C.cyan)
    elseif ctx.altitude then
        ui.text(L("ALTITUDE"), rx, gy + 52, C.uiDim, "small")
        ui.textRight(util.distance(ctx.altitude), rx + 190, gy + 52, ctx.altitude < 800 and C.uiWarn or C.uiText, "small")
        if ctx.verticalSpeed then
            ui.text(L("V/S"), rx, gy + 70, C.uiDim, "small")
            ui.textRight(string.format("%+.0f m/s", ctx.verticalSpeed), rx + 190, gy + 70,
                ctx.verticalSpeed < -40 and C.uiDanger or C.uiText, "small")
        end
    end

    ui.text(L("CARGO"), rx, gy + 92, C.uiDim, "small")
    ui.textRight(string.format("%d / %d t", player:cargoUsed(), player:cargoCapacity()), rx + 190, gy + 92, C.uiText, "small")
    ui.text(L("CREDITS"), rx, gy + 110, C.uiDim, "small")
    ui.textRight(util.money(player.credits), rx + 190, gy + 110, C.amber, "small")

    -- ---- artificial horizon, whenever there is a ground to be level with --
    if ctx.horizon then
        drawHorizon(cx, cy - h * 0.22, math.min(w, h) * 0.11,
            ctx.horizon.roll, ctx.horizon.pitch, ctx.altitude, ctx.verticalSpeed,
            ctx.horizon.landable)
        if ctx.hoverMode then
            ui.textCenter(L("LANDING MODE"), cx, cy - h * 0.22 + math.min(w, h) * 0.13,
                C.uiPrimary, "small")
        end
    end

    -- ---- scanner --------------------------------------------------------
    drawScanner(cx, h - 78, 132, 58, ship, ctx.contacts, config.combat.scanRange)
    ui.text(L("SCANNER"), cx - 132, h - 146, C.uiDim, "small")

    -- ---- landing gear / status flags ------------------------------------
    --
    -- Measured rather than assumed: the old version centred on a per-item
    -- width of 46 while stepping by 92, so the row sat 23px per flag to the
    -- right of centre and ran into the right-hand gauge bracket.
    local flags = {}
    if ctx.gearDown then flags[#flags + 1] = { L("GEAR"), C.uiWarn } end
    if ctx.boosting then flags[#flags + 1] = { L("BOOST"), C.cyan } end
    if ctx.massLocked then flags[#flags + 1] = { L("MASS LOCK"), C.uiWarn } end
    if ctx.overheating then flags[#flags + 1] = { L("HEAT"), C.uiDanger } end
    if player:totalBounty() > 0 then flags[#flags + 1] = { L("WANTED"), C.uiDanger } end
    if ctx.autopilot then flags[#flags + 1] = { L("AUTOPILOT"), C.uiPrimary } end

    if #flags > 0 then
        local font = ui.font("small")
        local gap = 18
        local total = -gap
        for _, f in ipairs(flags) do total = total + font:getWidth(f[1]) + gap end
        local fx = cx - total * 0.5
        for _, f in ipairs(flags) do
            local fw = font:getWidth(f[1])
            if not (f[2] == C.uiDanger) or ui.blink(0.4) then
                ui.text(f[1], fx, h - 168, f[2], "small")
            end
            fx = fx + fw + gap
        end
    end

    -- ---- target panel ---------------------------------------------------

    if ctx.target then
        local t = ctx.target
        local px, py = 26, 26
        local pw = 250
        local textW = pw - 28
        ui.panel(px, py, pw, t.detail and 118 or 78, L("TARGET"), accent)
        ui.textFit(t.label or L("Unknown"), px + 14, py + 12, textW, C.uiText, "small")
        ui.text(util.distance(t.distance or 0), px + 14, py + 30, C.uiDim, "small")
        if t.hull then
            ui.text(L("HULL"), px + 14, py + 48, C.uiDim, "small")
            ui.bar(px + 60, py + 50, pw - 80, 7, t.hull, t.hostile and C.uiDanger or C.uiPrimary)
        end
        if t.shield then
            ui.text(L("SHLD"), px + 14, py + 62, C.uiDim, "small")
            ui.bar(px + 60, py + 64, pw - 80, 7, t.shield, C.cyan)
        end
        if t.detail then
            ui.textFit(t.detail, px + 14, py + 82, textW, C.uiDim, "small")
            if t.detail2 then ui.textFit(t.detail2, px + 14, py + 96, textW, C.uiDim, "small") end
        end
    end

    -- ---- system banner --------------------------------------------------
    local sys = ctx.world.stub
    if sys then
        local faction = factions.get(sys.factionId)
        local bw = 274
        local bx = w - 34 - bw
        local textW = bw - 20
        -- the conflict line used to print at y=88 inside a frame that ended at
        -- 84, so the frame grows when it is showing
        local conflict = sys.conflict and sys.conflict > 0.2
        ui.brackets(bx, 22, bw, conflict and 84 or 62, 10, accent, 0.4)
        ui.textRightFit(sys.name, w - 34, 28, textW, C.uiText, "normal")
        ui.textRightFit(L(faction.name), w - 34, 48, textW,
            { faction.color[1], faction.color[2], faction.color[3], 1 }, "small")
        ui.textRightFit(ctx.world:dateString() .. "   " .. L(sys.economyName),
            w - 34, 64, textW, C.uiDim, "small")
        if conflict and ui.blink(0.7) then
            ui.textRightFit(L("CONFLICT ZONE"), w - 34, 82, textW, C.uiDanger, "small")
        end
    end

    -- ---- messages -------------------------------------------------------
    --
    -- The strip is anchored above the scanner rather than at a fixed fraction
    -- of the height: at 540px the old position put the last four messages
    -- inside the scanner ellipse.
    -- the band runs from just under the reticle to just above the scanner
    -- caption at h-146
    local msgBottom = h - 152
    local msgTop = math.max(h * 0.30, math.min(h * 0.5 + 60, msgBottom - 140))
    drawMessages(cx, msgTop, msgBottom, w)

    -- ---- objective ------------------------------------------------------
    --
    -- Top centre, under the system banner: the game never told anyone what to
    -- do next, and a player who does not know what to do next stops playing.
    if ctx.objective then
        local f = ui.font("normal")
        local fs = ui.font("small")
        local tw = math.max(f:getWidth(ctx.objective),
            ctx.objectiveHint and fs:getWidth(ctx.objectiveHint) or 0) + 40
        tw = math.min(tw, w - 620)
        if tw > 120 then
            local oy = 26
            local oh = ctx.objectiveHint and 50 or 32
            ui.setColor(C.uiPanel, 0.9)
            love.graphics.rectangle("fill", cx - tw * 0.5, oy, tw, oh)
            -- a newly set objective pulses its border for a couple of seconds,
            -- which is enough to notice without another line in the message log
            local edge = 0.55
            if ctx.objectiveFlash then edge = ui.blink(0.25) and 1.0 or 0.4 end
            ui.setColor(accent, edge)
            love.graphics.setLineWidth(ctx.objectiveFlash and 2 or 1)
            love.graphics.rectangle("line", cx - tw * 0.5, oy, tw, oh)
            love.graphics.setLineWidth(1)
            ui.textCenter(ui.fit(ctx.objective, tw - 20, "normal"), cx, oy + 6, C.uiPrimary, "normal")
            if ctx.objectiveHint then
                ui.textCenter(ui.fit(ctx.objectiveHint, tw - 20, "small"), cx, oy + 28, C.uiDim, "small")
            end
        end
    end

    -- ---- prompts --------------------------------------------------------
    if ctx.prompt then
        ui.setColor(C.uiPanel, 1)
        local f = ui.font("normal")
        local tw = f:getWidth(ctx.prompt) + 34
        love.graphics.rectangle("fill", cx - tw * 0.5, h * 0.5 - 96, tw, 30)
        ui.setColor(accent, 0.8)
        love.graphics.rectangle("line", cx - tw * 0.5, h * 0.5 - 96, tw, 30)
        ui.textCenter(ctx.prompt, cx, h * 0.5 - 90, C.uiPrimary, "normal")
    end
end

--- Compact readout for on-foot mode.
function hud.drawWalking(ctx, w, h)
    local cx, cy = w * 0.5, h * 0.5
    ui.setColor(C.uiPrimary, 0.7)
    love.graphics.circle("line", cx, cy, 3)

    -- 230 wide from x=20; every string inside is fitted to it, and the
    -- credits line sits on its own row instead of overlapping the subtitle
    local bw = 236
    ui.brackets(20, h - 84, bw, 72, 10, C.uiPrimary, 0.45)
    ui.textFit(ctx.locationName or "", 32, h - 76, bw - 24, C.uiText, "small")
    ui.textFit(ctx.subtitle or "", 32, h - 58, bw - 24, C.uiDim, "small")
    ui.textRightFit(util.money(ctx.player.credits) .. " " .. L("cr"),
        20 + bw - 12, h - 38, bw - 24, C.amber, "small")

    if ctx.prompt then
        ui.setColor(C.uiPanel, 1)
        local f = ui.font("normal")
        local tw = f:getWidth(ctx.prompt) + 34
        love.graphics.rectangle("fill", cx - tw * 0.5, cy + 60, tw, 30)
        ui.setColor(C.uiPrimary, 0.8)
        love.graphics.rectangle("line", cx - tw * 0.5, cy + 60, tw, 30)
        ui.textCenter(ctx.prompt, cx, cy + 66, C.uiPrimary, "normal")
    end

    drawMessages(cx, h * 0.3, h - 110, w)
end

return hud
