-- Walking on a planet surface.
--
-- Disembarking does not load anything: the same Surface object the ship was
-- flying over becomes the ground under the player's boots, so the settlement
-- they landed next to is the settlement they now walk into.

local class = require("src.lib.class")
local vec3 = require("src.lib.vec3")
local mat4 = require("src.lib.mat4")
local util = require("src.lib.util")
local config = require("src.config")
local palette = require("src.render.palette")
local hud = require("src.render.hud")
local ui = require("src.ui.widgets")
local settlementGen = require("src.procgen.settlement")
local combat = require("src.sim.combat")
local settings = require("src.settings")
local hints = require("src.render.hints")

local OnFoot = class("OnFootState")

local sqrt, min, max, cos, sin, pi = math.sqrt, math.min, math.max, math.cos, math.sin, math.pi
local W = config.walk
local C = palette.colors

function OnFoot:enter(opts)
    self.surface = opts.surface
    self.flight = opts.flight
    self.world = self.game.world
    self.player = self.world.player

    self.pos = vec3(opts.x or 0, 0, opts.z or 0)
    self.pos.y = self.surface:groundHeight(self.pos.x, self.pos.z)
    self.vel = vec3(0, 0, 0)
    self.yaw = 0
    self.pitch = 0
    self.onGround = true
    self.prompt = nil
    self.shipLocal = vec3(opts.x or 0, 0, opts.z or 0)
    if self.flight then
        self.shipLocal:copyFrom(self.flight.local_.pos)
    end

    love.mouse.setRelativeMode(true)
    hud.message("On foot. " .. config.keyName("interact") .. " to interact, " ..
        config.keyName("disembark") .. " to board the ship.", "info")
end

function OnFoot:exit()
    love.mouse.setRelativeMode(false)
end

function OnFoot:resume()
    love.mouse.setRelativeMode(true)
end

function OnFoot:pause()
    love.mouse.setRelativeMode(false)
end

-- ---------------------------------------------------------------------------

function OnFoot:mousemoved(x, y, dx, dy)
    self.yaw = self.yaw - dx * W.mouseSens
    self.pitch = util.clamp(self.pitch - dy * W.mouseSens, -1.45, 1.45)
end

function OnFoot:forward()
    local cp = cos(self.pitch)
    return vec3(sin(self.yaw) * cp, sin(self.pitch), cos(self.yaw) * cp)
end

function OnFoot:update(dt, background)
    if background then return end
    self.world:update(dt)
    local surface = self.surface
    surface:refreshFrame()

    -- movement in the tangent plane
    local fx, fz = sin(self.yaw), cos(self.yaw)
    local rx, rz = fz, -fx
    local mx, mz = 0, 0
    if love.keyboard.isDown("w") then mx, mz = mx + fx, mz + fz end
    if love.keyboard.isDown("s") then mx, mz = mx - fx, mz - fz end
    if love.keyboard.isDown("d") then mx, mz = mx + rx, mz + rz end
    if love.keyboard.isDown("a") then mx, mz = mx - rx, mz - rz end
    local len = sqrt(mx * mx + mz * mz)
    local speed = config.down("run") and W.runSpeed or W.speed
    -- low gravity worlds are floaty but you still walk at a human pace
    if len > 1e-6 then mx, mz = mx / len * speed, mz / len * speed end

    local blend = 1 - math.exp(-14 * dt)
    self.vel.x = util.lerp(self.vel.x, mx, blend)
    self.vel.z = util.lerp(self.vel.z, mz, blend)

    local gravity = (surface.body.gravity or 9) * W.gravityScale
    self.vel.y = self.vel.y - gravity * dt

    self.pos.x = self.pos.x + self.vel.x * dt
    self.pos.z = self.pos.z + self.vel.z * dt
    self.pos.y = self.pos.y + self.vel.y * dt

    -- collide with buildings of whichever settlement we are inside
    local site, mesh = surface:settlementAt(self.pos.x, self.pos.z)
    self.site, self.siteMesh = site, mesh
    if site and mesh then
        local lx, lz = self.pos.x - site.x, self.pos.z - site.z
        local nx, nz = settlementGen.collide(mesh, lx, lz, 0.6)
        self.pos.x, self.pos.z = site.x + nx, site.z + nz
    end

    local ground = surface:groundHeight(self.pos.x, self.pos.z)
    if site and mesh then
        ground = site.h + settlementGen.floorHeight(mesh, self.pos.x - site.x, self.pos.z - site.z)
    end
    if self.pos.y <= ground then
        self.pos.y = ground
        self.vel.y = 0
        self.onGround = true
    else
        self.onGround = false
    end

    surface:update(self.pos.x, self.pos.z, dt, 0)
    self:updatePrompt()
    self:updateCamera(dt)
end

function OnFoot:updatePrompt()
    self.prompt = nil
    self.action = nil

    -- board the ship
    local d = sqrt((self.pos.x - self.shipLocal.x) ^ 2 + (self.pos.z - self.shipLocal.z) ^ 2)
    if d < 14 then
        self.prompt = config.keyName("disembark") .. " to board ship"
        self.action = { kind = "board" }
    end

    -- building doors
    local site, mesh = self.site, self.siteMesh
    if site and mesh then
        for _, b in ipairs(mesh.interiors) do
            if b.entrance then
                local ex = site.x + b.entrance.x
                local ez = site.z + b.entrance.z
                local bd = sqrt((self.pos.x - ex) ^ 2 + (self.pos.z - ez) ^ 2)
                if bd < W.interactRange then
                    self.prompt = string.format("%s to enter %s", config.keyName("interact"), b.name)
                    self.action = { kind = "enter", building = b, site = site }
                    break
                end
            end
        end
    end
end

function OnFoot:updateCamera(dt)
    local camera = self.game.camera
    local surface = self.surface
    local eye = self.pos.y + W.eyeHeight
    surface:toWorld(self.pos.x, eye, self.pos.z, camera.pos)

    local f = self:forward()
    local wx, wy, wz = surface:dirToWorld(f.x, f.y, f.z)
    camera.fwd:set(wx, wy, wz)
    camera.up:set(surface.up.x, surface.up.y, surface.up.z)
    mat4.orthonormalize(camera.right, camera.up, camera.fwd)
    camera:updateShake(dt)
end

-- ---------------------------------------------------------------------------

function OnFoot:keypressed(key)
    if config.is("pause", key) then
        local Pause = require("src.states.pause")
        self.manager:push(Pause.new(), self)
        return
    end
    if config.is("jump", key) and self.onGround then
        self.vel.y = W.jumpSpeed * sqrt(math.max(self.surface.body.gravity or 9, 1) / 9.81)
        self.onGround = false
        return
    end
    if config.is("disembark", key) and self.action and self.action.kind == "board" then
        self.manager:pop()
        hud.message("Aboard", "info")
        return
    end
    if (config.is("interact", key)) and self.action and self.action.kind == "enter" then
        self:enterBuilding(self.action.building, self.action.site)
        return
    end
    if config.is("colony", key) then
        local Colonies = require("src.states.colonies")
        self.manager:push(Colonies.new(), self.flight, self.surface, { pos = self.pos })
        return
    end
    if config.is("help", key) then self.game.showHelp = not self.game.showHelp end
end

function OnFoot:enterBuilding(building, site)
    local Room = require("src.states.room")
    local place = site.place
    self.manager:push(Room.new(), {
        kind = building.interior or "lobby",
        seed = (place.seed or 1) + (building.kind and #building.kind or 0) * 977 + math.floor(building.x),
        name = building.name,
        place = place,
        flight = self.flight,
    })
end

-- ---------------------------------------------------------------------------

function OnFoot:draw(background)
    local renderer = self.game.renderer
    local camera = self.game.camera
    local w, h = renderer.width, renderer.height
    local flight = self.flight

    renderer:beginFrame(camera)
    if flight then
        flight:updateEnvironment(true)
        flight:submitBodies(renderer)
        flight:submitStations(renderer)
    end
    self.surface:draw(renderer, { nightGlow = flight and flight.nightGlow or 1, eye = self.pos })

    -- the parked ship
    if flight then
        local shipPos = self.surface:toWorld(self.shipLocal.x, self.shipLocal.y, self.shipLocal.z)
        local basis = { right = self.surface.east, up = self.surface.up,
                        fwd = vec3(-self.surface.north.x, -self.surface.north.y, -self.surface.north.z) }
        renderer:draw(self.player.shipDef.model, shipPos, basis)
    end

    local sys = self.world.system
    renderer:endFrame(function()
        self.game.sky:draw(camera, w, h, 1 - (renderer.env.atmos or 0) * 0.95)
        if not flight or flight:sunVisible() then
            self.game.sky:drawSun(camera, sys.star.pos, w, h, sys.star.radius, sys.star.color, false)
        end
    end)
    renderer:present()

    if background then return end

    hud.drawWalking({
        player = self.player,
        locationName = self.site and self.site.place.name or (self.surface.body.name .. " surface"),
        subtitle = self.site
            and string.format("pop %s  -  %s", util.money(self.site.place.population),
                self.site.place.economyId)
            or string.format("gravity %.1f m/s2", self.surface.body.gravity or 0),
        prompt = self.prompt,
    }, w, h)

    if settings.get("showHints") and not self.game.showHelp then
        hints.draw(hints.onFoot({
            canInteract = self.action and self.action.kind == "enter",
            canBoard = self.action and self.action.kind == "board",
        }), 26, 26)
    end

    if self.game.showHelp then
        local lines = {
            { "Move", "W A S D" },
            { "Run", "SHIFT" },
            { "Jump", "SPACE" },
            { "Look", "MOUSE" },
            { "Interact", config.keyName("interact") },
            { "Board ship", config.keyName("disembark") },
            { "Colonies", config.keyName("colony") },
        }
        local pw, ph = 300, #lines * 20 + 54
        local px, py = (w - pw) * 0.5, (h - ph) * 0.5
        ui.panel(px, py, pw, ph, "ON FOOT")
        for i, l in ipairs(lines) do
            ui.text(l[1], px + 22, py + 30 + (i - 1) * 20, C.uiText, "small")
            ui.textRight(l[2], px + pw - 22, py + 30 + (i - 1) * 20, C.uiPrimary, "small")
        end
    end
end

return OnFoot
