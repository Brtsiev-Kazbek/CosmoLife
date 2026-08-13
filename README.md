# CosmoLife

An Elite-style open-world space game in [LÖVE](https://love2d.org/) 11, with
filled flat-shaded polygon graphics, an endless procedural galaxy, a supply and
demand economy, faction war, contracts, colonisation — and seamless landing on
detailed planetary settlements you can walk into.

```
love .                  play
love . --new            skip the title screen
love . --selftest       scripted smoke test through every screen (needs a GPU)
luajit tests/run.lua    head-less test suite (no LÖVE required)
```

Nothing is loaded from disk. Every ship, city, building, planet and star in the
game is generated at runtime from an integer seed, so the whole project is
source code and no assets ship with it.

---

## What is in it

**An endless galaxy.** Space is an infinite lattice of 12-light-year sectors.
Hashing a sector's integer coordinates gives its stars, and a spiral-arm density
field modulates how many there are, so the galaxy has dense arms, sparse gulfs
and a bright core rather than uniform noise. Nothing is stored: fly a thousand
light years out and back, and the same systems are there.

**Systems that expand on demand.** A star, its planets and moons, asteroid
belts, orbital stations and the settlements scattered over habitable surfaces
are all derived from one seed. Orbits are evaluated analytically from the world
clock, so a system can be entered on day 900 without simulating the 899 days
before it.

**An economy with actual supply and demand.** A market never stores a price. It
stores *stock*, and derives price from stock against the local equilibrium:

```
price = base * (equilibrium / stock) ^ elasticity * local modifiers
```

Buying out a supply raises the price as you buy it. Flooding a world with grain
crashes it. An agricultural world's surplus is a high-tech world's shortage, and
that gap is the game. Wars raise the price of arms, medicine and food where they
burn; harvest failures and strikes fire as local events.

**Factions, territory and war.** Six powers claim territory through a Voronoi
diagram over an infinite lattice of claim points, which gives contiguous empires
with real borders — and the distance to the second nearest claim gives a
"frontier" factor that drives piracy, garrisons and conflict. Relations drift,
wars start and armistices get signed while you are elsewhere.

**Contracts** generated from the state of the galaxy rather than a list: a war
zone offers arms runs and evacuations, a mining world wants machinery, a
lawless port offers smuggling. Deliveries, bounties, passengers, surveys,
assassinations, colony supply.

**Combat** with lasers, cannons, beams, plasma and missiles; shields that
kinetic rounds bleed through; bounties, reputation and police who take an
interest when you shoot the wrong ship.

**Seamless landing.** See below — it is the piece the project is built around.

**Colonisation.** Plant a settlement on any solid world with a foundation kit,
then keep it supplied with provisions, water, medicine and machinery. It grows
through five tiers, unlocking services and producing goods you can collect. Stop
feeding it and it starves.

---

## How the seamless descent works

There is no cutscene and no separate surface level. The same ship, the same
controls and the same update loop run from deep space to taxiing on a pad. Only
the frame the ship is integrated in changes:

| | position and velocity are… |
|---|---|
| **space mode** | absolute world coordinates (doubles, metres) |
| **surface mode** | local to a tangent frame on the body |

Below 140 km, `src/procgen/surface.lua` fixes a tangent frame under the ship and
streams height-field chunks around it. Three details make the handover
invisible:

1. **The terrain and the planet are the same function.** The sphere you see from
   orbit is coloured by `Field:heightDir()`, and the ground under your landing
   gear is the same function sampled through a tangent projection. The brown
   wedge of desert you aimed at from orbit is the desert you land in.
2. **Chunks are bent to match the sphere.** Vertices are pulled down by
   `(x² + z²) / 2R`, so the flat patch follows the curvature of the sphere it is
   standing in for and meets the horizon exactly where the sphere does — which
   is still drawn beyond the patch.
3. **The frame is rebuilt from the body's live position and spin every frame.**
   A landed ship rides its planet around its star with no special case, because
   its authoritative coordinates are local to the ground it is sitting on.

Land, press `U`, and you are walking. The settlement you parked next to is the
settlement you walk into — the same `Surface` object is the ground under your
boots. Walk to a door, press `E`, and the building's interior is generated from
its seed: a room with service terminals that open the same market and contract
screens docking does.

---

## The look

Filled flat-shaded polygons, quantised light bands, hard facet edges, one hard
sun, and an optional CRT pass.

Everything goes through one GPU pipeline (`src/render/renderer.lua`) with a
depth buffer and two depth layers — near (0.2 m … 30 km) and far
(20 km … 2 × 10¹¹ m) with a depth clear between them. Two well-conditioned
near/far pairs are the cheapest correct way to cover eleven orders of magnitude
of distance with a 24-bit depth buffer. Objects are submitted with absolute
world positions and the camera position is subtracted in double precision before
the model matrix is built, so geometry never shimmers a hundred million
kilometres from the origin.

Flat shading means triangles never share vertices: each carries its own face
normal. That triples the vertex count and removes every seam-normal problem,
and it lets an entire city bake down to two draw calls — one for structure, one
for the emissive windows and signage that light up at night.

**Detail is spent on structure, not smoothness.** A tower is stacked setbacks,
window bands, balconies, floor separators, roof plant, railings, external
ducting and a recessed doorway with a lit sign — roughly 25 flat-shaded masses
and 200 window quads. The building catalogue covers habitation blocks, habitat
domes, manufactories, refineries with pipe bridges and flare stacks, warehouses
with container yards, control towers, hangars, market halls with awnings, fusion
plants with hyperboloid cooling towers, mine heads with sheave wheels,
garrisons, research campuses, agri-domes and monuments.

---

## Controls

| | |
|---|---|
| `W` `S` | pitch |
| `A` `D` | roll |
| `Q` `E` | yaw |
| `R` `F` | throttle up / down |
| `Z` `X` | full / zero throttle |
| `SHIFT` | boost |
| `J` (hold) | frame shift cruise |
| `SPACE` | fire |
| `T` / `Y` / `G` | target next / next hostile / scan |
| `L` | landing gear |
| `ENTER` | dock or enter |
| `U` | disembark / board |
| `TAB` | galaxy map |
| `N` / `C` | logbook / colonies |
| `V` | cockpit or chase view |
| `RMB` | toggle mouse flight |
| `F1` | controls |
| `F5` / `F9` | save / load |
| `F2` / `F3` / `F4` | wireframe / debug / CRT filter |

On foot: `WASD` move, `SHIFT` run, `SPACE` jump, mouse look, `E` interact.

Frame shift cruise is speed-limited by proximity to mass — its ceiling is
`0.06 × distance to the nearest surface` — so you decelerate naturally on
approach and cannot engage it below 4.5 km. That one rule is what makes flying
from a station to a planet and down to its surface a single continuous motion.

---

## Layout

```
main.lua              entry point and error handler
conf.lua              LÖVE configuration
src/config.lua        all tuning: scales, flight model, economy
src/settings.lua      player settings schema + persistence
src/input.lua         action bindings on top of baton (keyboard/mouse/gamepad)

lib/                  vendored MIT libraries (see lib/README.md)
src/ecs/              components and systems running on tiny-ecs

src/lib/              class, vec3, mat4, deterministic rng, noise, serialisation
src/render/           renderer, shaders, mesh builder, geometry, camera,
                      palette, sky, celestial bodies, HUD
src/procgen/          galaxy, systems, terrain, surface streaming, ships,
                      buildings, settlements, interiors, stations, names
src/sim/              economy, commodities, factions and diplomacy, missions,
                      colonies, equipment, player, NPC AI, combat, world clock
src/states/           menu, flight, on foot, interiors, port, galaxy map,
                      logbook, colonies, settings, pause, game over
src/ui/               immediate-mode widgets

tests/run.lua         head-less suite: 451 assertions, no LÖVE needed
tests/selftest.lua    scripted run through every screen, under real LÖVE
```

### Determinism

Every procedural feature derives from `src/lib/rng.lua`, which is L'Ecuyer's
combined multiple-recursive generator running exactly in IEEE doubles. We
deliberately avoid `math.random` (implementation-defined) and bitwise operators
(missing in 5.1, spelled differently in 5.3 and LuaJIT), so the same seed builds
the same universe on every machine and every Lua build. The test suite asserts
this.

### Saving

Only mutable state is saved — the commander, the clock, market stock,
diplomacy, colonies. Everything else regenerates from its seed. Saves are plain
Lua tables written with `src/lib/serialize.lua`, so they are diffable and
readable.

---

## Testing

`tests/run.lua` runs without LÖVE at all: the mesh builder falls back to plain
tables and no simulation module ever touches `love.*`. That makes the generators
testable in CI and makes balance questions answerable without launching the
game — there is a test that asserts one hold of cargo across two complementary
economies turns a profit, and one that asserts the ground under a landing site
agrees with the planet you saw from orbit.

```
luajit tests/run.lua
```

`tests/selftest.lua` needs a real GPU and covers what the head-less suite
cannot: it starts a commander, flies, fires, descends to a surface, lands,
disembarks, walks into a building, trades at a terminal, opens the galaxy map,
jumps, saves and reloads — drawing every frame and reporting each step.

```
love . --selftest
```

## Requirements

LÖVE 11.3 or newer, and a GPU that supports depth canvases (anything from the
last fifteen years). The head-less test suite needs only LuaJIT or Lua 5.1+.
