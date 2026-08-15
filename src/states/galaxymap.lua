-- The galaxy map.
--
-- Drawn in 2D on purpose: a projected top-down chart with a height rail for
-- the third axis is far easier to plot a route on than a rotating 3D cloud,
-- and it is what the genre's players expect.  Panning is unbounded, because
-- so is the galaxy.

local class = require("src.lib.class")
local util = require("src.lib.util")
local config = require("src.config")
local palette = require("src.render.palette")
local ui = require("src.ui.widgets")
local factions = require("src.sim.factions")
local i18n = require("src.i18n")
local commodities = require("src.sim.commodities")
local hud = require("src.render.hud")
local routeMod = require("src.sim.route")
local missionsMod = require("src.sim.missions")

local Map = class("GalaxyMapState")

local floor, min, max, sqrt = math.floor, math.min, math.max, math.sqrt
local C = palette.colors
local L = i18n.format

function Map:init()
    self.drawUnderlying = false
end

function Map:enter(flight)
    self.flight = flight
    self.world = self.game.world
    self.player = self.world.player
    local here = self.world.stub
    self.cx, self.cy, self.cz = here.x, here.y, here.z
    self.scale = 5.5                -- pixels per light year
    self.selected = here
    self.showRange = true
    self:refresh()
    self:findContracts()
    self:planRoute()
end

--- Systems the player has promised to reach, by id.
--
-- The chart knew nothing about the contracts in the hold, so a delivery to a
-- system four jumps away was a name in a list and a search on the map.
function Map:findContracts()
    local out = {}
    for _, m in ipairs(self.player.missions or {}) do
        if m.state == "active" and m.destSystemId then
            local list = out[m.destSystemId] or {}
            list[#list + 1] = m
            out[m.destSystemId] = list
        end
    end
    self.contracts = out
end

--- What this system's economy eats that the player is carrying.
--
-- Asked of the economy table, not of a market: building a market for every
-- star in view costs 0.11 ms each and there are a thousand of them, while
-- `consumes` is a table lookup and answers the same question -- who wants
-- this -- for nothing.
function Map:demandAt(s)
    local eco = commodities.economy(s.economyId)
    local out = {}
    for id in pairs(self.player.cargo or {}) do
        if (eco.consumes[id] or 0) > 0 then out[#out + 1] = id end
    end
    table.sort(out)
    return out
end

-- Filters dim what does not match rather than hiding it: a chart with holes
-- in it is a chart you cannot navigate by.
local FILTERS = { "none", "range", "demand", "lawful" }
local FILTER_NAME = {
    none = "ALL SYSTEMS", range = "IN RANGE", demand = "WANTS MY CARGO", lawful = "LAWFUL",
}

function Map:passesFilter(s, here)
    local f = FILTERS[self.filter or 1]
    if f == "none" then return true end
    if f == "range" then
        return (s.x - here.x) ^ 2 + (s.y - here.y) ^ 2 + (s.z - here.z) ^ 2
            <= self.jumpRange ^ 2
    end
    if f == "demand" then return (self.wantsCargo and self.wantsCargo[s.id]) == true end
    if f == "lawful" then return (s.lawLevel or 0) >= 0.6 end
    return true
end

--- Selects a system, replotting the course only when it really changed.
function Map:select(s)
    if not s or (self.selected and self.selected.id == s.id) then return end
    self.selected = s
    self:planRoute()
end

--- A course to the selection, however many jumps it takes.
--
-- The chart used to say "OUT OF JUMP RANGE" and stop there, which is the least
-- useful true thing it could say: a map exists for the places you cannot reach
-- directly. Plotted on selection rather than per frame -- the search is a few
-- milliseconds on a long haul.
function Map:planRoute()
    self.route, self.routeReason = nil, nil
    local s, here = self.selected, self.world.stub
    if not s or s.id == here.id then return end
    local world = self.world
    self.route, self.routeReason = routeMod.plan({
        galaxy = world.galaxy, from = here, to = s,
        jumpRange = self.jumpRange,
        fuelCost = function(d) return world:fuelCost(d) end,
    })
end

-- How far above and below the plane the chart looks.  The disc is thin, so
-- this covers everything reachable while keeping the sector sweep 2D-ish.
local SLAB = 44

function Map:refresh()
    local radius = min((love.graphics.getWidth() * 0.5) / self.scale + 20, 240)
    self.systems = self.world.galaxy:systemsNear(self.cx, self.cy, self.cz, radius, SLAB)
    self.jumpRange = self.player.stats.jumpRange or 10
    self:refreshDemand()
    self._viewKey = string.format("%.0f,%.0f,%.0f,%.3f", self.cx, self.cy, self.cz, self.scale)
end

--- Which systems in view would buy what is in the hold.
--
-- Recomputed with the visible set rather than per frame or per system drawn:
-- an empty hold skips it entirely, and a full one is a handful of table
-- lookups per star.
function Map:refreshDemand()
    local out = {}
    local cargo = self.player.cargo or {}
    if next(cargo) then
        for _, s in ipairs(self.systems) do
            local eco = commodities.economy(s.economyId)
            for id in pairs(cargo) do
                if (eco.consumes[id] or 0) > 0 then out[s.id] = true break end
            end
        end
    end
    self.wantsCargo = out
end

--- Rebuilds the visible set only when the view actually moved.
function Map:refreshIfMoved()
    local key = string.format("%.0f,%.0f,%.0f,%.3f", self.cx, self.cy, self.cz, self.scale)
    if key ~= self._viewKey then self:refresh() end
end

-- Where a system's *base* sits: its x/z projected onto the chart plane. This
-- is the foot of the height rail, not where the star is drawn.
function Map:screenOf(sys, w, h)
    local x = w * 0.5 + (sys.x - self.cx) * self.scale
    local y = h * 0.5 + (sys.z - self.cz) * self.scale
    return x, y
end

--- Where a system's marker is actually drawn: the base, lifted by its height
--- above the chart plane.
--
-- Everything that has to agree with what the player can see -- the hit test,
-- the labels, the range ring, the jump line -- has to use this. The click
-- test used `screenOf`, so the target was the foot of the rail and clicking
-- the circle itself missed by however tall the star stood.
function Map:dotOf(sys, w, h)
    local x, y = self:screenOf(sys, w, h)
    return x, y - (sys.y - self.cy) * self.scale
end

function Map:update(dt)
    self.world:update(dt)
    local pan = 90 / self.scale * dt * 60
    if love.keyboard.isDown("left", "a") then self.cx = self.cx - pan end
    if love.keyboard.isDown("right", "d") then self.cx = self.cx + pan end
    if love.keyboard.isDown("up", "w") then self.cz = self.cz - pan end
    if love.keyboard.isDown("down", "s") then self.cz = self.cz + pan end
    if love.keyboard.isDown("pageup") then self.cy = self.cy + pan end
    if love.keyboard.isDown("pagedown") then self.cy = self.cy - pan end
    self:refreshIfMoved()
end

function Map:nearestToCursor(w, h)
    local mx, my = love.mouse.getPosition()
    local best, bestD = nil, 26
    for _, s in ipairs(self.systems) do
        local x, y = self:dotOf(s, w, h)
        local d = sqrt((x - mx) ^ 2 + (y - my) ^ 2)
        if d < bestD then best, bestD = s, d end
    end
    return best
end

function Map:keypressed(key)
    if config.is("map", key) or config.is("pause", key) then
        self.manager:pop()
        return
    end
    if key == "return" or key == "space" then
        self:jump()
        return
    end
    if key == "=" or key == "+" or key == "kp+" then
        self.scale = min(self.scale * 1.35, 40)
        self:refresh()
    elseif key == "-" or key == "kp-" then
        self.scale = max(self.scale / 1.35, 0.4)
        self:refresh()
    elseif key == "home" then
        local here = self.world.stub
        self.cx, self.cy, self.cz = here.x, here.y, here.z
        self:select(here)
        self:refresh()
    elseif key == "c" then
        self:cycleContract()
    elseif key == "f" then
        self.filter = ((self.filter or 1) % #FILTERS) + 1
    elseif key == "r" then
        self.showRange = not self.showRange
    end
end

--- Centres the chart on the next system a contract is owed at.
--
-- Panning to a name read off the contracts list was the slowest thing the map
-- asked anyone to do, and it is the one thing the map already knows.
function Map:cycleContract()
    local ids = util.keys(self.contracts or {})
    if #ids == 0 then
        hud.message(L("No contracts to plot"), "warn")
        return
    end
    table.sort(ids)
    local at = 0
    for i, id in ipairs(ids) do
        if self.selected and self.selected.id == id then at = i end
    end
    local s = self.world.galaxy:byId(ids[(at % #ids) + 1])
    if not s then return end
    self.cx, self.cy, self.cz = s.x, s.y, s.z
    self:refresh()
    self:select(s)
end

function Map:mousepressed(x, y, button)
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    local s = self:nearestToCursor(w, h)
    if s then
        self:select(s)
        if button == 2 then self:jump() end
    end
end

function Map:wheelmoved(x, y)
    if y > 0 then self.scale = min(self.scale * 1.2, 40)
    elseif y < 0 then self.scale = max(self.scale / 1.2, 0.4) end
    self:refresh()
end

function Map:jump()
    local target = self.selected
    if not target or target.id == self.world.stub.id then
        hud.message("Already here", "warn")
        return
    end
    local ok, msg = self.world:jump(target)
    if ok then
        hud.message(msg, "good")
        self.manager:pop()
        if self.flight then
            self.flight.npcs = {}
            self.flight.stationMeshes = {}
            self.flight:leaveSurface()
            self.flight:spawn({})
            self.flight.target = nil
        end
    else
        hud.message(msg, "alert")
    end
end

function Map:draw()
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    love.graphics.clear(0.015, 0.02, 0.03, 1)

    local here = self.world.stub

    -- jump range ring around the current system
    if self.showRange then
        local hx, hy = self:dotOf(here, w, h)
        ui.setColor(C.uiPrimary, 0.16)
        love.graphics.circle("fill", hx, hy, self.jumpRange * self.scale)
        ui.setColor(C.uiPrimary, 0.5)
        love.graphics.circle("line", hx, hy, self.jumpRange * self.scale)
    end

    -- grid
    ui.setColor(C.uiLine, 0.10)
    local step = 10 * self.scale
    if step > 8 then
        local ox = (w * 0.5 - self.cx * self.scale) % step
        local oy = (h * 0.5 - self.cz * self.scale) % step
        for x = ox, w, step do love.graphics.line(x, 0, x, h) end
        for y = oy, h, step do love.graphics.line(0, y, w, y) end
    end

    -- systems
    local labels = {}
    for _, s in ipairs(self.systems) do
        local x, y = self:screenOf(s, w, h)
        if x > -20 and x < w + 20 and y > -20 and y < h + 20 then
            local faction = factions.get(s.factionId)
            local col = faction.color
            local dy = (s.y - self.cy)
            -- Height rail: the stalk that shows the third axis.
            --
            -- Drawn for every system in view, at a quarter opacity, this was
            -- a field of vertical streaks across the whole chart -- more ink
            -- than the stars themselves, and unreadable. The height only tells
            -- the player anything where it decides whether a system is
            -- reachable, so the rails are now on the current system, the
            -- selected one, and whatever is inside the jump range.
            local near = self.showRange
                and ((s.x - here.x) ^ 2 + (s.y - here.y) ^ 2 + (s.z - here.z) ^ 2)
                    < (self.jumpRange * 1.15) ^ 2
            if s.id == here.id or (self.selected and s.id == self.selected.id) or near then
                ui.setColor(C.uiLine, 0.35)
                love.graphics.line(x, y, x, y - dy * self.scale)
                ui.setColor(C.uiLine, 0.5)
                love.graphics.circle("fill", x, y, 1.5)
            end

            local r = util.clamp(2 + math.log(1 + s.population) * 0.22, 2, 8)
            local visited = self.player.knownSystems[s.id] ~= nil
            local shown = self:passesFilter(s, here)
            local alpha = (visited and 1 or 0.5) * (shown and 1 or 0.22)
            love.graphics.setColor(col[1], col[2], col[3], alpha)
            love.graphics.circle("fill", x, y - dy * self.scale, r)

            -- somewhere that eats what is in the hold: an open ring, which is
            -- the one mark on this chart that answers "where do I sell this"
            if shown and self.wantsCargo and self.wantsCargo[s.id] then
                ui.setColor(C.cyan, 0.8)
                love.graphics.circle("line", x, y - dy * self.scale, r + 4)
            end

            if s.id == here.id then
                ui.setColor(C.uiPrimary, 1)
                love.graphics.circle("line", x, y - dy * self.scale, r + 6)
                love.graphics.circle("line", x, y - dy * self.scale, r + 9)
            end
            if self.selected and s.id == self.selected.id then
                ui.setColor(C.uiWarn, 1)
                love.graphics.rectangle("line", x - r - 7, y - dy * self.scale - r - 7, (r + 7) * 2, (r + 7) * 2)
            end
            -- somewhere you owe someone something: a diamond, so it reads
            -- differently from the current system's rings and the selection box
            if self.contracts and self.contracts[s.id] then
                local cy = y - dy * self.scale
                local d = r + 11
                ui.setColor(C.amber, shown and 0.9 or 0.3)
                love.graphics.setLineWidth(1.4)
                love.graphics.polygon("line", x, cy - d, x + d, cy, x, cy + d, x - d, cy)
                love.graphics.setLineWidth(1)
            end
            -- Labels are collected, not drawn here. Printing one per system
            -- turned the chart into an unreadable wall of text the moment the
            -- view held more than a few dozen stars.
            if self.scale > 2.4 then
                labels[#labels + 1] = {
                    text = s.name, x = floor(x + r + 5), y = floor(y - dy * self.scale - 7),
                    col = col, alpha = (visited and 0.9 or 0.4) * (shown and 1 or 0.3),
                    rank = (s.id == here.id and 1e9 or 0)
                        + (self.selected and s.id == self.selected.id and 1e9 or 0)
                        + (self.contracts and self.contracts[s.id] and 1e8 or 0)
                        + (visited and 1e6 or 0) + (s.population or 0),
                }
            end
        end
    end

    self:drawLabels(labels, w, h)

    -- the course: every leg of it, not just the straight line to somewhere
    -- that may be four jumps away
    if self.selected and self.selected.id ~= here.id then
        local hx, hy = self:dotOf(here, w, h)
        love.graphics.setLineWidth(1)
        if self.route then
            local px, py = hx, hy
            -- over a field of a few thousand stars a hairline is not a course
            love.graphics.setLineWidth(1.6)
            ui.setColor(C.uiPrimary, 0.85)
            for i, s in ipairs(self.route.hops) do
                local x, y = self:dotOf(s, w, h)
                love.graphics.line(px, py, x, y)
                -- a stop on the way, drawn smaller than a selection
                if i < #self.route.hops then
                    love.graphics.circle("line", x, y, 4)
                end
                px, py = x, y
            end
        else
            local sx, sy = self:dotOf(self.selected, w, h)
            ui.setColor(C.uiDanger, 0.7)
            love.graphics.line(hx, hy, sx, sy)
        end
    end

    -- The chart furniture sits over the star field, so it gets a wash behind
    -- it; without one the hint line is read through a few hundred dots. Drawn
    -- before the info panel so it does not paint over it.
    love.graphics.setColor(0.015, 0.02, 0.03, 0.82)
    love.graphics.rectangle("fill", 0, 0, w, 84)
    love.graphics.rectangle("fill", 0, h - 68, w, 68)
    love.graphics.setColor(1, 1, 1, 1)

    -- info panel
    self:drawInfo(w - 372, 40, 332)

    ui.text(L("GALACTIC CHART"), 40, 30, C.uiPrimary, "large")
    ui.text(L("centre {x}, {y}, {z} ly     scale {scale} px/ly", {
        x = string.format("%.0f", self.cx), y = string.format("%.0f", self.cy),
        z = string.format("%.0f", self.cz), scale = string.format("%.1f", self.scale),
    }), 40, 62, C.uiDim, "small")
    -- the active filter has to be on screen: a chart where two thirds of the
    -- stars have gone dim, with nothing saying why, reads as a bug
    if (self.filter or 1) > 1 then
        -- on the header's own line: at y+80 it hung below the wash and read as
        -- a label lying loose on the star field
        ui.textRight(L(FILTER_NAME[FILTERS[self.filter]]), w - 400, 62, C.cyan, "small")
    end
    ui.rule(40, h - 60, w - 80, C.uiLine, 0.4)
    local fuel = L("FUEL") .. " " .. L("{a} / {b} t", {
        a = string.format("%.1f", self.player.fuel),
        b = string.format("%.1f", self.player.stats.fuel) })
    local fuelW = ui.font("small"):getWidth(fuel)
    ui.textFit(L("WASD pan   +/- zoom   F filter   C contracts   ENTER jump   TAB close"),
        40, h - 48, w - 100 - fuelW, C.uiDim, "small")
    ui.textRight(fuel, w - 40, h - 48, C.amber, "small")
end

--- Draws system labels, thinned so the chart stays readable.
--
-- Three rules, in order: never inside the header, footer or info panel;
-- never overlapping a label already placed; and never more than a fixed
-- budget, spending it on the systems that matter (current, selected, visited,
-- then populous).
local LABEL_BUDGET = 70

function Map:drawLabels(labels, w, h)
    if #labels == 0 then return end
    table.sort(labels, function(a, b) return a.rank > b.rank end)

    local font = ui.font("small")
    local lineH = font:getHeight()
    -- bands the chart furniture owns
    local headerH, footerY = 84, h - 68
    local panelX, panelY, panelH = w - 372, 40, 340

    local placed = {}
    local drawn = 0
    love.graphics.setFont(font)
    for _, l in ipairs(labels) do
        if drawn >= LABEL_BUDGET then break end
        local lw = font:getWidth(l.text)
        local x1, y1, x2, y2 = l.x, l.y, l.x + lw, l.y + lineH
        local blocked = y1 < headerH or y2 > footerY
            or (x2 > panelX and y1 < panelY + panelH and y2 > panelY)
            or x2 > w or x1 < 0
        if not blocked then
            for _, p in ipairs(placed) do
                if x1 < p[3] and x2 > p[1] and y1 < p[4] and y2 > p[2] then
                    blocked = true
                    break
                end
            end
        end
        if not blocked then
            placed[#placed + 1] = { x1 - 4, y1 - 2, x2 + 4, y2 + 2 }
            love.graphics.setColor(l.col[1], l.col[2], l.col[3], l.alpha)
            love.graphics.print(l.text, x1, y1)
            drawn = drawn + 1
        end
    end
    love.graphics.setColor(1, 1, 1, 1)
end

function Map:drawInfo(x, y, w)
    local s = self.selected
    if not s then return end
    -- height follows the content: the war list is variable, and a fixed 330
    -- meant three concurrent wars spilled out of the bottom of the panel
    local wars = 0
    for _, war in ipairs(self.world.diplomacy:activeWars()) do
        if war.a == s.factionId or war.b == s.factionId then wars = wars + 1 end
    end
    local contracts = (self.contracts and self.contracts[s.id]) or {}
    -- the course line and the contract list are both variable, and the panel
    -- has to be told about every line it will hold or the last one falls out
    local extra = (self.selected and self.selected.id ~= self.world.stub.id
        and sqrt((s.x - self.world.stub.x) ^ 2 + (s.y - self.world.stub.y) ^ 2
                 + (s.z - self.world.stub.z) ^ 2) > self.jumpRange) and 18 or 0
    local h = 310 + wars * 18 + extra + #contracts * 32
        + (#self:demandAt(s) > 0 and 18 or 0)
    ui.panel(x, y, w, h, L("SYSTEM"))
    local px, py = x + 18, y + 18
    ui.textFit(s.name, px, py, w - 36, C.uiPrimary, "large")
    py = py + 32

    local faction = factions.get(s.factionId)
    local dist = 0
    local here = self.world.stub
    dist = sqrt((s.x - here.x) ^ 2 + (s.y - here.y) ^ 2 + (s.z - here.z) ^ 2)
    local cost = self.world:fuelCost(dist)

    -- Beyond one jump the direct cost is a fiction -- it clamps at 24 t and
    -- reads as a flat contradiction of the course total printed below it.
    -- What the trip costs is what the legs cost.
    local outOfRange = dist > self.jumpRange
    local fuelShown = (outOfRange and self.route) and self.route.fuel or cost

    local rows = {
        { L("Distance"), L("{n} ly", { n = string.format("%.2f", dist) }) },
        { L("Fuel needed"), L("{n} t", { n = string.format("%.1f", fuelShown) }) },
        { L("Allegiance"), L(faction.name) },
        { L("Government"), L(s.governmentName) },
        { L("Economy"), L(s.economyName) },
        { L("Population"), util.money(s.population) },
        { L("Tech level"), tostring(s.techLevel) },
        { L("Security"), string.format("%.0f%%", s.lawLevel * 100) },
        { L("Star"), L("class {c}", { c = s.starClass }) },
        { L("Frontier"), string.format("%.0f%%", (s.frontier or 0) * 100) },
    }
    -- label and value share 296px; the value is measured first so a long
    -- faction or economy name shortens rather than collides
    for _, r in ipairs(rows) do
        local vw = math.min(ui.font("small"):getWidth(r[2]), (w - 36) * 0.6)
        ui.textRightFit(r[2], x + w - 18, py, vw, C.uiText, "small")
        ui.textFit(r[1], px, py, w - 36 - vw - 10, C.uiDim, "small")
        py = py + 18
    end

    py = py + 6
    if outOfRange then
        -- "out of range" on its own is a dead end; the course is the answer
        if self.route then
            ui.text(L("{n} {n:jump}, {t} t of fuel",
                { n = self.route.jumps, t = string.format("%.1f", self.route.fuel) }),
                px, py, C.uiPrimary, "small")
            py = py + 18
            ui.textFit(L("next: {name}", { name = self.route.hops[1].name }),
                px, py, w - 36, C.uiText, "small")
        else
            ui.text(L("OUT OF JUMP RANGE"), px, py, C.uiDanger, "small")
            py = py + 18
            ui.paragraph(L("No course: nothing within one jump leads there."),
                px, py, w - 36, C.uiDim, "small")
        end
    elseif cost > self.player.fuel then
        ui.text(L("NOT ENOUGH FUEL"), px, py, C.uiDanger, "small")
    elseif s.id == here.id then
        ui.text(L("CURRENT SYSTEM"), px, py, C.uiPrimary, "small")
    else
        ui.text(L("ENTER TO JUMP"), px, py, C.uiPrimary, "small")
    end
    py = py + 22

    -- war status
    local wars = self.world.diplomacy:activeWars()
    for _, war in ipairs(wars) do
        if war.a == s.factionId or war.b == s.factionId then
            local other = (war.a == s.factionId) and war.b or war.a
            ui.paragraph(L("At war with {faction:ins}", { faction = i18n.term(factions.get(other).name) }),
                px, py, w - 36, C.uiDanger, "small")
            py = py + 18
        end
    end
    local demand = self:demandAt(s)
    if #demand > 0 then
        local names = {}
        for i = 1, min(#demand, 3) do names[i] = L(commodities.get(demand[i]).name) end
        ui.textFit(L("Buys your {cargo}", { cargo = table.concat(names, ", ") }),
            px, py, w - 36, C.cyan, "small")
        py = py + 18
    end
    if self.player.knownSystems[s.id] then
        ui.text(L("Visited"), px, py, C.uiPrimary, "small")
    else
        ui.paragraph(L("Unvisited - long range survey"), px, py, w - 36, C.uiDim, "small")
    end
    py = py + 22

    -- what you promised, and by when
    if #contracts > 0 then
        ui.text(L("OWED HERE"), px, py, C.amber, "small")
        py = py + 18
        local day = self.world.day or 0
        for _, m in ipairs(contracts) do
            ui.textFit(missionsMod.title(m), px, py, w - 36, C.uiText, "small")
            py = py + 15
            local left = floor(max(0, (m.expires or day) - day))
            ui.textFit(L("{name} - {n} {n:day}", { name = m.destName or "?", n = left }),
                px + 8, py, w - 44, left <= 1 and C.uiWarn or C.uiDim, "small")
            py = py + 17
        end
    end
end

return Map
