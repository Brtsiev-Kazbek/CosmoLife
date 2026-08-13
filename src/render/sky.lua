-- Background starfield and sun glare.
--
-- Stars are drawn as 2D points rather than geometry: at infinite distance a
-- star is a single pixel anyway, and projecting a few thousand directions on
-- the CPU is far cheaper than pushing them through the 3D pipeline.

local class = require("src.lib.class")
local Rng = require("src.lib.rng")
local util = require("src.lib.util")

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
        self.stars[i] = { x, y, z, r * b, g * b, bl * b, 1 + mag * 2.2 }
    end
    self.points = {}
end

--- Draws the starfield for the current camera.  `fade` dims the field as the
--- atmosphere thickens, which is what makes daytime skies read as daytime.
function Sky:draw(camera, w, h, fade)
    fade = fade or 1
    if fade <= 0.01 then return end

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

    for i = 1, #self.stars do
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
                list[#list + 1] = { px, py, s[4], s[5], s[6], fade }
                n = n + 1
            end
        end
    end
    self._visible = n

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
