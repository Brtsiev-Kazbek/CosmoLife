-- GLSL sources.
--
-- The look we are after is the filled-polygon era: hard facet edges, a single
-- hard sun, a small amount of ambient bounce, and quantised light bands so a
-- curved hull reads as a handful of flat tones rather than a smooth gradient.

local shaders = {}

-- ---------------------------------------------------------------------------
-- Main geometry shader.  One directional sun, ambient term, distance fog and
-- an emissive channel for engine flares, windows and navigation lights.
-- ---------------------------------------------------------------------------
shaders.flat3d = [[
varying vec3 v_normal;
varying vec3 v_viewPos;   // position relative to the camera (metres)

#ifdef VERTEX
attribute vec3 VertexNormal;

uniform mat4 u_mvp;
uniform mat4 u_model;     // camera relative model matrix

vec4 position(mat4 transform_projection, vec4 vertex_position)
{
    vec3 p = vertex_position.xyz;
    v_viewPos = (u_model * vec4(p, 1.0)).xyz;
    // rotation only part of the model matrix (scales are uniform by contract)
    mat3 nm = mat3(u_model[0].xyz, u_model[1].xyz, u_model[2].xyz);
    v_normal = nm * VertexNormal;
    return u_mvp * vec4(p, 1.0);
}
#endif

#ifdef PIXEL
uniform vec3  u_lightDir;    // unit vector pointing *from* the sun
uniform vec3  u_lightColor;
uniform vec3  u_ambient;
uniform vec3  u_fogColor;
uniform float u_fogNear;
uniform float u_fogFar;
uniform float u_fogAmount;
uniform float u_bands;       // 0 = smooth shading, >0 = quantised bands
uniform float u_emissive;    // 0 = fully lit, 1 = self illuminated
uniform vec4  u_tint;
uniform float u_shadeFloor;  // how dark the unlit side is allowed to get

vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc)
{
    vec3 base = color.rgb * u_tint.rgb;
    vec3 n = normalize(v_normal);

    // Two sided lighting: procedural hulls are not always perfectly wound and
    // we render with culling disabled, so flip the normal towards the camera.
    if (dot(n, v_viewPos) > 0.0) n = -n;

    float ndl = max(dot(n, -u_lightDir), 0.0);
    if (u_bands > 0.5) {
        ndl = floor(ndl * u_bands + 0.5) / u_bands;
    }
    // a soft rim keeps silhouettes readable against black space
    float rim = pow(1.0 - max(dot(n, normalize(-v_viewPos)), 0.0), 3.0) * 0.18;

    vec3 lit = base * (u_ambient + u_shadeFloor + u_lightColor * ndl) + rim * u_lightColor;
    lit = mix(lit, base * 1.25, u_emissive);

    float d = length(v_viewPos);
    float f = clamp((d - u_fogNear) / max(u_fogFar - u_fogNear, 1.0), 0.0, 1.0) * u_fogAmount;
    lit = mix(lit, u_fogColor, f);

    return vec4(lit, color.a * u_tint.a);
}
#endif
]]

-- ---------------------------------------------------------------------------
-- Background: deep space gradient, faint nebula banding, and -- once inside an
-- atmosphere -- a horizon gradient that reddens near the terminator.
-- ---------------------------------------------------------------------------
shaders.sky = [[
uniform vec3  u_zenith;
uniform vec3  u_horizon;
uniform vec3  u_ground;
uniform vec3  u_camUp;      // camera basis
uniform vec3  u_camFwd;
uniform vec3  u_camRight;
uniform vec3  u_worldUp;    // "up" at the camera position (away from the planet)
uniform vec2  u_res;
uniform float u_tanHalfFov;
uniform float u_atmos;      // 0 = vacuum, 1 = thick atmosphere
uniform vec3  u_sunDir;
uniform vec3  u_sunColor;
uniform float u_nebula;

float hash12(vec2 p)
{
    vec3 p3 = fract(vec3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float valueNoise(vec2 p)
{
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash12(i);
    float b = hash12(i + vec2(1.0, 0.0));
    float c = hash12(i + vec2(0.0, 1.0));
    float d = hash12(i + vec2(1.0, 1.0));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc)
{
    // reconstruct a world space ray for this pixel
    vec2 ndc = (sc / u_res) * 2.0 - 1.0;
    ndc.y = -ndc.y;
    float aspect = u_res.x / u_res.y;
    vec3 dir = normalize(u_camFwd
        + u_camRight * (ndc.x * u_tanHalfFov * aspect)
        + u_camUp * (ndc.y * u_tanHalfFov));

    float up = dot(dir, normalize(u_worldUp));

    // space background: near black with a slow nebula wash
    vec3 spaceCol = mix(vec3(0.015, 0.016, 0.03), vec3(0.03, 0.02, 0.05), up * 0.5 + 0.5);
    if (u_nebula > 0.001) {
        float n = valueNoise(dir.xy * 3.0 + dir.z * 2.0);
        n += 0.5 * valueNoise(dir.yz * 7.0 - dir.x * 3.0);
        n = smoothstep(0.55, 1.35, n);
        spaceCol += u_zenith * n * u_nebula * 0.35;
    }

    // atmospheric sky: zenith -> horizon -> ground haze, warmed towards the sun
    float t = clamp(up * 1.4 + 0.15, -1.0, 1.0);
    vec3 skyCol = (t >= 0.0)
        ? mix(u_horizon, u_zenith, pow(t, 0.65))
        : mix(u_horizon, u_ground, clamp(-t * 2.0, 0.0, 1.0));
    float sunAmount = pow(max(dot(dir, -u_sunDir), 0.0), 8.0);
    skyCol += u_sunColor * sunAmount * 0.45;

    vec3 col = mix(spaceCol, skyCol, u_atmos);
    return vec4(col, 1.0);
}
]]

-- ---------------------------------------------------------------------------
-- Optional CRT-ish post pass: scanlines, slight vignette, subtle chromatic
-- offset.  Cheap, and it ties the flat polygons to the era we are quoting.
-- ---------------------------------------------------------------------------
shaders.post = [[
uniform float u_scanline;
uniform float u_vignette;
uniform float u_aberration;

vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc)
{
    vec2 d = tc - 0.5;
    vec4 c;
    if (u_aberration > 0.0001) {
        float k = u_aberration * 0.0025;
        c.r = Texel(tex, tc + d * k).r;
        c.g = Texel(tex, tc).g;
        c.b = Texel(tex, tc - d * k).b;
        c.a = 1.0;
    } else {
        c = Texel(tex, tc);
    }

    float line = 1.0 - u_scanline * 0.5 * (0.5 + 0.5 * sin(sc.y * 3.14159));
    c.rgb *= line;

    float v = 1.0 - u_vignette * dot(d, d) * 1.4;
    c.rgb *= clamp(v, 0.0, 1.0);

    return c * color;
}
]]

return shaders
