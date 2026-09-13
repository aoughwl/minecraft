## Six pictures into one, because a mesh has one material.
##
## The host's mesh builder has no submeshes (`docs/TEXTURES.md`, *What this does
## not do yet*), so a model may name exactly one picture. A Minecraft block
## routinely names three - a grass block is grass on top, dirt underneath and a
## third thing round the sides - and the previous importer answered that by
## putting the first face's texture on all six, which is why its grass was a
## dirt cube.
##
## This answers it the other way round: the tiles are laid in a row, the sheet
## is handed over as one `data:` URI, and every face's texture coordinates are
## moved into its own tile. The mesh stays one mesh and the block is right.
##
## Two details are the whole of why this works rather than nearly works.
##
## **Every tile is padded by a pixel of its own edge.** A texture is filtered
## and mipmapped by the host, so a sample at the very edge of a tile reaches
## into its neighbour and a stone block gets a rim of oak plank. Padding by one
## replicated pixel and addressing only the interior means the filter has
## something to reach into that is the right colour. It costs, for six 16x16
## tiles, going from 96x16 to 108x18.
##
## **An animated texture is a strip, and one frame of it goes in the sheet.**
## Minecraft stores fire, water and lava as one column of square frames beside a
## `.mcmeta` that says how fast to play them. `frameOf` takes any frame and
## `buildAtlasAt` puts a chosen one in each tile, so a mod holding a schedule
## from `mcanim` can rebuild the sheet as the animation runs. Nothing here runs
## it: the importer asks for frame zero, says in the log that it did, and
## publishes the schedule so a mod can do better later.

import mcpng
import mcmodel

const
  MaxTiles* = 32
    ## A block model has at most six faces per element and a handful of
    ## elements. Thirty-two distinct textures on one block is a resource pack
    ## doing something this was not built for, and the import says so.
  MaxSheetTiles* = 48
    ## A sheet shared by *many blocks*, rather than by the six faces of one.
    ##
    ## This is here, still works, and is **not what the voxel world is given** -
    ## see `facesRow` at the foot of this file and section 9 of
    ## `docs/MINECRAFT-IMPORT.md`. A padded tile cannot repeat, so a chunk
    ## mesher handed a sheet has to emit one quad per block face instead of one
    ## per merged run, and that was measured at 52,009 host crossings against
    ## 4,769 over the same twenty frames of the same world. The packing is
    ## correct; it is the wrong shape to hand a mesher.
  Pad* = 1

type
  Atlas* = object
    image*: Image
    tile*: int      ## the side of one tile, in pixels, without its padding
    columns*: int
    problem*: string

proc emptyAtlas*(): Atlas =
  Atlas(image: emptyImage(), tile: 0, columns: 0, problem: "")

proc pitch*(a: Atlas): int = a.tile + 2 * Pad

## One frame of what may be an animated strip. Minecraft's rule is that a
## texture whose height is a whole multiple of its width is a column of square
## frames; a plain 16x16 is that rule with one frame in it, so this needs no
## `.mcmeta` to be right about the shape, and `mcanim` reading the `.mcmeta`
## only ever tells it which frame to ask for and how long to hold it.
##
## A frame past the end of the strip, or a picture that is not a strip at all,
## answers with what is there rather than with a hole: a caller working from a
## `.mcmeta` that lies about a picture gets the first frame, not nothing.
proc frameOf*(img: Image; index: int): Image =
  result = emptyImage()
  if img.width <= 0 or img.height <= 0:
    result.problem = "this picture has no size"
    return result
  if img.height <= img.width: return img
  if img.height mod img.width != 0:
    # Not a strip: something else is going on, and cropping would be a guess.
    return img
  let frames = img.height div img.width
  var at = index
  if at < 0 or at >= frames: at = 0
  result.width = img.width
  result.height = img.width
  let want = img.width * img.width * 4
  var i = 0
  let from0 = at * want
  while i < want:
    result.rgba.add img.rgba[from0 + i]
    inc i

## Frame zero, which is what a sheet built without an animation schedule uses.
proc firstFrame*(img: Image): Image = frameOf(img, 0)

## Whether a texture is a strip of frames, and how many. Only for saying so.
proc frameCount*(img: Image): int =
  if img.width <= 0 or img.height <= 0: return 0
  if img.height <= img.width: return 1
  if img.height mod img.width != 0: return 1
  img.height div img.width

## The stand-in for a picture that would not read. Magenta and black, sixteen
## by sixteen, because a missing texture has to look missing: a face left blank
## or left white reads as a deliberate white block, and then nobody goes looking
## for the file that never arrived.
proc solidTile*(): Image =
  result = emptyImage()
  result.width = 16
  result.height = 16
  var y = 0
  while y < 16:
    var x = 0
    while x < 16:
      let lit = ((x div 4) + (y div 4)) mod 2 == 0
      result.rgba.add (if lit: 255 else: 0)
      result.rgba.add 0
      result.rgba.add (if lit: 255 else: 0)
      result.rgba.add 255
      inc x
    inc y

proc sample(img: Image; x, y: int; r, g, b, a: var int) =
  var sx = x
  var sy = y
  if sx < 0: sx = 0
  if sx >= img.width: sx = img.width - 1
  if sy < 0: sy = 0
  if sy >= img.height: sy = img.height - 1
  let at = (sy * img.width + sx) * 4
  r = img.rgba[at]
  g = img.rgba[at + 1]
  b = img.rgba[at + 2]
  a = img.rgba[at + 3]

proc put(img: var Image; x, y, r, g, b, a: int) =
  let at = (y * img.width + x) * 4
  img.rgba[at] = r
  img.rgba[at + 1] = g
  img.rgba[at + 2] = b
  img.rgba[at + 3] = a

## Lay the tiles out in a row. Tiles of different sizes - a resource pack that
## replaced some textures at a higher resolution and not others - are all
## brought up to the biggest, nearest-neighbour, which is the only resampling
## that leaves Minecraft's art looking like Minecraft's art.
proc buildAtlasAt*(tiles: seq[Image]; pick: seq[int]; limit = MaxTiles): Atlas =
  result = emptyAtlas()
  if tiles.len == 0:
    result.problem = "there are no pictures to put in a sheet"
    return result
  if tiles.len > limit:
    result.problem = "this model wants " & $tiles.len &
      " textures on one mesh, and the sheet holds " & $limit
    return result
  var side = 0
  var i = 0
  while i < tiles.len:
    let frame = frameOf(tiles[i], (if i < pick.len: pick[i] else: 0))
    if frame.width <= 0:
      result.problem = "one of the pictures has no size"
      return result
    if frame.width > side: side = frame.width
    inc i
  if side <= 0:
    result.problem = "every picture is empty"
    return result
  result.tile = side
  result.columns = tiles.len
  let p = side + 2 * Pad
  result.image.width = p * tiles.len
  result.image.height = p
  var n = 0
  let total = result.image.width * result.image.height * 4
  while n < total:
    result.image.rgba.add 0
    inc n
  i = 0
  while i < tiles.len:
    let frame = frameOf(tiles[i], (if i < pick.len: pick[i] else: 0))
    let left = i * p
    var y = 0
    while y < p:
      var x = 0
      while x < p:
        # Clamped sampling is what makes the padding a copy of the edge: a
        # coordinate outside the tile reads the nearest pixel inside it.
        var sx = ((x - Pad) * frame.width) div side
        var sy = ((y - Pad) * frame.height) div side
        if x < Pad: sx = 0
        if y < Pad: sy = 0
        if x >= Pad + side: sx = frame.width - 1
        if y >= Pad + side: sy = frame.height - 1
        var r = 0
        var g = 0
        var b = 0
        var a = 0
        sample(frame, sx, sy, r, g, b, a)
        put(result.image, left + x, y, r, g, b, a)
        inc x
      inc y
    inc i

## The same sheet with every tile on its first frame, which is what a caller
## that is not animating anything wants and is every caller today.
proc buildAtlas*(tiles: seq[Image]): Atlas =
  var pick: seq[int] = @[]
  var i = 0
  while i < tiles.len:
    pick.add 0
    inc i
  buildAtlasAt(tiles, pick)

## Move one face's texture coordinate into its tile. `u` and `v` arrive in 0..1
## of that face's own picture, with v already counted up from the bottom the way
## the host wants it, and leave in 0..1 of the sheet.
##
## Both are clamped first. A model may legally name a uv outside its texture -
## Minecraft wraps - and on a sheet a wrap is not a wrap, it is the tile next
## door showing up on this block. Clamping is the honest failure: the edge
## repeats, which is what a wrapped coordinate looked like anyway for the
## overwhelming majority of models, and no block ever wears its neighbour's skin.
proc remap*(a: Atlas; tile: int; u, v: float; ou, ov: var float) =
  ou = u
  ov = v
  if a.columns <= 0 or tile < 0 or tile >= a.columns: return
  var cu = u
  if cu < 0.0: cu = 0.0
  if cu > 1.0: cu = 1.0
  var cv = v
  if cv < 0.0: cv = 0.0
  if cv > 1.0: cv = 1.0
  let p = float(a.tile + 2 * Pad)
  let side = float(a.tile)
  let pad = float(Pad)
  ou = (float(tile) * p + pad + cu * side) / float(a.image.width)
  # Row 0 of the sheet is its top and v counts up from its bottom, and with one
  # row of tiles those two facts cancel to the same offset on both sides.
  ov = (pad + cv * side) / float(a.image.height)

# ---------------------------------------------------------------------------
# The row a voxel world reads
#
# `aoughwl.voxel/vxatlas.nim` is the consumer half of this file's packing,
# written against it deliberately so that neither mod imports the other, and it
# reads two things: the picture, and which tile each of the world's six faces
# wears. The picture is `dataUri(encodePng(sheet.image))`, which is what this
# file already ends in. The tiles are a string, and this is where it is spelled.
#
#     <columns>x<side>|<+X>,<-X>,<+Y>,<-Y>,<+Z>,<-Z>
#
# Fewer than six indices repeats the last, so one picture on every face is the
# single character `0`. That shortening is *not* done here: a full six is one
# more comma and it is the spelling a person reading a catalog can check.
#
# ## Which Minecraft face is which world face
#
# The bake mirrors X - `mcmodel.emit` negates it, and that with the reversed
# winding is the whole right-to-left-handed conversion - so Minecraft's **east**
# face comes out on the world's **-X** side and its west face on +X. Y and Z are
# untouched. Getting this backwards mirrors every log, every furnace and every
# pumpkin in the world along one axis, and looks entirely plausible until you
# stand two of them side by side.
#
# It is stated as the same mirror the rest of the importer applies, rather than
# as Minecraft's own axes, so that a block a voxel world places and the same
# block spawned as a part wear their faces the same way round.

const WorldFaces*: array[6, int] = [
  FaceWest,   # +X, because X is mirrored on the way out
  FaceEast,   # -X
  FaceUp,     # +Y
  FaceDown,   # -Y
  FaceSouth,  # +Z
  FaceNorth]  # -Z

## Which baked face wears the world's `which` face, or -1 when the model has no
## face pointing that way. A caller with no answer repeats whatever it has,
## which is what a half-modelled block should look like rather than a hole.
proc worldFace*(b: Bake; which: int): int =
  if which < 0 or which > 5: return -1
  let want = WorldFaces[which]
  var f = 0
  while f < b.count:
    if b.face[f] == want: return f
    inc f
  -1

## The catalog row. `side` is the tile size without its padding, which is what
## `vxatlas.parseSkin` reads and what `tileUAt` divides by.
proc tilesRow*(columns, side: int; tile: array[6, int]): string =
  result = $columns & "x" & $side & "|"
  var i = 0
  while i < 6:
    if i > 0: result.add ","
    var at = tile[i]
    if at < 0 or at >= columns: at = 0
    result.add $at
    inc i

## Six whole pictures, as `aoughwl.voxel` reads a `voxel.blocks.atlas` row
## that has **no** `voxel.blocks.tiles` row beside it.
##
## The absence of the tiles row is the whole signal, and it needs no new facet:
## if you did not say how your picture is packed, it is not packed. A picture
## that is not packed has nothing next door, the host decodes every texture with
## `wrapMode = TextureWrapMode.Repeat`, and a `u` of sixteen is therefore that
## picture sixteen times - which is one merged quad over sixteen blocks instead
## of sixteen quads. A tile inside a padded slot cannot do that, because a `u`
## past the slot is the neighbour, which is the very thing the padding exists to
## prevent. That is the whole trade and it is why this exists beside the packer
## rather than instead of it.
##
## `|` and not `,`: a `data:` URI carries commas of its own and base64 never
## carries a bar, so this is the one separator that cannot cut a picture in
## half. The test puts a real `data:` URI through it for that reason.
##
## A trailing run of the same picture is dropped, because the reader repeats the
## last field - so a block with one picture on all six faces is one field, and a
## grass block is five.
proc facesRow*(uri: array[6, string]): string =
  var last = 5
  while last > 0 and uri[last] == uri[last - 1]: dec last
  result = ""
  var i = 0
  while i <= last:
    if i > 0: result.add "|"
    result.add uri[i]
    inc i

## Whether all six faces are filled in. A row with a hole in it would be read as
## a picture called nothing, so a block with one is not published at all and
## keeps the flat colour it already had.
proc facesWhole*(uri: array[6, string]): bool =
  var i = 0
  while i < 6:
    if uri[i].len == 0: return false
    inc i
  true
