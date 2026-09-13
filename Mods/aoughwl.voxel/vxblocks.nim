## What a block *is*, and the registry every other mod fills.
##
## Nothing in this file calls the host. It is the half of the block system that
## can be wrong quietly - a hardness that parses as zero, a colour whose hex is
## read a nibble out, a name that collides with one another mod already put in -
## so it lives here and `Tests/voxel_test.exe` settles it in a second.
##
## A block arrives as one row of a catalog of kind `aoughwl.block`, whose
## value is text, because a catalog value is one scalar and a block is eight
## things. The text is a list of `field=value` pairs separated by semicolons:
##
##   label=Stone;hardness=1.5;solid=true;opaque=true;colour=#7f7f7f;drops=cobble
##
## Every field is optional and every one has a default that makes an ordinary
## solid block, so `addToCatalog("voxel.blocks", "stone", "colour=#7f7f7f")` is
## a complete contribution. An unknown field is kept in `problem` rather than
## thrown: a resource pack is other people's data, and a typo in it must cost
## the player one block, never the session.

const
  AirId* = 0
    ## Block 0 is nothing, always, in every registry. Meshing and collision both
    ## lean on that, so it is a constant rather than a lookup.
  UnknownId* = -1

type
  BlockDef* = object
    ## One kind of block. `name` is the catalog item id and is what another mod
    ## refers to it by; `id` is this session's numbering and is private to the
    ## world's storage.
    id*: int
    name*: string
    label*: string
    hardness*: float
      ## Seconds of holding the button to break it by hand. Zero means instant,
      ## and a negative one means it cannot be broken at all.
    solid*: bool
      ## Whether a body is stopped by it. Water is not.
    opaque*: bool
      ## Whether it hides the face of the block behind it. Glass would not.
    liquid*: bool
    red*, green*, blue*: float
    texture*: string
      ## A part reference for the picture this block wears - `minecraft://block/stone`,
      ## say. Carried and published; nothing in this mod paints with it yet.
    drops*: string
      ## What breaking it puts in your hand: another block's name, empty for
      ## itself, or "-" for nothing at all.
    provider*: string
    problem*: string

  Registry* = object
    defs*: seq[BlockDef]
    ## The three questions the mesher asks, one flat array each.
    ##
    ## This is not premature: `buildChunk` asks "is the block beyond this face
    ## opaque" twenty-four thousand times per chunk, and answering it out of
    ## `defs` means copying a `BlockDef` - six strings and eight numbers - that
    ## many times, in an interpreter, inside a frame. Measured, that copy was
    ## most of the cost of a chunk. These arrays are written only when a block
    ## is registered.
    solidFlag*: seq[bool]
    opaqueFlag*: seq[bool]
    hardValue*: seq[float]
    slots*: seq[int]
      ## Where a name is, by its hash: an index into `defs`, or -1 for an empty
      ## slot. Always a power of two long and never less than twice `defs.len`,
      ## so a probe always ends on an empty slot rather than going round.
      ##
      ## `idOf` was a scan of `defs`, and `registerBlock` calls `idOf` on every
      ## block that is put in, so filling a registry was quadratic in the number
      ## of blocks. Twelve blocks cost 78 comparisons and nobody noticed; a
      ## granted copy of Minecraft contributes 1172 and it is 687,000, inside an
      ## interpreter, inside the frame that starts the world. `aoughwl.spawner`
      ## has the same index over titles for the same reason, and the comment
      ## above `browser.Titles` is the longer version of this one.
      ##
      ## Empty means "not indexed yet" and every reader rebuilds rather than
      ## scanning, so a registry built by an older copy of this code - one
      ## deserialised, one in a test written before this field - still answers.

# ---------------------------------------------------------------------------
# Reading numbers out of text, without a standard library
#
# The pure modules import nothing, because they are compiled twice - once into
# the mod by the mod builder and once into the test by nimony - and the two
# toolchains agree on the language and not on the library.

proc digitOf(c: char): int =
  if c >= '0' and c <= '9': return int(c) - int('0')
  -1

proc hexOf(c: char): int =
  if c >= '0' and c <= '9': return int(c) - int('0')
  if c >= 'a' and c <= 'f': return 10 + int(c) - int('a')
  if c >= 'A' and c <= 'F': return 10 + int(c) - int('A')
  -1

## A decimal number, with an optional sign and an optional fraction. `ok` is
## false when the text is not one, and the result is then zero rather than a
## guess.
proc readNumber*(text: string; ok: var bool): float =
  ok = false
  var i = 0
  while i < text.len and (text[i] == ' ' or text[i] == '\t'): inc i
  var sign = 1.0
  if i < text.len and (text[i] == '-' or text[i] == '+'):
    if text[i] == '-': sign = -1.0
    inc i
  var whole = 0.0
  var digits = 0
  while i < text.len and digitOf(text[i]) >= 0:
    whole = whole * 10.0 + float(digitOf(text[i]))
    inc i
    inc digits
  if i < text.len and text[i] == '.':
    inc i
    var scale = 0.1
    while i < text.len and digitOf(text[i]) >= 0:
      whole = whole + float(digitOf(text[i])) * scale
      scale = scale * 0.1
      inc i
      inc digits
  while i < text.len and (text[i] == ' ' or text[i] == '\t'): inc i
  if digits == 0 or i != text.len: return 0.0
  ok = true
  sign * whole

proc readTruth*(text: string; ok: var bool): bool =
  ok = true
  if text == "true" or text == "yes" or text == "1": return true
  if text == "false" or text == "no" or text == "0": return false
  ok = false
  false

## `#rgb`, `#rrggbb` or `#rrggbbaa`, with or without the hash. Alpha is read and
## dropped: a block is either there or it is not, and this mod has no glass yet.
proc readColour*(text: string; r, g, b: var float; ok: var bool) =
  ok = false
  var start = 0
  if text.len > 0 and text[0] == '#': start = 1
  let count = text.len - start
  if count != 3 and count != 6 and count != 8: return
  var value: array[8, int] = [0, 0, 0, 0, 0, 0, 0, 0]
  var i = 0
  while i < count:
    let nibble = hexOf(text[start + i])
    if nibble < 0: return
    value[i] = nibble
    inc i
  ok = true
  if count == 3:
    r = float(value[0] * 17) / 255.0
    g = float(value[1] * 17) / 255.0
    b = float(value[2] * 17) / 255.0
  else:
    r = float(value[0] * 16 + value[1]) / 255.0
    g = float(value[2] * 16 + value[3]) / 255.0
    b = float(value[4] * 16 + value[5]) / 255.0

# ---------------------------------------------------------------------------
# The descriptor

proc plainBlock*(name: string): BlockDef =
  ## Every default a contributor does not have to write down.
  BlockDef(id: UnknownId, name: name, label: name, hardness: 1.0,
    solid: true, opaque: true, liquid: false,
    red: 0.7, green: 0.7, blue: 0.7, texture: "", drops: "",
    provider: "", problem: "")

## Two halves of `field=value`, with the whitespace off both ends. `mark` is
## where the `=` was; below zero when the pair has none.
proc splitPair(pair: string; key, value: var string) =
  key = ""
  value = ""
  var mark = -1
  var i = 0
  while i < pair.len:
    if pair[i] == '=':
      mark = i
      break
    inc i
  if mark < 0:
    key = pair
    return
  i = 0
  while i < mark:
    key.add pair[i]
    inc i
  i = mark + 1
  while i < pair.len:
    value.add pair[i]
    inc i

proc trimmed(text: string): string =
  result = ""
  var first = 0
  while first < text.len and (text[first] == ' ' or text[first] == '\t'): inc first
  var last = text.len - 1
  while last >= first and (text[last] == ' ' or text[last] == '\t'): dec last
  var i = first
  while i <= last:
    result.add text[i]
    inc i

## One catalog row read into a block. Never fails: a field that will not parse
## keeps its default and is named in `problem`.
proc parseBlockSpec*(name, spec: string): BlockDef =
  result = plainBlock(name)
  var field = ""
  var i = 0
  while i <= spec.len:
    if i == spec.len or spec[i] == ';':
      if field.len > 0:
        var key = ""
        var value = ""
        splitPair(field, key, value)
        # Never `key = trimmed(key)`. `x = f(x)` is a confirmed miscompile in
        # this toolchain: once anything has copied `x`, the assignment clears
        # the argument's string fields before the call runs, and the callee
        # silently takes the empty branch. A named intermediate is the fix, and
        # it has to stay one.
        let trimmedKey = trimmed(key)
        let trimmedValue = trimmed(value)
        key = trimmedKey
        value = trimmedValue
        var ok = false
        case key
        of "": discard
        of "label": result.label = value
        of "texture": result.texture = value
        of "drops": result.drops = value
        of "hardness":
          let v = readNumber(value, ok)
          if ok: result.hardness = v
          else: result.problem.add "hardness '" & value & "' is not a number; "
        of "solid":
          let v = readTruth(value, ok)
          if ok: result.solid = v
          else: result.problem.add "solid '" & value & "' is not true or false; "
        of "opaque":
          let v = readTruth(value, ok)
          if ok: result.opaque = v
          else: result.problem.add "opaque '" & value & "' is not true or false; "
        of "liquid":
          let v = readTruth(value, ok)
          if ok:
            result.liquid = v
            if v:
              result.solid = false
              result.opaque = false
          else: result.problem.add "liquid '" & value & "' is not true or false; "
        of "colour", "color":
          var r = 0.0
          var g = 0.0
          var b = 0.0
          readColour(value, r, g, b, ok)
          if ok:
            result.red = r
            result.green = g
            result.blue = b
          else: result.problem.add "colour '" & value & "' is not a hex colour; "
        else:
          result.problem.add "no such field '" & key & "'; "
      field = ""
    else:
      field.add spec[i]
    inc i

## Two decimal places, which is all a hardness or a colour channel needs, and
## enough that a spec written out and read back is the spec that went in.
proc twoPlaces(value: float): string =
  var v = value
  var sign = ""
  if v < 0.0:
    sign = "-"
    v = -v
  let scaled = int(v * 100.0 + 0.5)
  let whole = scaled div 100
  let rest = scaled mod 100
  result = sign & $whole & "."
  if rest < 10: result.add "0"
  result.add $rest

proc hexPair(value: float): string =
  const Digits = "0123456789abcdef"
  var v = int(value * 255.0 + 0.5)
  if v < 0: v = 0
  if v > 255: v = 255
  result = ""
  result.add Digits[v div 16]
  result.add Digits[v mod 16]

## A block's colour as the six hex digits it would be written as. Two blocks
## painted the same colour can share one mesh, so this is what an untextured
## block's material is compared by.
proc colourKey*(d: BlockDef): string =
  hexPair(d.red) & hexPair(d.green) & hexPair(d.blue)

## The other direction, so a mod can publish what it read. `parseBlockSpec` of
## this is the block it came from, which is what the test checks.
proc formatBlockSpec*(d: BlockDef): string =
  result = "label=" & d.label & ";hardness=" & twoPlaces(d.hardness) &
    ";solid=" & (if d.solid: "true" else: "false") &
    ";opaque=" & (if d.opaque: "true" else: "false") &
    ";liquid=" & (if d.liquid: "true" else: "false") &
    ";colour=#" & hexPair(d.red) & hexPair(d.green) & hexPair(d.blue)
  if d.texture.len > 0: result.add ";texture=" & d.texture
  if d.drops.len > 0: result.add ";drops=" & d.drops

# ---------------------------------------------------------------------------
# The registry

## A registry with nothing in it but air, which is block 0 in every registry.
proc newRegistry*(): Registry =
  var air = plainBlock("air")
  air.id = AirId
  air.label = "Air"
  air.hardness = -1.0
  air.solid = false
  air.opaque = false
  Registry(defs: @[air], solidFlag: @[false], opaqueFlag: @[false],
    hardValue: @[-1.0])

proc blockCount*(r: Registry): int = r.defs.len

## FNV-1a, masked to stay positive in 32 bits however wide an int is here. The
## same one `aoughwl.spawner`'s title index uses, spelled out again rather
## than imported: these pure modules import nothing, because they are compiled
## twice - once into the mod and once into the test - and the two toolchains
## agree on the language and not on the library.
func hashOfName*(text: string): int =
  var h = 2166136261
  var i = 0
  while i < text.len:
    h = h xor int(text[i])
    h = (h * 16777619) and 0x3FFFFFFF
    inc i
  h

## Build the name index from scratch. Called when a registry has outgrown its
## table, which is the only time it can be wrong: every other write keeps it.
proc reindex*(r: var Registry) =
  var size = 8
  while size < r.defs.len * 2: size = size * 2
  r.slots = @[]
  var i = 0
  while i < size:
    r.slots.add(-1)
    inc i
  i = 0
  while i < r.defs.len:
    var at = hashOfName(r.defs[i].name) and (size - 1)
    # First one in wins, which is what `registerBlock` already guarantees by
    # replacing in place rather than adding beside - so there is never a second
    # def of one name for this to have to choose between.
    while r.slots[at] >= 0 and r.defs[r.slots[at]].name != r.defs[i].name:
      at = (at + 1) and (r.slots.len - 1)
    if r.slots[at] < 0: r.slots[at] = i
    inc i

proc idOf*(r: Registry; name: string): int =
  # A registry whose index has not been built, or has been outgrown, is still
  # answerable - by the scan this used to be. Nothing depends on the index
  # existing; it only decides whether the answer costs one probe or all of them.
  if r.slots.len < r.defs.len * 2:
    var i = 0
    while i < r.defs.len:
      if r.defs[i].name == name: return i
      inc i
    return UnknownId
  let mask = r.slots.len - 1
  var at = hashOfName(name) and mask
  var steps = 0
  while steps <= r.slots.len:
    let row = r.slots[at]
    if row < 0: return UnknownId
    if r.defs[row].name == name: return row
    at = (at + 1) and mask
    inc steps
  UnknownId

proc known*(r: Registry; id: int): bool = id >= 0 and id < r.defs.len

## The block with that number. An id nobody registered reads as air rather than
## throwing, because the caller is usually a meshing loop with a corrupt index
## and a missing block is a hole, not a crash.
proc defOf*(r: Registry; id: int): BlockDef =
  if not r.known(id): return r.defs[AirId]
  r.defs[id]

## Put one in. A name that is already registered is *replaced* rather than added
## beside, so a later contributor wins the way a later catalog row does, and the
## number the world's storage already holds keeps meaning the same block.
proc registerBlock*(r: var Registry; d: BlockDef): int =
  let existing = r.idOf(d.name)
  var entry = d
  if existing >= 0:
    entry.id = existing
    r.defs[existing] = entry
    r.solidFlag[existing] = entry.solid
    r.opaqueFlag[existing] = entry.opaque
    r.hardValue[existing] = entry.hardness
    return existing
  entry.id = r.defs.len
  r.defs.add entry
  r.solidFlag.add entry.solid
  r.opaqueFlag.add entry.opaque
  r.hardValue.add entry.hardness
  # Keep the index, or rebuild it when this block is the one that outgrew the
  # table. A rebuild is O(n) and happens on a power of two, so filling a
  # registry of n blocks costs 2n index writes in total and not n per block.
  if r.slots.len < r.defs.len * 2:
    r.reindex()
  else:
    let mask = r.slots.len - 1
    var at = hashOfName(entry.name) and mask
    while r.slots[at] >= 0: at = (at + 1) and mask
    r.slots[at] = entry.id
  entry.id

proc registerSpec*(r: var Registry; name, spec, provider: string): int =
  var d = parseBlockSpec(name, spec)
  d.provider = provider
  r.registerBlock(d)

## The three hot ones, answered out of the flat arrays. An id nobody registered
## reads as air, exactly as `defOf` does.
proc isSolid*(r: Registry; id: int): bool =
  if id < 0 or id >= r.solidFlag.len: return false
  r.solidFlag[id]
proc isOpaque*(r: Registry; id: int): bool =
  if id < 0 or id >= r.opaqueFlag.len: return false
  r.opaqueFlag[id]
proc isLiquid*(r: Registry; id: int): bool = r.defOf(id).liquid
proc isAir*(id: int): bool = id == AirId

## How long breaking it takes. Below zero means never, which is what bedrock and
## air both are.
proc hardnessOf*(r: Registry; id: int): float =
  if id < 0 or id >= r.hardValue.len: return -1.0
  r.hardValue[id]
proc breakable*(r: Registry; id: int): bool =
  id != AirId and r.known(id) and r.hardnessOf(id) >= 0.0

## What ends up in your hand. Empty `drops` means the block itself; "-" means
## nothing; anything else is another block's name, which is how stone drops
## cobble.
proc dropOf*(r: Registry; id: int): int =
  let d = r.defOf(id)
  if d.drops.len == 0: return id
  if d.drops == "-": return AirId
  let other = r.idOf(d.drops)
  if other < 0: return AirId
  other
