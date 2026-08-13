-- Background starfield and sun glare.
--
-- Stars are drawn as 2D points rather than geometry: at infinite distance a
-- star is a single pixel anyway, and projecting a few thousand directions on
-- the CPU is far cheaper than pushing them through the 3D pipeline.

local class = require("src.lib.class")
local Rng = require("src.lib.rng")
local util = require("src.lib.util")
local settings = require("src.settings")

local Sky = class("Sky")

local STAR_COUNT = 1400

function Sky:init(seed)
    local rng = Rng.new(seed or 1337)
    self.stars = {}
    for i = 1, STAR_COUNT do
        local x, y, z = rng:direction()
        -- brightness distribution: many faint stars, a few bright ones
        local mag = rng:float()
        mag = mag * mag * mag
        local b = 0.25 + mag * 0.75
        -- stellar colour: cool red through hot blue
        local temp = rng:float()
        local r = util.lerp(1.0, 0.72, temp)
        local g = util.lerp(0.78, 0.85, temp)
        local bl = util.lerp(0.62, 1.0, temp)
        -- [8] and [9] give each star its own twinkle rate and phase, so the
        -- field shimmers instead of sitting dead still. Real starlight
        -- scintillates through an atmosphere and not in vacuum, so the effect
        -- is scaled by `atmos` at draw time.
        self.stars[i] = { x, y, z, r * b, g * b, bl * b, 1 + mag * 2.2,
                          rng:range(0.6, 2.4), rng:range(0, math.pi * 2) }
    end
    self.points = {}
    self:buildConstellations(rng)
end

--- Constellations.
--
-- Real constellations are just bright stars that people joined with lines, so
-- that is exactly how these are made: take the brightest stars, and link each
-- to a near neighbour a few times.  Drawn faintly, they give the sky structure
-- and make one system's night distinguishable from another's.
function Sky:buildConstellations(rng)
    local bright = {}
    for i = 1, #self.stars do
        if self.stars[i][7] > 2.0 then bright[#bright + 1] = i end
    end
    self.lines = {}
    local groups = math.min(math.floor(#bright / 6), 22)
    local used = {}
    for _ = 1, groups do
        -- pick an unused seed star and grow a short chain from it
        local start
        for _ = 1, 30 do
            local cand = bright[rng:int(1, #bright)]
            if not used[cand] then start = cand break end
        end
        if not start then break end
        local current = start
        used[current] = true
        local links = rng:int(2, 5)
        for _ = 1, links do
            -- nearest unused bright star within a plausible angular reach
            local best, bestD = nil, 0.55
            local a = self.stars[current]
            for _, j in ipairs(bright) do
                if not used[j] then
                    local b = self.stars[j]
                    local dx, dy, dz = b[1] - a[1], b[2] - a[2], b[3] - a[3]
                    local d = math.sqrt(dx * dx + dy * dy + dz * dz)
                    if d < bestD then best, bestD = j, d end
                end
            end
            if not best then break end
            used[best] = true
            self.lines[#self.lines + 1] = { current, best }
            current = best
        end
    end
end

--- Draws the starfield for the current camera.  `fade` dims the field as the
--- atmosphere thickens, which is what makes daytime skies read as daytime.
--- `atmos` is how much air is between the camera and the stars: scintillation
--- is an atmospheric effect, so in vacuum the field is rock steady.
function Sky:draw(camera, w, h, fade, atmos)
    fade = fade or 1
    if fade <= 0.01 then return end

    local t = (love and love.timer) and love.timer.getTime() or 0
    local twinkle = math.min(atmos or 0, 1)

    local cam = camera
    local tan = math.tan(cam.fov * 0.5)
    local invT = 1 / tan
    local aspect = cam.aspect
    local fx, fy, fz = cam.fwd.x, cam.fwd.y, cam.fwd.z
    local rx, ry, rz = cam.right.x, cam.right.y, cam.right.z
    local ux, uy, uz = cam.up.x, cam.up.y, cam.up.z

    local pts = self.points
    local n = 0
    local sizeGroups = { {}, {}, {} }

    local budget = math.min(#self.stars, settings.q().starCount)
    for i = 1, budget do
        local s = self.stars[i]
        local sx, sy, sz = s[1], s[2], s[3]
        local zf = sx * fx + sy * fy + sz * fz
        if zf > 0.05 then
            local xr = sx * rx + sy * ry + sz * rz
            local yu = sx * ux + sy * uy + sz * uz
            local px = ((xr / zf) * invT / aspect * 0.5 + 0.5) * w
            local py = (0.5 - (yu / zf) * invT * 0.5) * h
            if px >= -2 and px <= w + 2 and py >= -2 and py <= h + 2 then
                local g = s[7] > 2.4 and 3 or (s[7] > 1.6 and 2 or 1)
                local list = sizeGroups[g]
                local a = fade
                if twinkle > 0 then
                    a = a * (1 - twinkle * 0.45 * (0.5 + 0.5 * math.sin(t * s[8] + s[9])))
                end
                list[#list + 1] = { px, py, s[4], s[5], s[6], a }
                n = n + 1
            end
        end
    end
    self._visible = n

    -- constellation lines, drawn under the stars
    if self.lines and fade > 0.25 then
        local proj = self._proj or {}
        self._proj = proj
        local function project(i)
            local st = self.stars[i]
            local zf = st[1] * fx + st[2] * fy + st[3] * fz
            if zf <= 0.08 then return nil end
            local xr = st[1] * rx + st[2] * ry + st[3] * rz
            local yu = st[1] * ux + st[2] * uy + st[3] * uz
            return ((xr / zf) * invT / aspect * 0.5 + 0.5) * w,
                   (0.5 - (yu / zf) * invT * 0.5) * h
        end
        love.graphics.setLineWidth(1)
        love.graphics.setColor(0.42, 0.56, 0.78, 0.16 * fade)
        for i = 1, #self.lines do
            local a, b = self.lines[i][1], self.lines[i][2]
            local ax, ay = project(a)
            if ax then
                local bx, by = project(b)
                if bx then love.graphics.line(ax, ay, bx, by) end
            end
        end
        love.graphics.setColor(1, 1, 1, 1)
    end

    for g = 1, 3 do
        local list = sizeGroups[g]
        if #list > 0 then
            love.graphics.setPointSize(g)
            love.graphics.points(list)
        end
    end
    love.graphics.setPointSize(1)
    pts[1] = nil
end

--- The local star: a hard disc plus a soft bloom, drawn in 2D so it never
--- fights the depth buffer.
function Sky:drawSun(camera, sunPos, w, h, radius, color, occluded)
    local x, y, dist = camera:project(sunPos.x, sunPos.y, sunPos.z, w, h)
    if not x then return end
    local angular = math.atan(radius / math.max(dist, 1))
    local px = angular / (camera.fov * 0.5) * (h * 0.5)
    px = util.clamp(px, 2, h * 0.9)

    local a = occluded and 0.15 or 1
    love.graphics.setBlendMode("add")
    love.graphics.setColor(color[1] * 0.16 * a, color[2] * 0.14 * a, color[3] * 0.12 * a, 1)
    love.graphics.circle("fill", x, y, px * 5.5)
    love.graphics.setColor(color[1] * 0.35 * a, color[2] * 0.32 * a, color[3] * 0.30 * a, 1)
    love.graphics.circle("fill", x, y, px * 2.4)
    love.graphics.setColor(color[1] * a, color[2] * a, color[3] * a, 1)
    love.graphics.circle("fill", x, y, px)
    if not occluded and px < 12 then
        -- classic four point flare while the star is still a pinpoint
        love.graphics.setColor(color[1] * 0.5, color[2] * 0.5, color[3] * 0.5, 1)
        love.graphics.setLineWidth(1)
        love.graphics.line(x - px * 7, y, x + px * 7, y)
        love.graphics.line(x, y - px * 7, x, y + px * 7)
    end
    love.graphics.setBlendMode("alpha")
    love.graphics.setColor(1, 1, 1, 1)
end

return Sky
