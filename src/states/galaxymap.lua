-- The galaxy map.
--
-- Drawn in 2D on purpose: a projected top-down chart is far easier to plot a
-- route on than a rotating 3D cloud, and it is what the genre's players
-- expect.  Panning is unbounded, because so is the galaxy.
--
-- The third axis used to be drawn as a vertical rail under every star. Those
-- rails were the loudest marks on the chart and the stars were lost in them,
-- so the height now shows in the dot -- higher is nearer, so larger and
-- brighter -- and as a figure in the panel for the one system it matters for.

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
local rumoursMod = require("src.sim.rumours")

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
    -- what a bar told you, marked where it applies: this is the whole point of
    -- noting a lead, and without it the talk tab is a wall of text
    self.leads = rumoursMod.bySystem(self.player)
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

-- Where a system's *base* sits: its x/z projected onto the chart plane,
-- ignoring its height.
function Map:screenOf(sys, w, h)
    local x = w * 0.5 + (sys.x - self.cx) * self.scale
    local y = h * 0.5 + (sys.z - self.cz) * self.scale
    return x, y
end

--- Where a system's marker is actually drawn: the base, lifted by its height
--- above the chart plane.
--
-- Everything that has to agree with what the player can see -- the hit test,
-- the labels, the range ring, the course -- has to use this. The click test
-- used `screenOf`, so the target sat at the foot of the lift and clicking the
-- star itself missed by however far it stood off the plane.
function Map:dotOf(sys, w, h)
    local x, y = self:screenOf(sys, w, h)
    return x, y - (sys.y - self.cy) * self.scale
end

function Map:update(dt)
    self.world:update(dt)
    -- Keyboard panning stays, because a chart you can only drive with a mouse
    -- is a chart somebody cannot drive. It is the fallback now, not the way.
    local pan = 90 / self.scale * dt * 60
    if love.keyboard.isDown("left", "a") then self.cx = self.cx - pan end
    if love.keyboard.isDown("right", "d") then self.cx = self.cx + pan end
    if love.keyboard.isDown("up", "w") then self.cz = self.cz - pan end
    if love.keyboard.isDown("down", "s") then self.cz = self.cz + pan end
    if love.keyboard.isDown("pageup") then self.cy = self.cy + pan end
    if love.keyboard.isDown("pagedown") then self.cy = self.cy - pan end
    self:refreshIfMoved()
    self.hover = self:nearestToCursor(love.graphics.getWidth(), love.graphics.getHeight())
end

--- The star under the pointer, if the pointer is near enough to one.
--
-- The radius is in pixels rather than light years on purpose: what the player
-- is aiming at is a dot on a screen, and at low zoom a light year is a
-- fraction of one.
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

--- Zooms about a screen point rather than about the middle.
--
-- Wheel zoom that always works on the centre makes the player chase what they
-- were looking at: zoom in, lose it, pan back, zoom in again. Holding the
-- point under the cursor still is what every map made in the last twenty years
-- does, and it is the single biggest thing this screen was missing.
function Map:zoomAt(factor, px, py)
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    local before = self.scale
    self.scale = util.clamp(self.scale * factor, 0.4, 40)
    if self.scale == before then return end
    px = px or w * 0.5
    py = py or h * 0.5
    -- the light-year position under the cursor must not move: solve for the
    -- centre that keeps it fixed at the new scale
    local lx = self.cx + (px - w * 0.5) / before
    local lz = self.cz + (py - h * 0.5) / before
    self.cx = lx - (px - w * 0.5) / self.scale
    self.cz = lz - (py - h * 0.5) / self.scale
    self:refresh()
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
        self:zoomAt(1.35)
    elseif key == "-" or key == "kp-" then
        self:zoomAt(1 / 1.35)
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

-- Two clicks within this many seconds, on the same star, is a double click.
local DOUBLE_CLICK = 0.35

function Map:mousepressed(x, y, button)
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    local s = self:nearestToCursor(w, h)

    if button == 1 then
        if s then
            -- double click jumps, the way double click opens things
            local now = love.timer.getTime()
            if self._lastClickId == s.id and (now - (self._lastClickAt or 0)) < DOUBLE_CLICK then
                self:select(s)
                self:jump()
                return
            end
            self._lastClickId, self._lastClickAt = s.id, now
            self:select(s)
        end
        -- a press on empty space starts a drag; a press on a star selects it
        -- and may still turn into one, because a player who grabs the chart
        -- near a star still means to move the chart
        self.drag = { x = x, y = y, cx = self.cx, cz = self.cz, moved = 0 }
        return
    end

    if button == 3 then
        -- middle button: pan, the CAD convention, without losing the selection
        self.drag = { x = x, y = y, cx = self.cx, cz = self.cz, moved = 99 }
    end
end

function Map:mousereleased(x, y, button)
    self.drag = nil
end

function Map:mousemoved(x, y, dx, dy)
    local d = self.drag
    if not d then return end
    d.moved = d.moved + math.abs(dx) + math.abs(dy)
    -- Drag the chart under the cursor, one light year per light year: the map
    -- moves with the hand rather than the camera moving against it, which is
    -- the difference between dragging paper and driving a machine.
    self.cx = d.cx - (x - d.x) / self.scale
    self.cz = d.cz - (y - d.y) / self.scale
    self:refreshIfMoved()
end

function Map:wheelmoved(x, y)
    if y == 0 then return end
    local mx, my = love.mouse.getPosition()
    self:zoomAt(y > 0 and 1.2 or 1 / 1.2, mx, my)
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

    -- Grid, at whatever spacing keeps the lines readable.
    --
    -- It was fixed at 10 ly, so zoomed out it turned into a grey wash and
    -- zoomed in it vanished. Stepping through 5 / 10 / 25 / 50 / 100 keeps the
    -- squares between 30 and 150 px, and the spacing is printed with the scale
    -- bar so the grid is a ruler rather than decoration.
    local gridLy = 10
    for _, candidate in ipairs({ 5, 10, 25, 50, 100, 250 }) do
        gridLy = candidate
        if candidate * self.scale >= 60 then break end
    end
    self.gridLy = gridLy
    local step = gridLy * self.scale
    ui.setColor(C.uiLine, 0.08)
    if step > 8 then
        local ox = (w * 0.5 - self.cx * self.scale) % step
        local oy = (h * 0.5 - self.cz * self.scale) % step
        for x = ox, w, step do love.graphics.line(x, 0, x, h) end
        for y = oy, h, step do love.graphics.line(0, y, w, y) end
    end

    -- Systems.
    --
    -- The chart used to draw a vertical rail under every star to carry the
    -- third axis, and the rails were the loudest thing on it -- a field of
    -- streaks with the stars lost among them. The height is still in the
    -- drawing, because a star is plotted at its true projected position, but
    -- it is carried by the dot itself now: a star above the plane is drawn a
    -- touch larger and brighter than the same star below it, the way anything
    -- nearer the viewer is. The exact figure, for the one system anyone needs
    -- it for, is a line in the panel.
    local labels = {}
    local seen = { contract = 0, lead = 0, demand = 0 }
    for _, s in ipairs(self.systems) do
        local x, y = self:dotOf(s, w, h)
        if x > -20 and x < w + 20 and y > -20 and y < h + 20 then
            local faction = factions.get(s.factionId)
            local col = faction.color
            local visited = self.player.knownSystems[s.id] ~= nil
            local shown = self:passesFilter(s, here)

            -- height as depth: +-SLAB of lift maps to a quarter either way
            local lift = util.clamp((s.y - self.cy) / SLAB, -1, 1)
            local r = util.clamp(2 + math.log(1 + s.population) * 0.22, 2, 8) * (1 + lift * 0.25)
            local alpha = (visited and 1 or 0.5) * (shown and 1 or 0.22) * (1 + lift * 0.2)

            love.graphics.setColor(col[1], col[2], col[3], min(alpha, 1))
            love.graphics.circle("fill", x, y, r)

            -- Marks. One size for all of them regardless of the star under
            -- them, so three marks on one system stay three readable rings
            -- instead of a target.
            -- Only under its own filter.
            --
            -- Drawn always, this marked every economy that eats anything in
            -- the hold -- which at one tonne of grain was a third of the
            -- chart, a wash of rings worse than the rails they replaced. It is
            -- the answer to a question, so it appears when the question is
            -- asked.
            if shown and FILTERS[self.filter or 1] == "demand"
                and self.wantsCargo and self.wantsCargo[s.id] then
                ui.setColor(C.cyan, 0.75)
                love.graphics.circle("line", x, y, 7)
                seen.demand = seen.demand + 1
            end
            if self.leads and self.leads[s.id] then
                ui.setColor(C.magenta, shown and 0.95 or 0.3)
                love.graphics.line(x - 12, y - 5, x - 15, y, x - 12, y + 5)
                love.graphics.line(x + 12, y - 5, x + 15, y, x + 12, y + 5)
                seen.lead = seen.lead + 1
            end
            if self.contracts and self.contracts[s.id] then
                ui.setColor(C.amber, shown and 0.9 or 0.3)
                love.graphics.setLineWidth(1.4)
                love.graphics.polygon("line", x, y - 13, x + 13, y, x, y + 13, x - 13, y)
                love.graphics.setLineWidth(1)
                seen.contract = seen.contract + 1
            end

            if s.id == here.id then
                ui.setColor(C.uiPrimary, 0.9)
                love.graphics.circle("line", x, y, 16)
            end
            if self.hover and s.id == self.hover.id
                and not (self.selected and s.id == self.selected.id) then
                -- the pointer is over this one: say so before it is clicked,
                -- because a chart of two thousand identical dots gives no other
                -- clue that clicking will hit the one you mean
                ui.setColor(C.uiText, 0.7)
                love.graphics.circle("line", x, y, r + 5)
            end
            if self.selected and s.id == self.selected.id then
                -- corners rather than a box: the star stays visible inside its
                -- own selection, the same reason the flight HUD stopped
                -- drawing cages round its contacts
                ui.setColor(C.uiWarn, 1)
                local d, arm = 19, 7
                for _, c in ipairs({ { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } }) do
                    love.graphics.line(x + c[1] * d, y + c[2] * d,
                        x + c[1] * (d - arm), y + c[2] * d)
                    love.graphics.line(x + c[1] * d, y + c[2] * d,
                        x + c[1] * d, y + c[2] * (d - arm))
                end
            end

            -- Labels are collected, not drawn here. Printing one per system
            -- turned the chart into an unreadable wall of text the moment the
            -- view held more than a few dozen stars.
            if self.scale > 2.4 then
                labels[#labels + 1] = {
                    text = s.name, x = floor(x + r + 6), y = floor(y - 7),
                    col = col, alpha = (visited and 0.9 or 0.4) * (shown and 1 or 0.3),
                    rank = (s.id == here.id and 1e9 or 0)
                        + (self.selected and s.id == self.selected.id and 1e9 or 0)
                        + (self.contracts and self.contracts[s.id] and 1e8 or 0)
                        + (self.leads and self.leads[s.id] and 1e7 or 0)
                        + (visited and 1e6 or 0) + (s.population or 0),
                }
            end
        end
    end

    self.seenMarks = seen
    self:drawLabels(labels, w, h)

    -- The hovered star's name, drawn after the thinning and regardless of it:
    -- the one label the player has actually asked for is the one they must
    -- always get.
    if self.hover then
        -- A tooltip rather than just a name: sweeping the pointer over the
        -- chart should answer "what is that, and can I get there" without a
        -- click and without replotting a course for every star passed over.
        local s = self.hover
        local hx, hy = self:dotOf(s, w, h)
        local d = sqrt((s.x - here.x) ^ 2 + (s.y - here.y) ^ 2 + (s.z - here.z) ^ 2)
        local rows = {
            { s.name, C.uiText },
            { L("{n} ly", { n = string.format("%.2f", d) }),
              d <= self.jumpRange and C.uiPrimary or C.uiDim },
            { L(s.economyName), C.uiDim },
        }
        local font = ui.font("small")
        local tw = 0
        for _, r in ipairs(rows) do tw = max(tw, font:getWidth(r[1])) end
        tw = tw + 16
        local th = #rows * 16 + 8
        -- Flipped to the other side rather than run off the edge -- and the
        -- info panel counts as an edge, because a tooltip laid over the panel
        -- makes both of them unreadable.
        local tx = hx + 14
        if tx + tw > w - 380 then tx = hx - 14 - tw end
        if tx < 20 then tx = 20 end
        local ty = min(hy - 12, h - 100 - th)
        love.graphics.setColor(0.015, 0.02, 0.03, 0.88)
        love.graphics.rectangle("fill", tx, ty, tw, th)
        ui.setColor(C.uiLine, 0.5)
        love.graphics.rectangle("line", tx, ty, tw, th)
        for i, r in ipairs(rows) do
            ui.text(r[1], tx + 8, ty + 4 + (i - 1) * 16, r[2], "small")
        end
    end

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
    -- the wash has to cover the scale bar too, or the ruler is read through a
    -- few hundred stars
    love.graphics.rectangle("fill", 0, h - 92, w, 92)
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
    -- Legend, for the marks that are actually on screen.
    --
    -- A diamond, a pair of brackets and a ring are not guessable, and a legend
    -- listing every mark the chart *can* draw is furniture. This names the ones
    -- in front of the player and nothing else, so it disappears when there is
    -- nothing to explain.
    do
        local seenMarks = self.seenMarks or {}
        local ly = h - 116
        local function entry(kind, text, col)
            if (seenMarks[kind] or 0) == 0 then return end
            love.graphics.setColor(0.015, 0.02, 0.03, 0.8)
            local tw = ui.font("small"):getWidth(L(text)) + 34
            love.graphics.rectangle("fill", 36, ly - 3, tw, 18)
            ui.setColor(col, 0.9)
            if kind == "contract" then
                love.graphics.polygon("line", 46, ly + 1, 52, ly + 7, 46, ly + 13, 40, ly + 7)
            elseif kind == "lead" then
                love.graphics.line(43, ly + 2, 40, ly + 7, 43, ly + 12)
                love.graphics.line(49, ly + 2, 52, ly + 7, 49, ly + 12)
            else
                love.graphics.circle("line", 46, ly + 7, 6)
            end
            ui.text(L(text), 62, ly, C.uiDim, "small")
            ly = ly - 20
        end
        entry("demand", "buys your cargo", C.cyan)
        entry("lead", "someone mentioned it", C.magenta)
        entry("contract", "contract due here", C.amber)
    end

    -- Scale bar: one grid square, labelled. A chart without one leaves the
    -- player guessing how far a gap is, which is the question the chart exists
    -- to answer.
    do
        local barLen = (self.gridLy or 10) * self.scale
        local bx, by = 40, h - 76
        ui.setColor(C.uiDim, 0.9)
        love.graphics.line(bx, by, bx + barLen, by)
        love.graphics.line(bx, by - 4, bx, by + 4)
        love.graphics.line(bx + barLen, by - 4, bx + barLen, by + 4)
        ui.text(L("{n} ly", { n = tostring(self.gridLy or 10) }), bx + barLen + 8, by - 8,
            C.uiDim, "small")
    end

    ui.rule(40, h - 60, w - 80, C.uiLine, 0.4)
    local fuel = L("FUEL") .. " " .. L("{a} / {b} t", {
        a = string.format("%.1f", self.player.fuel),
        b = string.format("%.1f", self.player.stats.fuel) })
    local fuelW = ui.font("small"):getWidth(fuel)
    ui.textFit(L("DRAG pan   WHEEL zoom   CLICK select   DOUBLE-CLICK jump   F filter   C contracts   TAB close"),
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
    local headerH, footerY = 84, h - 92
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
    local h = 330 + wars * 18 + extra + #contracts * 34
        + (#self:demandAt(s) > 0 and 18 or 0)
        + #((self.leads and self.leads[s.id]) or {}) * 34
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
        { L("Height"), L("{n} ly", { n = string.format("%+.2f", s.y - here.y) }) },
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

    -- what you were told about this place
    local leads = (self.leads and self.leads[s.id]) or {}
    for _, lead in ipairs(leads) do
        py = py + ui.paragraph(rumoursMod.line(lead), px, py, w - 36, C.magenta, "small") + 4
    end

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
