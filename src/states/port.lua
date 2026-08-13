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
local i18n = require("src.i18n")

local Port = class("PortState")

local C = palette.colors
local L = i18n.format
local floor, min, max = math.floor, math.min, math.max

-- Layout constants shared by the menu builders and the draw code, so the
-- number of visible rows is derived from the same geometry that draws them
-- rather than being a hand-tuned constant that overran the footer at 540px.
local LIST_TOP = 152
local LIST_LINE = 24
local FOOTER = 76        -- rule, hint line and status line below the list

local function listRows()
    local h = love.graphics and love.graphics.getHeight() or 720
    return ui.rowsFor(h - LIST_TOP - FOOTER, LIST_LINE)
end

local TAB_ORDER = { "summary", "market", "blackMarket", "missions", "outfitting", "shipyard", "colony" }
-- Tab captions are looked up at draw time rather than stored, so switching
-- language re-labels the screen without rebuilding the state.
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
            label = L("Refuel ({amount} t)", { amount = string.format("%.1f", fuelMissing) }),
            value = util.money(fuelPrice) .. " " .. L("cr"),
            action = function()
                if self.player:spend(fuelPrice) then
                    self.player.fuel = stats.fuel
                    self:say(L("Tanks full."))
                else
                    self:say(L("Not enough credits."), true)
                end
                self:rebuild()
            end,
        }
    else
        items[#items + 1] = { label = L("Refuel"), value = L("tanks full"), disabled = true }
    end

    local hullMissing = stats.maxHull - self.player.hull
    local repairPrice = floor(hullMissing * 22)
    if hullMissing > 0.5 and (self.place.services or {}).repair ~= false then
        items[#items + 1] = {
            label = L("Repair hull ({amount})", { amount = floor(hullMissing) }),
            value = util.money(repairPrice) .. " " .. L("cr"),
            action = function()
                if self.player:spend(repairPrice) then
                    self.player.hull = stats.maxHull
                    self.player.shield = stats.maxShield
                    self:say(L("Hull restored."))
                else
                    self:say(L("Not enough credits."), true)
                end
                self:rebuild()
            end,
        }
    else
        items[#items + 1] = { label = L("Repair hull"), value = L("no damage"), disabled = true }
    end

    if self.player.missiles < 6 then
        items[#items + 1] = {
            label = L("Buy missile"), value = util.money(1200) .. " " .. L("cr"),
            action = function()
                if self.player:spend(1200) then
                    self.player.missiles = self.player.missiles + 1
                    self:say(L("Missile loaded."))
                else self:say(L("Not enough credits."), true) end
                self:rebuild()
            end,
        }
    end

    local bounty = self.player:bounty(self.place.factionId)
    if bounty > 0 then
        items[#items + 1] = {
            label = L("Pay off bounty with {faction}",
                { faction = factions.get(self.place.factionId).short }),
            value = util.money(bounty) .. " " .. L("cr"), color = C.uiWarn,
            action = function()
                if self.player:spend(bounty) then
                    self.player:clearBounty(self.place.factionId)
                    self:say(L("Record cleared."))
                else self:say(L("Not enough credits."), true) end
                self:rebuild()
            end,
        }
    end

    items[#items + 1] = { label = L("Trade computer: best local exports"), disabled = true, color = C.uiDim }
    for _, e in ipairs(self.market:bestExports(4)) do
        local c = commodities.get(e.id)
        items[#items + 1] = {
            label = "   " .. L(c.name), value = util.money(e.price) .. " " .. L("cr"),
            disabled = true, color = C.uiDim,
        }
    end

    items[#items + 1] = {
        label = self.docked and L("Launch") or L("Step away from the terminal"),
        value = "ESC", color = C.uiPrimary,
        action = function() self:launch() end,
    }

    self.menu = ui.menu(items, { visible = listRows(), onSelect = function() end })
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
                label = L(c.name),
                value = string.format("%s / %s   %d   %d",
                    util.money(buy), util.money(sell), self.market:available(id), held),
                commodity = id,
                color = illicit and C.magenta or nil,
            }
        end
    end
    if #items == 0 then
        items[1] = {
            label = black and L("No black market trade today.") or L("Nothing traded here."),
            disabled = true,
        }
    end
    self.menu = ui.menu(items, { visible = listRows() })
end

function Port:buildMissionMenu()
    local board = self.world:board(self.place)
    self.board = board
    local items = {}
    for _, m in ipairs(board) do
        local ok = missionsMod.canAccept(m, self.player)
        items[#items + 1] = {
            label = missionsMod.title(m),
            value = util.money(m.reward) .. " " .. L("cr"),
            mission = m,
            color = m.illegal and C.magenta or (m.warZone and C.uiWarn or nil),
            valueColor = ok and C.amber or C.uiDim,
        }
    end
    if #items == 0 then items[1] = { label = L("No contracts posted."), disabled = true } end
    self.menu = ui.menu(items, { visible = listRows() })
end

function Port:buildOutfitMenu()
    local tech = self.place.techLevel or 6
    local allowIllegal = (self.place.lawLevel or 0.5) < 0.4 or self.place.blackMarket
    local items = {}
    items[#items + 1] = { label = "-- " .. L("FITTED") .. " --", disabled = true, color = C.uiDim }
    for _, id in ipairs(self.player.installed) do
        local e = equipment.get(id)
        if e then
            items[#items + 1] = {
                label = "  " .. L(e.name),
                value = L("sell") .. " " .. util.money(floor(e.price * 0.55)),
                moduleId = id, sell = true, color = C.uiText,
            }
        end
    end
    items[#items + 1] = { label = "-- " .. L("FOR SALE") .. " --", disabled = true, color = C.uiDim }
    for _, e in ipairs(equipment.available(tech, allowIllegal)) do
        items[#items + 1] = {
            label = "  " .. L(e.name),
            value = util.money(e.price) .. " " .. L("cr"),
            moduleId = e.id, sell = false,
            color = e.illegal and C.magenta or nil,
            valueColor = self.player.credits >= e.price and C.amber or C.uiDim,
        }
    end
    self.menu = ui.menu(items, { visible = listRows() })
end

function Port:buildShipyardMenu()
    if not self.catalogue then
        self.catalogue = shipsGen.catalogue(self.place.seed, self.place.techLevel or 6, 6)
    end
    local items = {}
    local tradeIn = floor(self.player.shipDef.stats.price * 0.62)
    items[#items + 1] = {
        label = L("Your {class} ({name})",
            { class = L(self.player.shipDef.roleName), name = self.player.shipDef.name }),
        value = L("trade-in") .. " " .. util.money(tradeIn), disabled = true, color = C.uiDim,
    }
    for _, def in ipairs(self.catalogue) do
        items[#items + 1] = {
            label = string.format("%s  %s", L(def.roleName), def.name),
            value = util.money(def.stats.price) .. " " .. L("cr"),
            shipDef = def,
            valueColor = (self.player.credits + tradeIn) >= def.stats.price and C.amber or C.uiDim,
        }
    end
    self.menu = ui.menu(items, { visible = listRows() })
end

function Port:buildColonyMenu()
    local c = self.place.colony
    colonyMod.update(c, self.world.day)
    local items = {}
    items[#items + 1] = {
        label = L("Collect exports and taxes"),
        value = util.money(floor(c.credits)) .. " " .. L("cr"),
        action = function()
            local taken, cash = colonyMod.collect(c, self.player)
            local n = 0
            for _, q in pairs(taken) do n = n + q end
            self:say(L("Collected {qty} {qty:t} and {cash} cr.", { qty = n, cash = util.money(cash) }))
            self:rebuild()
        end }
    for _, amount in ipairs({ 10000, 50000, 200000 }) do
        items[#items + 1] = {
            label = L("Invest {amount} cr", { amount = util.money(amount) }),
            value = self.player.credits >= amount and L("available") or L("too expensive"),
            disabled = self.player.credits < amount,
            action = function()
                local ok = colonyMod.invest(c, self.player, amount)
                self:say(ok and L("Investment committed.") or L("Not enough credits."), not ok)
                self:rebuild()
            end,
        }
    end
    -- deliver supplies straight from the hold
    for id in pairs(colonyMod.NEEDS) do
        local held = self.player:cargoCount(id)
        if held > 0 then
            items[#items + 1] = {
                label = L("Unload {qty} {qty:t} of {cargo:gen:lc}",
                    { qty = held, cargo = i18n.term(commodities.get(id).name) }),
                value = L("supply"),
                action = function()
                    self.player:removeCargo(id, held)
                    colonyMod.supply(c, id, held)
                    self:say(L("Supplies delivered."))
                    self:rebuild()
                end,
            }
        end
    end
    self.menu = ui.menu(items, { visible = listRows() })
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
    local cargo = i18n.term(commodities.get(id).name)
    if sell then
        local have = self.player:cargoCount(id)
        local n, total = self.market:quote(id, min(qty, have), true)
        n = min(n, have)
        if n <= 0 then self:say(L("Nothing to sell."), true) return end
        n, total = self.market:sell(id, n)
        self.player:removeCargo(id, n)
        self.player:earn(total)
        self.player.record.trades = self.player.record.trades + 1
        self.player.record.profit = self.player.record.profit + total
        self:say(L("Sold {qty} {qty:t} of {cargo:gen:lc} for {cash} cr.",
            { qty = n, cargo = cargo, cash = util.money(total) }))
    else
        local space = self.player:cargoFree()
        local price = self.market:buyPrice(id) or 1
        local affordable = floor(self.player.credits / max(price, 1))
        local n = min(qty, space, affordable, self.market:available(id))
        if n <= 0 then
            self:say(space <= 0 and L("Hold is full.") or L("Cannot afford any."), true)
            return
        end
        local bought, cost = self.market:buy(id, n)
        self.player:spend(cost)
        self.player:addCargo(id, bought)
        self.player.record.trades = self.player.record.trades + 1
        self:say(L("Bought {qty} {qty:t} of {cargo:gen:lc} for {cash} cr.",
            { qty = bought, cargo = cargo, cash = util.money(cost) }))
    end
    self:buildMarketMenu(self:currentTab() == "blackMarket")
end

function Port:acceptMission()
    local item = self.menu:current()
    if not item or not item.mission then return end
    local ok, why = missionsMod.accept(item.mission, self.player, self.world.day)
    if ok then
        self:say(L("Contract accepted."))
        self.player:addLog(L("Accepted: {title}", { title = missionsMod.title(item.mission) }),
            self.world.day, "info")
        self:buildMissionMenu()
    else
        self:say(L("Cannot accept: {reason}", { reason = L(tostring(why)) }), true)
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
        self:say(L("Sold {module:acc:lc} for {cash} cr.",
            { module = i18n.term(e.name), cash = util.money(refund) }))
    else
        if self.player.credits < e.price then self:say(L("Not enough credits."), true) return end
        local ok, why = self.player:install(item.moduleId)
        if ok then
            self.player:spend(e.price)
            self:say(L("{module} fitted.", { module = i18n.term(e.name) }))
        else
            self:say(L("Cannot fit: {reason}", { reason = L(tostring(why)) }), true)
        end
    end
    self:buildOutfitMenu()
end

function Port:buyShip()
    local item = self.menu:current()
    if not item or not item.shipDef then return end
    local tradeIn = floor(self.player.shipDef.stats.price * 0.62)
    local cost = item.shipDef.stats.price - tradeIn
    if self.player.credits < cost then self:say(L("Not enough credits."), true) return end
    if self.player:cargoUsed() > item.shipDef.stats.cargo then
        self:say(L("New ship's hold is too small for your cargo."), true)
        return
    end
    self.player:spend(cost)
    self.player:setShip(item.shipDef, false)
    self:say(L("Registered to {name}.", { name = item.shipDef.name }))
    self.player:addLog(L("Bought a {class:acc:lc}.", { class = i18n.term(item.shipDef.roleName) }),
        self.world.day, "info")
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
    local listX, listY = 70, LIST_TOP
    -- the side panel starts at w-380 and the menu's own furniture adds 13px on
    -- the right, so leave room for both
    local listW = w - 380 - listX - ui.MENU_BLEED_RIGHT - 24

    if tab == "market" or tab == "blackMarket" then
        ui.text(L("COMMODITY"), listX, listY - 20, C.uiDim, "small")
        -- right-aligned against the same edge the values use, so the header
        -- lines up with them instead of relying on space padding
        ui.textRight(L("BUY / SELL   STOCK   HOLD"), listX + listW, listY - 20, C.uiDim, "small")
    end

    if self.menu then
        self.menu:setVisible(listRows())
        self.menu:draw(listX, listY, listW, LIST_LINE, "small")
    end

    -- side panel
    self:drawSidePanel(w - 380, LIST_TOP, 320, h - LIST_TOP - FOOTER)

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
        py = py + 24
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
