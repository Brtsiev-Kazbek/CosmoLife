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

local hud = {}

local C = palette.colors
local cos, sin, pi, floor, min, max = math.cos, math.sin, math.pi, math.floor, math.min, math.max

hud.messages = {}

function hud.message(text, kind)
    table.insert(hud.messages, 1, { text = text, kind = kind or "info", life = 6.5 })
    for i = #hud.messages, 7, -1 do hud.messages[i] = nil end
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
        if c.label and (selected or dist < 6000) then
            ui.text(c.label, x + s + 6, y - 8, col, "small")
            if selected then
                ui.text(util.distance(dist), x + s + 6, y + 6, col, "small")
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

    ui.text("SHIELD", gx, gy, C.uiDim, "small")
    ui.segmentBar(gx, gy + 16, 190, 9, (ship.shield or 0) / max(stats.maxShield, 1), 14, C.cyan)
    ui.text("HULL", gx, gy + 32, C.uiDim, "small")
    local hullFrac = (ship.hull or 0) / max(stats.maxHull, 1)
    ui.segmentBar(gx, gy + 48, 190, 9, hullFrac, 14, hullFrac < 0.3 and C.uiDanger or C.uiPrimary)
    ui.text("FUEL", gx, gy + 64, C.uiDim, "small")
    ui.segmentBar(gx, gy + 80, 190, 7, (player.fuel or 0) / max(stats.fuel, 1), 12, C.amber)
    ui.text("HEAT", gx, gy + 94, C.uiDim, "small")
    local heat = util.clamp((ctx.heat or 0) / max(stats.heatCapacity or 100, 1), 0, 1)
    ui.segmentBar(gx, gy + 110, 190, 7, heat, 12, heat > 0.8 and C.uiDanger or C.orange)

    -- ---- right gauges ---------------------------------------------------
    local rx = w - 236
    ui.brackets(rx - 8, gy - 12, 210, 140, 12, accent, 0.5)
    ui.text("THROTTLE", rx, gy, C.uiDim, "small")
    ui.bar(rx, gy + 16, 190, 9, ctx.throttle or 0, C.uiPrimary)
    ui.textRight(string.format("%d%%", floor((ctx.throttle or 0) * 100)), rx + 190, gy - 2, C.uiText, "small")

    ui.text("SPEED", rx, gy + 32, C.uiDim, "small")
    ui.textRight(util.speed(ctx.speed or 0), rx + 190, gy + 32, C.uiText, "small")

    if ctx.warpState and ctx.warpState ~= "off" then
        ui.text("FRAME SHIFT", rx, gy + 52, C.uiDim, "small")
        local label = ctx.warpState == "spool" and "SPOOLING" or "CRUISE"
        ui.textRight(label, rx + 190, gy + 52, C.cyan, "small")
        ui.bar(rx, gy + 70, 190, 6, ctx.warpFraction or 0, C.cyan)
    elseif ctx.altitude then
        ui.text("ALTITUDE", rx, gy + 52, C.uiDim, "small")
        ui.textRight(util.distance(ctx.altitude), rx + 190, gy + 52, ctx.altitude < 800 and C.uiWarn or C.uiText, "small")
        if ctx.verticalSpeed then
            ui.text("V/S", rx, gy + 70, C.uiDim, "small")
            ui.textRight(string.format("%+.0f m/s", ctx.verticalSpeed), rx + 190, gy + 70,
                ctx.verticalSpeed < -40 and C.uiDanger or C.uiText, "small")
        end
    end

    ui.text("CARGO", rx, gy + 92, C.uiDim, "small")
    ui.textRight(string.format("%d / %d t", player:cargoUsed(), player:cargoCapacity()), rx + 190, gy + 92, C.uiText, "small")
    ui.text("CREDITS", rx, gy + 110, C.uiDim, "small")
    ui.textRight(util.money(player.credits), rx + 190, gy + 110, C.amber, "small")

    -- ---- scanner --------------------------------------------------------
    drawScanner(cx, h - 78, 132, 58, ship, ctx.contacts, config.combat.scanRange)
    ui.text("SCANNER", cx - 132, h - 146, C.uiDim, "small")

    -- ---- landing gear / status flags ------------------------------------
    local flags = {}
    if ctx.gearDown then flags[#flags + 1] = { "GEAR", C.uiWarn } end
    if ctx.boosting then flags[#flags + 1] = { "BOOST", C.cyan } end
    if ctx.massLocked then flags[#flags + 1] = { "MASS LOCK", C.uiWarn } end
    if ctx.overheating then flags[#flags + 1] = { "HEAT", C.uiDanger } end
    if player:totalBounty() > 0 then flags[#flags + 1] = { "WANTED", C.uiDanger } end
    for i, f in ipairs(flags) do
        local fx = cx - (#flags * 46) * 0.5 + (i - 1) * 92
        if not (f[2] == C.uiDanger) or ui.blink(0.4) then
            ui.textCenter(f[1], fx + 46, h - 168, f[2], "small")
        end
    end

    -- ---- target panel ---------------------------------------------------
    if ctx.target then
        local t = ctx.target
        local px, py = 26, 26
        ui.panel(px, py, 250, t.detail and 118 or 78, "TARGET", accent)
        ui.text(t.label or "Unknown", px + 14, py + 12, C.uiText, "small")
        ui.text(util.distance(t.distance or 0), px + 14, py + 30, C.uiDim, "small")
        if t.hull then
            ui.text("HULL", px + 14, py + 48, C.uiDim, "small")
            ui.bar(px + 60, py + 50, 170, 7, t.hull, t.hostile and C.uiDanger or C.uiPrimary)
        end
        if t.shield then
            ui.text("SHLD", px + 14, py + 62, C.uiDim, "small")
            ui.bar(px + 60, py + 64, 170, 7, t.shield, C.cyan)
        end
        if t.detail then
            ui.text(t.detail, px + 14, py + 82, C.uiDim, "small")
            if t.detail2 then ui.text(t.detail2, px + 14, py + 96, C.uiDim, "small") end
        end
    end

    -- ---- system banner --------------------------------------------------
    local sys = ctx.world.stub
    if sys then
        local faction = factions.get(sys.factionId)
        local bx = w - 300
        ui.brackets(bx, 22, 274, 62, 10, accent, 0.4)
        ui.textRight(sys.name, w - 34, 28, C.uiText, "normal")
        ui.textRight(faction.name, w - 34, 48, { faction.color[1], faction.color[2], faction.color[3], 1 }, "small")
        ui.textRight(ctx.world:dateString() .. "   " .. sys.economyName, w - 34, 64, C.uiDim, "small")
        if sys.conflict and sys.conflict > 0.2 and ui.blink(0.7) then
            ui.textRight("CONFLICT ZONE", w - 34, 88, C.uiDanger, "small")
        end
    end

    -- ---- messages -------------------------------------------------------
    local my = h * 0.5 + 60
    for i, m in ipairs(hud.messages) do
        local alpha = util.clamp(m.life / 1.5, 0, 1)
        local col = C.uiText
        if m.kind == "good" then col = C.uiPrimary
        elseif m.kind == "alert" then col = C.uiDanger
        elseif m.kind == "warn" then col = C.uiWarn end
        love.graphics.setColor(col[1], col[2], col[3], alpha)
        love.graphics.setFont(ui.font("small"))
        local f = ui.font("small")
        love.graphics.print(m.text, floor(cx - f:getWidth(m.text) * 0.5), floor(my + (i - 1) * 17))
    end
    love.graphics.setColor(1, 1, 1, 1)

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

    ui.brackets(20, h - 76, 230, 56, 10, C.uiPrimary, 0.45)
    ui.text(ctx.locationName or "", 32, h - 68, C.uiText, "small")
    ui.text(ctx.subtitle or "", 32, h - 50, C.uiDim, "small")
    ui.textRight(util.money(ctx.player.credits) .. " cr", 240, h - 32, C.amber, "small")

    if ctx.prompt then
        ui.setColor(C.uiPanel, 1)
        local f = ui.font("normal")
        local tw = f:getWidth(ctx.prompt) + 34
        love.graphics.rectangle("fill", cx - tw * 0.5, cy + 60, tw, 30)
        ui.setColor(C.uiPrimary, 0.8)
        love.graphics.rectangle("line", cx - tw * 0.5, cy + 60, tw, 30)
        ui.textCenter(ctx.prompt, cx, cy + 66, C.uiPrimary, "normal")
    end

    local my = h * 0.35
    for i, m in ipairs(hud.messages) do
        local alpha = util.clamp(m.life / 1.5, 0, 1)
        love.graphics.setColor(C.uiText[1], C.uiText[2], C.uiText[3], alpha)
        love.graphics.setFont(ui.font("small"))
        local f = ui.font("small")
        love.graphics.print(m.text, floor(cx - f:getWidth(m.text) * 0.5), floor(my + (i - 1) * 17))
    end
    love.graphics.setColor(1, 1, 1, 1)
end

return hud
