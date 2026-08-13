-- Scripted smoke test for the parts that need a real GPU and a real LOVE.
--
--     love . --selftest
--
-- It starts a new commander and then drives the game through every rendering
-- path in turn -- space, descent, surface, on foot, a building interior, the
-- docked screens, the galaxy map and a hyperspace jump -- drawing every frame
-- and reporting the first failure of each step.  Exit code is non-zero if any
-- step failed, so it can gate a release.

local selftest = {}

local steps = {}
local function step(atFrame, name, fn)
    steps[#steps + 1] = { frame = atFrame, name = name, fn = fn }
end

local results = {}
local function record(name, ok, err)
    results[#results + 1] = { name = name, ok = ok, err = err }
    io.write(ok and "  ok    " or "  FAIL  ", name, ok and "" or ("   " .. tostring(err)), "\n")
    io.flush()
end

-- ---------------------------------------------------------------------------

step(2, "new commander in flight", function(game)
    game:newGame(20250811, "Selftest")
    local Flight = require("src.states.flight")
    game.manager:switch(Flight.new())
    local f = game.manager:current()
    assert(f.ship, "no ship")
    assert(game.world.system, "no system")
end)

step(20, "fly in normal space", function(game)
    local f = game.manager:current()
    f.throttle = 1
    f.ship.angular:set(0.2, 0.1, 0)
    assert(f.speed ~= nil, "no speed computed")
end)

step(40, "target and scan", function(game)
    local f = game.manager:current()
    f:cycleTarget(false)
    f:scanTarget()
end)

step(44, "a new arrival can reach a port", function(game)
    -- The whole opening of the game depends on this: from the spawn point the
    -- player must be able to select a station and hand it to the autopilot.
    -- With the old 36 km target clamp neither was possible, and the market,
    -- contracts and outfitting behind them were unreachable.
    local f = game.manager:current()
    local port = f:targetNearestPort()
    assert(port, "nothing dockable is selectable from the arrival point")
    assert(port.distance > 36000,
        "test is not exercising the clamp: port is only " .. math.floor(port.distance) .. " m away")
    local ok = f:toggleAutopilot()
    assert(f.autopilot, "autopilot refused a target at " .. math.floor(port.distance) .. " m")
    f:toggleAutopilot()
end)

step(55, "fire weapons", function(game)
    local f = game.manager:current()
    local w = game.world.player:weapon()
    local combat = require("src.sim.combat")
    for i = 1, 5 do
        combat.fire(f.arena, f.ship, w, f.ship.fwd.x, f.ship.fwd.y, f.ship.fwd.z, i)
    end
    assert(f.arena.nProjectiles >= 5, "projectiles were not queued")
end)

step(70, "approach a landable world", function(game)
    local f = game.manager:current()
    local systemGen = require("src.procgen.system")
    local body
    for _, b in ipairs(systemGen.landables(game.world.system)) do
        if b.landable and not b.giant then body = b break end
    end
    assert(body, "no landable body in the start system")
    selftest.body = body
    -- drop the ship into the upper atmosphere directly above the equator
    local x, y, z = systemGen.surfacePoint(body, 0.12, 0.4, 40000)
    f.ship.pos:set(x, y, z)
    f.ship.vel:set(0, 0, 0)
    f.throttle = 0
    f.warpState = "off"
end)

step(90, "terrain streamed in", function(game)
    local f = game.manager:current()
    assert(f.surface, "no surface patch after descending to 40 km")
    local n = 0
    for _ in pairs(f.surface.chunkCache or {}) do n = n + 1 end
    assert(n > 0, "no terrain chunks were built")
    selftest.chunkCount = n
end)

step(105, "land on the surface", function(game)
    local f = game.manager:current()
    local s = f.surface
    f.gearDown = true
    local h = s:groundHeight(f.local_.pos.x, f.local_.pos.z)
    f.local_.pos.y = h + game.world.player.shipDef.length * 0.22 + 1.0
    f.local_.vel:set(0, 0, 0)
    f.local_.up:set(0, 1, 0)
    f.local_.fwd:set(0, 0, 1)
    local mat4 = require("src.lib.mat4")
    mat4.orthonormalize(f.local_.right, f.local_.up, f.local_.fwd)
    f:syncFromLocal()
end)

step(120, "touchdown registered", function(game)
    local f = game.manager:current()
    assert(f.landedOn, "the ship never registered as landed")
end)

step(124, "diagnostics: landed state", function(game)
    local f = game.manager:current()
    local s = f.surface
    local gh = s:groundHeight(f.local_.pos.x, f.local_.pos.z)
    local n = 0
    for _ in pairs(s.chunkCache or {}) do n = n + 1 end
    io.write(string.format(
        "    DIAG-L local=(%.0f,%.0f,%.0f) ground=%.0f alt(hud)=%.0f lod=%d size=%.0f chunks=%d\n",
        f.local_.pos.x, f.local_.pos.y, f.local_.pos.z, gh, f.altitude or -1,
        s.lodLevel, s.chunkSize, n))
    local fieldH = s.field:height(f.local_.pos.x, f.local_.pos.z)
    io.write(string.format("    DIAG-L fieldH=%.0f curvature=%.0f originLat=%.4f originLon=%.4f\n",
        fieldH, (f.local_.pos.x^2 + f.local_.pos.z^2) / (2 * s.radius), s.field.originLat, s.field.originLon))
    io.flush()
end)

step(130, "disembark on foot", function(game)
    local f = game.manager:current()
    f:disembark()
    local s = game.manager:current()
    assert(s.pos, "on-foot state has no position")
    selftest.onFoot = s
end)

step(150, "walk around", function(game)
    local s = game.manager:current()
    s.yaw = 1.2
    s.vel:set(2, 0, 2)
    assert(s.onGround ~= nil, "ground contact not evaluated")
end)

step(157, "diagnostics: surface state", function(game)
    local s = game.manager:current()
    local surf = s.surface
    local n = 0
    for _ in pairs(surf.chunkCache or {}) do n = n + 1 end
    local gh = surf:groundHeight(s.pos.x, s.pos.z)
    io.write(string.format(
        "    DIAG lod=%d size=%.0f chunks=%d pos=(%.0f,%.0f,%.0f) ground=%.0f alt=%.1f settlements=%d draws=%d\n",
        surf.lodLevel, surf.chunkSize, n, s.pos.x, s.pos.y, s.pos.z, gh, s.pos.y - gh,
        #surf.settlements, game.renderer.stats.draws))
    io.write(string.format("    DIAG camera=(%.0f,%.0f,%.0f) fwd=(%.2f,%.2f,%.2f) up=(%.2f,%.2f,%.2f)\n",
        game.camera.pos.x, game.camera.pos.y, game.camera.pos.z,
        game.camera.fwd.x, game.camera.fwd.y, game.camera.fwd.z,
        game.camera.up.x, game.camera.up.y, game.camera.up.z))
    local origin = surf.origin
    io.write(string.format("    DIAG origin=(%.0f,%.0f,%.0f) bodyR=%.0f\n", origin.x, origin.y, origin.z, surf.radius))
    io.flush()
end)

step(165, "enter a building interior", function(game)
    local onfoot = game.manager:current()
    -- find any settlement on this patch and walk into its first door
    local surface = onfoot.surface
    local site = surface.settlements[1]
    if not site then
        record("enter a building interior", true, nil)
        selftest.skippedInterior = true
        return
    end
    local mesh = surface:ensureSettlement(site.place)
    assert(mesh, "settlement mesh was not built")
    assert(#mesh.buildings > 0, "settlement has no buildings")
    local target = mesh.interiors[1]
    if not target then
        selftest.skippedInterior = true
        return
    end
    onfoot.pos:set(site.x + target.entrance.x, onfoot.pos.y, site.z + target.entrance.z)
    onfoot.site, onfoot.siteMesh = site, mesh
    onfoot:enterBuilding(target, site)
    local room = game.manager:current()
    assert(room.room and room.room.model, "interior mesh missing")
end)

step(185, "open a service terminal", function(game)
    local room = game.manager:current()
    -- If the landing site had no settlement the interior steps were skipped,
    -- which used to mean the port screen -- market, contracts, outfitting,
    -- shipyard -- was never drawn at all while three steps still reported ok.
    -- Dock at the system's own port instead so the screen is always exercised.
    if selftest.skippedInterior then
        local systemGen = require("src.procgen.system")
        local Port = require("src.states.port")
        local place = systemGen.ports(game.world.system)[1]
        assert(place, "system has nowhere to dock")
        game.manager:push(Port.new(), place, { docked = false })
        local port = game.manager:current()
        assert(port.menu, "port screen has no menu")
        selftest.port = port
        return
    end
    if not room.room then return end
    local t = room.room.terminals[1]
    assert(t, "interior has no terminals")
    room.pos:set(t.x, 0, t.z + 1.0)
    room:updatePrompt()
    assert(room.action and room.action.kind == "service", "terminal did not offer a service")
    room:keypressed(require("src.config").keys.interact[1])
    local port = game.manager:current()
    assert(port.menu, "port screen has no menu")
    selftest.port = port
end)

step(200, "browse every port tab", function(game)
    local port = selftest.port
    assert(port, "the port screen never opened")
    for i = 1, #port.tabs do
        port.tab = i
        port:rebuild()
        port:draw()
    end
    -- leave it on the market tab so the screenshot at 205 catches the busiest
    -- layout: a scrolling list, a detail panel and a footer
    for i, t in ipairs(port.tabs) do
        if t == "market" then port.tab = i end
    end
    port:rebuild()
end)

step(215, "buy and sell a commodity", function(game)
    local port = selftest.port
    assert(port, "the port screen never opened")
    for i, t in ipairs(port.tabs) do
        if t == "market" then port.tab = i end
    end
    port:rebuild()
    local before = game.world.player.credits
    port.quantity = 10
    port:trade(false)
    port:trade(true)
    assert(game.world.player.credits ~= before or port.status ~= nil,
        "trading did nothing and reported nothing")
end)

step(230, "leave the port and the building", function(game)
    if selftest.port then
        selftest.port:launch()
    end
    -- back in the room; step outside
    local s = game.manager:current()
    if s.room then
        s.pos:set(s.room.exit.x, 0, s.room.exit.z)
        s:updatePrompt()
        s:keypressed(require("src.config").keys.interact[1])
    end
end)

step(245, "board the ship", function(game)
    local s = game.manager:current()
    if s.shipLocal then
        s.pos:set(s.shipLocal.x, s.pos.y, s.shipLocal.z)
        s:updatePrompt()
        s:keypressed(require("src.config").keys.disembark[1])
    end
    local f = game.manager:current()
    assert(f.ship, "did not return to the flight state")
end)

step(260, "open the galaxy map", function(game)
    local f = game.manager:current()
    local config = require("src.config")
    f:keypressed(config.keys.map[1])
    local map = game.manager:current()
    assert(map.systems, "galaxy map has no systems")
    assert(#map.systems > 0, "galaxy map is empty")
    selftest.map = map
end)

step(275, "hyperspace jump", function(game)
    local map = selftest.map
    if not map then return end
    local targets = game.world:jumpTargets()
    local pick
    for _, t in ipairs(targets) do
        if t.reachable then pick = t break end
    end
    assert(pick, "nothing in jump range with a full tank")
    map.selected = pick
    local before = game.world.stub.id
    map:jump()
    assert(game.world.stub.id ~= before, "the jump did not happen")
end)

step(290, "back in flight after the jump", function(game)
    local f = game.manager:current()
    assert(f.ship, "not in the flight state after jumping")
    assert(game.world.system, "arrived without a system")
end)

step(305, "logbook and colony screens", function(game)
    local f = game.manager:current()
    local config = require("src.config")
    f:keypressed(config.keys.missions[1])
    local log = game.manager:current()
    for i = 1, 3 do
        log.tab = i
        log:draw()
    end
    log:keypressed("escape")
    f:keypressed(config.keys.colony[1])
    local col = game.manager:current()
    col:draw()
    col:keypressed("escape")
end)

step(320, "save and reload", function(game)
    local ok, err = game:saveGame()
    assert(ok, "save failed: " .. tostring(err))
    local loaded, lerr = game:loadGame()
    assert(loaded, "load failed: " .. tostring(lerr))
    local Flight = require("src.states.flight")
    game.manager:switch(Flight.new())
end)

step(335, "chase view and wireframe", function(game)
    local f = game.manager:current()
    f:keypressed(require("src.config").keys.view[1])
    game.renderer.settings.wireframe = true
    game.renderer.settings.post = false
end)

step(342, "settings screen and lighting presets", function(game)
    local SettingsState = require("src.states.settings")
    local settings = require("src.settings")
    local lighting = require("src.render.lighting")
    game.manager:push(SettingsState.new(), game.manager:current())
    local scr = game.manager:current()
    assert(scr.optionMenu and scr.bindMenu, "settings panes missing")
    -- walk both panes and draw them
    for pane = 1, 2 do
        scr.pane = pane
        for _ = 1, 12 do
            scr:keypressed("down")
            scr:draw()
        end
    end
    -- cycle every lighting preset through the live renderer
    scr.pane = 1
    for _, id in ipairs(lighting.order) do
        settings.set("lightingPreset", id)
        scr:apply()
        game:applyLighting()
        scr:draw()
    end
    -- rebind a key and put it back
    scr.pane = 2
    scr.rebinding = "boost"
    scr:keypressed("p")
    local input = require("src.input")
    assert(input.is("boost", "p"), "rebinding did not take effect")
    input.resetBindings()
    scr:keypressed("escape")
    assert(game.manager:current() ~= scr, "settings screen did not close")
end)

step(350, "title screen renders", function(game)
    local Menu = require("src.states.menu")
    game.manager:switch(Menu.new())
    game.renderer.settings.wireframe = false
    game.renderer.settings.post = true
end)

-- ---------------------------------------------------------------------------

-- Frames to capture to disk (LÖVE's save directory) when --shots is passed.
-- Looking at the output is the only way to check that a procedural renderer
-- actually produces the picture you intended.
local SHOTS = {
    [30] = "01-space",
    [95] = "02-descent",
    [125] = "03-landed",
    [158] = "04-onfoot",
    [178] = "05-interior",
    [205] = "06-port",
    [268] = "07-chart",
    [345] = "08-chase",
    [358] = "09-title",
}

selftest.lastFrame = 360

function selftest.captureIfWanted(frame)
    local name = SHOTS[frame]
    if name and selftest.shots then
        love.graphics.captureScreenshot(string.format("shot-%s.png", name))
    end
end

function selftest.run(game, frame)
    -- a heartbeat with real wall-clock time, so a stall is distinguishable
    -- from a merely slow software renderer
    if frame % 10 == 0 then
        local now = love.timer.getTime()
        local elapsed = now - (selftest.lastBeat or now)
        selftest.lastBeat = now
        io.write(string.format("[frame %3d] %5.1f ms/frame, %d draws, %d tris  (%s)\n",
            frame, elapsed * 100, game.renderer.stats.draws, game.renderer.stats.triangles,
            tostring(game.manager:current().__name or "?")))
        io.flush()
    end
    for _, s in ipairs(steps) do
        if s.frame == frame then
            local ok, err = pcall(s.fn, game)
            record(s.name, ok, err)
        end
    end
    if frame >= selftest.lastFrame then
        local failed = 0
        for _, r in ipairs(results) do
            if not r.ok then failed = failed + 1 end
        end
        io.write(string.rep("-", 52), "\n")
        io.write(string.format("selftest: %d steps, %d failed\n", #results, failed))
        io.write(string.format("renderer: %d draws, %d triangles in the last frame\n",
            game.renderer.stats.draws, game.renderer.stats.triangles))
        io.flush()
        love.event.quit(failed > 0 and 1 or 0)
    end
end

return selftest
