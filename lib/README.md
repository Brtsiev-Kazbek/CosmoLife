# Vendored libraries

Third-party Lua modules, committed verbatim with their licence headers intact.
They are vendored rather than fetched at build time so the game has no install
step and stays reproducible.

| file | library | author | licence | used for |
|---|---|---|---|---|
| `tiny.lua` | [tiny-ecs](https://github.com/bakpakin/tiny-ecs) | Calvin Rose | MIT | the entity–component–system that runs flight entities |
| `baton.lua` | [baton](https://github.com/tesselode/baton) | Andrew Minnich | MIT | input: rebindable actions, analogue pairs, gamepad support with deadzones |
| `flux.lua` | [flux](https://github.com/rxi/flux) | rxi | MIT | tweening for camera moves and UI transitions |

None of these are modified. Project code wraps them:

* `src/input.lua` configures baton and owns the bindings the settings screen edits;
* `src/ecs/` defines the components and systems that run on tiny-ecs;
* `src/lib/*` remains our own code (deterministic RNG, maths, serialisation) —
  those have requirements (bit-exact reproducibility across Lua builds) that
  general-purpose libraries do not promise.
