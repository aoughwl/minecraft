## A box model, as data: any number of boxes, hung off one another, reading
## rectangles of one picture.
##
## ## Why this file exists
##
## `vxskin.nim` landed a complete box player - six axis-aligned boxes whose
## faces read rectangles of a 64x64 skin, built out of the same
## `FaceCorner`/`FaceNormal`/`FaceUv` tables the chunk mesher uses so there is
## only one spelling of the winding in the mod. Everything about it was right
## except that it was six boxes and it was the player's six.
##
## A zombie is the player's six boxes with the arms held out. A creeper is four
## legs and a box. A cow is a body, a head, four legs, two horns and an udder. A
## spider is a head, a body and eight legs. **None of them is a different kind
## of thing from the player** - they are all boxes with pivots reading
## rectangles of a texture, which is what a Minecraft entity model *is*, not an
## approximation of one. So this file is `vxskin` with the sixes taken out:
## boxes come from a list, the picture may be any size, and a box may hang off
## another box instead of off the feet.
##
## `vxskin.nim` now sits on top of this and still says exactly what it said
## before; `Tests/view_test.exe` did not change a line, which is the check that
## the generalisation did not move the player.
##
## ## The models are a file, not this file
##
## Every number that describes an entity is in `entities.conf` beside this one,
## in the same `<id> field=value ...` grammar the F3 screen's `screen.conf`
## uses, and nothing here knows the name of a single mob. A modpack that wants
## a taller zombie ships its own rows; a modpack that wants an entity nobody
## has heard of ships those too, and this file never learns about it. That is
## the same rule the block catalog follows and the reason `vxdefaults.nim`
## exists: **data a test can read, not literals in a source file a test
## cannot.**
##
## ## The one rule the unwrap follows
##
## Unchanged from `vxskin`, and generalised only in the size of the picture:
## four sides in a strip, top and bottom above them.
##
##       v+0   .....[ top ][bot ].....
##       v+d   [rgt][front][left][back]
##             u    u+d    u+d+w      u+2d+w
##
## The strip is a real unwrap and not four unrelated rectangles, which is what
## makes it checkable: the right edge of `rgt` and the left edge of `front` are
## the *same edge of the box*, so they must land in the same texture column.
## `Tests/entity_test.exe` checks that seam for **every box of every model in
## the file**, which is the check that catches a face put on back to front - the
## defect you otherwise find by walking round a cow.
##
## ## No host, no trigonometry
##
## Nothing here calls the host and nothing here calls `sin`. A box turns about
## its pivot and the turning is done by a transform the host composes (see
## `vxanim.nim` for why that is enough), so the arithmetic in this file is
## multiplication and subtraction only.

import vxworld
import vxblocks

const
  PixelsPerBlock* = 16.0
    ## Minecraft models are measured in sixteenths of a block, whatever they
    ## are models of.
  DefaultScale* = 0.9375
    ## 15/16, the player's. A model says its own; this is what one that does
    ## not say gets, because the player is the one everybody pictures.
  DefaultTexSide* = 64
    ## A skin is 64x64. So is a zombie, a creeper and a cow; a chicken is
    ## 64x32 and says so.

type
  TexRect* = object
    ## A rectangle of the picture, in texture pixels, `y` counted down from the
    ## top the way a PNG is stored.
    x*, y*, w*, h*: int

  BoxRole* = enum
    ## What moves a box, and therefore which transform it is drawn on. This is
    ## the *only* thing in the model data that animation reads; a box with no
    ## role is welded to the model's root and costs nothing per frame.
    RoleStill
      ## Part of the body. Never turns on its own.
    RoleHead
      ## Follows where the entity is looking, within the neck's limit.
    RoleArmRight
    RoleArmLeft
    RoleLegRight
    RoleLegLeft
      ## Swings fore and aft with the walk. Right and left are half a stride
      ## apart, and an arm is the opposite of the leg on its own side.
    RoleWingRight
    RoleWingLeft
      ## Flaps. A chicken's, and anything else that has them.
    RoleCrawl
      ## A spider's leg: eight of them round a body, each with its own place in
      ## the ring, and the ring is in the data rather than here.
    RoleTail
      ## Sways with the walk, across rather than fore and aft.

  Box* = object
    name*: string
    of0*: string
      ## The box this one hangs off, by name, or "" for the model's root.
      ## Spelled `of0` because `of` is a keyword.
    parent*: int
      ## The same, resolved to an index into the model's own `boxes`, or -1.
      ## Resolved once when the file is read, so nothing searches per frame.
    ## The box, in model pixels: feet at y 0, facing +Z, right hand at +X.
    minX*, minY*, minZ*: float
    maxX*, maxY*, maxZ*: float
    ## What it turns about, in the same pixels and in the same frame - an
    ## absolute point on the model and not an offset from the parent. The
    ## offset is `localPivot`, which subtracts the parent's.
    pivotX*, pivotY*, pivotZ*: float
    ## Where its six faces read from.
    u*, v*: int
    ## What it wears when nobody has granted a texture.
    red*, green*, blue*: float
    role*: BoxRole
    turn*: float
      ## What the role is worth on this box, in degrees at a full walk. A
      ## spider's leg uses it as its place in the ring instead. Roles that do
      ## not read it leave it at zero.
    hold*: float
      ## A constant pitch this box is always at, in degrees, before anything
      ## the role adds. A zombie's arms are held out in front by `hold=-90`
      ## and swing about that; a sheep grazing is its head at `hold`.
    grow*: float
      ## How many pixels bigger than its box the geometry is drawn, on every
      ## side. Minecraft's hat layer and a sheep's wool are the same box grown
      ## by a quarter of a pixel; zero is the box itself.
    spin*: float
      ## A quarter turn, or two, or three, about the box's own sideways axis
      ## through its own pivot, baked into the geometry.
      ##
      ## This is not decoration and it is not an animation: **it is how a
      ## quadruped's body is authored.** A cow's barrel is a box twelve wide,
      ## eighteen tall and ten deep laid on its side, and it has to be that box
      ## rather than the eighteen-deep one it looks like, because the picture is
      ## unwrapped from the box as authored - an eighteen-deep box would want a
      ## sixty-pixel strip and would run off the edge of a sixty-four pixel
      ## sheet, which is exactly what happens if you skip this and is exactly
      ## what `Tests/entity_test.exe` catches.
      ##
      ## Quarter turns only, and they are exact: a quarter turn about x sends
      ## (y, z) to (-z, y), which is a swap and a sign and involves no
      ## trigonometry at all. Anything else is rounded to the nearest quarter,
      ## because a box at thirty degrees is a thing this model has no way to
      ## unwrap.

  Model* = object
    name*: string
    texW*, texH*: int
    scale*: float
    height*: float
      ## How tall the live thing is, in metres - its hitbox, not its picture.
      ## The nameplate floats above this and nothing else reads it.
    plate*: bool
      ## Whether this kind carries a nameplate when it has a name.
    flat*: bool
      ## A billboard rather than boxes: a dropped item, an arrow, a snowball.
      ## `boxes` is empty and `flatW`/`flatH` are its size in metres.
    flatW*, flatH*: float
    boxes*: seq[Box]
    problem*: string
      ## Why a row of this model would not read. Empty when it all did. Never
      ## thrown: a model with one bad row is drawn with the rest of its boxes,
      ## because half a cow on the screen and a sentence in the log is a better
      ## Tuesday than a world that will not start.

  ModelSet* = object
    ## Every model that has been read, by name. Flat and swept linearly: there
    ## are tens of these and a lookup happens when an entity is first seen,
    ## never per frame.
    name*: seq[string]
    model*: seq[Model]

  BoxQuad* = object
    ## One face of one box, ready to hand over: four corners in metres relative
    ## to that box's own pivot, four texture coordinates, and the one normal
    ## all four share.
    pos*: array[12, float]
    uv*: array[8, float]
    nx*, ny*, nz*: float

# ---------------------------------------------------------------------------
# The box itself

proc widthOf*(b: Box): float = b.maxX - b.minX
proc heightOf*(b: Box): float = b.maxY - b.minY
proc depthOf*(b: Box): float = b.maxZ - b.minZ

## Metres per model pixel for this model. One multiplication, and every length
## in the file goes through it.
proc metresPerPixel*(m: Model): float = m.scale / PixelsPerBlock

## Where a box hangs, in metres, measured from the model's own origin - the
## point between the feet.
proc pivotXOf*(m: Model; b: Box): float = b.pivotX * metresPerPixel(m)
proc pivotYOf*(m: Model; b: Box): float = b.pivotY * metresPerPixel(m)
proc pivotZOf*(m: Model; b: Box): float = b.pivotZ * metresPerPixel(m)

## Where a box hangs **from its parent**, in metres. This is what a transform
## parented to another transform is given, and it is the whole of the
## hierarchy: a box whose parent is the root gets its own pivot, and a box on a
## head gets the difference. Subtraction, once, at spawn.
proc localPivotX*(m: Model; at: int): float =
  let b = m.boxes[at]
  if b.parent < 0: return pivotXOf(m, b)
  (b.pivotX - m.boxes[b.parent].pivotX) * metresPerPixel(m)

proc localPivotY*(m: Model; at: int): float =
  let b = m.boxes[at]
  if b.parent < 0: return pivotYOf(m, b)
  (b.pivotY - m.boxes[b.parent].pivotY) * metresPerPixel(m)

proc localPivotZ*(m: Model; at: int): float =
  let b = m.boxes[at]
  if b.parent < 0: return pivotZOf(m, b)
  (b.pivotZ - m.boxes[b.parent].pivotZ) * metresPerPixel(m)

## How many quarter turns a box is laid over by. Rounded, because a box at
## thirty degrees is not a thing a box unwrap can draw.
proc spinQuarters*(b: Box): int =
  var turns = b.spin / 90.0
  if turns < 0.0: turns = turns - 0.5 else: turns = turns + 0.5
  ((int(turns) mod 4) + 4) mod 4

## One point turned about the x axis by that many quarters. A swap and a sign,
## applied `quarters` times: (y, z) becomes (-z, y) each time.
proc spinPoint*(quarters: int; y, z: var float) =
  var q = 0
  while q < quarters:
    let wasY = y
    y = -z
    z = wasY
    inc q

## How high and how low a box reaches, in model pixels, once it has been laid
## over. The corners are turned about the pivot and the extent is taken off
## them - which is the only honest way to ask, because a box on its side is as
## tall as it is deep.
proc boxReach*(b: Box; lowY, highY: var float) =
  let quarters = spinQuarters(b)
  lowY = 1.0e9
  highY = -1.0e9
  var c = 0
  while c < 8:
    var y = b.minY - b.grow
    var z = b.minZ - b.grow
    if (c and 1) != 0: y = b.maxY + b.grow
    if (c and 2) != 0: z = b.maxZ + b.grow
    y = y - b.pivotY
    z = z - b.pivotZ
    spinPoint(quarters, y, z)
    let at = y + b.pivotY
    if at < lowY: lowY = at
    if at > highY: highY = at
    inc c

## How tall the picture stands, in metres: the highest corner of any box, laid
## over if it is laid over. Not the same number as `height`, which is what the
## *thing* is; the two agreeing to a few centimetres is the point, and
## `Tests/entity_test.exe` says so.
proc pictureHeight*(m: Model): float =
  result = 0.0
  var i = 0
  while i < m.boxes.len:
    var lowY = 0.0
    var highY = 0.0
    boxReach(m.boxes[i], lowY, highY)
    let top = highY * metresPerPixel(m)
    if top > result: result = top
    inc i

## And how far above - or below - the ground its lowest corner is, in metres. A
## model whose origin is not between its feet floats or is buried, which is the
## defect this exists to make visible.
proc pictureFloor*(m: Model): float =
  result = 1.0e9
  var i = 0
  while i < m.boxes.len:
    var lowY = 0.0
    var highY = 0.0
    boxReach(m.boxes[i], lowY, highY)
    let foot = lowY * metresPerPixel(m)
    if foot < result: result = foot
    inc i
  if m.boxes.len == 0: result = 0.0

# ---------------------------------------------------------------------------
# Which rectangle of the picture a face reads
#
# The face numbers are the world's: 0 +X, 1 -X, 2 +Y, 3 -Y, 4 +Z, 5 -Z, the
# same order `vxworld.FaceNormal` is in, so the corner winding and the outward
# normals come from there rather than being written a second time here.

## The strip, generalised only in that the box may be any size. `grow` does not
## move the rectangle: an inflated box wears the same picture stretched over a
## slightly bigger shape, which is what Minecraft's hat layer is.
proc faceRect*(b: Box; face: int): TexRect =
  let w = int(b.maxX - b.minX)
  let h = int(b.maxY - b.minY)
  let d = int(b.maxZ - b.minZ)
  case face
  of 0: TexRect(x: b.u, y: b.v + d, w: d, h: h)
  of 1: TexRect(x: b.u + d + w, y: b.v + d, w: d, h: h)
  of 2: TexRect(x: b.u + d, y: b.v, w: w, h: d)
  of 3: TexRect(x: b.u + d + w, y: b.v, w: w, h: d)
  of 4: TexRect(x: b.u + d, y: b.v + d, w: w, h: h)
  else: TexRect(x: b.u + d + w + d, y: b.v + d, w: w, h: h)

## Where a corner of a face sits inside that face's rectangle, as a fraction
## across and a fraction down.
##
## This is the whole of the orientation question and it is decided by one rule:
## **the strip is continuous**. `rgt`, `front`, `left` and `back` are laid out
## side by side because they are unfolded from the box in that order, so the
## edge two of them share is the column they meet at. Follow that round and
## every one of the six falls out. Nothing here is remembered from a picture of
## a skin; all six are the same rule applied six times, and the test checks the
## rule rather than the answers.
proc faceAcross*(face: int; u: float): float =
  case face
  of 0: u
  of 5: u
  else: 1.0 - u

proc faceDown*(face: int; v: float): float =
  if face == 2: return v
  1.0 - v

## One face of one box, in metres relative to that box's own pivot, with the
## texture coordinates the picture wants. `skinned` false leaves the
## coordinates at the plain 0..1 corners, which is the mesh a flat colour is
## painted onto.
proc boxQuad*(m: Model; b: Box; face: int; skinned = true): BoxQuad =
  result = BoxQuad(nx: float(FaceNormal[face][0]),
    ny: float(FaceNormal[face][1]), nz: float(FaceNormal[face][2]))
  let rect = faceRect(b, face)
  let scale = metresPerPixel(m)
  let lowX = b.minX - b.grow
  let lowY = b.minY - b.grow
  let lowZ = b.minZ - b.grow
  let spanX = (b.maxX + b.grow) - lowX
  let spanY = (b.maxY + b.grow) - lowY
  let spanZ = (b.maxZ + b.grow) - lowZ
  # The quarter turns, applied to the normal once and to each corner as it is
  # made. Both, because a face that is turned and whose normal is not is a face
  # lit from the wrong side.
  let quarters = spinQuarters(b)
  var ny = result.ny
  var nz = result.nz
  spinPoint(quarters, ny, nz)
  result.ny = ny
  result.nz = nz
  var c = 0
  while c < 4:
    let cx = float(FaceCorner[face][c * 3])
    let cy = float(FaceCorner[face][c * 3 + 1])
    let cz = float(FaceCorner[face][c * 3 + 2])
    var py = lowY + cy * spanY - b.pivotY
    var pz = lowZ + cz * spanZ - b.pivotZ
    spinPoint(quarters, py, pz)
    result.pos[c * 3] = (lowX + cx * spanX - b.pivotX) * scale
    result.pos[c * 3 + 1] = py * scale
    result.pos[c * 3 + 2] = pz * scale
    let bu = FaceUv[face][c * 2]
    let bv = FaceUv[face][c * 2 + 1]
    if skinned:
      let across = faceAcross(face, bu)
      let down = faceDown(face, bv)
      result.uv[c * 2] = (float(rect.x) + across * float(rect.w)) /
        float(m.texW)
      result.uv[c * 2 + 1] = 1.0 -
        (float(rect.y) + down * float(rect.h)) / float(m.texH)
    else:
      result.uv[c * 2] = bu
      result.uv[c * 2 + 1] = bv
    inc c

# ---------------------------------------------------------------------------
# Looking a model up

proc noModels*(): ModelSet = ModelSet(name: @[], model: @[])

proc modelCount*(s: ModelSet): int = s.name.len

## Which model that name is, or -1. Swept linearly on purpose: an entity looks
## its model up the frame it is first seen and never again.
proc modelIndex*(s: ModelSet; name: string): int =
  var i = 0
  while i < s.name.len:
    if s.name[i] == name: return i
    inc i
  -1

## Which box of a model that name is, or -1.
proc boxIndex*(m: Model; name: string): int =
  var i = 0
  while i < m.boxes.len:
    if m.boxes[i].name == name: return i
    inc i
  -1

## The first box with that role, or -1. What a caller wanting "the head"
## actually means, since the box may be called anything.
proc roleIndex*(m: Model; role: BoxRole): int =
  var i = 0
  while i < m.boxes.len:
    if m.boxes[i].role == role: return i
    inc i
  -1

## Which moving box a box is drawn on: itself if it moves, otherwise the
## nearest moving box above it, and -1 when there is none and it belongs on the
## model's root.
##
## **This is the whole of the hierarchy at run time**, and it is here rather
## than beside the spawning because it is the rule that decides what is drawn
## where and a rule like that belongs where it can be checked. A chicken's beak
## is still and hangs off its head, which moves, so the beak is meshed into the
## head's part and turns with it for nothing; a cow's horns are the same. A
## still box on the root - a barrel, a snout - is meshed into the root and
## costs no transform at all, which is why `movingParts` and not `boxes.len` is
## the number that matters.
##
## The guard is not decoration: a box hung off itself would loop here for ever,
## and `resolveParents` refuses that case, so this is the second of two locks
## on the same door.
proc groupOf*(m: Model; at: int): int =
  var i = at
  var guard = 0
  while i >= 0 and guard <= m.boxes.len:
    if m.boxes[i].role != RoleStill: return i
    i = m.boxes[i].parent
    inc guard
  -1

## How many boxes of a model turn on their own, which is how many transforms it
## costs to draw and therefore how many host crossings a frame it is worth.
## Read by nothing at runtime and by the test, which holds the models to a
## budget - a model somebody gives forty moving parts to is a model that will
## not scale, and that should fail a check rather than a frame.
proc movingParts*(m: Model): int =
  result = 0
  var i = 0
  while i < m.boxes.len:
    if m.boxes[i].role != RoleStill: inc result
    inc i

# ---------------------------------------------------------------------------
# Reading the file
#
# The grammar is `screen.conf`'s, because there is no reason for a second one:
# `# ...` is a comment, a blank line is nothing, and every other line is an id
# followed by `field=value` pairs. Two things are said in it:
#
#     model  zombie         tex=64,64 scale=0.9375 height=1.95 plate=1
#     box    zombie.head    at=-4,24,-4,4,32,4 pivot=0,24,0 uv=0,0 role=head
#
# The id of a box row is `<model>.<box>`, and that dot is the grammar: an id
# with a dot in it is a box of the model named before it. A model row's id has
# no dot. Nothing branches on what a model is *called* - `zombie` is a string
# this file never compares against anything.

proc roleOf*(word: string): BoxRole =
  if word == "head": return RoleHead
  if word == "armR" or word == "armRight": return RoleArmRight
  if word == "armL" or word == "armLeft": return RoleArmLeft
  if word == "legR" or word == "legRight": return RoleLegRight
  if word == "legL" or word == "legLeft": return RoleLegLeft
  if word == "wingR" or word == "wingRight": return RoleWingRight
  if word == "wingL" or word == "wingLeft": return RoleWingLeft
  if word == "crawl": return RoleCrawl
  if word == "tail": return RoleTail
  RoleStill

## The name a role is written as, so a round trip through the file is a thing
## the test can check rather than a thing the reader is trusted about.
proc roleName*(role: BoxRole): string =
  case role
  of RoleStill: "still"
  of RoleHead: "head"
  of RoleArmRight: "armR"
  of RoleArmLeft: "armL"
  of RoleLegRight: "legR"
  of RoleLegLeft: "legL"
  of RoleWingRight: "wingR"
  of RoleWingLeft: "wingL"
  of RoleCrawl: "crawl"
  of RoleTail: "tail"

## `a,b,c,...` read into however many numbers are there, up to `room`. Answers
## how many it found; a value that will not parse stops the list, so a caller
## that wanted six and got four knows which row to complain about.
proc readList(text: string; out0: var array[6, float]; room: int): int =
  result = 0
  var piece = ""
  var i = 0
  while i <= text.len:
    if i == text.len or text[i] == ',':
      var ok = false
      let value = readNumber(piece, ok)
      if not ok: return result
      if result >= room: return result
      out0[result] = value
      inc result
      piece = ""
    else:
      piece.add text[i]
    inc i

## Everything before the first dot, and everything after it. `mark` below zero
## when there is none, which is how a model row is told from a box row.
proc splitDot(id: string; head, tail: var string): bool =
  head = ""
  tail = ""
  var mark = -1
  var i = 0
  while i < id.len:
    if id[i] == '.':
      mark = i
      break
    inc i
  if mark < 0:
    head = id
    return false
  i = 0
  while i < mark:
    head.add id[i]
    inc i
  i = mark + 1
  while i < id.len:
    tail.add id[i]
    inc i
  true

## The two halves of one `field=value`. A pair with no `=` is a key on its own,
## which is how a bare flag would be written if anything wanted one.
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

proc blankBox*(name: string): Box =
  ## Every default a row does not have to write down. A box with nothing said
  ## about it is a one-pixel cube at the origin reading the corner of the
  ## picture, which is visible and wrong rather than invisible and wrong.
  Box(name: name, of0: "", parent: -1,
    minX: 0.0, minY: 0.0, minZ: 0.0, maxX: 1.0, maxY: 1.0, maxZ: 1.0,
    pivotX: 0.0, pivotY: 0.0, pivotZ: 0.0, u: 0, v: 0,
    red: 0.8, green: 0.8, blue: 0.8, role: RoleStill, turn: 0.0, hold: 0.0,
    grow: 0.0, spin: 0.0)

proc blankModel*(name: string): Model =
  Model(name: name, texW: DefaultTexSide, texH: DefaultTexSide,
    scale: DefaultScale, height: 1.8, plate: false, flat: false,
    flatW: 0.5, flatH: 0.5, boxes: @[], problem: "")

## One model row's fields over a model.
proc readModelRow(m: var Model; row: string) =
  var field = ""
  var i = 0
  while i <= row.len:
    if i == row.len or row[i] == ' ' or row[i] == '\t':
      if field.len > 0:
        var key = ""
        var value = ""
        splitPair(field, key, value)
        var list: array[6, float] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        var ok = false
        if key == "tex":
          if readList(value, list, 6) == 2:
            m.texW = int(list[0])
            m.texH = int(list[1])
          else: m.problem = "tex wants two numbers"
        elif key == "scale":
          let value0 = readNumber(value, ok)
          if ok: m.scale = value0 else: m.problem = "scale is not a number"
        elif key == "height":
          let value0 = readNumber(value, ok)
          if ok: m.height = value0 else: m.problem = "height is not a number"
        elif key == "plate":
          let value0 = readTruth(value, ok)
          if ok: m.plate = value0 else: m.problem = "plate is not a truth"
        elif key == "flat":
          if readList(value, list, 6) == 2:
            m.flat = true
            m.flatW = list[0]
            m.flatH = list[1]
          else: m.problem = "flat wants two numbers"
        else:
          m.problem = "no such model field: " & key
      field = ""
    else:
      field.add row[i]
    inc i

## One box row's fields over a box.
proc readBoxRow(b: var Box; row: string; problem: var string) =
  var field = ""
  var i = 0
  while i <= row.len:
    if i == row.len or row[i] == ' ' or row[i] == '\t':
      if field.len > 0:
        var key = ""
        var value = ""
        splitPair(field, key, value)
        var list: array[6, float] = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
        var ok = false
        if key == "at":
          if readList(value, list, 6) == 6:
            b.minX = list[0]
            b.minY = list[1]
            b.minZ = list[2]
            b.maxX = list[3]
            b.maxY = list[4]
            b.maxZ = list[5]
          else: problem = "at wants six numbers"
        elif key == "pivot":
          if readList(value, list, 6) == 3:
            b.pivotX = list[0]
            b.pivotY = list[1]
            b.pivotZ = list[2]
          else: problem = "pivot wants three numbers"
        elif key == "uv":
          if readList(value, list, 6) == 2:
            b.u = int(list[0])
            b.v = int(list[1])
          else: problem = "uv wants two numbers"
        elif key == "rgb":
          var r = 0.0
          var g = 0.0
          var bl = 0.0
          readColour(value, r, g, bl, ok)
          if ok:
            b.red = r
            b.green = g
            b.blue = bl
          else: problem = "rgb is not a colour"
        elif key == "role":
          b.role = roleOf(value)
          if roleName(b.role) != value and value != "still":
            problem = "no such role: " & value
        elif key == "of":
          b.of0 = value
        elif key == "turn":
          let value0 = readNumber(value, ok)
          if ok: b.turn = value0 else: problem = "turn is not a number"
        elif key == "hold":
          let value0 = readNumber(value, ok)
          if ok: b.hold = value0 else: problem = "hold is not a number"
        elif key == "grow":
          let value0 = readNumber(value, ok)
          if ok: b.grow = value0 else: problem = "grow is not a number"
        elif key == "spin":
          let value0 = readNumber(value, ok)
          if ok: b.spin = value0 else: problem = "spin is not a number"
        else:
          problem = "no such box field: " & key
      field = ""
    else:
      field.add row[i]
    inc i

## Hang every box off the one it named, now that they all exist. A box naming a
## box that is not there is left on the root and says so, which is a model that
## still draws.
proc resolveParents*(m: var Model) =
  var i = 0
  while i < m.boxes.len:
    if m.boxes[i].of0.len > 0:
      let at = boxIndex(m, m.boxes[i].of0)
      if at < 0:
        m.problem = "no such box to hang " & m.boxes[i].name & " off: " &
          m.boxes[i].of0
      elif at == i:
        m.problem = m.boxes[i].name & " hangs off itself"
      else:
        m.boxes[i].parent = at
    inc i

## The whole file. Rows are applied in the order they are read, so a modpack's
## own file layered after this mod's overrides field by field rather than
## wholesale - the rule a resource pack's language file follows, and the rule
## `screen.conf` follows, spelled again here because it is the rule that makes
## layering worth having.
##
## A box row naming a model that has not been declared makes that model with
## its defaults, so a file may say a box before it says the model - and a
## modpack adding one box to somebody else's model does not have to restate it.
proc parseModels*(body: string; into: ModelSet): ModelSet =
  result = into
  var line = ""
  var i = 0
  while i <= body.len:
    if i == body.len or body[i] == '\n':
      var j = 0
      while j < line.len and (line[j] == ' ' or line[j] == '\t'): inc j
      if j < line.len and line[j] != '#':
        var id = ""
        while j < line.len and line[j] != ' ' and line[j] != '\t':
          if line[j] != '\r': id.add line[j]
          inc j
        while j < line.len and (line[j] == ' ' or line[j] == '\t'): inc j
        var rest = ""
        while j < line.len:
          if line[j] != '\r': rest.add line[j]
          inc j
        if id.len > 0:
          var modelName = ""
          var boxName = ""
          let isBox = splitDot(id, modelName, boxName)
          var at = modelIndex(result, modelName)
          if at < 0:
            result.name.add modelName
            result.model.add blankModel(modelName)
            at = result.name.len - 1
          if isBox:
            var slot = boxIndex(result.model[at], boxName)
            if slot < 0:
              result.model[at].boxes.add blankBox(boxName)
              slot = result.model[at].boxes.len - 1
            var b = result.model[at].boxes[slot]
            var problem = ""
            readBoxRow(b, rest, problem)
            result.model[at].boxes[slot] = b
            if problem.len > 0:
              result.model[at].problem = boxName & ": " & problem
          else:
            var m = result.model[at]
            readModelRow(m, rest)
            result.model[at] = m
      line = ""
    else:
      line.add body[i]
    inc i
  var k = 0
  while k < result.model.len:
    var m = result.model[k]
    resolveParents(m)
    result.model[k] = m
    inc k

## The same, starting from nothing.
proc readModels*(body: string): ModelSet = parseModels(body, noModels())

## Every model that would not read, as one sentence per model. Empty when the
## file is clean, which is what the test asserts of the shipped file and what a
## mod logs at start for anybody else's.
proc problemsIn*(s: ModelSet): seq[string] =
  result = @[]
  var i = 0
  while i < s.model.len:
    if s.model[i].problem.len > 0:
      result.add s.model[i].name & ": " & s.model[i].problem
    inc i
