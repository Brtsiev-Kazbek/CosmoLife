-- The 3D renderer.
--
-- Pipeline per frame:
--
--   1. sky pass          -- full screen procedural background, no depth
--   2. starfield         -- 2D points, no depth
--   3. FAR depth layer   -- stars, planets, moons: 20 km .. 1e11 m
--   4. (depth cleared)
--   5. NEAR depth layer  -- terrain, cities, ships, debris: 0.2 m .. 30 km
--   6. FX layer          -- additive, depth tested but not depth written
--   7. post pass         -- optional scanlines / vignette
--
-- Two depth layers with a depth clear in between is the cheapest correct way
-- to cover eleven orders of magnitude of distance with a 24 bit depth buffer:
-- each layer gets its own well conditioned near/far pair.
--
-- Every object is submitted with an absolute world position; the renderer
-- subtracts the camera position in double precision before it builds the
-- (single precision) model matrix, so geometry never shimmers far from origin.

local class = require("src.lib.class")
local mat4 = require("src.lib.mat4")
local vec3 = require("src.lib.vec3")
local shaders = require("src.render.shaders")

local Renderer = class("Renderer")

local LAYER_FAR, LAYER_NEAR, LAYER_FX = 1, 2, 3

Renderer.LAYER_FAR = LAYER_FAR
Renderer.LAYER_NEAR = LAYER_NEAR
Renderer.LAYER_FX = LAYER_FX

local NEAR_NEAR, NEAR_FAR = 0.2, 30000
local FAR_FAR = 2e11
local LAYER_SPLIT = 24000       -- objects beyond this go to the far layer

-- The far layer's near plane is adaptive.  Standing on a planet, the sphere
-- that stands in for the ground beyond the streamed terrain patch starts a few
-- hundred metres away, and a fixed 20 km near plane would clip it into a hole
-- full of stars.  Flight lowers this as altitude drops; the only cost is depth
-- precision out at planetary distances, where nothing interpenetrates anyway.
local FAR_NEAR_MAX = 20000
local FAR_NEAR_MIN = 400

local IDENTITY_BASIS = {
    right = vec3(1, 0, 0),
    up = vec3(0, 1, 0),
    fwd = vec3(0, 0, -1),
}

function Renderer:init()
    self.width, self.height = 1, 1
    self.queues = { {}, {}, {} }
    self.counts = { 0, 0, 0 }

    self.env = {
        sunDir = vec3(0, -1, 0),          -- direction light travels
        sunColor = { 1.0, 0.96, 0.90 },
        ambient = { 0.10, 0.11, 0.14 },
        fogColor = { 0.02, 0.02, 0.03 },
        fogNear = 4000,
        fogFar = 26000,
        fogAmount = 0,
        atmos = 0,
        nebula = 1,
        zenith = { 0.05, 0.07, 0.14 },
        horizon = { 0.30, 0.38, 0.48 },
        ground = { 0.12, 0.10, 0.09 },
        worldUp = vec3(0, 1, 0),
        bands = 5,
        shadeFloor = 0.06,
        fillDir = vec3(0, 1, 0),
        fillColor = { 0.09, 0.13, 0.24 },
        rimColor = { 0.40, 0.48, 0.62 },
        keyIntensity = 1.0,
        saturation = 1.1,
        exposure = 1.15,
    }

    self.settings = {
        post = true,
        scanline = 0.35,
        vignette = 0.55,
        aberration = 0.6,
        wireframe = false,
        cull = "none",
    }

    self.stats = { draws = 0, triangles = 0 }
    self.farNear = FAR_NEAR_MAX

    self._mvp = mat4.identity()
    self._model = mat4.identity()
    self._view = mat4.identity()
    self._proj = mat4.identity()
    self._vp = mat4.identity()
    self._relPos = { x = 0, y = 0, z = 0 }
    self._emptyOpts = {}
    self._uniforms = setmetatable({}, { __mode = "k" })

    self.available = love ~= nil and love.graphics ~= nil
    if self.available then self:_createResources() end
end

function Renderer:_createResources()
    self.shader = love.graphics.newShader(shaders.flat3d)
    self.skyShader = love.graphics.newShader(shaders.sky)
    self.postShader = love.graphics.newShader(shaders.post)
    self:resize(love.graphics.getWidth(), love.graphics.getHeight())
end

-- Fraction of the window the sky pass is rendered at (see Renderer:resize).
local SKY_SCALE = 0.5

--- Picks the best depth format the driver actually supports.
local function newDepthCanvas(w, h)
    for _, format in ipairs({ "depth24stencil8", "depth24", "depth32f", "depth16" }) do
        local ok, canvas = pcall(love.graphics.newCanvas, w, h, { format = format, readable = false })
        if ok and canvas then return canvas end
    end
    return nil
end

function Renderer:resize(w, h)
    w, h = math.max(1, math.floor(w)), math.max(1, math.floor(h))
    if w == self.width and h == self.height and self.color then return end
    self.width, self.height = w, h
    if not self.available then return end

    if self.color then self.color:release() end
    if self.depth then self.depth:release() end

    self.color = love.graphics.newCanvas(w, h, { format = "rgba8" })
    self.color:setFilter("nearest", "nearest")

    -- The sky is rendered at a fraction of the resolution and upscaled.
    --
    -- It is a full-screen procedural pass -- gradient, galactic plane, two
    -- warped nebula layers and a filament layer -- and measured on a descent
    -- it was 65 of the frame's 166 ms, paid for every pixel including the
    -- ones the ground then covers. All of it is low frequency, so at half
    -- resolution it is visually the same picture for a quarter of the work.
    -- Stars and the sun are drawn separately at full resolution, so nothing
    -- that needs to be sharp is softened.
    if self.skyCanvas then self.skyCanvas:release() end
    local sw = math.max(1, math.floor(w * SKY_SCALE))
    local sh = math.max(1, math.floor(h * SKY_SCALE))
    self.skyCanvas = love.graphics.newCanvas(sw, sh, { format = "rgba8" })
    self.skyCanvas:setFilter("linear", "linear")
    self.skyWidth, self.skyHeight = sw, sh

    self.depth = newDepthCanvas(w, h)
    if not self.depth then
        -- Without a depth buffer we would have to sort per triangle; refuse
        -- quietly and let the game fall back to a flat 2D presentation.
        self.depthUnsupported = true
    end
end

-- ---------------------------------------------------------------------------
-- Frame
-- ---------------------------------------------------------------------------

--- Sets the far layer's near plane from how close the camera is to a surface.
-- `clearance` is metres of empty space in front of the nearest huge body.
function Renderer:setFarClearance(clearance)
    local n = clearance and (clearance * 0.3) or FAR_NEAR_MAX
    if n > FAR_NEAR_MAX then n = FAR_NEAR_MAX end
    if n < FAR_NEAR_MIN then n = FAR_NEAR_MIN end
    self.farNear = n
end

function Renderer:beginFrame(camera)
    self.camera = camera
    camera.aspect = self.width / self.height
    for i = 1, 3 do
        local q = self.queues[i]
        for j = 1, self.counts[i] do q[j] = nil end
        self.counts[i] = 0
    end
    self.stats.draws = 0
    self.stats.triangles = 0
end

--- Submits a model for rendering.
-- `pos`   absolute world position (vec3 of doubles)
-- `basis` table with right/up/fwd unit vectors (defaults to world axes)
-- `opts`  { scale, layer, tint, emissive, alpha, additive }
function Renderer:draw(model, pos, basis, opts)
    if not model then return end
    opts = opts or self._emptyOpts
    local cam = self.camera
    local dx = pos.x - cam.pos.x
    local dy = pos.y - cam.pos.y
    local dz = pos.z - cam.pos.z
    local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
    local scale = opts.scale or 1
    local radius = (model.radius or 1) * scale

    local layer = opts.layer
    if not layer then
        layer = (dist - radius > LAYER_SPLIT) and LAYER_FAR or LAYER_NEAR
    end
    if opts.additive then layer = LAYER_FX end

    -- frustum reject: a cheap cone test around the view direction
    if layer ~= LAYER_FX and dist > radius then
        local cosA = (dx * cam.fwd.x + dy * cam.fwd.y + dz * cam.fwd.z) / dist
        local margin = radius / dist
        -- half diagonal of the frustum plus the object's angular radius
        local limit = math.cos(math.min(math.pi, cam.fov * 0.5 * math.sqrt(1 + cam.aspect * cam.aspect) + math.asin(math.min(1, margin)) + 0.15))
        if cosA < limit then return end
    end

    local n = self.counts[layer] + 1
    self.counts[layer] = n
    self.queues[layer][n] = {
        model = model,
        dx = dx, dy = dy, dz = dz,
        dist = dist,
        basis = basis or IDENTITY_BASIS,
        scale = scale,
        tint = opts.tint,
        emissive = opts.emissive or 0,
        alpha = opts.alpha or 1,
        additive = opts.additive,
    }
end

local WHITE = { 1, 1, 1, 1 }

--- Sends a uniform, tolerating one that the GLSL compiler stripped.
--
-- A uniform that a shader declares but never actually reads does not exist in
-- the linked program, and `Shader:send` throws for it.  That is a real hazard
-- when shader code is edited, so every send goes through here: the answer from
-- `hasUniform` is memoised, making this a table lookup after the first frame.
function Renderer:_send(shader, name, ...)
    local cache = self._uniforms[shader]
    if not cache then
        cache = {}
        self._uniforms[shader] = cache
    end
    local has = cache[name]
    if has == nil then
        has = shader:hasUniform(name)
        cache[name] = has
    end
    if has then shader:send(name, ...) end
    return has
end

function Renderer:_setupShader(env)
    local s = self.shader
    self:_send(s, "u_lightDir", { env.sunDir.x, env.sunDir.y, env.sunDir.z })
    self:_send(s, "u_lightColor", env.sunColor)
    self:_send(s, "u_ambient", env.ambient)
    self:_send(s, "u_fogColor", env.fogColor)
    self:_send(s, "u_fogNear", env.fogNear)
    self:_send(s, "u_fogFar", env.fogFar)
    self:_send(s, "u_fogAmount", env.fogAmount)
    self:_send(s, "u_bands", env.bands)
    self:_send(s, "u_shadeFloor", env.shadeFloor)
    -- three-point lighting (see render.lighting)
    local fd = env.fillDir or env.sunDir
    self:_send(s, "u_fillDir", { fd.x, fd.y, fd.z })
    self:_send(s, "u_fillColor", env.fillColor or { 0, 0, 0 })
    self:_send(s, "u_rimColor", env.rimColor or { 0, 0, 0 })
    self:_send(s, "u_keyIntensity", env.keyIntensity or 1)
    self:_send(s, "u_saturation", env.saturation or 1)
    self:_send(s, "u_exposure", env.exposure or 1.15)
end

local function byDistance(a, b) return a.dist < b.dist end

function Renderer:_drawQueue(layer, near, far)
    local queue, count = self.queues[layer], self.counts[layer]
    if count == 0 then return end

    -- Opaque geometry goes front to back.
    --
    -- Submission order was whatever `pairs` gave, so on a descent the terrain
    -- arrived in random depth order and the depth test rejected almost nothing:
    -- a hundred and thirty chunks, several of them filling the screen, were
    -- each shaded in full. Sorting first lets early-Z discard the ones behind,
    -- which is the whole point of having a depth buffer.
    --
    -- The FX layer is additive and therefore order independent, so it is left
    -- alone rather than paying for a sort it cannot use.
    if layer ~= LAYER_FX then
        -- `queue` is a reused array with stale entries past `count`; sort only
        -- the live prefix
        if count > 1 then
            local live = self._sortBuf or {}
            self._sortBuf = live
            for i = 1, count do live[i] = queue[i] end
            for i = #live, count + 1, -1 do live[i] = nil end
            table.sort(live, byDistance)
            queue = live
        end
    end

    local cam = self.camera
    local proj = cam:projection(near, far, self._proj)
    local view = cam:viewMatrix(self._view)
    local vp = mat4.mul(proj, view, self._vp)

    local s = self.shader
    local rel = self._relPos
    for i = 1, count do
        local it = queue[i]
        local b = it.basis
        rel.x, rel.y, rel.z = it.dx, it.dy, it.dz
        local model = mat4.model(rel, b.right, b.up, b.fwd, it.scale, self._model)
        local mvp = mat4.mul(vp, model, self._mvp)
        self:_send(s, "u_mvp", "column", mvp)
        self:_send(s, "u_model", "column", model)
        self:_send(s, "u_emissive", it.emissive)
        local tint = it.tint or WHITE
        self:_send(s, "u_tint", { tint[1], tint[2], tint[3], (tint[4] or 1) * it.alpha })
        love.graphics.draw(it.model.mesh)
        self.stats.draws = self.stats.draws + 1
        self.stats.triangles = self.stats.triangles + it.model.triangles
    end
end

function Renderer:_drawSky(env)
    local cam = self.camera
    local s = self.skyShader

    local target = self.skyCanvas
    local rw, rh = self.skyWidth or self.width, self.skyHeight or self.height
    if target then
        love.graphics.setCanvas(target)
        love.graphics.clear(0, 0, 0, 1)
        love.graphics.setDepthMode("always", false)
    end

    love.graphics.setShader(s)
    self:_send(s, "u_res", { rw, rh })
    self:_send(s, "u_camFwd", { cam.fwd.x, cam.fwd.y, cam.fwd.z })
    self:_send(s, "u_camUp", { cam.up.x, cam.up.y, cam.up.z })
    self:_send(s, "u_camRight", { cam.right.x, cam.right.y, cam.right.z })
    self:_send(s, "u_worldUp", { env.worldUp.x, env.worldUp.y, env.worldUp.z })
    self:_send(s, "u_tanHalfFov", math.tan(cam.fov * 0.5))
    self:_send(s, "u_atmos", env.atmos)
    self:_send(s, "u_nebula", env.nebula)
    self:_send(s, "u_zenith", env.zenith)
    self:_send(s, "u_horizon", env.horizon)
    self:_send(s, "u_ground", env.ground)
    self:_send(s, "u_sunDir", { env.sunDir.x, env.sunDir.y, env.sunDir.z })
    self:_send(s, "u_sunColor", env.sunColor)
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.rectangle("fill", 0, 0, rw, rh)
    love.graphics.setShader()

    if target then
        -- back to the frame's own target, and blow the sky up into it
        love.graphics.setCanvas({ self.color, depthstencil = self.depth })
        love.graphics.setDepthMode("always", false)
        love.graphics.setColor(1, 1, 1, 1)
        love.graphics.draw(target, 0, 0, 0, self.width / rw, self.height / rh)
    end
end

--- Renders everything queued this frame into the internal colour canvas.
-- `overlay2d` is called after the sky (for stars and the sun disc) and
-- `after3d` after all geometry (for HUD elements drawn in 3D screen space).
function Renderer:endFrame(overlay2d)
    if not self.available or self.depthUnsupported then return end
    local env = self.env

    love.graphics.push("all")
    love.graphics.setCanvas({ self.color, depthstencil = self.depth })
    love.graphics.clear(0, 0, 0, 1, true, true)
    love.graphics.setDepthMode("always", false)
    love.graphics.setBlendMode("alpha")

    self:_drawSky(env)
    if overlay2d then overlay2d() end

    love.graphics.setShader(self.shader)
    love.graphics.setMeshCullMode(self.settings.cull)
    love.graphics.setWireframe(self.settings.wireframe)
    self:_setupShader(env)

    love.graphics.setDepthMode("lequal", true)
    self:_drawQueue(LAYER_FAR, self.farNear, FAR_FAR)
    love.graphics.clear(false, false, true)
    self:_drawQueue(LAYER_NEAR, NEAR_NEAR, NEAR_FAR)

    -- additive effects: tested against the near layer, never written
    if self.counts[LAYER_FX] > 0 then
        love.graphics.setDepthMode("lequal", false)
        love.graphics.setBlendMode("add")
        self:_drawQueue(LAYER_FX, NEAR_NEAR, NEAR_FAR)
    end

    love.graphics.setWireframe(false)
    love.graphics.setMeshCullMode("none")
    love.graphics.setShader()
    love.graphics.setDepthMode()
    love.graphics.setCanvas()
    love.graphics.pop()
end

--- Blits the rendered frame to the screen.
function Renderer:present()
    if not self.available then return end
    if self.depthUnsupported then
        love.graphics.setColor(1, 0.4, 0.4, 1)
        love.graphics.print("This GPU/driver reports no depth buffer support; 3D rendering is disabled.", 20, 20)
        love.graphics.setColor(1, 1, 1, 1)
        return
    end
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setBlendMode("alpha", "premultiplied")
    if self.settings.post then
        local s = self.postShader
        love.graphics.setShader(s)
        self:_send(s, "u_scanline", self.settings.scanline)
        self:_send(s, "u_vignette", self.settings.vignette)
        self:_send(s, "u_aberration", self.settings.aberration)
    end
    love.graphics.draw(self.color, 0, 0)
    love.graphics.setShader()
    love.graphics.setBlendMode("alpha")
end

--- Convenience wrapper used by generators that only have a position.
function Renderer:drawAt(model, x, y, z, opts)
    self:draw(model, { x = x, y = y, z = z }, nil, opts)
end

return Renderer
