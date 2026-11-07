# Game data and research notes

These files are for people who want to build on the same game data. They are not needed to play the mod.

Game: Phantom Blade Zero, Steam build `26367565`, Unreal Engine 5.7.4.
The mapping file was generated from the game's own reflection data; game assets remain the property of S-GAME.

## Contents

```
data/
  full.usmap      mapping file for the shipping build
  schema.txt      readable class/property schema generated from full.usmap
tools/
  usmap_dump.js   parses full.usmap and writes schema.txt / schema.json
  check_lua_locals.js
                  counts active locals in a Lua chunk (UE4SS fails to load a chunk above 200)
notes/
  runtime-api.md  UE4SS and game API behaviour verified at runtime
  crash-analysis.md
                  fault addresses, call stacks and the current mitigation
  bossrush-trainer.md
                  a non-mod cause of "the boss takes no damage"
  break-research.md
                  early research on the poise/break system
```

## Regenerate the schema

```bash
node tools/usmap_dump.js
```

The script reads `data/full.usmap` and writes `data/schema.txt` and `data/schema.json` (the JSON file is not
committed because of its size). Any recent Node.js works; no packages are required.

## Check a Lua file for the local-variable limit

```bash
node tools/check_lua_locals.js path/to/main.lua
```

This uses `luaparse` (install it with `npm install luaparse` or point `NODE_PATH` at an existing install). The
custom UE4SS build rejects a chunk with more than 200 active locals with `main.lua:<line>: too many local
variables (limit is 200)`, and the whole mod fails to load. Wrapping self-contained sections in `do ... end`
brings the main chunk back under the limit.
