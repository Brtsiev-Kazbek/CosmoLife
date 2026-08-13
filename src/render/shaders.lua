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
uniform vec3  u_fillDir;     // soft opposing light, travels this way
uniform vec3  u_fillColor;
uniform vec3  u_rimColor;
uniform float u_keyIntensity;
uniform float u_saturation;

vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc)
{
    vec3 base = color.rgb * u_tint.rgb;
    vec3 n = normalize(v_normal);

    // Two sided lighting: procedural hulls are not always perfectly wound and
    // we render with culling disabled, so flip the normal towards the camera.
    if (dot(n, v_viewPos) > 0.0) n = -n;

    vec3 toEye = normalize(-v_viewPos);

    // key light: the star.  Quantised into bands for the retro look.
    float ndl = max(dot(n, -u_lightDir), 0.0);
    if (u_bands > 0.5) {
        ndl = floor(ndl * u_bands + 0.5) / u_bands;
    }

    // fill light: soft, wrapped so it lifts the terminator rather than
    // adding a second hard edge
    float ndf = dot(n, -u_fillDir);
    ndf = max(ndf * 0.5 + 0.5, 0.0);
    ndf *= ndf;

    // rim light: a band along the silhouette, gated to the lit hemisphere so
    // an object's dark side does not glow for no reason
    float fresnel = pow(1.0 - max(dot(n, toEye), 0.0), 3.0);
    float rimGate = clamp(dot(n, -u_lightDir) * 0.5 + 0.75, 0.0, 1.0);
    float rim = fresnel * rimGate;

    vec3 lit = base * (u_ambient + u_shadeFloor
                       + u_lightColor * ndl * u_keyIntensity
                       + u_fillColor * ndf)
             + u_rimColor * rim;

    // a touch of saturation control lets a preset be graded without
    // re-authoring every palette entry
    float grey = dot(lit, vec3(0.299, 0.587, 0.114));
    lit = mix(vec3(grey), lit, u_saturation);

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

float fbm(vec2 p, int octaves)
{
    float sum = 0.0;
    float amp = 0.5;
    float norm = 0.0;
    for (int i = 0; i < 5; i++) {
        if (i >= octaves) break;
        sum += amp * valueNoise(p);
        norm += amp;
        p *= 2.07;
        amp *= 0.55;
    }
    return sum / max(norm, 0.0001);
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

    // Space background.
    //
    // Nebulae are three octaves of value noise in two colours, gated so most
    // of the sky stays dark and the clouds appear in drifts.  A separate,
    // much larger band adds the galactic plane -- a faint bright stripe with
    // dust lanes cut through it -- which is what stops deep space from
    // looking like a uniform black box in every direction.
    vec3 spaceCol = mix(vec3(0.012, 0.013, 0.026), vec3(0.026, 0.018, 0.045), up * 0.5 + 0.5);

    if (u_nebula > 0.001) {
        // galactic plane: a broad band around one great circle
        float band = 1.0 - abs(dot(dir, normalize(vec3(0.24, 0.94, -0.13))));
        float plane = smoothstep(0.86, 1.0, band);
        float dust = fbm(dir.xz * 5.0 + dir.y * 2.0, 3);
        plane *= mix(0.35, 1.0, smoothstep(0.35, 0.75, dust));
        spaceCol += vec3(0.16, 0.17, 0.22) * plane * u_nebula * 0.5;
        // a dense scatter of unresolved stars inside the band
        float grain = fbm(dir.xy * 42.0 + dir.z * 17.0, 2);
        spaceCol += vec3(0.10, 0.11, 0.14) * plane * smoothstep(0.62, 0.95, grain) * u_nebula;

        // two nebula clouds in complementary hues
        float n1 = fbm(dir.xy * 2.4 + dir.z * 1.7, 4);
        float n2 = fbm(dir.yz * 3.1 - dir.x * 2.3 + 11.0, 4);
        float c1 = smoothstep(0.56, 0.92, n1);
        float c2 = smoothstep(0.60, 0.95, n2);
        vec3 hueA = u_zenith * 1.6 + vec3(0.10, 0.02, 0.16);
        vec3 hueB = vec3(0.06, 0.16, 0.22);
        spaceCol += hueA * c1 * u_nebula * 0.40;
        spaceCol += hueB * c2 * u_nebula * 0.34;
        // bright cores where the two overlap
        spaceCol += vec3(0.22, 0.16, 0.28) * c1 * c2 * u_nebula * 0.5;
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
