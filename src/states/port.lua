-- The docked screen: everything you can do at a station, a settlement or one
-- of your own colonies.
--
-- One state serves all of them because a port is just a bundle of services.
-- The tabs available are whatever the place actually offers, so a mining
-- outpost really does have fewer options than a core world.

local class = require("src.lib.class")
local util = require("src.lib.util")
local config = require("src.config")
local palette = require("src.render.palette")
local ui = require("src.ui.widgets")
local commodities = require("src.sim.commodities")
local equipment = require("src.sim.equipment")
local missionsMod = require("src.sim.missions")
local colonyMod = require("src.sim.colony")
local factions = require("src.sim.factions")
local i18n = require("src.i18n")
local layout = require("src.port.layout")
local summary = require("src.port.summary")
local market = require("src.port.market")
local missions = require("src.port.missions")
local outfitting = require("src.port.outfitting")
local shipyard = require("src.port.shipyard")
local colony = require("src.port.colony")
local talk = require("src.port.talk")

local Port = class("PortState")

local C = palette.colors
local L = i18n.format
local floor, min, max = math.floor, math.min, math.max


local TAB_ORDER = { "summary", "market", "blackMarket", "missions", "talk", "outfitting", "shipyard", "colony" }
-- Tab captions are looked up at draw time rather than stored, so switching
-- language re-labels the screen without rebuilding the state.
local TAB_NAME = {
    summary = "OVERVIEW", market = "MARKET", blackMarket = "BLACK MARKET",
    missions = "CONTRACTS", talk = "LOCAL TALK", outfitting = "OUTFITTING",
    shipyard = "SHIPYARD", colony = "COLONY",
}

function Port:init()
    self.drawUnderlying = false
end

--- opts: { flight = FlightState, docked = true when arrived by ship,
---         service = tab to open on a terminal }
function Port:enter(place, opts)
    opts = opts or {}
    local initialTab = opts.service
    self.place = place
    self.flight = opts.flight
    self.docked = opts.docked or false
    self.world = self.game.world
    self.player = self.world.player
    self.quantity = 1
    self.status = nil

    self.market = self.world:market(place)
    self.world:restoreMarket(place, self.market)

    self.tabs = { "summary" }
    local svc = place.services or {}
    if svc.market ~= false then self.tabs[#self.tabs + 1] = "market" end
    if svc.blackMarket or place.blackMarket then self.tabs[#self.tabs + 1] = "blackMarket" end
    if svc.missions then self.tabs[#self.tabs + 1] = "missions" end
    -- anywhere with people in it has people talking; a derelict does not
    if (place.population or 0) > 0 then self.tabs[#self.tabs + 1] = "talk" end
    if svc.outfitting then self.tabs[#self.tabs + 1] = "outfitting" end
    if svc.shipyard then self.tabs[#self.tabs + 1] = "shipyard" end
    if place.colony then self.tabs[#self.tabs + 1] = "colony" end

    self.tab = 1
    if initialTab then
        for i, t in ipairs(self.tabs) do
            if t == initialTab or (initialTab == "refuel" and t == "summary")
                or (initialTab == "repair" and t == "summary")
                or (initialTab == "rumours" and t == "talk")
                or (initialTab == "navdata" and t == "summary") then
                self.tab = i
                break
            end
        end
    end

    self.completed = nil
    if not self.arrived then
        self.arrived = true
        local completed, seized, fine = self.world:onDock(place)
        self.completed = completed
        if seized then
            local n = 0
            for _, g in ipairs(seized) do n = n + g.qty end
            self:say(L("Customs seized {n} {n:t}. Fine {cash} cr.",
                { n = n, cash = util.money(fine) }), true)
        end
    end
    self:rebuild()
end

function Port:currentTab() return self.tabs[self.tab] end

function Port:rebuild()
    local tab = self:currentTab()
    if tab == "market" or tab == "blackMarket" then
        self:buildMarketMenu(tab == "blackMarket")
    elseif tab == "missions" then
        self:buildMissionMenu()
    elseif tab == "outfitting" then
        self:buildOutfitMenu()
    elseif tab == "shipyard" then
        self:buildShipyardMenu()
    elseif tab == "talk" then
        self:buildTalkMenu()
    elseif tab == "colony" then
        self:buildColonyMenu()
    else
        self:buildSummaryMenu()
    end
end

-- ---------------------------------------------------------------------------
-- Tabs
-- ---------------------------------------------------------------------------

-- Each tab builds its own menu and owns its own actions, in src/port/*.lua.
-- What is left here is the frame around them: which tabs a place offers, which
-- one is open, and the drawing that is the same on all of them.

function Port:buildSummaryMenu() return summary.buildSummaryMenu(self) end
function Port:buildMarketMenu(black) return market.buildMarketMenu(self, black) end
function Port:buildMissionMenu() return missions.buildMissionMenu(self) end
function Port:buildOutfitMenu() return outfitting.buildOutfitMenu(self) end
function Port:buildShipyardMenu() return shipyard.buildShipyardMenu(self) end
function Port:buildColonyMenu() return colony.buildColonyMenu(self) end
function Port:buildTalkMenu() return talk.buildTalkMenu(self) end

function Port:trade(sell) return market.trade(self, sell) end
function Port:acceptMission() return missions.acceptMission(self) end
function Port:toggleModule() return outfitting.toggleModule(self) end
function Port:buyShip() return shipyard.buyShip(self) end
function Port:noteRumour() return talk.note(self) end








-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

function Port:say(text, bad)
    self.status = { text = text, bad = bad, life = 4 }
end

--- Closes the screen.  Only a visit that arrived by ship launches one: a
--- terminal reached on foot just puts the player back in the room.
function Port:launch()
    self.manager:pop()
    if not self.docked or not self.flight then return end
    self.world:onLaunch()
    if self.place.kind == "station" then
        self.flight:spawn({ atPort = self.place })
    else
        self.flight:spawn({ atSurface = { place = self.place, body = self.place.body } })
    end
end





-- ---------------------------------------------------------------------------
-- Input
-- ---------------------------------------------------------------------------

function Port:keypressed(key)
    if config.is("pause", key) then self:launch() return end
    if key == "left" or key == "q" then
        self.tab = ((self.tab - 2) % #self.tabs) + 1
        self:rebuild()
        return
    end
    if key == "right" or key == "e" then
        self.tab = (self.tab % #self.tabs) + 1
        self:rebuild()
        return
    end
    if key == "1" then self.quantity = 1 return end
    if key == "2" then self.quantity = 10 return end
    if key == "3" then self.quantity = 100 return end
    if key == "4" then self.quantity = "max" return end

    local tab = self:currentTab()
    if tab == "market" or tab == "blackMarket" then
        if key == "b" or key == "return" or key == "space" then self:trade(false) return end
        if key == "n" or key == "backspace" then self:trade(true) return end
    elseif tab == "missions" then
        if key == "return" or key == "space" then self:acceptMission() return end
    elseif tab == "outfitting" then
        if key == "return" or key == "space" then self:toggleModule() return end
    elseif tab == "shipyard" then
        if key == "return" or key == "space" then self:buyShip() return end
    elseif tab == "talk" then
        if key == "return" or key == "space" then self:noteRumour() return end
    end

    if self.menu then self.menu:keypressed(key) end
end

function Port:wheelmoved(x, y)
    if self.menu then self.menu:move(-y) end
end

function Port:update(dt)
    self.world:update(dt)
    if self.status then
        self.status.life = self.status.life - dt
        if self.status.life <= 0 then self.status = nil end
    end
end

-- ---------------------------------------------------------------------------
-- Draw
-- ---------------------------------------------------------------------------

function Port:draw()
    local w, h = love.graphics.getWidth(), love.graphics.getHeight()
    love.graphics.clear(0.02, 0.025, 0.035, 1)

    -- header
    local place = self.place
    local faction = factions.get(place.factionId)
    ui.text(place.name, 40, 30, C.uiPrimary, "large")
    ui.text(L("{kind}  -  {economy}  -  pop {pop}  -  tech {tech}  -  law {law}%", {
        kind = place.kind == "station"
            and L("{kind} station", { kind = L(place.stationKindName) })
            or L("surface settlement"),
        economy = L(commodities.economy(place.economyId).name),
        pop = util.money(place.population or 0),
        tech = place.techLevel or 0,
        law = string.format("%.0f", (place.lawLevel or 0) * 100),
    }), 40, 60, C.uiDim, "small")
    ui.textRight(L(faction.name), w - 40, 30,
        { faction.color[1], faction.color[2], faction.color[3], 1 }, "normal")
    ui.textRight(self.world:dateString(), w - 40, 54, C.uiDim, "small")
    ui.textRight(util.money(self.player.credits) .. " " .. L("cr"), w - 40, 72, C.amber, "small")
    ui.rule(40, 90, w - 80)

    -- tabs
    local tx = 40
    for i, t in ipairs(self.tabs) do
        local name = L(TAB_NAME[t] or t:upper())
        local selected = (i == self.tab)
        local tw = ui.font("small"):getWidth(name) + 26
        if selected then
            ui.setColor(C.uiPrimary, 0.22)
            love.graphics.rectangle("fill", tx, 100, tw, 24)
        end
        ui.text(name, tx + 13, 104, selected and C.uiPrimary or C.uiDim, "small")
        tx = tx + tw + 6
    end
    ui.rule(40, 128, w - 80, C.uiLine, 0.4)

    -- body
    local tab = self:currentTab()
    local listX, listY = 70, layout.LIST_TOP
    -- the side panel starts at w-380 and the menu's own furniture adds 13px on
    -- the right, so leave room for both
    local listW = w - 380 - listX - ui.MENU_BLEED_RIGHT - 24

    if tab == "market" or tab == "blackMarket" then
        ui.text(L("COMMODITY"), listX, listY - 20, C.uiDim, "small")
        -- right-aligned against the same edge the values use, so the header
        -- lines up with them instead of relying on space padding
        ui.textRight(L("VS AVG   BUY / SELL   STOCK   HOLD"), listX + listW, listY - 20, C.uiDim, "small")
    end

    if self.menu then
        self.menu:setVisible(layout.rows())
        self.menu:draw(listX, listY, listW, layout.LIST_LINE, "small")
    end

    -- side panel
    self:drawSidePanel(w - 380, layout.LIST_TOP, 320, h - layout.LIST_TOP - layout.FOOTER)

    -- footer: the status line sits between the list and the rule, so the list
    -- height above already reserves room for it
    local leave = self.docked and L("ESC launch") or L("ESC leave")
    local hint
    if tab == "market" or tab == "blackMarket" then
        hint = L("B buy   N sell   1/2/3/4 quantity   Q/E tabs")
    elseif tab == "missions" then
        hint = L("ENTER accept   Q/E tabs")
    elseif tab == "outfitting" or tab == "shipyard" then
        hint = L("ENTER buy or sell   Q/E tabs")
    elseif tab == "talk" then
        hint = L("ENTER note a lead   Q/E tabs")
    else
        hint = L("ENTER select   Q/E tabs")
    end
    ui.rule(40, h - 60, w - 80, C.uiLine, 0.4)
    ui.text(hint .. "   " .. leave, 40, h - 48, C.uiDim, "small")
    if tab == "market" or tab == "blackMarket" then
        local qty = self.quantity == "max" and L("max") or tostring(self.quantity)
        ui.textRight(L("QUANTITY") .. ": " .. qty, w - 40, h - 48, C.uiPrimary, "small")
    end

    if self.status then
        local col = self.status.bad and C.uiDanger or C.uiPrimary
        ui.textCenter(self.status.text, w * 0.5, h - 82, col, "normal")
    end
end

function Port:drawSidePanel(x, y, w, h)
    local tab = self:currentTab()
    local item = self.menu and self.menu:current()
    ui.panel(x, y, w, h, L("DETAIL"))
    -- the hold, a colony's export list and a market event blurb are all
    -- unbounded; without this they paint over the footer and the list
    ui.clip(x + 1, y + 1, w - 2, h - 2, function()
        self:drawSidePanelContent(x, y, w, h, tab, item)
    end)
end

function Port:drawSidePanelContent(x, y, w, h, tab, item)
    local px, py = x + 18, y + 20

    if (tab == "market" or tab == "blackMarket") and item and item.commodity then
        local c = commodities.get(item.commodity)
        ui.text(L(c.name), px, py, C.uiPrimary, "normal")
        py = py + 26
        ui.text(L(commodities.categoryNames[c.category] or c.category), px, py, C.uiDim, "small")
        py = py + 20
        local buy = self.market:buyPrice(c.id)
        local sell = self.market:sellPrice(c.id)
        ui.text(L("Galactic average"), px, py, C.uiDim, "small")
        ui.textRight(util.money(c.base) .. " " .. L("cr"), x + w - 18, py, C.uiText, "small")
        py = py + 18
        ui.text(L("Buy here"), px, py, C.uiDim, "small")
        ui.textRight(util.money(buy) .. " " .. L("cr"), x + w - 18, py,
            buy < c.base and C.uiPrimary or C.uiDanger, "small")
        py = py + 18
        ui.text(L("Sell here"), px, py, C.uiDim, "small")
        ui.textRight(util.money(sell) .. " " .. L("cr"), x + w - 18, py,
            sell > c.base and C.uiPrimary or C.uiDanger, "small")
        py = py + 22

        -- the three questions the screen exists to answer: is this cheap, how
        -- much of it can I leave with, and does anyone I answer to want it
        local a = self.assessed and self.assessed[c.id]
        if a then
            local off = floor(math.abs((a.ratio or 1) - 1) * 100 + 0.5)
            if a.verdict == "cheap" then
                ui.text(L("{n}% under the average", { n = off }), px, py, C.uiPrimary, "small")
            elseif a.verdict == "dear" then
                ui.text(L("{n}% over the average", { n = off }), px, py, C.uiWarn, "small")
            else
                ui.text(L("About the average price"), px, py, C.uiDim, "small")
            end
            py = py + 18
            if a.take > 0 then
                ui.text(L("Your hold takes {n} {n:t} for {cash} cr",
                    { n = a.take, cash = util.money(a.take * a.buy) }), px, py, C.uiText, "small")
            elseif a.stock <= 0 then
                ui.text(L("None in stock"), px, py, C.uiDim, "small")
            elseif self.player:cargoFree() <= 0 then
                ui.text(L("Hold is full."), px, py, C.uiDim, "small")
            else
                ui.text(L("Cannot afford any."), px, py, C.uiDim, "small")
            end
            py = py + 18
            if a.wanted > 0 then
                ui.text(L("Your colonies are short {n} {n:t}", { n = floor(a.wanted + 0.5) }),
                    px, py, C.uiWarn, "small")
                py = py + 18
            end
            py = py + 6
        end

        -- Why the price is what it is.
        --
        -- A world only makes what its inputs allow, and when a chain upstream
        -- breaks the price of everything it makes climbs. Without this line
        -- that is invisible: the player sees an expensive commodity and no
        -- reason, when the reason is a shortage they could go and fix.
        local prod = require("src.sim.production")
        if prod.isOutput(self.place.economyId, c.id) and (self.market.supply or 1) < 0.75 then
            local short = self.market.limiting
            ui.textFit(L("Production here is short of {cargo:gen:lc}", {
                cargo = i18n.term(commodities.get(short or "ore").name) }),
                px, py, w - 36, C.uiWarn, "small")
            py = py + 18
        end

        local ev = self.market.events[c.id]
        if ev then
            py = py + ui.paragraph(ev.text, px, py, w - 36, C.uiWarn, "small") + 8
        end
        local legality = commodities.legalityIn(c, self.place.lawLevel or 0.5)
        if legality ~= "legal" then
            ui.text(legality == "illegal" and L("ILLEGAL HERE") or L("RESTRICTED"), px, py, C.uiDanger, "small")
            py = py + 20
        end
        ui.text(L("In your hold: {qty} {qty:t}", { qty = self.player:cargoCount(c.id) }),
            px, py, C.uiText, "small")
        py = py + 22
        -- a shelf of thirty rows is a search problem; this is the answer to it
        if self.bestBuy and self.bestBuy.id ~= c.id then
            ui.textFit(L("Best value here: {name}",
                { name = L(commodities.get(self.bestBuy.id).name) }),
                px, py, w - 36, C.uiDim, "small")
        elseif self.bestBuy then
            ui.text(L("Best value on this shelf"), px, py, C.uiPrimary, "small")
        end

    elseif tab == "missions" and item and item.mission then
        local m = item.mission
        py = py + ui.paragraph(missionsMod.title(m), px, py, w - 36, C.uiPrimary, "normal") + 6
        py = py + ui.paragraph(missionsMod.brief(m), px, py, w - 36, C.uiText, "small") + 10
        ui.text(L("Employer"), px, py, C.uiDim, "small")
        ui.textRight(m.employer or "-", x + w - 18, py, C.uiText, "small")
        py = py + 18
        ui.text(L("Reward"), px, py, C.uiDim, "small")
        ui.textRight(util.money(m.reward) .. " " .. L("cr"), x + w - 18, py, C.amber, "small")
        py = py + 18
        ui.text(L("Deadline"), px, py, C.uiDim, "small")
        ui.textRight(L("{n} {n:day}", { n = math.floor(m.days or 0) }), x + w - 18, py, C.uiText, "small")
        py = py + 18
        if m.destName then
            ui.text(L("Destination"), px, py, C.uiDim, "small")
            ui.textRight(m.destName, x + w - 18, py, C.uiText, "small")
            py = py + 18
        end
        if m.illegal then
            ui.text(L("ILLEGAL CONTRACT"), px, py, C.magenta, "small")
            py = py + 18
        end
        local ok, why = missionsMod.canAccept(m, self.player)
        if not ok then
            ui.text(L("Cannot accept: {reason}", { reason = L(tostring(why)) }),
                px, py, C.uiDanger, "small")
        end

    elseif tab == "outfitting" and item and item.moduleId then
        local e = equipment.get(item.moduleId)
        ui.text(L(e.name), px, py, C.uiPrimary, "normal")
        py = py + 26
        ui.text(L(e.slot:upper()) .. "  -  " .. L("tech {n}", { n = e.tech }), px, py, C.uiDim, "small")
        py = py + 20
        py = py + ui.paragraph(L(e.blurb or ""), px, py, w - 36, C.uiText, "small") + 10
        ui.text(L("Price"), px, py, C.uiDim, "small")
        ui.textRight(util.money(e.price) .. " " .. L("cr"), x + w - 18, py, C.amber, "small")
        if e.illegal then
            py = py + 20
            ui.text(L("Illegal in high-law systems"), px, py, C.magenta, "small")
        end

    elseif tab == "shipyard" and item and item.shipDef then
        local d = item.shipDef
        local s = d.stats
        ui.text(d.name, px, py, C.uiPrimary, "normal")
        py = py + 24
        ui.text(L(d.roleName), px, py, C.uiDim, "small")
        py = py + 22
        local rows = {
            { L("Hull"), string.format("%d", s.maxHull) },
            { L("Shield"), string.format("%d", s.maxShield) },
            { L("Cargo"), string.format("%d t", s.cargo) },
            { L("Top speed"), string.format("%.0f m/s", s.topSpeed) },
            { L("Agility"), string.format("%.2f", s.agility) },
            { L("Jump range"), string.format("%.1f ly", s.jumpRange) },
            { L("Hardpoints"), string.format("%d", s.hardpoints) },
            { L("Mass"), string.format("%d t", s.mass) },
        }
        for _, r in ipairs(rows) do
            ui.text(r[1], px, py, C.uiDim, "small")
            ui.textRight(r[2], x + w - 18, py, C.uiText, "small")
            py = py + 17
        end

    elseif tab == "talk" and item and item.rumour then
        local r = item.rumour
        py = py + ui.paragraph(require("src.sim.rumours").line(r), px, py, w - 36, C.uiText, "normal") + 10
        if r.systemId then
            ui.text(L("System"), px, py, C.uiDim, "small")
            ui.textRight(r.systemName or "?", x + w - 18, py, C.uiText, "small")
            py = py + 18
            local stub = self.world.galaxy:byId(r.systemId)
            if stub and self.world.stub then
                local here = self.world.stub
                local d = math.sqrt((stub.x - here.x) ^ 2 + (stub.y - here.y) ^ 2
                    + (stub.z - here.z) ^ 2)
                ui.text(L("Distance"), px, py, C.uiDim, "small")
                ui.textRight(L("{n} ly", { n = string.format("%.2f", d) }),
                    x + w - 18, py, C.uiText, "small")
                py = py + 18
            end
            py = py + 6
            ui.paragraph(L("Noted leads are marked on the galactic chart."),
                px, py, w - 36, C.uiDim, "small")
        else
            ui.paragraph(L("Talk, and nothing you can steer by."), px, py, w - 36, C.uiDim, "small")
        end

    elseif tab == "colony" and self.place.colony then
        local c = self.place.colony
        ui.text(c.name, px, py, C.uiPrimary, "normal")
        py = py + 24
        local rows = {
            { L("Tier"), L(colonyMod.tierName(c.tier)) },
            { L("Population"), util.money(floor(c.population)) },
            { L("Specialisation"), L(colonyMod.specialisations[c.specialisation].name) },
            { L("Morale"), string.format("%.0f%%", c.morale * 100) },
            { L("Supplies"), L("{n} {n:day}", { n = floor(colonyMod.suppliesLeft(c)) }) },
            { L("Treasury"), util.money(floor(c.credits)) .. " " .. L("cr") },
        }
        for _, r in ipairs(rows) do
            ui.text(r[1], px, py, C.uiDim, "small")
            ui.textRight(r[2], x + w - 18, py, C.uiText, "small")
            py = py + 17
        end
        py = py + 10
        ui.text(L("Pending exports"), px, py, C.uiDim, "small")
        py = py + 17
        for id, amount in pairs(c.exports) do
            if amount >= 1 then
                ui.text("  " .. L(commodities.get(id).name), px, py, C.uiText, "small")
                ui.textRight(L("{n} {n:t}", { n = floor(amount) }), x + w - 18, py, C.uiText, "small")
                py = py + 16
            end
        end

    else
        ui.text(L("Ship"), px, py, C.uiPrimary, "normal")
        py = py + 24
        local s = self.player.stats
        local rows = {
            { L("Hull"), string.format("%d / %d", floor(self.player.hull), floor(s.maxHull)) },
            { L("Shield"), string.format("%d / %d", floor(self.player.shield), floor(s.maxShield)) },
            { L("Fuel"), string.format("%.1f / %.1f t", self.player.fuel, s.fuel) },
            { L("Cargo"), string.format("%d / %d t", self.player:cargoUsed(), self.player:cargoCapacity()) },
            { L("Jump range"), string.format("%.1f ly", s.jumpRange) },
            { L("Missiles"), tostring(self.player.missiles) },
        }
        for _, r in ipairs(rows) do
            ui.text(r[1], px, py, C.uiDim, "small")
            ui.textRight(r[2], x + w - 18, py, C.uiText, "small")
            py = py + 17
        end
        py = py + 12
        ui.text(L("Hold"), px, py, C.uiDim, "small")
        py = py + 18
        local any = false
        for id, qty in pairs(self.player.cargo) do
            ui.text("  " .. L(commodities.get(id).name), px, py, C.uiText, "small")
            ui.textRight(L("{n} {n:t}", { n = qty }), x + w - 18, py, C.uiText, "small")
            py = py + 16
            any = true
        end
        if not any then ui.text("  " .. L("empty"), px, py, C.uiDim, "small") end
    end
end

return Port
