## Tint: why grass was grey, and what is honest to do about it.
##
## Pure: nothing here calls the host.
##
## A `tintindex` on a face says "Minecraft multiplies this face by a colour it
## works out at draw time". For grass, leaves, vines and sugar cane that colour
## comes from the biome the block is standing in - a two-dimensional colour map
## indexed by temperature and rainfall, read out of `colormap/grass.png` - and
## for water from the biome's own water colour. The importer read the index,
## carried it on every face, and applied nothing, so every grass block, every
## leaf and every lily pad imported **grey**, which is exactly what the texture
## is: Minecraft ships them colourless on purpose.
##
## ## What this does instead, and why that is not a cop-out
##
## **A fixed biome.** There are no biomes in this game, so there is no honest
## way to ask what colour a block should be *here*. What there is, is the colour
## Minecraft itself uses at the middle of the grass colour map - the plains
## biome, which is the one every screenshot of Minecraft is taken in - and using
## it everywhere gives a world that looks like Minecraft rather than like a
## black-and-white photograph of it. The colours below are read off vanilla's
## own `colormap/grass.png` and `colormap/foliage.png` at the plains coordinate,
## plus the handful vanilla hard-codes.
##
## This is a **choice with a wrong side**, and the wrong side is worse: a grey
## world is not neutral, it is a bug that looks like a decision.
##
## **A table, not a heuristic.** Which of the colours a block wants is decided
## by a table of names, and where a name is not in it by a suffix rule that
## Minecraft's own naming makes reliable - anything `*_leaves` is foliage. It is
## a table because the alternative is branching on substrings of a name, which is
## the thing this project's house rules forbid and for good reason: `deepslate`
## contains `slate`, `grass_block` contains `grass`, and a rule that reads them
## as one thing is wrong in a way nobody finds.
##
## **It is applied to the atlas, not to the mesh.** A mesh has one material and
## no vertex colours (`docs/TEXTURES.md`), so there is nowhere to put a per-face
## colour. What there is, is the tile that face reads from, and multiplying the
## tile is the same picture. It costs nothing extra: the tile is already being
## copied into the sheet.
##
## The one thing it cannot do is tint two faces differently when they share a
## picture. In vanilla that case does not arise - a tinted face and an untinted
## one never name the same texture, because the whole point of the tint is that
## the texture is the grey one - and `tintOfTiles` says so rather than guessing:
## a tile that some faces tint and others do not is left alone and reported.

import mcpng
import mcmodel

const
  ## Vanilla's grass colour at the plains coordinate of `colormap/grass.png`.
  GrassTint* = 0x91BD59
  ## `colormap/foliage.png` at the same place: ordinary leaves, and vines.
  FoliageTint* = 0x77AB2F
  ## Spruce and birch do not read the map at all; Minecraft hard-codes these.
  SpruceTint* = 0x619961
  BirchTint* = 0x80A755
  ## Water, from the plains biome's own `water_color`.
  WaterTint* = 0x3F76E4
  ## The three Minecraft hard-codes outright, whatever the biome.
  LilyPadTint* = 0x208030
  RedstoneTint* = 0xFF0000
  StemTint* = 0x00FF00

  NoTint* = -1

## The blocks whose tint is not the one their name would suggest. Everything
## else falls to the suffix rules below, and everything that falls past those
## takes the grass colour, which is what Minecraft's own default tint is.
const
  NamedBlocks = [
    "spruce_leaves", "birch_leaves",
    "water", "water_still", "water_flow", "flowing_water", "bubble_column",
    "cauldron_water", "lily_pad", "redstone_dust_dot", "redstone_dust_side",
    "redstone_dust_side_alt", "redstone_dust_up", "redstone_dust_overlay",
    "melon_stem", "pumpkin_stem", "attached_melon_stem", "attached_pumpkin_stem"]
  NamedTints = [
    SpruceTint, BirchTint,
    WaterTint, WaterTint, WaterTint, WaterTint, WaterTint,
    WaterTint, LilyPadTint, RedstoneTint, RedstoneTint,
    RedstoneTint, RedstoneTint, RedstoneTint,
    StemTint, StemTint, StemTint, StemTint]

proc endsWith(name, tail: string): bool =
  if name.len < tail.len: return false
  var i = 0
  while i < tail.len:
    if name[name.len - tail.len + i] != tail[i]: return false
    inc i
  true

## What colour a tinted face of this model should be multiplied by, as 0xRRGGBB.
##
## `model` is the model's resource path - `block/grass_block` - and only its
## leaf is looked at, because that is the name Minecraft itself keys on.
## `tintIndex` below zero is not a tinted face and answers `NoTint`.
proc tintFor*(model: string; tintIndex: int): int =
  if tintIndex < 0: return NoTint
  let name = leaf(model)
  var i = 0
  while i < NamedBlocks.len:
    if NamedBlocks[i] == name: return NamedTints[i]
    inc i
  if endsWith(name, "_leaves"): return FoliageTint
  if endsWith(name, "_stem"): return StemTint
  # Grass, tall grass, fern, large fern, vine, sugar cane and the potted forms
  # of all of them read the grass map, and so does anything a pack invents with
  # a tintindex and no name this table knows. That default is Minecraft's own.
  GrassTint

## Which tiles of a model's sheet are tinted, and with what.
##
## One entry per name in `names` - the palette, which is the atlas's tile order
## - holding `NoTint` or a colour. A tile that some faces tint and others do not
## is left untinted and named in `problem`, because there is one picture and it
## cannot be two colours.
proc tintOfTiles*(b: Bake; names: seq[string]; model: string;
                  problem: var string): seq[int] =
  result = @[]
  var mixed: seq[bool] = @[]
  var tinted: seq[bool] = @[]
  var i = 0
  while i < names.len:
    result.add NoTint
    mixed.add false
    tinted.add false
    inc i
  var bare: seq[bool] = @[]
  i = 0
  while i < names.len:
    bare.add false
    inc i
  var f = 0
  while f < b.count:
    let tile = tileOf(b, f, names)
    if tile >= 0:
      if b.tint[f] < 0:
        bare[tile] = true
      else:
        let colour = tintFor(model, b.tint[f])
        if tinted[tile] and result[tile] != colour: mixed[tile] = true
        result[tile] = colour
        tinted[tile] = true
    inc f
  # A tile both a tinted and an untinted face read is one picture wanted in two
  # colours, whichever order the faces came in.
  i = 0
  while i < names.len:
    if tinted[i] and bare[i]: mixed[i] = true
    inc i
  i = 0
  while i < names.len:
    if mixed[i]:
      result[i] = NoTint
      if problem.len == 0:
        problem = "'" & leaf(names[i]) &
          "' is on both a tinted and an untinted face, so it is left untinted"
    inc i

## Multiply a picture by a colour, in place. Straight multiplication in eight-bit
## sRGB, which is what Minecraft's own shader does - it does not linearise, and
## matching it matters more here than being right about colour spaces.
##
## Alpha is untouched: a tint changes what colour a leaf is, never whether the
## gaps between the leaves are there.
proc applyTint*(img: var Image; rgb: int) =
  if rgb < 0: return
  let r = (rgb shr 16) and 255
  let g = (rgb shr 8) and 255
  let b = rgb and 255
  var i = 0
  while i + 3 < img.rgba.len:
    img.rgba[i] = (img.rgba[i] * r) div 255
    img.rgba[i + 1] = (img.rgba[i + 1] * g) div 255
    img.rgba[i + 2] = (img.rgba[i + 2] * b) div 255
    i = i + 4

## The colour as `#rrggbb`, for a catalog row and for a log line.
proc tintText*(rgb: int): string =
  if rgb < 0: return ""
  const Digits = "0123456789abcdef"
  result = "#"
  var shift = 20
  while shift >= 0:
    result.add Digits[(rgb shr shift) and 15]
    shift = shift - 4
