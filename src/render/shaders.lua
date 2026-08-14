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
uniform float u_exposure;
uniform float u_shell;       // 0 = ordinary geometry, 1 = air, 2 = cloud deck

vec4 effect(vec4 color, Image tex, vec2 tc, vec2 sc)
{
    vec3 base = color.rgb * u_tint.rgb;
    vec3 n = normalize(v_normal);

    // Shells -- the atmosphere and the cloud deck -- are spheres drawn around
    // a planet, and only the hemisphere facing us may be drawn. Culling is off
    // globally (procedural hulls are not reliably wound), and these two are
    // additive, so without this the far side of the sphere would be added on
    // top of the planet it is supposed to be behind.
    if (u_shell > 0.5 && dot(n, v_viewPos) > 0.0) discard;

    // Two sided lighting: procedural hulls are not always perfectly wound and
    // we render with culling disabled, so flip the normal towards the camera.
    if (dot(n, v_viewPos) > 0.0) n = -n;

    vec3 toEye = normalize(-v_viewPos);

    // ---- atmosphere ------------------------------------------------------
    //
    // A planet's air used to be a sphere of flat translucent colour, which
    // reads as a bubble rather than as atmosphere. What makes it look like air
    // is that you see through more of it at the edge of the disc than at the
    // middle, and that it is lit from the side: bright blue where the sun is
    // overhead, deep and thin on the night side, and a warm band at the
    // terminator where you are looking through the whole depth of it towards
    // the sun.
    if (u_shell > 0.5 && u_shell < 1.5) {
        float ndv = max(dot(n, toEye), 0.0);
        // Path length through the air. A high exponent is what keeps the glow
        // hugging the silhouette: a gentle falloff fills the whole disc with
        // haze instead, and the planet underneath disappears behind it.
        float limb = pow(1.0 - ndv, 3.4);
        float sun = dot(n, -u_lightDir);
        float day = clamp(sun * 2.2 + 0.06, 0.0, 1.0);
        // Forward scattering: the sunset band. Narrow, and confined to the
        // limb -- it is the band along the terminator, not a wash over
        // everything facing away from the star.
        float warm = pow(clamp(1.0 - abs(sun) * 5.0, 0.0, 1.0), 2.0) * limb;
        vec3 col = mix(base, base * vec3(2.4, 1.05, 0.55), warm * 0.9);
        float a = limb * day * u_tint.a;
        return vec4(col * (0.35 + day * 1.1), a);
    }

    // ---- cloud deck ------------------------------------------------------
    //
    // Lit like ground, faded out towards the night side (additive cannot
    // darken, so cloud simply stops being visible there) and thinned at the
    // limb, where a flat deck would otherwise draw a hard ring around the
    // planet.
    if (u_shell > 1.5) {
        float sun = dot(n, -u_lightDir);
        float day = clamp(sun * 1.8 - 0.05, 0.0, 1.0);
        float ndv = max(dot(n, toEye), 0.0);
        // fade out towards the silhouette as well: a flat deck seen edge-on
        // draws a hard bright ring around the planet otherwise
        float a = u_tint.a * day * smoothstep(0.0, 0.55, ndv);
        return vec4(base * (0.35 + day * 0.85), a);
    }

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

    // Rim light: a band along the silhouette, gated to the lit hemisphere so
    // an object's dark side does not glow for no reason.
    //
    // It multiplies the surface colour rather than being added on top of it.
    // Added, it was the single thing draining the colour out of every planet:
    // the fresnel term peaks where the surface turns away from the eye, and a
    // ground plane seen from a metre and a half above it is at a grazing angle
    // *everywhere*, so the whole landscape was being flooded with a flat
    // blue-grey regardless of what colour it was. Measured on the biome tour,
    // ground whose vertices were 0.24/0.90/0.99 reached the screen as
    // 0.33/0.35/0.40 -- and so did every other biome, which is what "it is all
    // grey" meant. A rim light is still a light: it should light what is there,
    // not paint over it.
    float fresnel = pow(1.0 - max(dot(n, toEye), 0.0), 3.0);
    float rimGate = clamp(dot(n, -u_lightDir) * 0.5 + 0.75, 0.0, 1.0);
    float rim = fresnel * rimGate;

    vec3 lit = base * (u_ambient + u_shadeFloor
                       + u_lightColor * ndl * u_keyIntensity
                       + u_fillColor * ndf
                       + u_rimColor * rim * 1.7);

    // Tone mapping.
    //
    // Three lights plus ambient plus a rim add up past 1.0 on anything pale,
    // and a hard clamp turns a light grey hull into a white silhouette with no
    // shape left in it. This exponential roll-off keeps mid tones where they
    // are and compresses the highlights instead of cutting them off.
    //
    // It is applied to *brightness*, not to each channel on its own. Rolling
    // off the channels independently is what was draining the colour out of
    // the whole game: the brightest channel saturates first, so a cyan ground
    // lit to 1.4 came out white, and every complaint that "everything is grey"
    // traced back here rather than to the palette. Scaling all three by the
    // same factor moves the brightness and leaves the hue where the generator
    // put it.
    float lum = max(dot(lit, vec3(0.2126, 0.7152, 0.0722)), 1e-4);
    lit *= (1.0 - exp(-lum * u_exposure)) / lum;
    // a colour can still leave the cube on one channel; pull it back along the
    // line to white rather than clipping, which would desaturate it again
    float peak = max(lit.r, max(lit.g, lit.b));
    if (peak > 1.0) lit /= peak;

    // a touch of saturation control lets a preset be graded without
    // re-authoring every palette entry
    float grey = dot(lit, vec3(0.299, 0.587, 0.114));
    lit = mix(vec3(grey), lit, u_saturation);

    lit = mix(lit, base * 1.15, u_emissive);

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

        // Two nebula clouds in complementary hues, domain warped.
        //
        // Plain fbm gives soft round blobs, which read as fog. Offsetting the
        // sample point by another fbm bends those blobs into filaments and
        // sheets -- the shapes a real emission nebula has -- for the cost of
        // one extra noise lookup per layer.
        vec2 wq = vec2(fbm(dir.xy * 1.3 + 4.0, 2), fbm(dir.yz * 1.1 - 2.0, 2));
        vec2 warp = (wq - 0.5) * 1.6;

        float n1 = fbm(dir.xy * 2.4 + dir.z * 1.7 + warp, 4);
        float n2 = fbm(dir.yz * 3.1 - dir.x * 2.3 + 11.0 - warp * 0.8, 4);
        float c1 = smoothstep(0.54, 0.90, n1);
        float c2 = smoothstep(0.58, 0.94, n2);
        vec3 hueA = u_zenith * 1.6 + vec3(0.10, 0.02, 0.16);
        vec3 hueB = vec3(0.06, 0.16, 0.22);
        spaceCol += hueA * c1 * u_nebula * 0.40;
        spaceCol += hueB * c2 * u_nebula * 0.34;
        // bright cores where the two overlap
        spaceCol += vec3(0.22, 0.16, 0.28) * c1 * c2 * u_nebula * 0.5;

        // A third, much finer layer only inside the densest parts: filament
        // structure at a scale the broad layers cannot resolve, which is what
        // gives the clouds depth rather than flatness.
        float dense = c1 * c2 + c1 * 0.35;
        if (dense > 0.02) {
            float fil = fbm(dir.xy * 9.0 + dir.z * 5.0 + warp * 2.0, 3);
            fil = smoothstep(0.55, 0.85, fil);
            spaceCol += (hueA * 0.5 + vec3(0.10, 0.08, 0.14)) * fil * dense * u_nebula * 0.55;
        }
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
