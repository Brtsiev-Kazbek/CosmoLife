-- Inside a building.
--
-- Rooms are generated from the building's seed on entry (see procgen.interior)
-- and thrown away on exit.  Walking up to a terminal and pressing the
-- interact key opens the same service screens the docking UI uses, so a market
-- reached on foot and a market reached by docking are the same market.

local class = require("src.lib.class")
local vec3 = require("src.lib.vec3")
local mat4 = require("src.lib.mat4")
local util = require("src.lib.util")
local config = require("src.config")
local palette = require("src.render.palette")
local interiorGen = require("src.procgen.interior")
local hud = require("src.render.hud")
local ui = require("src.ui.widgets")
local i18n = require("src.i18n")
local input = require("src.input")
local Walker = require("src.sim.walker")

local Room = class("RoomState")

local sqrt, sin, cos = math.sqrt, math.sin, math.cos
local W = config.walk
local C = palette.colors
local L = i18n.format

local SERVICE_LABEL = {
    market = "Commodity Market", blackMarket = "Black Market", missions = "Contract Board",
    shipyard = "Shipyard", outfitting = "Outfitting", repair = "Repair Bay",
    refuel = "Refuelling", rumours = "Local Talk", navdata = "Navigation Data",
    colony = "Colony Office",
}

function Room:init()
    self.drawUnderlying = false
end

function Room:enter(opts)
    self.opts = opts
    self.world = self.game.world
    self.player = self.world.player
    self.place = opts.place
    self.room = interiorGen.generate(opts.kind, opts.seed, {})
    self.buildingName = opts.name or self.room.name

    -- an interior is drawn in the plain world axes, which are right handed --
    -- unlike the planet surface, whose tangent frame is left handed
    self.walker = Walker.new({
        frame = "world", x = self.room.spawn.x, z = self.room.spawn.z,
    })
    self.pos = self.walker.pos
    self.vel = self.walker.vel
    self.prompt = nil

    -- the room is drawn in its own little world, far from anything else
    self.origin = vec3(0, 0, 0)

    love.mouse.setRelativeMode(true)
    hud.message("Entered " .. self.buildingName, "info")
end

function Room:exit()
    love.mouse.setRelativeMode(false)
    if self.room.model and self.room.model.mesh and self.room.model.mesh.release then
        self.room.model.mesh:release()
    end
    if self.room.glowModel and self.room.glowModel.mesh and self.room.glowModel.mesh.release then
        self.room.glowModel.mesh:release()
    end
end

function Room:pause() love.mouse.setRelativeMode(false) end
function Room:resume() love.mouse.setRelativeMode(true) end

function Room:mousemoved(x, y, dx, dy)
    self.walker:look(dx, dy)
end

function Room:update(dt, background)
    if background then return end
    self.world:update(dt)

    -- indoors you move at a considered pace, not a sprint down a corridor
    local ax = input.axis("walkLeft", "walkRight")
    local az = input.axis("walkBack", "walkForward")
    self.walker:walk(dt, ax, az, config.down("run"), { speedScale = 0.72 })

    self.pos.x = self.pos.x + self.vel.x * dt
    self.pos.z = self.pos.z + self.vel.z * dt
    self.pos.x, self.pos.z = interiorGen.collide(self.room, self.pos.x, self.pos.z, 0.45)

    self:updatePrompt()
    self:updateCamera(dt)
end

function Room:updatePrompt()
    self.prompt = nil
    self.action = nil
    local best, bestD = nil, W.interactRange
    for _, t in ipairs(self.room.terminals) do
        local d = sqrt((self.pos.x - t.x) ^ 2 + (self.pos.z - t.z) ^ 2)
        if d < bestD then best, bestD = t, d end
    end
    if best then
        self.prompt = string.format("%s: %s", config.keyName("interact"),
            L(SERVICE_LABEL[best.service] or best.service))
        self.action = { kind = "service", service = best.service }
        return
    end
    local ex = self.room.exit
    local d = sqrt((self.pos.x - ex.x) ^ 2 + (self.pos.z - ex.z) ^ 2)
    if d < 2.6 then
        self.prompt = L("{key} to step outside", { key = config.keyName("interact") })
        self.action = { kind = "exit" }
    end
end

function Room:updateCamera(dt)
    local camera = self.game.camera
    camera.pos:set(self.pos.x, W.eyeHeight, self.pos.z)
    camera.fwd:set(self.walker:forward())
    camera.up:set(0, 1, 0)
    mat4.orthonormalize(camera.right, camera.up, camera.fwd)
    camera:updateShake(dt)
end

function Room:keypressed(key)
    if config.is("pause", key) then
        local Pause = require("src.states.pause")
        self.manager:push(Pause.new(), self)
        return
    end
    if config.is("interact", key) and self.action then
        if self.action.kind == "exit" then
            self.manager:pop()
        else
            local Port = require("src.states.port")
            self.manager:push(Port.new(), self.place, {
                flight = self.opts.flight, docked = false, service = self.action.service,
            })
        end
    end
end

function Room:draw(background)
    local renderer = self.game.renderer
    local camera = self.game.camera
    local w, h = renderer.width, renderer.height

    -- interiors get their own lighting: no sun, warm fill from the ceiling
    local env = renderer.env
    local savedSun = { env.sunDir.x, env.sunDir.y, env.sunDir.z }
    local savedAmbient = env.ambient
    local savedAtmos, savedFog = env.atmos, env.fogAmount
    env.sunDir:set(0.2, -1, 0.15)
    env.ambient = { 0.34, 0.33, 0.36 }
    env.atmos = 0
    env.fogAmount = 0.25
    env.fogColor = { 0.04, 0.04, 0.05 }
    env.fogNear = 14
    env.fogFar = 46

    renderer:beginFrame(camera)
    renderer:draw(self.room.model, self.origin, nil, { layer = renderer.LAYER_NEAR })
    if self.room.glowModel then
        renderer:draw(self.room.glowModel, self.origin, nil, { layer = renderer.LAYER_NEAR, emissive = 1 })
    end
    renderer:endFrame()
    renderer:present()

    env.sunDir:set(savedSun[1], savedSun[2], savedSun[3])
    env.ambient = savedAmbient
    env.atmos = savedAtmos
    env.fogAmount = savedFog

    if background then return end

    hud.drawWalking({
        player = self.player,
        locationName = self.buildingName,
        subtitle = self.place and self.place.name or self.room.name,
        prompt = self.prompt,
    }, w, h)
end

return Room
