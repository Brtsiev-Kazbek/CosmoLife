# assets

The project generates all of its art at runtime and ships no textures, models
or sounds. These two font files are the one exception, and they are here for a
concrete reason: LÖVE's built-in font covers Latin only, so with it the Russian
localisation renders as a row of empty boxes.

| file | font | licence |
|---|---|---|
| `DejaVuSans.ttf` | DejaVu Sans | Bitstream Vera / DejaVu licence (free, permissive, redistributable) |
| `DejaVuSansMono.ttf` | DejaVu Sans Mono | same |

DejaVu covers Latin, Cyrillic and Greek, which is what the interface needs.
`src/ui/widgets.lua` loads these and falls back to LÖVE's own font if they are
missing, so deleting this directory degrades the game to Latin-only rather than
breaking it.
