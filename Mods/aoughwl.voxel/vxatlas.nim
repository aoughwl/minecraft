## Where a face's texture coordinate lands on a block's sheet.
##
## A mesh has one material, so a block whose six faces are six pictures - grass,
## a log, a furnace - is a *sheet* with the faces packed into it and every face's
## uvs moved into its own tile. That packing already exists and is already
## proved: `aoughwl.minecraft`'s `mcatlas.nim` builds exactly this sheet out
## of a Minecraft block model, and `Tests/minecraft_test.exe` asserts it.
##
## **This file is not a copy of that reader.** It holds no PNG, no packer and no
## pixels; it is the *consumer* half of the same contract, which is six lines of
## arithmetic and the description of a catalog row. That mod publishes a sheet,
## this one reads coordinates onto it, and neither imports the other.
##
## ## The contract, spelled out
##
## A sheet is one row of square tiles, each `side` pixels across, each padded by
## `Pad` pixels of its own replicated edge. So the pitch of a tile is
## `side + 2 * Pad`, the sheet is `pitch * columns` wide and `pitch` tall, and
## the interior of tile `t` runs from `t * pitch + Pad` to `t * pitch + Pad +
## side`.
##
## The padding is the whole reason this is a written-down convention rather than
## a division. The host filters and mipmaps a texture, so a sample at the very
## edge of a tile reaches past it; without a pixel of the tile's own edge to
## reach into, a stone block at chunk distance gets a rim of whatever was packed
## beside it. Addressing only the interior and padding by one is what stops that,
## and it is why `tileU` is not `(tile + u) / columns`.
##
## ## The catalog rows
##
## Two facets of the `aoughwl.block` catalog, spelled the way
## `aoughwl.inventory` spells facets - the base catalog's id plus a suffix -
## so a mod that fills them never names this one:
##
## | catalog | value |
## | --- | --- |
## | `voxel.blocks.atlas` | the picture: a `data:` URI, or a file inside the mod that contributed the row |
## | `voxel.blocks.tiles` | `<columns>x<side>\|<+X>,<-X>,<+Y>,<-Y>,<+Z>,<-Z>` |
##
## `voxel.blocks.tiles` without an atlas beside it means nothing. A block with
## neither is painted its flat colour, which is what every block did before this
## file existed and still does.
##
## ## The other shape a picture arrives in, and why it is the one that ships
##
## An `atlas` row with **no** `tiles` row beside it is not a sheet: it is the
## block's own picture, or - `|` separated, in the world's face order - one
## picture per face. A picture with nothing said about how it is packed is not
## packed.
##
## That distinction is the whole of whether a run of blocks may be merged into
## one quad. A tile inside a padded slot cannot repeat: a `u` past the slot is
## the tile next door, which is exactly what the padding exists to prevent and
## what `tileUAt` clamps against. A whole picture has nothing next door, and the
## host decodes every texture with `wrapMode = TextureWrapMode.Repeat`
## (`Runtime/Unity/UnityApi.cs`), so a `u` of sixteen is that picture sixteen
## times - which is what one merged quad over sixteen blocks means.
##
## The trade is meshes against quads, and it was measured rather than guessed.
## A sheet is one mesh per chunk and one quad per block face; whole pictures are
## one mesh per picture and one quad per merged run. Over the same twenty frames
## of the same world: 45 meshes and 52,009 crossings against 75 meshes and
## 4,769. A mesh costs about five crossings and a quad costs five, so the mesh
## count never had a chance of paying for the quads.
##
## Both shapes stay. `aoughwl.minecraft` builds a sheet out of a resource
## pack and must go on being able to hand one over; it is read here and meshed
## the old way, one quad per face.

const
  Pad* = 1
    ## One pixel of replicated edge round every tile. The same constant
    ## `mcatlas.nim` packs with; the two have to agree or every block wears a
    ## sliver of its neighbour.
  DefaultSide* = 16

type
  Skin* = object
    ## What one kind of block wears.
    atlas*: string
      ## The picture, as `useTexture` takes it: a `data:` URI, or a path inside
      ## the folder of the mod that contributed the catalog row. Empty means
      ## this block is painted a flat colour instead.
    columns*: int
    side*: int
    tile*: array[6, int]
      ## Which tile each face reads, in the world's own face order:
      ## +X, -X, +Y, -Y, +Z, -Z.
    face*: array[6, string]
      ## When `whole`: the picture each face wears, one per face, in that same
      ## order. A sheet leaves these empty and reads `tile` instead.
    whole*: bool
      ## The pictures are whole pictures rather than slots in a sheet.
      ##
      ## This is the difference between a block that can be *merged* and one
      ## that cannot, and it is the whole of it. A tile inside a padded sheet
      ## cannot repeat - a `u` past its slot is the tile next door, which is
      ## precisely what the padding exists to stop - so a run of sixteen blocks
      ## of it has to be sixteen quads. A picture that IS the tile has nothing
      ## next door: the host decodes every texture with
      ## `wrapMode = TextureWrapMode.Repeat` (`Runtime/Unity/UnityApi.cs`), so a
      ## `u` of sixteen is that picture sixteen times over - which is exactly
      ## what one merged quad across sixteen blocks means.
      ##
      ## What it costs is meshes: a mesh carries one texture, so a chunk becomes
      ## one mesh per *picture* in it rather than one per sheet. That trade is
      ## measured and it is not close. A mesh is about five crossings - a spawn,
      ## a surface, a texture, and the begin and end of it - and the quads it
      ## saves are five crossings each; the same twenty frames of the same world
      ## are 45 meshes and 52,009 crossings on a sheet, and 75 meshes and 4,769
      ## crossings on whole pictures.
    problem*: string

proc plainSkin*(): Skin =
  Skin(atlas: "", columns: 1, side: DefaultSide, tile: [0, 0, 0, 0, 0, 0],
    face: ["", "", "", "", "", ""], whole: false, problem: "")

proc textured*(s: Skin): bool = s.atlas.len > 0 and s.columns > 0

## Whether a merged quad of this block would carry its picture correctly - the
## one question the mesher asks before growing a run. A block painted a flat
## colour has no picture to stretch; a block wearing whole pictures repeats
## them; a block on a sheet can do neither.
proc repeats*(s: Skin): bool =
  if not s.textured(): return true
  s.whole

## The picture one face wears, in whichever shape the skin arrived. A sheet
## answers the sheet for every face, because that is the one texture its mesh
## carries; whole pictures answer that face's own.
proc facePicture*(s: Skin; face: int): string =
  if not s.whole: return s.atlas
  if face < 0 or face > 5: return s.face[0]
  s.face[face]

# ---------------------------------------------------------------------------
# Reading the row

proc digitOf(c: char): int =
  if c >= '0' and c <= '9': return int(c) - int('0')
  -1

## A non-negative whole number, or -1. Deliberately not the float reader in
## `vxblocks`: a tile index that is nearly two is not a tile index.
proc readWhole*(text: string): int =
  if text.len == 0: return -1
  var value = 0
  var i = 0
  var digits = 0
  while i < text.len:
    if text[i] == ' ' or text[i] == '\t':
      inc i
      continue
    let d = digitOf(text[i])
    if d < 0: return -1
    value = value * 10 + d
    inc digits
    inc i
  if digits == 0: return -1
  value

## `<columns>x<side>|t,t,t,t,t,t`, and every part of it optional from the right.
## A row that will not read keeps the defaults and says so in `problem`, because
## a resource pack is other people's data and a typo in it must cost one block's
## texture rather than the session.
## Six pictures out of a row that names between one and six of them, `|`
## separated, in the world's face order, the last one repeating - exactly the
## rule the tile row already follows for its indices, so a provider learns one
## convention rather than two.
##
## `|` and not `,`: a `data:` URI carries commas of its own and base64 never
## carries a bar, so this is the one separator that cannot cut a picture in
## half. `mcatlas` ends in `dataUri(encodePng(...))` and this has to survive it.
proc splitPictures*(row: string): array[6, string] =
  result = ["", "", "", "", "", ""]
  var face = 0
  var field = ""
  var last = ""
  var i = 0
  while i <= row.len:
    if i == row.len or row[i] == '|':
      if face < 6:
        result[face] = field
        last = field
        inc face
      field = ""
    else:
      field.add row[i]
    inc i
  while face < 6:
    result[face] = last
    inc face

## `atlas` is the picture (or, `|` separated, one per face) and `tiles`
## describes the sheet it sits in.
##
## **A picture with no sheet description is not a sheet.** An `atlas` row with
## no `tiles` row beside it is a whole picture per face, addressed 0..n and
## repeatable; an `atlas` row with a `tiles` row is a packed sheet and is
## addressed inside its padded slot. That is the only thing that tells the two
## apart, it needs no new facet, and it reads the way somebody filling the rows
## would expect: if you did not say how your picture is packed, it is not
## packed.
proc parseSkin*(atlas, tiles: string): Skin =
  result = plainSkin()
  result.atlas = atlas
  if tiles.len == 0:
    if atlas.len > 0:
      result.whole = true
      result.face = splitPictures(atlas)
      # `atlas` goes on meaning "the picture this block wears" for anything that
      # only wants one of them, which is every caller that is not the mesher.
      result.atlas = result.face[0]
    return result
  var head = ""
  var rest = ""
  var mark = -1
  var i = 0
  while i < tiles.len:
    if tiles[i] == '|':
      mark = i
      break
    inc i
  if mark < 0:
    head = tiles
  else:
    i = 0
    while i < mark:
      head.add tiles[i]
      inc i
    i = mark + 1
    while i < tiles.len:
      rest.add tiles[i]
      inc i

  # <columns>x<side>
  var columnsText = ""
  var sideText = ""
  var atX = -1
  i = 0
  while i < head.len:
    if head[i] == 'x' or head[i] == 'X':
      atX = i
      break
    inc i
  if atX < 0:
    columnsText = head
  else:
    i = 0
    while i < atX:
      columnsText.add head[i]
      inc i
    i = atX + 1
    while i < head.len:
      sideText.add head[i]
      inc i
  if columnsText.len > 0:
    let columns = readWhole(columnsText)
    if columns > 0: result.columns = columns
    else: result.problem.add "'" & columnsText & "' is not a column count; "
  if sideText.len > 0:
    let side = readWhole(sideText)
    if side > 0: result.side = side
    else: result.problem.add "'" & sideText & "' is not a tile size; "

  # Six tile indices. Fewer than six is legal and the last one repeats, which is
  # what makes "one picture on every face" the single character `0`.
  var face = 0
  var field = ""
  var last = 0
  i = 0
  while i <= rest.len:
    if i == rest.len or rest[i] == ',':
      if field.len > 0 and face < 6:
        let want = readWhole(field)
        if want >= 0 and want < result.columns:
          result.tile[face] = want
          last = want
        else:
          result.problem.add "'" & field & "' is not a tile of this sheet; "
          result.tile[face] = last
        inc face
      field = ""
    else:
      field.add rest[i]
    inc i
  while face < 6:
    result.tile[face] = last
    inc face

proc formatTiles*(s: Skin): string =
  result = $s.columns & "x" & $s.side & "|"
  var i = 0
  while i < 6:
    if i > 0: result.add ","
    result.add $s.tile[i]
    inc i

# ---------------------------------------------------------------------------
# The mapping itself

proc clamped(v: float): float =
  if v < 0.0: return 0.0
  if v > 1.0: return 1.0
  v

## Across the sheet. `u` arrives in 0..1 of that face's own picture and leaves in
## 0..1 of the whole sheet, inside tile `tile`'s padding.
##
## Clamped first, and that is the honest failure rather than a wrap: a wrapped
## coordinate on a sheet is not a wrap, it is the tile next door showing up on
## this block.
##
## Said in scalars rather than in a `Skin` because the mesher calls it four
## times a face and the interpreter copies an object with a string in it every
## time one crosses a signature. `columns` of zero means no sheet, and `u` comes
## back untouched.
proc tileUAt*(columns, side, tile: int; u: float): float =
  if columns <= 0 or side <= 0: return u
  var at = tile
  if at < 0 or at >= columns: at = 0
  let pitch = float(side + 2 * Pad)
  (float(at) * pitch + float(Pad) + clamped(u) * float(side)) /
    (pitch * float(columns))

## Up the sheet. There is one row of tiles, so every face's v maps the same way,
## and row 0 being the top while v counts up from the bottom cancels out.
proc tileVAt*(columns, side: int; v: float): float =
  if columns <= 0 or side <= 0: return v
  let pitch = float(side + 2 * Pad)
  (float(Pad) + clamped(v) * float(side)) / pitch

## The same three, said as a skin, for everything that is not the hot loop.
proc tileU*(s: Skin; tile: int; u: float): float =
  if not s.textured(): return u
  tileUAt(s.columns, s.side, tile, u)

proc tileV*(s: Skin; v: float): float =
  if not s.textured(): return v
  tileVAt(s.columns, s.side, v)

## What a face of this block reads, given the face number the mesher is
## emitting.
proc faceU*(s: Skin; face: int; u: float): float =
  if face < 0 or face > 5: return s.tileU(0, u)
  s.tileU(s.tile[face], u)

## Which tile a face reads, for a caller that pulled the sheet's numbers out
## once and is about to map four corners with them.
proc faceTile*(s: Skin; face: int): int =
  if face < 0 or face > 5: return 0
  s.tile[face]

# ---------------------------------------------------------------------------
# Which faces can share one mesh

## The material a face wants, as a string two faces can be compared by. Faces
## that agree on it can be one mesh; faces that do not, cannot, because the host
## gives a mesh one material.
##
## This is the whole of how many meshes a chunk becomes. Blocks that share a
## sheet share a mesh - so a world whose blocks are all packed into one sheet is
## one mesh per chunk, and a world of blocks that each brought their own picture
## is one per block. Neither is a special case in the mesher; both fall out of
## comparing this string.
proc materialKey*(s: Skin; colour: string): string =
  if s.textured(): return "t:" & s.atlas
  "c:" & colour

## The same question asked per *face*, which is what a world of whole pictures
## needs: a sheet answers one key for all six faces because its mesh carries the
## one sheet, and whole pictures answer one key per picture, so a grass block's
## top, sides and bottom land in three meshes and each of the three can merge.
##
## A block whose six faces name the same picture still answers one key six
## times and is still one mesh - which is the common case and costs nothing.
proc faceMaterialKey*(s: Skin; face: int; colour: string): string =
  if not s.textured(): return "c:" & colour
  if not s.whole: return "t:" & s.atlas
  "p:" & s.facePicture(face)
