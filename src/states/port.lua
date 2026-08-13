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
local shipsGen = require("src.procgen.ships")
local hud = require("src.render.hud")

local Port = class("PortState")

local C = palette.colors
local floor, min, max = math.floor, math.min, math.max

local TAB_ORDER = { "summary", "market", "blackMarket", "missions", "outfitting", "shipyard", "colony" }
local TAB_NAME = {
    summary = "OVERVIEW", market = "MARKET", blackMarket = "BLACK MARKET",
    missions = "CONTRACTS", outfitting = "OUTFITTING", shipyard = "SHIPYARD", colony = "COLONY",
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
    if svc.outfitting then self.tabs[#self.tabs + 1] = "outfitting" end
    if svc.shipyard then self.tabs[#self.tabs + 1] = "shipyard" end
    if place.colony then self.tabs[#self.tabs + 1] = "colony" end

    self.tab = 1
    if initialTab then
        for i, t in ipairs(self.tabs) do
            if t == initialTab or (initialTab == "refuel" and t == "summary")
                or (initialTab == "repair" and t == "summary")
                or (initialTab == "rumours" and t == "summary")
                or (initialTab == "navdata" and t == "summary") then
                self.tab = i
                break
            end
        end
    end

    self.completed = nil
    if not self.arrived then
        self.arrived = true
        self.completed = self.world:onDock(place)
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
    elseif tab == "colony" then
        self:buildColonyMenu()
    else
        self:buildSummaryMenu()
    end
end

-- ---------------------------------------------------------------------------
-- Tabs
-- ---------------------------------------------------------------------------

function Port:buildSummaryMenu()
    local items = {}
    local stats = self.player.stats
    local fuelMissing = stats.fuel - self.player.fuel
    local fuelPrice = floor(fuelMissing * 34)
    if fuelMissing > 0.05 then
        items[#items + 1] = {
            label = string.format("Refuel (%.1f t)", fuelMissing),
            value = util.money(fuelPrice) .. " cr",
            action = function()
                if self.player:spend(fuelPrice) then
                    self.player.fuel = stats.fuel
                    self:say("Tanks full.")
                else
                    self:say("Not enough credits.", true)
                end
                self:rebuild()
            end,
        }
    else
        items[#items + 1] = { label = "Refuel", value = "tanks full", disabled = true }
    end

    local hullMissing = stats.maxHull - self.player.hull
    local repairPrice = floor(hullMissing * 22)
    if hullMissing > 0.5 and (self.place.services or {}).repair ~= false then
        items[#items + 1] = {
            label = string.format("Repair hull (%d)", floor(hullMissing)),
            value = util.money(repairPrice) .. " cr",
            action = function()
                if self.player:spend(repairPrice) then
                    self.player.hull = stats.maxHull
                    self.player.shield = stats.maxShield
                    self:say("Hull restored.")
                else
                    self:say("Not enough credits.", true)
                end
                self:rebuild()
            end,
        }
    else
        items[#items + 1] = { label = "Repair hull", value = "no damage", disabled = true }
    end

    if self.player.missiles < 6 then
        items[#items + 1] = {
            label = "Buy missile", value = "1 200 cr",
            action = function()
                if self.player:spend(1200) then
                    self.player.missiles = self.player.missiles + 1
                    self:say("Missile loaded.")
                else self:say("Not enough credits.", true) end
                self:rebuild()
            end,
        }
    end

    local bounty = self.player:bounty(self.place.factionId)
    if bounty > 0 then
        items[#items + 1] = {
            label = "Pay off bounty with " .. factions.get(self.place.factionId).short,
            value = util.money(bounty) .. " cr", color = C.uiWarn,
            action = function()
                if self.player:spend(bounty) then
                    self.player:clearBounty(self.place.factionId)
                    self:say("Record cleared.")
                else self:say("Not enough credits.", true) end
                self:rebuild()
            end,
        }
    end

    items[#items + 1] = { label = "Trade computer: best local exports", disabled = true, color = C.uiDim }
    for _, e in ipairs(self.market:bestExports(4)) do
        local c = commodities.get(e.id)
        items[#items + 1] = {
            label = "   " .. c.name, value = util.money(e.price) .. " cr", disabled = true, color = C.uiDim,
        }
    end

    items[#items + 1] = {
        label = self.docked and "Launch" or "Step away from the terminal",
        value = "ESC", color = C.uiPrimary,
        action = function() self:launch() end,
    }

    self.menu = ui.menu(items, { visible = 14, onSelect = function() end })
end

function Port:buildMarketMenu(black)
    local items = {}
    local law = self.place.lawLevel or 0.5
    for _, id in ipairs(self.market:tradedIds()) do
        local c = commodities.get(id)
        local legality = commodities.legalityIn(c, law)
        local illicit = (legality ~= "legal")
        if illicit == (black and true or false) then
            local buy = self.market:buyPrice(id)
            local sell = self.market:sellPrice(id)
            local held = self.player:cargoCount(id)
            items[#items + 1] = {
                label = c.name,
                value = string.format("%s / %s   stock %d   hold %d",
                    util.money(buy), util.money(sell), self.market:available(id), held),
                commodity = id,
                color = illicit and C.magenta or nil,
            }
        end
    end
    if #items == 0 then
        items[1] = { label = black and "No black market trade today." or "Nothing traded here.", disabled = true }
    end
    self.menu = ui.menu(items, { visible = 15 })
end

function Port:buildMissionMenu()
    local board = self.world:board(self.place)
    self.board = board
    local items = {}
    for _, m in ipairs(board) do
        local ok = missionsMod.canAccept(m, self.player)
        items[#items + 1] = {
            label = m.title,
            value = util.money(m.reward) .. " cr",
            mission = m,
            color = m.illegal and C.magenta or (m.warZone and C.uiWarn or nil),
            valueColor = ok and C.amber or C.uiDim,
        }
    end
    if #items == 0 then items[1] = { label = "No contracts posted.", disabled = true } end
    self.menu = ui.menu(items, { visible = 12 })
end

function Port:buildOutfitMenu()
    local tech = self.place.techLevel or 6
    local allowIllegal = (self.place.lawLevel or 0.5) < 0.4 or self.place.blackMarket
    local items = {}
    items[#items + 1] = { label = "-- FITTED --", disabled = true, color = C.uiDim }
    for _, id in ipairs(self.player.installed) do
        local e = equipment.get(id)
        if e then
            items[#items + 1] = {
                label = "  " .. e.name,
                value = "sell " .. util.money(floor(e.price * 0.55)),
                moduleId = id, sell = true, color = C.uiText,
            }
        end
    end
    items[#items + 1] = { label = "-- FOR SALE --", disabled = true, color = C.uiDim }
    for _, e in ipairs(equipment.available(tech, allowIllegal)) do
        items[#items + 1] = {
            label = "  " .. e.name,
            value = util.money(e.price) .. " cr",
            moduleId = e.id, sell = false,
            color = e.illegal and C.magenta or nil,
            valueColor = self.player.credits >= e.price and C.amber or C.uiDim,
        }
    end
    self.menu = ui.menu(items, { visible = 15 })
end

function Port:buildShipyardMenu()
    if not self.catalogue then
        self.catalogue = shipsGen.catalogue(self.place.seed, self.place.techLevel or 6, 6)
    end
    local items = {}
    local tradeIn = floor(self.player.shipDef.stats.price * 0.62)
    items[#items + 1] = {
        label = string.format("Your %s (%s)", self.player.shipDef.roleName, self.player.shipDef.name),
        value = "trade-in " .. util.money(tradeIn), disabled = true, color = C.uiDim,
    }
    for _, def in ipairs(self.catalogue) do
        items[#items + 1] = {
            label = string.format("%s  %s", def.roleName, def.name),
            value = util.money(def.stats.price) .. " cr",
            shipDef = def,
            valueColor = (self.player.credits + tradeIn) >= def.stats.price and C.amber or C.uiDim,
        }
    end
    self.menu = ui.menu(items, { visible = 12 })
end

function Port:buildColonyMenu()
    local c = self.place.colony
    colonyMod.update(c, self.world.day)
    local items = {}
    items[#items + 1] = { label = "Collect exports and taxes", value = util.money(floor(c.credits)) .. " cr",
        action = function()
            local taken, cash = colonyMod.collect(c, self.player)
            local n = 0
            for _, q in pairs(taken) do n = n + q end
            self:say(string.format("Collected %d t and %s cr.", n, util.money(cash)))
            self:rebuild()
        end }
    for _, amount in ipairs({ 10000, 50000, 200000 }) do
        items[#items + 1] = {
            label = "Invest " .. util.money(amount) .. " cr",
            value = self.player.credits >= amount and "available" or "too expensive",
            disabled = self.player.credits < amount,
            action = function()
                local ok = colonyMod.invest(c, self.player, amount)
                self:say(ok and "Investment committed." or "Not enough credits.", not ok)
                self:rebuild()
            end,
        }
    end
    -- deliver supplies straight from the hold
    for id in pairs(colonyMod.NEEDS) do
        local held = self.player:cargoCount(id)
        if held > 0 then
            items[#items + 1] = {
                label = string.format("Unload %d t of %s", held, commodities.get(id).name),
                value = "supply",
                action = function()
                    self.player:removeCargo(id, held)
                    colonyMod.supply(c, id, held)
                    self:say("Supplies delivered.")
                    self:rebuild()
                end,
            }
        end
    end
    self.menu = ui.menu(items, { visible = 12 })
end

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

function Port:trade(sell)
    local item = self.menu:current()
    if not item or not item.commodity then return end
    local id = item.commodity
    local qty = self.quantity
    if qty == "max" then
        qty = sell and self.player:cargoCount(id) or 1e9
    end
    if sell then
        local have = self.player:cargoCount(id)
        local n, total = self.market:quote(id, min(qty, have), true)
        n = min(n, have)
        if n <= 0 then self:say("Nothing to sell.", true) return end
        n, total = self.market:sell(id, n)
        self.player:removeCargo(id, n)
        self.player:earn(total)
        self.player.record.trades = self.player.record.trades + 1
        self.player.record.profit = self.player.record.profit + total
        self:say(string.format("Sold %d t of %s for %s cr.", n, commodities.get(id).name, util.money(total)))
    else
        local space = self.player:cargoFree()
        local price = self.market:buyPrice(id) or 1
        local affordable = floor(self.player.credits / max(price, 1))
        local n = min(qty, space, affordable, self.market:available(id))
        if n <= 0 then
            self:say(space <= 0 and "Hold is full." or "Cannot afford any.", true)
            return
        end
        local bought, cost = self.market:buy(id, n)
        self.player:spend(cost)
        self.player:addCargo(id, bought)
        self.player.record.trades = self.player.record.trades + 1
        self:say(string.format("Bought %d t of %s for %s cr.", bought, commodities.get(id).name, util.money(cost)))
    end
    self:buildMarketMenu(self:currentTab() == "blackMarket")
end

function Port:acceptMission()
    local item = self.menu:current()
    if not item or not item.mission then return end
    local ok, why = missionsMod.accept(item.mission, self.player, self.world.day)
    if ok then
        self:say("Contract accepted.")
        self.player:addLog("Accepted: " .. item.mission.title, self.world.day, "info")
        self:buildMissionMenu()
    else
        self:say("Cannot accept: " .. tostring(why), true)
    end
end

function Port:toggleModule()
    local item = self.menu:current()
    if not item or not item.moduleId then return end
    local e = equipment.get(item.moduleId)
    if item.sell then
        local refund = floor(e.price * 0.55)
        self.player:uninstall(item.moduleId)
        self.player:earn(refund)
        self:say(string.format("Sold %s for %s cr.", e.name, util.money(refund)))
    else
        if self.player.credits < e.price then self:say("Not enough credits.", true) return end
        local ok, why = self.player:install(item.moduleId)
        if ok then
            self.player:spend(e.price)
            self:say(e.name .. " fitted.")
        else
            self:say("Cannot fit: " .. tostring(why), true)
        end
    end
    self:buildOutfitMenu()
end

function Port:buyShip()
    local item = self.menu:current()
    if not item or not item.shipDef then return end
    local tradeIn = floor(self.player.shipDef.stats.price * 0.62)
    local cost = item.shipDef.stats.price - tradeIn
    if self.player.credits < cost then self:say("Not enough credits.", true) return end
    if self.player:cargoUsed() > item.shipDef.stats.cargo then
        self:say("New ship's hold is too small for your cargo.", true)
        return
    end
    self.player:spend(cost)
    self.player:setShip(item.shipDef, false)
    self:say("Registered to " .. item.shipDef.name .. ".")
    self.player:addLog("Bought a " .. item.shipDef.roleName .. ".", self.world.day, "info")
    self.catalogue = nil
    self:buildShipyardMenu()
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
    ui.text(string.format("%s  -  %s  -  pop %s  -  tech %d  -  law %.0f%%",
        place.kind == "station" and (place.stationKindName .. " station") or "surface settlement",
        commodities.economy(place.economyId).name,
        util.money(place.population or 0),
        place.techLevel or 0,
        (place.lawLevel or 0) * 100), 40, 60, C.uiDim, "small")
    ui.textRight(faction.name, w - 40, 30, { faction.color[1], faction.color[2], faction.color[3], 1 }, "normal")
    ui.textRight(self.world:dateString(), w - 40, 54, C.uiDim, "small")
    ui.textRight(util.money(self.player.credits) .. " cr", w - 40, 72, C.amber, "small")
    ui.rule(40, 90, w - 80)

    -- tabs
    local tx = 40
    for i, t in ipairs(self.tabs) do
        local name = TAB_NAME[t] or t:upper()
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
    local listX, listY = 70, 152
    local listW = w - 480

    if tab == "market" or tab == "blackMarket" then
        ui.text("COMMODITY", listX, listY - 20, C.uiDim, "small")
        ui.textRight("BUY / SELL      STOCK      HOLD", listX + listW, listY - 20, C.uiDim, "small")
    end

    if self.menu then self.menu:draw(listX, listY, listW, 24, "small") end

    -- side panel
    self:drawSidePanel(w - 380, 152, 320, h - 240)

    -- footer
    local leave = self.docked and "ESC launch" or "ESC leave"
    local hint
    if tab == "market" or tab == "blackMarket" then
        hint = "B buy   N sell   1/2/3/4 quantity 1/10/100/max   Q/E tabs   " .. leave
    elseif tab == "missions" then
        hint = "ENTER accept   Q/E tabs   " .. leave
    elseif tab == "outfitting" or tab == "shipyard" then
        hint = "ENTER buy or sell   Q/E tabs   " .. leave
    else
        hint = "ENTER select   Q/E tabs   " .. leave
    end
    ui.rule(40, h - 60, w - 80, C.uiLine, 0.4)
    ui.text(hint, 40, h - 48, C.uiDim, "small")
    if tab == "market" or tab == "blackMarket" then
        ui.textRight("QUANTITY: " .. tostring(self.quantity), w - 40, h - 48, C.uiPrimary, "small")
    end

    if self.status then
        local col = self.status.bad and C.uiDanger or C.uiPrimary
        ui.textCenter(self.status.text, w * 0.5, h - 84, col, "normal")
    end
end

function Port:drawSidePanel(x, y, w, h)
    local tab = self:currentTab()
    local item = self.menu and self.menu:current()
    ui.panel(x, y, w, h, "DETAIL")
    local px, py = x + 18, y + 20

    if (tab == "market" or tab == "blackMarket") and item and item.commodity then
        local c = commodities.get(item.commodity)
        ui.text(c.name, px, py, C.uiPrimary, "normal")
        py = py + 26
        ui.text(commodities.categoryNames[c.category] or c.category, px, py, C.uiDim, "small")
        py = py + 20
        local buy = self.market:buyPrice(c.id)
        local sell = self.market:sellPrice(c.id)
        ui.text("Galactic average", px, py, C.uiDim, "small")
        ui.textRight(util.money(c.base) .. " cr", x + w - 18, py, C.uiText, "small")
        py = py + 18
        ui.text("Buy here", px, py, C.uiDim, "small")
        ui.textRight(util.money(buy) .. " cr", x + w - 18, py,
            buy < c.base and C.uiPrimary or C.uiDanger, "small")
        py = py + 18
        ui.text("Sell here", px, py, C.uiDim, "small")
        ui.textRight(util.money(sell) .. " cr", x + w - 18, py,
            sell > c.base and C.uiPrimary or C.uiDanger, "small")
        py = py + 24
        local ev = self.market.events[c.id]
        if ev then
            py = py + ui.paragraph(ev.text, px, py, w - 36, C.uiWarn, "small") + 8
        end
        local legality = commodities.legalityIn(c, self.place.lawLevel or 0.5)
        if legality ~= "legal" then
            ui.text(legality == "illegal" and "ILLEGAL HERE" or "RESTRICTED", px, py, C.uiDanger, "small")
            py = py + 20
        end
        ui.text(string.format("In your hold: %d t", self.player:cargoCount(c.id)), px, py, C.uiText, "small")

    elseif tab == "missions" and item and item.mission then
        local m = item.mission
        py = py + ui.paragraph(m.title, px, py, w - 36, C.uiPrimary, "normal") + 6
        py = py + ui.paragraph(m.brief, px, py, w - 36, C.uiText, "small") + 10
        ui.text("Employer", px, py, C.uiDim, "small")
        ui.textRight(m.employer or "-", x + w - 18, py, C.uiText, "small")
        py = py + 18
        ui.text("Reward", px, py, C.uiDim, "small")
        ui.textRight(util.money(m.reward) .. " cr", x + w - 18, py, C.amber, "small")
        py = py + 18
        ui.text("Deadline", px, py, C.uiDim, "small")
        ui.textRight(string.format("%.0f days", m.days or 0), x + w - 18, py, C.uiText, "small")
        py = py + 18
        if m.destName then
            ui.text("Destination", px, py, C.uiDim, "small")
            ui.textRight(m.destName, x + w - 18, py, C.uiText, "small")
            py = py + 18
        end
        if m.illegal then
            ui.text("ILLEGAL CONTRACT", px, py, C.magenta, "small")
            py = py + 18
        end
        local ok, why = missionsMod.canAccept(m, self.player)
        if not ok then ui.text("Cannot accept: " .. tostring(why), px, py, C.uiDanger, "small") end

    elseif tab == "outfitting" and item and item.moduleId then
        local e = equipment.get(item.moduleId)
        ui.text(e.name, px, py, C.uiPrimary, "normal")
        py = py + 26
        ui.text(e.slot:upper() .. "  -  tech " .. e.tech, px, py, C.uiDim, "small")
        py = py + 20
        py = py + ui.paragraph(e.blurb or "", px, py, w - 36, C.uiText, "small") + 10
        ui.text("Price", px, py, C.uiDim, "small")
        ui.textRight(util.money(e.price) .. " cr", x + w - 18, py, C.amber, "small")
        if e.illegal then
            py = py + 20
            ui.text("Illegal in high-law systems", px, py, C.magenta, "small")
        end

    elseif tab == "shipyard" and item and item.shipDef then
        local d = item.shipDef
        local s = d.stats
        ui.text(d.name, px, py, C.uiPrimary, "normal")
        py = py + 24
        ui.text(d.roleName, px, py, C.uiDim, "small")
        py = py + 22
        local rows = {
            { "Hull", string.format("%d", s.maxHull) },
            { "Shield", string.format("%d", s.maxShield) },
            { "Cargo", string.format("%d t", s.cargo) },
            { "Top speed", string.format("%.0f m/s", s.topSpeed) },
            { "Agility", string.format("%.2f", s.agility) },
            { "Jump range", string.format("%.1f ly", s.jumpRange) },
            { "Hardpoints", string.format("%d", s.hardpoints) },
            { "Mass", string.format("%d t", s.mass) },
        }
        for _, r in ipairs(rows) do
            ui.text(r[1], px, py, C.uiDim, "small")
            ui.textRight(r[2], x + w - 18, py, C.uiText, "small")
            py = py + 17
        end

    elseif tab == "colony" and self.place.colony then
        local c = self.place.colony
        ui.text(c.name, px, py, C.uiPrimary, "normal")
        py = py + 24
        local rows = {
            { "Tier", colonyMod.tierName(c.tier) },
            { "Population", util.money(floor(c.population)) },
            { "Specialisation", colonyMod.specialisations[c.specialisation].name },
            { "Morale", string.format("%.0f%%", c.morale * 100) },
            { "Supplies", string.format("%.0f days", colonyMod.suppliesLeft(c)) },
            { "Treasury", util.money(floor(c.credits)) .. " cr" },
        }
        for _, r in ipairs(rows) do
            ui.text(r[1], px, py, C.uiDim, "small")
            ui.textRight(r[2], x + w - 18, py, C.uiText, "small")
            py = py + 17
        end
        py = py + 10
        ui.text("Pending exports", px, py, C.uiDim, "small")
        py = py + 17
        for id, amount in pairs(c.exports) do
            if amount >= 1 then
                ui.text("  " .. commodities.get(id).name, px, py, C.uiText, "small")
                ui.textRight(string.format("%d t", floor(amount)), x + w - 18, py, C.uiText, "small")
                py = py + 16
            end
        end

    else
        ui.text("Ship", px, py, C.uiPrimary, "normal")
        py = py + 24
        local s = self.player.stats
        local rows = {
            { "Hull", string.format("%d / %d", floor(self.player.hull), floor(s.maxHull)) },
            { "Shield", string.format("%d / %d", floor(self.player.shield), floor(s.maxShield)) },
            { "Fuel", string.format("%.1f / %.1f t", self.player.fuel, s.fuel) },
            { "Cargo", string.format("%d / %d t", self.player:cargoUsed(), self.player:cargoCapacity()) },
            { "Jump range", string.format("%.1f ly", s.jumpRange) },
            { "Missiles", tostring(self.player.missiles) },
        }
        for _, r in ipairs(rows) do
            ui.text(r[1], px, py, C.uiDim, "small")
            ui.textRight(r[2], x + w - 18, py, C.uiText, "small")
            py = py + 17
        end
        py = py + 12
        ui.text("Hold", px, py, C.uiDim, "small")
        py = py + 18
        local any = false
        for id, qty in pairs(self.player.cargo) do
            ui.text("  " .. commodities.get(id).name, px, py, C.uiText, "small")
            ui.textRight(qty .. " t", x + w - 18, py, C.uiText, "small")
            py = py + 16
            any = true
        end
        if not any then ui.text("  empty", px, py, C.uiDim, "small") end
    end
end

return Port
