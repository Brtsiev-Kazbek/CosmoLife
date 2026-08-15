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

local hudmode = require("src.render.hudmode")
local aim = require("src.sim.aim")

local hud = {}

local C = palette.colors
local cos, sin, pi, floor, min, max = math.cos, math.sin, math.pi, math.floor, math.min, math.max

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

--- Where every group of the HUD sits, for a given window.
--
-- This exists so the numbers have one owner. The check that the message band
-- does not run into the scanner used to live in tests/run.lua as a *copy* of
-- the arithmetic -- `msgBottom = h - 152` written out again -- so the test was
-- checking its own transcription and the two could drift apart in silence.
-- Now the drawing and the test read the same table.
function hud.layout(w, h)
    local l = {
        cx = w * 0.5,
        cy = h * 0.5,
        gaugeY = h - 150,             -- top of both gauge clusters
        gaugeW = 210,
        gaugeH = 140,
        leftX = 26,
        rightX = w - 236,
        scannerY = h - 78,            -- centre of the scanner bowl
        scannerRX = 132,
        scannerRY = 58,
        scannerCaptionY = h - 146,
        flagsY = h - 168,
        targetX = 26,
        targetY = 26,
        targetW = 250,
        bannerW = 274,
        bannerY = 22,
        objectiveY = 26,
        promptY = h * 0.5 - 96,
    }
    l.bannerX = w - 34 - l.bannerW
    -- The message band runs from under the reticle to just above the scanner
    -- caption. At 540 px the old fixed fraction put the last four messages
    -- inside the scanner ellipse.
    l.msgBottom = l.scannerCaptionY - 6
    l.msgTop = max(h * 0.30, min(h * 0.5 + 60, l.msgBottom - 140))
    return l
end

hud.messages = {}

-- ---------------------------------------------------------------------------
-- Messages
-- ---------------------------------------------------------------------------

-- How many lines can be on screen at once.
--
-- It was seven, and the strip drew as many as fitted the band, so a busy
-- moment -- arriving in a system, being scanned, taking a contract -- filled a
-- third of the screen with text nobody reads. Three is what a player takes in
-- between glances at the world.
hud.MAX_MESSAGES = 3

-- Which lines survive when there are more than three. A warning has to beat
-- the chatter that arrives on top of it, or the one line that mattered is
-- gone before it is read.
local PRIORITY = { alert = 3, warn = 2, good = 1, info = 0 }

hud.PRIORITY = PRIORITY

local MESSAGE_LIFE = 6.5

--- Adds a line to a message list, keeping the list within its cap.
--
-- Pure, so the rule can be tested without a window: the list goes in, the list
-- comes out, and nothing here draws or makes a sound. Returns true when the
-- line is genuinely new, which is what decides whether an alarm sounds -- a
-- warning repeating every frame must not become a klaxon.
function hud.push(list, text, kind, cap)
    kind = kind or "info"
    cap = cap or hud.MAX_MESSAGES

    -- The same line again refreshes the one already there rather than stacking
    -- copies of itself. "Hold is full" fires once per scoop attempt, which
    -- used to push everything else off the screen on its own.
    for i, m in ipairs(list) do
        if m.text == text then
            m.life = MESSAGE_LIFE
            m.kind = kind
            table.remove(list, i)
            table.insert(list, 1, m)
            return false
        end
    end

    table.insert(list, 1, { text = text, kind = kind, life = MESSAGE_LIFE })

    -- Over the cap, the lowest priority goes, and the oldest of those. The new
    -- line is not exempt: three alerts and an incoming "info" means the info
    -- never appears, which is the correct answer.
    while #list > cap do
        local worst, worstRank = 1, math.huge
        for i = #list, 1, -1 do
            local rank = PRIORITY[list[i].kind] or 0
            if rank < worstRank then worst, worstRank = i, rank end
        end
        table.remove(list, worst)
    end
    return true
end

function hud.message(text, kind)
    local fresh = hud.push(hud.messages, text, kind)
    -- Only the two that mean something bad get a sound, and only when the line
    -- is new. A bleep on every line of chatter trains the player to ignore it,
    -- which is the opposite of what an alert is for.
    if not fresh then return end
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

--- The selected target, drawn on the target rather than in a corner.
--
-- A panel in the corner of the screen tells you about the thing you are trying
-- to shoot while your eyes are on the thing you are trying to shoot. Putting
-- the shield and hull on the target itself means one place to look, and the
-- lead ring -- where to aim so the bolt and the ship arrive together -- is the
-- only part of this HUD that helps land a shot rather than describing the
-- situation.
local function drawTargetIndicator(ctx, w, h)
    local t = ctx.target
    if not t or not t.entity then return end
    local e = t.entity
    local camera = ctx.camera
    local x, y, dist = camera:project(e.pos.x, e.pos.y, e.pos.z, w, h)
    if not x then return end

    local col = t.hostile and C.uiDanger or C.cyan
    local s = util.clamp(3200 / max(dist, 1), 14, 90)

    -- corner brackets rather than a closed box: the target stays visible
    -- inside its own indicator
    ui.setColor(col, 0.95)
    love.graphics.setLineWidth(2)
    local arm = s * 0.42
    for _, corner in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
        local px, py = x + corner[1] * s, y + corner[2] * s
        love.graphics.line(px, py, px - corner[1] * arm, py)
        love.graphics.line(px, py, px, py - corner[2] * arm)
    end
    love.graphics.setLineWidth(1)

    -- health, under the frame, as wide as the frame is
    local bw = s * 2
    local by = y + s + 5
    if t.shield then
        ui.bar(x - s, by, bw, 4, t.shield, C.cyan)
        by = by + 6
    end
    if t.hull then
        ui.bar(x - s, by, bw, 4, t.hull, t.hostile and C.uiDanger or C.uiPrimary)
    end

    -- Lead ring. Only while the target is in weapon range: past that the
    -- intercept is real but the bolt expires before it arrives, and a ring
    -- promising a hit that cannot happen is worse than none.
    local speed = ctx.weaponSpeed
    if not speed or not e.vel or not ctx.ship then return end
    if dist > (ctx.weaponRange or 0) then return end
    local ship = ctx.ship
    local lx, ly, lz = aim.lead(
        e.pos.x - ship.pos.x, e.pos.y - ship.pos.y, e.pos.z - ship.pos.z,
        e.vel.x - ship.vel.x, e.vel.y - ship.vel.y, e.vel.z - ship.vel.z, speed)
    if not lx then return end
    local px, py = camera:project(ship.pos.x + lx, ship.pos.y + ly, ship.pos.z + lz, w, h)
    if not px then return end
    ui.setColor(C.amber, 0.9)
    love.graphics.circle("line", px, py, 7)
    love.graphics.points(px, py)
    -- a line back to the hull, so it is obvious which target the ring is for
    ui.setColor(C.amber, 0.35)
    love.graphics.line(px, py, x, y)
    love.graphics.setColor(1, 1, 1, 1)
end

--- The docking corridor, drawn where it actually is.
--
-- The game used to convey a dock with the line "slow to under 120 m/s to
-- dock", which says nothing about *where* -- and a station's mouth is one
-- specific opening on one face, quite possibly round the back from wherever
-- you approached. This draws the opening and the axis running out of it, so
-- lining up is something the player sees rather than reads, and colours the
-- whole thing by whether the closing speed would be let in.
local function drawCorridor(ctx, c, w, h)
    local camera = ctx.camera
    -- two axes across the mouth: any vector not parallel to the normal will do
    local ax, ay, az = 0, 1, 0
    if math.abs(c.ny) > 0.94 then ax, ay, az = 1, 0, 0 end
    -- u = n x a, v = n x u
    local ux, uy, uz = c.ny * az - c.nz * ay, c.nz * ax - c.nx * az, c.nx * ay - c.ny * ax
    local ul = math.sqrt(ux * ux + uy * uy + uz * uz)
    if ul < 1e-6 then return end
    ux, uy, uz = ux / ul, uy / ul, uz / ul
    local vx, vy, vz = c.ny * uz - c.nz * uy, c.nz * ux - c.nx * uz, c.nx * uy - c.ny * ux

    local col = c.tooFast and C.uiWarn or C.uiPrimary
    local r = c.radius

    local function at(du, dv, dn)
        return camera:project(
            c.x + ux * du + vx * dv + c.nx * dn,
            c.y + uy * du + vy * dv + c.ny * dn,
            c.z + uz * du + vz * dv + c.nz * dn, w, h)
    end

    -- the mouth itself, and two rings up the approach axis: three squares of
    -- shrinking screen size read as a tunnel without drawing one
    ui.setColor(col, 0.9)
    love.graphics.setLineWidth(2)
    for i, dn in ipairs({ 0, r * 1.6, r * 3.4 }) do
        local pts, ok = {}, true
        for _, corner in ipairs({ { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } }) do
            local px, py = at(corner[1] * r, corner[2] * r, dn)
            if not px then ok = false break end
            pts[#pts + 1] = px
            pts[#pts + 1] = py
        end
        if ok then
            ui.setColor(col, i == 1 and 0.95 or (0.5 / i))
            love.graphics.polygon("line", pts)
        end
    end
    love.graphics.setLineWidth(1)

    -- the axis, so the direction to come in from is unambiguous
    local mx, my = at(0, 0, 0)
    local ex, ey = at(0, 0, r * 3.4)
    if mx and ex then
        ui.setColor(col, 0.35)
        love.graphics.line(mx, my, ex, ey)
    end

    -- and the one number that decides whether this works, on the mouth rather
    -- than in a corner
    if mx then
        local label = util.speed(c.speed)
        if c.tooFast then label = label .. "  " .. L("TOO FAST") end
        ui.textCenter(label, mx, my + r * 0.1 + 8, col, "small")
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
    local l = hud.layout(w, h)

    -- What the situation calls for. Groups the mode does not want are faded
    -- rather than removed: a readout that vanishes and comes back is harder to
    -- trust than one that recedes. See render/hudmode.lua.
    local mode = ctx.mode or hudmode.resolve(ctx)
    hud.mode = mode
    ui.resetAlpha()
    local function layer(name) ui.pushAlpha(hudmode.alpha(mode, name)) end
    local pop = ui.popAlpha

    -- ---- reticle --------------------------------------------------------
    local cx, cy = l.cx, l.cy
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
    layer("target")
    drawTargetIndicator(ctx, w, h)
    if ctx.corridor then drawCorridor(ctx, ctx.corridor, w, h) end
    pop()

    -- ---- left gauges ----------------------------------------------------
    local gx, gy = l.leftX, l.gaugeY
    layer("vitals")
    ui.brackets(gx - 8, gy - 12, l.gaugeW, l.gaugeH, 12, accent, 0.5)

    ui.text(L("SHIELD"), gx, gy, C.uiDim, "small")
    ui.segmentBar(gx, gy + 16, 190, 9, (ship.shield or 0) / max(stats.maxShield, 1), 14, C.cyan)
    ui.text(L("HULL"), gx, gy + 32, C.uiDim, "small")
    local hullFrac = (ship.hull or 0) / max(stats.maxHull, 1)
    ui.segmentBar(gx, gy + 48, 190, 9, hullFrac, 14, hullFrac < 0.3 and C.uiDanger or C.uiPrimary)
    pop()
    layer("power")
    ui.text(L("FUEL"), gx, gy + 64, C.uiDim, "small")
    ui.segmentBar(gx, gy + 80, 190, 7, (player.fuel or 0) / max(stats.fuel, 1), 12, C.amber)
    ui.text(L("HEAT"), gx, gy + 94, C.uiDim, "small")
    local heat = util.clamp((ctx.heat or 0) / max(stats.heatCapacity or 100, 1), 0, 1)
    ui.segmentBar(gx, gy + 110, 190, 7, heat, 12, heat > 0.8 and C.uiDanger or C.orange)
    pop()

    -- ---- right gauges ---------------------------------------------------
    local rx = l.rightX
    layer("drive")
    ui.brackets(rx - 8, gy - 12, l.gaugeW, l.gaugeH, 12, accent, 0.5)
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
        pop()
        layer("nav")
        ui.text(L("ALTITUDE"), rx, gy + 52, C.uiDim, "small")
        ui.textRight(util.distance(ctx.altitude), rx + 190, gy + 52, ctx.altitude < 800 and C.uiWarn or C.uiText, "small")
        if ctx.verticalSpeed then
            ui.text(L("V/S"), rx, gy + 70, C.uiDim, "small")
            ui.textRight(string.format("%+.0f m/s", ctx.verticalSpeed), rx + 190, gy + 70,
                ctx.verticalSpeed < -40 and C.uiDanger or C.uiText, "small")
        end
        pop()
        layer("drive")
    end
    pop()

    layer("cargo")
    ui.text(L("CARGO"), rx, gy + 92, C.uiDim, "small")
    ui.textRight(string.format("%d / %d t", player:cargoUsed(), player:cargoCapacity()), rx + 190, gy + 92, C.uiText, "small")
    ui.text(L("CREDITS"), rx, gy + 110, C.uiDim, "small")
    ui.textRight(util.money(player.credits), rx + 190, gy + 110, C.amber, "small")
    pop()

    -- ---- artificial horizon, whenever there is a ground to be level with --
    if ctx.horizon then
        layer("nav")
        drawHorizon(cx, cy - h * 0.22, math.min(w, h) * 0.11,
            ctx.horizon.roll, ctx.horizon.pitch, ctx.altitude, ctx.verticalSpeed,
            ctx.horizon.landable)
        if ctx.hoverMode then
            ui.textCenter(L("LANDING MODE"), cx, cy - h * 0.22 + math.min(w, h) * 0.13,
                C.uiPrimary, "small")
        end
        pop()
    end

    -- ---- scanner --------------------------------------------------------
    if hudmode.alpha(mode, "scanner") > 0 then
        layer("scanner")
        drawScanner(cx, l.scannerY, l.scannerRX, l.scannerRY, ship, ctx.contacts,
            config.combat.scanRange)
        ui.text(L("SCANNER"), cx - l.scannerRX, l.scannerCaptionY, C.uiDim, "small")
        pop()
    end

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
                ui.text(f[1], fx, l.flagsY, f[2], "small")
            end
            fx = fx + fw + gap
        end
    end

    -- ---- target panel ---------------------------------------------------

    if ctx.target then
        layer("target")
        local t = ctx.target
        local px, py = l.targetX, l.targetY
        local pw = l.targetW
        local textW = pw - 28
        -- Identity here, condition on the target itself.
        --
        -- The hull and shield bars used to be repeated in this panel, which
        -- meant reading them in the corner while looking at the ship in the
        -- middle of the screen. They are drawn on the target now
        -- (drawTargetIndicator), and what is left here is what a bracket in
        -- the world cannot say: who it is, how far, and what the scanner found.
        local rows = t.detail and 3 or 2
        ui.panel(px, py, pw, 26 + rows * 18, L("TARGET"), accent)
        ui.textFit(t.label or L("Unknown"), px + 14, py + 12, textW, C.uiText, "small")
        ui.text(util.distance(t.distance or 0), px + 14, py + 30, C.uiDim, "small")
        if t.detail then
            ui.textFit(t.detail, px + 14, py + 48, textW, C.uiDim, "small")
            if t.detail2 then ui.textFit(t.detail2, px + 14, py + 62, textW, C.uiDim, "small") end
        end
        pop()
    end

    -- ---- system banner --------------------------------------------------
    local sys = ctx.world.stub
    if sys then
        layer("banner")
        local faction = factions.get(sys.factionId)
        local bw = l.bannerW
        local bx = l.bannerX
        local textW = bw - 20
        -- the conflict line used to print at y=88 inside a frame that ended at
        -- 84, so the frame grows when it is showing
        local conflict = sys.conflict and sys.conflict > 0.2
        ui.brackets(bx, l.bannerY, bw, conflict and 84 or 62, 10, accent, 0.4)
        ui.textRightFit(sys.name, w - 34, 28, textW, C.uiText, "normal")
        ui.textRightFit(L(faction.name), w - 34, 48, textW,
            { faction.color[1], faction.color[2], faction.color[3], 1 }, "small")
        ui.textRightFit(ctx.world:dateString() .. "   " .. L(sys.economyName),
            w - 34, 64, textW, C.uiDim, "small")
        if conflict and ui.blink(0.7) then
            ui.textRightFit(L("CONFLICT ZONE"), w - 34, 82, textW, C.uiDanger, "small")
        end
        pop()
    end

    -- ---- messages -------------------------------------------------------
    --
    -- The strip is anchored above the scanner rather than at a fixed fraction
    -- of the height: at 540px the old position put the last four messages
    -- inside the scanner ellipse.
    -- the band runs from just under the reticle to just above the scanner
    -- caption at h-146
    drawMessages(cx, l.msgTop, l.msgBottom, w)

    -- ---- objective ------------------------------------------------------
    --
    -- Top centre, under the system banner: the game never told anyone what to
    -- do next, and a player who does not know what to do next stops playing.
    if ctx.objective then
        layer("objective")
        local f = ui.font("normal")
        local fs = ui.font("small")
        local tw = math.max(f:getWidth(ctx.objective),
            ctx.objectiveHint and fs:getWidth(ctx.objectiveHint) or 0) + 40
        tw = math.min(tw, w - 620)
        if tw > 120 then
            local oy = l.objectiveY
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
        pop()
    end

    -- ---- prompts --------------------------------------------------------
    if ctx.prompt then
        ui.setColor(C.uiPanel, 1)
        local f = ui.font("normal")
        local tw = f:getWidth(ctx.prompt) + 34
        love.graphics.rectangle("fill", cx - tw * 0.5, l.promptY, tw, 30)
        ui.setColor(accent, 0.8)
        love.graphics.rectangle("line", cx - tw * 0.5, l.promptY, tw, 30)
        ui.textCenter(ctx.prompt, cx, l.promptY + 6, C.uiPrimary, "normal")
    end

    -- a group that threw part way through must not leave the whole UI faded
    ui.resetAlpha()
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
