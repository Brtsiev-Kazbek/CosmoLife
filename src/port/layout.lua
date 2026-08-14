-- Geometry shared by the docked screen and its tabs.
--
-- The number of visible rows is derived from the same numbers that draw them
-- rather than being a hand-tuned constant -- which is how it came to overrun
-- the footer at 540 px. Every tab module needs it, and none of them should
-- reach back into states/port.lua for it, so it lives here.

local ui = require("src.ui.widgets")

local layout = {}

layout.LIST_TOP = 152
layout.LIST_LINE = 24
layout.FOOTER = 76        -- rule, hint line and status line below the list

--- How many list rows fit on screen at the current window height.
function layout.rows()
    local h = love.graphics and love.graphics.getHeight() or 720
    return ui.rowsFor(h - layout.LIST_TOP - layout.FOOTER, layout.LIST_LINE)
end

return layout
