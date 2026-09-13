## The blocks this mod ships, and the sheet they wear, as data.
##
## They live here rather than as string literals in `main.nim` for one reason:
## `Tests/voxel_test.exe` can read this file and cannot read that one. A tile
## index that pointed off the end of the shipped sheet, a hardness that would not
## parse, a grass block whose top and sides read the same tile - every one of
## those is a thing you would find out by looking at a play session, and every
## one of them is now a failing check that takes a second.
##
## Nothing here is privileged. These are exactly the rows any other mod would
## add to `voxel.blocks` and its two facets; this mod's own set is just the one
## that arrives first.

const
  AtlasFile* = "Textures/blocks.png"
  AtlasColumns* = 13
  AtlasSide* = 16
    ## The sheet in `Textures/blocks.png`: thirteen sixteen-pixel tiles in a
    ## row, each padded by one pixel of its own edge.
    ##
    ##   0 stone        1 cobblestone  2 dirt      3 grass top   4 grass side
    ##   5 sand         6 wood top     7 wood side 8 leaves      9 brick
    ##  10 glowstone   11 bedrock     12 water
    ##
    ## `Textures/make_blocks_png.nim.txt` beside it is the program that drew it.

## The name of every block this mod puts in the catalog, in order.
proc defaultNames*(): seq[string] =
  @["bedrock", "stone", "cobblestone", "dirt", "grass", "sand", "water",
    "wood", "leaves", "brick", "glowstone"]

## The `voxel.blocks` row for each of them, in the same order.
proc defaultSpecs*(): seq[string] =
  @[
    "label=Bedrock;hardness=-1;colour=#2f2f33",
    "label=Stone;hardness=1.5;colour=#7d7d80;drops=cobblestone",
    "label=Cobblestone;hardness=2.0;colour=#8a8a8d",
    "label=Dirt;hardness=0.5;colour=#8b5a2b",
    "label=Grass;hardness=0.6;colour=#5d9b42;drops=dirt",
    "label=Sand;hardness=0.5;colour=#ddd0a0",
    "label=Water;hardness=-1;liquid=true;colour=#3a6fd0",
    "label=Wood;hardness=1.0;colour=#6b4a2a",
    "label=Leaves;hardness=0.2;colour=#3f7d33",
    "label=Brick;hardness=1.8;colour=#a8503c",
    "label=Glowstone;hardness=0.3;colour=#f0d47a"]

## The `voxel.blocks.atlas` row for each block, in the same order as
## `defaultNames`: the picture each of its six faces wears, `|` separated in the
## world's face order - +X, -X, +Y, -Y, +Z, -Z - and a single one where all six
## are the same. Fewer than six repeats the last, exactly as the tile row does.
##
## **These are whole pictures and not a sheet, and that is the point.** A tile
## packed into `blocks.png` cannot be repeated across a merged quad - a `u` past
## its padded slot is the tile next door - so a world dressed from the sheet is
## one quad per block face. A block whose picture is its own file repeats under
## the host's `wrapMode = Repeat`, so a run of sixteen is one quad with a `u` of
## sixteen. Measured over the same twenty frames, that is 52,009 crossings
## against 4,457.
##
## The cost is one mesh per picture rather than one per sheet - 45 meshes
## against 72 - which is roughly a hundred and thirty crossings against
## forty-seven thousand saved. `blocks.png` and `defaultTiles` stay exactly
## where they were, for a provider that has only a sheet to give.
proc defaultPictures*(): seq[string] =
  @[
    "Textures/blocks/bedrock.png",
    "Textures/blocks/stone.png",
    "Textures/blocks/cobblestone.png",
    "Textures/blocks/dirt.png",
    # Grass is the block that pays for the whole scheme: three pictures, so
    # three meshes, and each of the three merges.
    "Textures/blocks/grass_side.png|Textures/blocks/grass_side.png|" &
      "Textures/blocks/grass_top.png|Textures/blocks/dirt.png|" &
      "Textures/blocks/grass_side.png|Textures/blocks/grass_side.png",
    "Textures/blocks/sand.png",
    "Textures/blocks/water.png",
    "Textures/blocks/wood_side.png|Textures/blocks/wood_side.png|" &
      "Textures/blocks/wood_top.png|Textures/blocks/wood_top.png|" &
      "Textures/blocks/wood_side.png|Textures/blocks/wood_side.png",
    "Textures/blocks/leaves.png",
    "Textures/blocks/brick.png",
    "Textures/blocks/glowstone.png"]

## The `voxel.blocks.tiles` row for each, in the same order. Six tiles in the
## world's face order - +X, -X, +Y, -Y, +Z, -Z - and a single one where all six
## faces are the same picture.
##
## Kept, and no longer what this mod dresses itself with: it is the sheet
## spelling, which every other mod is still free to use and which
## `aoughwl.minecraft` produces. See `defaultPictures` for why the shipped
## blocks moved off it.
proc defaultTiles*(): seq[string] =
  @[
    "13x16|11",                 # bedrock
    "13x16|0",                  # stone
    "13x16|1",                  # cobblestone
    "13x16|2",                  # dirt
    "13x16|4,4,3,2,4,4",        # grass: sides, grass on top, dirt underneath
    "13x16|5",                  # sand
    "13x16|12",                 # water
    "13x16|7,7,6,6,7,7",        # wood: end grain on the two flat faces
    "13x16|8",                  # leaves
    "13x16|9",                  # brick
    "13x16|10"]                 # glowstone
