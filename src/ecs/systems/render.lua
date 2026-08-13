-- Submits every renderable entity to the renderer.
--
-- Marked `isDrawSystem`, so it runs in the draw pass rather than the update
-- pass and the scene can be drawn without advancing time.

local tiny = require("lib.tiny")

return function()
    local system = tiny.processingSystem()
    system.filter = tiny.requireAll("transform", "renderable")
    system.isDrawSystem = true

    function system:process(e)
        local renderer = self.context.renderer
        if not renderer then return end
        local r = e.renderable
        if not r.model then return end
        renderer:draw(r.model, e.transform.pos, e.transform, {
            scale = r.scale,
            emissive = r.emissive,
            alpha = r.alpha,
            additive = r.additive,
            layer = r.layer,
            tint = r.tint,
        })
    end

    return system
end
