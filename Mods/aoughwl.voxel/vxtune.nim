## What a settings screen asks for, turned into what this world measures in.
##
## Every value an options screen sends arrives as text, in the range Mojang
## chose, and none of those ranges is the one this world works in: a view is
## counted in sixteen-block chunks over there and in forty-eight-block regions
## here, and a sensitivity is a percentage of a look speed that came out of a
## catalog and is not known until the character is configured. Getting either
## mapping wrong is a thing you would otherwise find out by standing in the
## world and guessing at the horizon, so all of it is here, where it calls no
## host and `Tests/voxel_test.exe` can break it.
##
## Nothing here decides whether a setting is honoured - that is `main.nim`,
## which is the only part that knows what actually moved.

const
  McChunk* = 16
    ## Minecraft's chunk, in blocks. The same number as `vxworld.ChunkSize`,
    ## written again so this module depends on nothing.
  TuneRegion* = 48
    ## `vxlod.LodRegion`, for the same reason.

  MinRender* = 2
  MaxRender* = 32
    ## Minecraft's own render-distance range, in chunks.
  MinFov* = 30
  MaxFov* = 110
  MaxSensitivity* = 200
    ## A hundred is the feel the world already has, so twice that is as far as
    ## the slider goes in the direction that is not "stop".

## Whether every character is a digit and there is at least one, because
## `wholeOf` answers zero for rubbish and zero is also a legitimate value for
## half of these settings. A caller that cannot tell them apart says `ok` to a
## typo.
proc isWhole*(text: string): bool =
  if text.len == 0: return false
  var i = 0
  while i < text.len:
    if text[i] < '0' or text[i] > '9': return false
    inc i
  true

## The number, for text `isWhole` has already agreed to.
proc wholeOf*(text: string): int =
  var value = 0
  var i = 0
  while i < text.len:
    value = value * 10 + (int(text[i]) - int('0'))
    inc i
  value

proc clampWhole*(value, lo, hi: int): int =
  if value < lo: return lo
  if value > hi: return hi
  value

## `0` and `1`, and nothing else - not "true", not "on". The screen sends one of
## two characters and anything else is a bug on that side that should be said
## out loud rather than guessed at.
proc isFlag*(text: string): bool = text == "0" or text == "1"

## How many rings of far regions a render distance of that many chunks needs.
##
## Minecraft counts its view in chunks of sixteen blocks; this world draws its
## horizon in regions of forty-eight. So three of Mojang's chunks are one of our
## rings, and a distance that is not a multiple of three rounds **up**: a player
## who asked for eight chunks gets nine, because a horizon that stops short of
## what was asked for is the one of the two mistakes you can see from where you
## are standing.
##
## Never zero. A radius of nothing is a scene of one region, the one the player
## is standing in, and the near world already covers most of that - so the
## horizon would vanish rather than shrink.
proc lodRadiusFor*(chunks: int): int =
  let blocks = clampWhole(chunks, MinRender, MaxRender) * McChunk
  result = (blocks + TuneRegion - 1) div TuneRegion
  if result < 1: result = 1

## The other way round: how many whole Minecraft chunks a horizon of that many
## rings actually reaches. What the debug line says, so a play script reads the
## distance the world is drawing and not the one that was asked for.
proc renderChunksFor*(radius: int): int = radius * TuneRegion div McChunk

## A hundred per cent is exactly the look speed the control scheme tuned, so a
## world nobody has touched feels the way it always did. Linear either side of
## it, and zero is a head that does not turn rather than a refused value: a
## slider dragged to the bottom gets what the slider says.
proc lookSpeedFor*(base: float; percent: int): float =
  base * float(clampWhole(percent, 0, MaxSensitivity)) / 100.0

## Whole degrees, because that is what the slider has.
proc fovFor*(degrees: int): float =
  float(clampWhole(degrees, MinFov, MaxFov))
