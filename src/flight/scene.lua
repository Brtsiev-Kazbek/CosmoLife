-- Everything the flight state hands to the renderer each frame.
--
-- One function per kind of thing in the sky -- bodies, air, city lights, points
-- of interest, stations, ships, weather, loose cargo, weapon effects -- and
-- nothing that decides anything. A `submit*` reads the world and calls
-- `renderer:draw`; it never changes the simulation. Keeping them apart from
-- the update path is most of the reason this module exists: the two used to be
-- interleaved in one file, so a change to how mining works sat three lines
-- from a change to how asteroids are drawn.
--
-- The flight state arrives as an explicit first argument, as in the other
-- flight modules, and `states/flight.lua` keeps forwarding methods.

local vec3 = require("src.lib.vec3")
local mat4 = require("src.lib.mat4")
local util = require("src.lib.util")
local palette = require("src.render.palette")
local bodies = require("src.render.bodies")
local systemGen = require("src.procgen.system")
local pois = require("src.procgen.pois")
local combat = require("src.sim.combat")
local salvage = require("src.sim.salvage")
local settings = require("src.settings")

local scene = {}

local sqrt, min, max, floor = math.sqrt, math.min, math.max, math.floor
local C = palette.colors

function scene.submitBodies(f, renderer)
    local sys = f.world.system
    local camPos = f.game.camera.pos
    local IDENT = f._identBasis or { right = vec3(1, 0, 0), up = vec3(0, 1, 0), fwd = vec3(0, 0, -1) }
    f._identBasis = IDENT

    -- star
    renderer:draw(bodies.star(sys.star), sys.star.pos, IDENT, {
        scale = sys.star.radius, emissive = 1, layer = renderer.LAYER_FAR,
    })


    -- Celestial bodies always belong to the far layer.  Left to the automatic
    -- split they would fall into the near layer as soon as their *surface*
    -- came within 24 km -- exactly when landing -- and the near layer's 30 km
    -- far plane would cut the planet into a hole full of stars.
    local FAR = { layer = renderer.LAYER_FAR }
    for _, b in ipairs(sys.bodies) do
        if b.kind == "planet" then
            local dist = vec3.distance(b.pos, camPos)
            -- more segments when it fills the sky
            local q = settings.q().bodyDetail
            local detail = (dist < b.radius * 12) and q or math.max(16, math.floor(q * 0.6))
            local basis = scene.bodyBasis(f, b)
            renderer:draw(bodies.planet(b, detail), b.pos, basis,
                { scale = b.radius, layer = renderer.LAYER_FAR })
            scene.submitAir(f, renderer, b, basis, dist)
            local rings = bodies.rings(b)
            if rings then
                renderer:draw(rings, b.pos, basis, { scale = b.radius, layer = renderer.LAYER_FAR })
            end
            scene.submitCityLights(f, renderer, b, basis, dist)
            for _, m in ipairs(b.moons) do
                local mbasis = scene.bodyBasis(f, m)
                renderer:draw(bodies.planet(m, math.max(12, math.floor(settings.q().bodyDetail * 0.4))), m.pos, mbasis,
                    { scale = m.radius, layer = renderer.LAYER_FAR })
                -- a moon with air gets air: the shell used to be a planets-only
                -- feature, so the one body a player is most likely to be
                -- looking at up close had none
                scene.submitAir(f, renderer, m, mbasis, vec3.distance(m.pos, camPos))
            end
        end
    end

    -- give the far layer a near plane that clears whatever we are standing on
    renderer:setFarClearance(f.altitude)
end

--- A world's cloud deck and its atmosphere, seen from outside.
--
-- Both are additive shells around the body, and both are drawn in the far
-- additive pass -- the ordinary FX layer is depth-tested against the near
-- pass, whose far plane is 30 km, so a planet's air three hundred thousand
-- kilometres away was clipped out of existence and never appeared at all.
function scene.submitAir(f, renderer, body, basis, dist)
    -- Cloud deck first, so the air scatters over it the way it does.
    local clouds = bodies.clouds(body)
    if clouds and dist > body.radius * 1.02 then
        -- turning faster than the ground below: a deck locked to the surface
        -- is a painted texture, not weather
        renderer:draw(clouds, body.pos, scene.bodyBasis(f, body, 1.35), {
            scale = body.radius * 1.006,
            additive = true, layer = renderer.LAYER_FAR, shell = 2,
        })
    end

    -- No atmosphere shell.
    --
    -- A sphere drawn around the planet cannot look like air from here. The
    -- scattering it needs is a function of how far the view ray travels
    -- through the atmosphere, and a single additive shell only has the angle
    -- between the surface normal and the eye to work with -- so it renders as
    -- a flat pale disc laid over the planet, larger than the planet, with a
    -- hard edge. Several rounds of tuning the falloff moved that edge around
    -- without ever making it read as air. It is off until it can be done as a
    -- ray-marched depth through the shell, where the maths actually holds.
    --
    -- `bodies.atmosphere` and the `u_shell = 1` branch in flat3d are kept for
    -- that: they are what a proper version would build on.
end

--- Lit settlements on a world's night side, seen from orbit.
--
-- bodies.settlementGlow() was written and never called, so an inhabited world
-- looked exactly like a dead one from space: a planet with two million people
-- on it went dark the moment the terminator crossed them. This is the single
-- cheapest thing that makes a system feel lived in.
function scene.submitCityLights(f, renderer, body, basis, dist)
    local places = body.settlements
    if not places or #places == 0 then return end
    -- only worth drawing while the planet is a disc, not a dot
    if dist > body.radius * 26 or dist < body.radius * 1.02 then return end

    local glow = bodies.settlementGlow()
    if not glow then return end

    local sun = renderer.env.sunDir
    local pos = f._glowPos or vec3()
    f._glowPos = pos
    local systemGen = require("src.procgen.system")

    for _, place in ipairs(places) do
        local x, y, z = systemGen.surfacePoint(body, place.latitude, place.longitude, 0)
        -- night side only: the outward normal must face away from the sun
        local nx, ny, nz = (x - body.pos.x), (y - body.pos.y), (z - body.pos.z)
        local len = math.sqrt(nx * nx + ny * ny + nz * nz)
        if len > 1 then
            nx, ny, nz = nx / len, ny / len, nz / len
            local lit = -(nx * sun.x + ny * sun.y + nz * sun.z)
            if lit < 0.06 then
                -- brightest deep in the night side, fading through the terminator
                local night = util.clamp((0.06 - lit) / 0.3, 0, 1)
                local pop = place.population or 1000
                local scale = body.radius * 0.012 * (0.6 + math.min(pop / 400000, 1.6))
                pos:set(x, y, z)
                renderer:draw(glow, pos, basis, {
                    scale = scale, emissive = 1, additive = true,
                    alpha = 0.5 * night, layer = renderer.LAYER_FAR,
                })
            end
        end
    end
end

--- Basis for a body, applying its spin about a polar axis tilted by
--- `axialTilt`.  The sphere mesh is generated pole-up, so `up` is that axis.
-- `spinScale` lets a shell turn at a different rate to the ground under it:
-- a cloud deck that rotated exactly with the planet would be painted on.
function scene.bodyBasis(f, body, spinScale)
    local key = spinScale and "_basisAlt" or "_basis"
    body[key] = body[key] or { right = vec3(), up = vec3(), fwd = vec3() }
    local b = body[key]
    local spin = (body.spin or 0) * (spinScale or 1)
    local tilt = body.axialTilt or 0
    local ct, st = math.cos(tilt), math.sin(tilt)
    local cs, ss = math.cos(spin), math.sin(spin)

    -- polar axis, tilted about X
    b.up:set(0, ct, st)
    -- an equatorial reference, rotated by the spin about that axis
    b.right:set(cs, st * ss, -ct * ss)
    -- our convention is right x up = -fwd (see mat4.orthonormalize)
    b.fwd:set(-ss, cs * st, -cs * ct)
    mat4.orthonormalize(b.right, b.up, b.fwd)
    return b
end

function scene.submitPois(f, renderer)
    local seed = f.world.system.seed
    pois.near(seed, f.ship.pos.x, f.ship.pos.y, f.ship.pos.z, f.pois)
    local basis = f._poiBasis or { right = vec3(), up = vec3(0, 1, 0), fwd = vec3() }
    f._poiBasis = basis
    local pos = f._poiPos or vec3()
    f._poiPos = pos

    for _, p in ipairs(f.pois) do
        local model, glow = pois.spaceMesh(p)
        if model then
            local a = p.spin + f.time * p.spinRate
            basis.right:set(math.cos(a), 0, -math.sin(a))
            basis.up:set(0, 1, 0)
            basis.fwd:set(-math.sin(a), 0, -math.cos(a))
            mat4.orthonormalize(basis.right, basis.up, basis.fwd)
            pos:set(p.x, p.y, p.z)
            renderer:draw(model, pos, basis, { scale = p.scale })
            if glow then
                renderer:draw(glow, pos, basis, { scale = p.scale, emissive = 1 })
            end
        end
    end

    -- surface features, in the ground frame
    if f.surface then
        local s = f.surface
        pois.surfaceNear(f.surface.body.seed, f.local_.pos.x, f.local_.pos.z, f.surfacePois)
        local sbasis = f._spoiBasis or { right = vec3(), up = vec3(), fwd = vec3() }
        f._spoiBasis = sbasis
        for _, p in ipairs(f.surfacePois) do
            local dx = p.x - f.local_.pos.x
            local dz = p.z - f.local_.pos.z
            if dx * dx + dz * dz < 9e6 then       -- within 3 km
                local built = pois.surfaceMesh(p)
                if built and built.model then
                    local h = s:groundHeight(p.x, p.z)
                    local c, sn = math.cos(p.rot), math.sin(p.rot)
                    sbasis.right:set(s.east.x * c - s.north.x * sn,
                                     s.east.y * c - s.north.y * sn,
                                     s.east.z * c - s.north.z * sn)
                    sbasis.up:set(s.up.x, s.up.y, s.up.z)
                    sbasis.fwd:set(-(s.east.x * sn + s.north.x * c),
                                   -(s.east.y * sn + s.north.y * c),
                                   -(s.east.z * sn + s.north.z * c))
                    mat4.orthonormalize(sbasis.right, sbasis.up, sbasis.fwd)
                    s:toWorld(p.x, h, p.z, pos)
                    renderer:draw(built.model, pos, sbasis, { layer = renderer.LAYER_NEAR })
                    if built.glowModel then
                        renderer:draw(built.glowModel, pos, sbasis,
                            { layer = renderer.LAYER_NEAR, emissive = 1 })
                    end
                end
            end
        end
    end
end

function scene.submitStations(f, renderer)
    local IDENT = f._identBasis
    for _, st in ipairs(f.world.system.stations) do
        local mesh = f:stationMesh(st)
        local basis = st._basis or { right = vec3(), up = vec3(), fwd = vec3(0, 0, -1) }
        st._basis = basis
        local spin = st.spin or 0
        local axis = mesh.spin or { x = 0, y = 0, z = 1 }
        if axis.y == 1 then
            basis.right:set(math.cos(spin), 0, -math.sin(spin))
            basis.up:set(0, 1, 0)
            basis.fwd:set(-math.sin(spin), 0, -math.cos(spin))
        else
            basis.right:set(math.cos(spin), math.sin(spin), 0)
            basis.up:set(-math.sin(spin), math.cos(spin), 0)
            basis.fwd:set(0, 0, -1)
        end
        mat4.orthonormalize(basis.right, basis.up, basis.fwd)
        renderer:draw(mesh.model, st.pos, basis)
        if mesh.glowModel then
            renderer:draw(mesh.glowModel, st.pos, basis, { emissive = 1 })
        end
    end
end

function scene.submitShips(f, renderer)
    for _, e in ipairs(f.npcs) do
        if not e.dead then
            renderer:draw(e.shipDef.model, e.pos, e)
            -- engine glow scales with throttle
            local glow = util.clamp(e.throttle, 0, 1)
            if glow > 0.05 and e.engines then
                for _, en in ipairs(e.engines) do
                    local x = e.pos.x + e.right.x * en.x + e.up.x * en.y - e.fwd.x * en.z
                    local y = e.pos.y + e.right.y * en.x + e.up.y * en.y - e.fwd.y * en.z
                    local z = e.pos.z + e.right.z * en.x + e.up.z * en.y - e.fwd.z * en.z
                    renderer:drawAt(combat.boltMesh(C.engine), x, y, z, {
                        scale = en.radius * (0.6 + glow), additive = true, alpha = 0.5 * glow,
                    })
                end
            end
        end
    end

    -- the player's own ship, in chase view only
    if f.game.camera.mode ~= "cockpit" then
        renderer:draw(f.player.shipDef.model, f.ship.pos, f.ship)
        local glow = util.clamp(f.throttle, 0, 1) + (f.boosting and 0.6 or 0)
        if glow > 0.05 then
            for _, en in ipairs(f.player.shipDef.engines) do
                local s = f.ship
                local x = s.pos.x + s.right.x * en.x + s.up.x * en.y - s.fwd.x * en.z
                local y = s.pos.y + s.right.y * en.x + s.up.y * en.y - s.fwd.y * en.z
                local z = s.pos.z + s.right.z * en.x + s.up.z * en.y - s.fwd.z * en.z
                renderer:drawAt(combat.boltMesh(f.boosting and C.engineHot or C.engine), x, y, z, {
                    scale = en.radius * (0.7 + glow * 1.1), additive = true, alpha = 0.6,
                })
            end
        end
    end
end

--- Rain, snow or blown dust around the camera.
--
-- The whole field is one mesh moved as a unit: it is drawn centred on the
-- camera with an offset that wraps at the cube's own size, so it falls
-- continuously without a seam and without being rebuilt.
function scene.submitWeather(f, renderer, camera)
    local cond = f.weather
    if not cond or cond.strength < 0.15 then return end
    if cond.kind ~= "rain" and cond.kind ~= "snow" and cond.kind ~= "dust" then return end
    if not settings.q().scatter then return end

    local long = (cond.kind ~= "snow")
    local mesh = bodies.precipitation(long)
    if not mesh then return end

    local SIZE = bodies.PRECIP_SIZE
    -- fall speed, and the wind carrying it sideways
    local fall = (cond.kind == "snow") and 2.4 or (cond.kind == "dust" and 1.2 or 14)
    local drift = cond.wind * 0.6
    local t = f.time
    local function wrap(v) return v - math.floor(v / SIZE) * SIZE - SIZE * 0.5 end
    local ox = wrap(math.cos(cond.windAngle) * drift * t)
    local oy = wrap(-fall * t)
    local oz = wrap(math.sin(cond.windAngle) * drift * t)

    local TINT = {
        rain = { 0.62, 0.72, 0.88 },
        snow = { 0.95, 0.97, 1.0 },
        dust = { 0.78, 0.62, 0.40 },
    }
    local pos = f._precipPos or vec3()
    f._precipPos = pos
    pos:set(camera.pos.x + ox, camera.pos.y + oy, camera.pos.z + oz)
    renderer:draw(mesh, pos, nil, {
        additive = true, emissive = 1,
        tint = TINT[cond.kind],
        alpha = util.clamp(cond.strength * 0.85, 0, 1),
    })
end

--- Cargo canisters tumbling where a ship used to be.
function scene.submitCanisters(f, renderer)
    local list = f.canisters
    if #list == 0 then return end
    local mesh = bodies.canister()
    local basis = f._canBasis or { right = vec3(), up = vec3(0, 1, 0), fwd = vec3() }
    f._canBasis = basis
    for i = 1, #list do
        local c = list[i]
        local a = c.spin
        basis.right:set(math.cos(a), 0, -math.sin(a))
        basis.up:set(0, 1, 0)
        basis.fwd:set(-math.sin(a), 0, -math.cos(a))
        -- the beacon fades with the canister's remaining life, so a field of
        -- them reads as "hurry up" rather than as scenery
        local urgency = util.clamp(c.life / salvage.LIFETIME, 0, 1)
        renderer:draw(mesh, c.pos, basis, { scale = salvage.RADIUS })
        renderer:drawAt(combat.boltMesh(C.amber), c.pos.x, c.pos.y + salvage.RADIUS, c.pos.z, {
            scale = salvage.RADIUS * 0.32, additive = true,
            alpha = 0.35 + 0.45 * urgency, emissive = 1,
        })
    end
end

function scene.submitEffects(f, renderer)
    local arena = f.arena
    for i = 1, arena.nProjectiles do
        local p = arena.projectiles[i]
        local basis = p._basis or { right = vec3(), up = vec3(), fwd = vec3() }
        p._basis = basis
        basis.fwd:copyFrom(p.dir)
        basis.up:set(0, 1, 0)
        mat4.orthonormalize(basis.right, basis.up, basis.fwd)
        renderer:draw(combat.boltMesh(p.color), p.pos, basis, {
            scale = p.scale, additive = true, emissive = 1,
        })
    end
    for i = 1, arena.nEffects do
        local e = arena.effects[i]
        local t = 1 - (e.life / e.maxLife)
        if e.kind == "explosion" then
            local s = e.size * (0.4 + t * 1.6)
            renderer:draw(combat.debrisMesh(), e.pos, nil, {
                scale = s, additive = true, alpha = (1 - t) * 0.9, emissive = 1,
            })
            for _, sh in ipairs(e.shards or {}) do
                local d = t * sh[4] * 8
                renderer:drawAt(combat.debrisMesh(),
                    e.pos.x + sh[1] * d, e.pos.y + sh[2] * d, e.pos.z + sh[3] * d, {
                        scale = sh[4] * (1 - t), additive = true, alpha = (1 - t) * 0.8, emissive = 1,
                    })
            end
        else
            renderer:draw(combat.boltMesh(e.color), e.pos, nil, {
                scale = e.size * (0.5 + t * 1.4), additive = true, alpha = 1 - t, emissive = 1,
            })
        end
    end
end
return scene
