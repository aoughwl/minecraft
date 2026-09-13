## A Minecraft block model, resolved and baked.
##
## Pure: nothing here calls the host. It is handed documents and it answers with
## corners, normals and texture coordinates, which is why `Tests/minecraft_test`
## can prove the rules below against fixtures that fit in a string literal.
##
## ## The three rules people get wrong
##
## **1. The parent chain is walked to the end, always.** A model inherits its
## geometry from the *first* model in the chain that has `elements` - the child
## wins outright, it does not merge - but it inherits its texture variables from
## *every* model in the chain, child first. Those are different rules over the
## same walk, and the mistake is to stop walking when the elements turn up:
## `block/stone` -> `block/cube_all` -> `block/cube` puts `elements` in `cube`
## and `#all` in `stone`, so a reader that stops at the first `elements` reads
## the file that has none of the variables, and a reader that stops at the first
## `textures` reads none of the geometry. `layers()` below takes the whole chain
## and each rule takes what it needs from it.
##
## **2. A texture variable is a chain, not a lookup.** `#down` may be defined as
## `#side`, which may be defined as `#all`, which is finally a file. Resolution
## follows it until it stops being a `#`, with a cycle guard, because a resource
## pack is other people's data and `{"a": "#b", "b": "#a"}` is a legal file.
##
## **3. A face's default uv is derived from the *unrotated* box.** Minecraft
## computes it from `from`/`to` before any element rotation is applied, and the
## previous JavaScript importer derived it from the rotated point instead, which
## is why its stairs and its anvils were subtly smeared. Here the uv rectangle
## and the corner selection are decided in box space and only the finished
## corners are rotated.
##
## ## What comes out
##
## A `Bake` in Unity's left-handed metre space: X mirrored and the winding
## reversed, the same conversion `aoughwl.gltf` documents, with a block
## one metre on a side centred on its own origin. Texture coordinates are
## per-face and in 0..1 of that face's *own* picture; putting several pictures
## side by side is the atlas's problem and it is in `mcatlas.nim`.

import mcjson

const
  FaceDown* = 0
  FaceUp* = 1
  FaceNorth* = 2
  FaceSouth* = 3
  FaceWest* = 4
  FaceEast* = 5

  NoCull* = -1
    ## `cullface` is read and kept even though a single block never hides a
    ## face, because a chunk import is the caller that needs it and re-deriving
    ## it from geometry later would be guesswork.

  MaxVariableHops = 16
  MaxChain* = 24
    ## Vanilla's deepest chain is four. A resource pack that makes a longer one
    ## than this has a cycle in it, and the walk stops rather than spins.

type
  Textures* = object
    ## The merged variable table. Child-first insertion, first writer wins,
    ## which is the same thing as parent-first insertion with the child
    ## overwriting - and it is the order that lets a chain be walked once.
    keys*: seq[string]
    vals*: seq[string]

  Bake* = object
    count*: int
    texture*: seq[string]  ## per face: the resolved texture, "" when unresolved
    face*: seq[int]        ## per face: which of the six it was declared as
    tint*: seq[int]        ## per face: `tintindex`, or -1
    cull*: seq[int]        ## per face: the face it is hidden by, or NoCull
    pos*: seq[float]       ## per face: 12 numbers, four corners of x,y,z
    norm*: seq[float]      ## per face: 3 numbers
    uv*: seq[float]        ## per face: 8 numbers, four corners of u,v
    problem*: string
    skipped*: int          ## faces named but not emitted, and why is in problem

# ---------------------------------------------------------------------------
# Naming

## `minecraft:block/cube_all`, `block/cube_all` and `cube_all` all name the same
## file; this is the part after the namespace, with any `.json` taken off.
proc resourcePath*(reference: string): string =
  var start = 0
  var i = 0
  while i < reference.len:
    if reference[i] == ':': start = i + 1
    inc i
  result = ""
  i = start
  while i < reference.len:
    result.add reference[i]
    inc i
  if result.len > 5:
    var isJson = true
    var j = 0
    let tail = ".json"
    while j < 5:
      var c = result[result.len - 5 + j]
      if c >= 'A' and c <= 'Z': c = char(int(c) + 32)
      if c != tail[j]: isJson = false
      inc j
    if isJson: result.setLen(result.len - 5)
  while result.len > 0 and result[0] == '/':
    var trimmed = ""
    var k = 1
    while k < result.len:
      trimmed.add result[k]
      inc k
    result = trimmed

## The last segment of a resource path - `stone` out of `block/stone`.
proc leaf*(reference: string): string =
  let path = resourcePath(reference)
  var start = 0
  var i = 0
  while i < path.len:
    if path[i] == '/': start = i + 1
    inc i
  result = ""
  i = start
  while i < path.len:
    result.add path[i]
    inc i

## The namespace, or "minecraft" when the reference did not name one.
proc namespaceOf*(reference: string): string =
  var i = 0
  while i < reference.len:
    if reference[i] == ':':
      result = ""
      var j = 0
      while j < i:
        result.add reference[j]
        inc j
      if result.len == 0: return "minecraft"
      return result
    inc i
  "minecraft"

## Whether a parent reference leaves geometry behind. `builtin/generated` and
## `builtin/entity` are Minecraft's own words for "the game draws this, there is
## no model" - a chain that reaches one stops there with whatever it has.
proc isBuiltin*(reference: string): bool =
  let path = resourcePath(reference)
  if path.len < 8: return false
  let want = "builtin/"
  var i = 0
  while i < 8:
    if path[i] != want[i]: return false
    inc i
  true

# ---------------------------------------------------------------------------
# Rule one: the chain

## What this model says its parent is, or "" when it is the top of its chain.
proc parentOf*(doc: Json): string =
  text(doc, member(doc, doc.root, "parent"))

## Fold one model's `textures` in. Called child first, so the first writer of a
## key is the one nearest the child, which is the one that wins.
proc absorb*(t: var Textures; doc: Json) =
  let node = member(doc, doc.root, "textures")
  if node < 0: return
  var i = 0
  while i < len(doc, node):
    let entry = item(doc, node, i)
    inc i
    let key = keyAt(doc, entry)
    if key.len == 0: continue
    var seen = false
    var j = 0
    while j < t.keys.len:
      if t.keys[j] == key:
        seen = true
        break
      inc j
    if seen: continue
    t.keys.add key
    t.vals.add text(doc, entry)

proc lookup(t: Textures; name: string): string =
  var i = 0
  while i < t.keys.len:
    if t.keys[i] == name: return t.vals[i]
    inc i
  ""

## Rule two. A reference with no `#` is already a file. One with a `#` is a
## variable, whose value may be another variable, until it is not - or until
## the hop count says this pack has a cycle in it, and then it is nothing.
proc resolveTexture*(t: Textures; reference: string): string =
  var name = reference
  var hops = 0
  while hops < MaxVariableHops:
    if name.len == 0: return ""
    if name[0] != '#': return name
    var bare = ""
    var i = 1
    while i < name.len:
      bare.add name[i]
      inc i
    let next = lookup(t, bare)
    if next.len == 0: return ""
    if next == name: return ""
    name = next
    inc hops
  ""

## Which document in a chain owns the geometry: the first, counting from the
## child, that has a non-empty `elements`. -1 when none of them does, which is
## what an item model looks like from here.
proc geometryLayer*(docs: seq[Json]): int =
  var i = 0
  while i < docs.len:
    let node = member(docs[i], docs[i].root, "elements")
    if node >= 0 and kindAt(docs[i], node) == jArray and len(docs[i], node) > 0:
      return i
    inc i
  -1

# ---------------------------------------------------------------------------
# Rule three: corners, and the uv rectangle they came from
#
# The four corners of a face are listed in the order that matches the uv
# rectangle's own corners - (u1,v1), (u1,v2), (u2,v2), (u2,v1) - so that an
# explicit `uv` and a derived one are laid on by exactly the same code. Each
# entry says, for x, y and z, whether to take `from` (0) or `to` (1). The tables
# were derived from Minecraft's own default-uv formulas and the test asserts
# that they still agree with them.

const
  Corners: array[6, array[4, array[3, int]]] = [
    [[0, 0, 1], [0, 0, 0], [1, 0, 0], [1, 0, 1]],   # down,  y = from.y
    [[0, 1, 0], [0, 1, 1], [1, 1, 1], [1, 1, 0]],   # up,    y = to.y
    [[1, 1, 0], [1, 0, 0], [0, 0, 0], [0, 1, 0]],   # north, z = from.z
    [[0, 1, 1], [0, 0, 1], [1, 0, 1], [1, 1, 1]],   # south, z = to.z
    [[0, 1, 0], [0, 0, 0], [0, 0, 1], [0, 1, 1]],   # west,  x = from.x
    [[1, 1, 1], [1, 0, 1], [1, 0, 0], [1, 1, 0]]]   # east,  x = to.x

  Normals: array[6, array[3, float]] = [
    [0.0, -1.0, 0.0], [0.0, 1.0, 0.0],
    [0.0, 0.0, -1.0], [0.0, 0.0, 1.0],
    [-1.0, 0.0, 0.0], [1.0, 0.0, 0.0]]

proc faceIndex*(key: string): int =
  if key == "down": FaceDown
  elif key == "up": FaceUp
  elif key == "north": FaceNorth
  elif key == "south": FaceSouth
  elif key == "west": FaceWest
  elif key == "east": FaceEast
  else: -1

proc faceName*(index: int): string =
  case index
  of FaceDown: "down"
  of FaceUp: "up"
  of FaceNorth: "north"
  of FaceSouth: "south"
  of FaceWest: "west"
  of FaceEast: "east"
  else: ""

## Minecraft's own default uv, in sixteenths, with v counted down from the top
## of the picture. Taken from `BlockElementFace.uvsByFace`; the flips are not
## decoration, they are what makes a texture face outwards on all six sides.
proc defaultUv*(face: int; x0, y0, z0, x1, y1, z1: float;
                u1, v1, u2, v2: var float) =
  case face
  of FaceDown:
    u1 = x0; v1 = 16.0 - z1; u2 = x1; v2 = 16.0 - z0
  of FaceUp:
    u1 = x0; v1 = z0; u2 = x1; v2 = z1
  of FaceNorth:
    u1 = 16.0 - x1; v1 = 16.0 - y1; u2 = 16.0 - x0; v2 = 16.0 - y0
  of FaceSouth:
    u1 = x0; v1 = 16.0 - y1; u2 = x1; v2 = 16.0 - y0
  of FaceWest:
    u1 = z0; v1 = 16.0 - y1; u2 = z1; v2 = 16.0 - y0
  else:
    u1 = 16.0 - z1; v1 = 16.0 - y1; u2 = 16.0 - z0; v2 = 16.0 - y0

# ---------------------------------------------------------------------------
# Element rotation
#
# The only angles Minecraft allows are 0 and +/-22.5 and +/-45, so the two
# cosines are constants and this module needs no trigonometry at all - which is
# what keeps it free of `std/math` and therefore loadable in the interpreter.

const
  Cos22 = 0.9238795325112867
  Sin22 = 0.3826834323650898
  Cos45 = 0.7071067811865476
  Rescale22 = 1.0823922002923940   # 1 / cos(22.5 degrees)
  Rescale45 = 1.4142135623730951   # 1 / cos(45 degrees)

proc sinCosOf(angle: float; s, c: var float): bool =
  ## True when the angle is one Minecraft allows. A model asking for anything
  ## else is malformed, and the caller says so rather than rounding it.
  if angle > -0.0001 and angle < 0.0001:
    s = 0.0; c = 1.0; return true
  if angle > 22.4999 and angle < 22.5001:
    s = Sin22; c = Cos22; return true
  if angle > -22.5001 and angle < -22.4999:
    s = -Sin22; c = Cos22; return true
  if angle > 44.9999 and angle < 45.0001:
    s = Cos45; c = Cos45; return true
  if angle > -45.0001 and angle < -44.9999:
    s = -Cos45; c = Cos45; return true
  false

proc rescaleOf(angle: float): float =
  if angle > 22.4999 and angle < 22.5001: return Rescale22
  if angle > -22.5001 and angle < -22.4999: return Rescale22
  if angle > 44.9999 and angle < 45.0001: return Rescale45
  if angle > -45.0001 and angle < -44.9999: return Rescale45
  1.0

type
  Spin = object
    ## An element's `rotation`, already reduced to numbers. `axis` is -1 when
    ## there is nothing to do, which is the common case and costs nothing.
    axis: int
    ox, oy, oz: float
    sin, cos: float
    sx, sy, sz: float

proc noSpin(): Spin =
  Spin(axis: -1, ox: 0.0, oy: 0.0, oz: 0.0, sin: 0.0, cos: 1.0,
       sx: 1.0, sy: 1.0, sz: 1.0)

proc turn(spin: Spin; x, y, z: var float) =
  if spin.axis < 0: return
  let a = x - spin.ox
  let b = y - spin.oy
  let c = z - spin.oz
  var na = a
  var nb = b
  var nc = c
  case spin.axis
  of 0:
    nb = b * spin.cos - c * spin.sin
    nc = b * spin.sin + c * spin.cos
  of 1:
    na = a * spin.cos + c * spin.sin
    nc = -a * spin.sin + c * spin.cos
  else:
    na = a * spin.cos - b * spin.sin
    nb = a * spin.sin + b * spin.cos
  x = na * spin.sx + spin.ox
  y = nb * spin.sy + spin.oy
  z = nc * spin.sz + spin.oz

proc turnNormal(spin: Spin; x, y, z: var float) =
  ## The same rotation without the origin and without the rescale: a rescale is
  ## a stretch of the box, and stretching a normal is how a lit face goes wrong.
  if spin.axis < 0: return
  let a = x
  let b = y
  let c = z
  case spin.axis
  of 0:
    y = b * spin.cos - c * spin.sin
    z = b * spin.sin + c * spin.cos
  of 1:
    x = a * spin.cos + c * spin.sin
    z = -a * spin.sin + c * spin.cos
  else:
    x = a * spin.cos - b * spin.sin
    y = a * spin.sin + b * spin.cos

proc readSpin(doc: Json; element: int; problem: var string): Spin =
  result = noSpin()
  let node = member(doc, element, "rotation")
  if node < 0: return result
  let axisText = text(doc, member(doc, node, "axis"))
  var axis = -1
  if axisText == "x": axis = 0
  elif axisText == "y": axis = 1
  elif axisText == "z": axis = 2
  else:
    if problem.len == 0:
      problem = "an element's rotation names axis '" & axisText & "'"
    return result
  let angle = number(doc, member(doc, node, "angle"), 0.0)
  var s = 0.0
  var c = 1.0
  if not sinCosOf(angle, s, c):
    if problem.len == 0:
      problem = "an element's rotation is " & $angle &
        " degrees; Minecraft allows 0, 22.5 and 45 either way"
    return result
  let origin = member(doc, node, "origin")
  result = noSpin()
  result.axis = axis
  result.ox = numberAt(doc, origin, 0, 8.0)
  result.oy = numberAt(doc, origin, 1, 8.0)
  result.oz = numberAt(doc, origin, 2, 8.0)
  result.sin = s
  result.cos = c
  if truth(doc, member(doc, node, "rescale"), false):
    let f = rescaleOf(angle)
    # The stretch is applied in the rotated frame, on the two axes the rotation
    # actually moved. Stretching the axis it spun about would make a box grow.
    case axis
    of 0: result.sy = f; result.sz = f
    of 1: result.sx = f; result.sz = f
    else: result.sx = f; result.sy = f

# ---------------------------------------------------------------------------
# The bake

## Minecraft measures a block in sixteenths from a corner; this game wants a
## metre cube around its own centre. X is mirrored on the way, which with the
## reversed winding below is the whole of the right-to-left-handed conversion.
proc metres(v: float): float = v / 16.0 - 0.5

proc emit(b: var Bake; texture: string; which, tint, cull: int;
          px, py, pz: array[4, float]; nx, ny, nz: float;
          uu, vv: array[4, float]) =
  b.texture.add texture
  b.face.add which
  b.tint.add tint
  b.cull.add cull
  b.norm.add -nx
  b.norm.add ny
  b.norm.add nz
  # Reversed: mirroring one axis turns every triangle inside out, and putting
  # the corners back to front turns them the right way round again.
  var i = 3
  while i >= 0:
    b.pos.add -metres(px[i])
    b.pos.add metres(py[i])
    b.pos.add metres(pz[i])
    b.uv.add uu[i] / 16.0
    b.uv.add 1.0 - vv[i] / 16.0
    dec i
  inc b.count

## Every face of every element of one model, resolved and placed. `elements` is
## the node the geometry layer owns; `t` is the whole chain's variable table.
proc bakeElements*(doc: Json; elements: int; t: Textures): Bake =
  result = Bake(count: 0, texture: @[], face: @[], tint: @[], cull: @[],
                pos: @[], norm: @[], uv: @[], problem: "", skipped: 0)
  if elements < 0 or kindAt(doc, elements) != jArray:
    result.problem = "this model has no elements"
    return result
  var e = 0
  while e < len(doc, elements):
    let element = item(doc, elements, e)
    inc e
    let fromNode = member(doc, element, "from")
    let toNode = member(doc, element, "to")
    if fromNode < 0 or toNode < 0:
      if result.problem.len == 0:
        result.problem = "an element has no 'from' and 'to'"
      continue
    let x0 = numberAt(doc, fromNode, 0, 0.0)
    let y0 = numberAt(doc, fromNode, 1, 0.0)
    let z0 = numberAt(doc, fromNode, 2, 0.0)
    let x1 = numberAt(doc, toNode, 0, 16.0)
    let y1 = numberAt(doc, toNode, 1, 16.0)
    let z1 = numberAt(doc, toNode, 2, 16.0)
    let spin = readSpin(doc, element, result.problem)
    let faces = member(doc, element, "faces")
    if faces < 0: continue
    var f = 0
    while f < len(doc, faces):
      let entry = item(doc, faces, f)
      inc f
      let which = faceIndex(keyAt(doc, entry))
      if which < 0:
        inc result.skipped
        if result.problem.len == 0:
          result.problem = "'" & keyAt(doc, entry) & "' is not one of the six faces"
        continue
      let reference = text(doc, member(doc, entry, "texture"))
      let resolved = resolveTexture(t, reference)
      if resolved.len == 0 and result.problem.len == 0:
        result.problem = "'" & reference & "' resolves to no texture"
      var u1 = 0.0
      var v1 = 0.0
      var u2 = 16.0
      var v2 = 16.0
      let uvNode = member(doc, entry, "uv")
      if uvNode >= 0 and len(doc, uvNode) >= 4:
        u1 = numberAt(doc, uvNode, 0, 0.0)
        v1 = numberAt(doc, uvNode, 1, 0.0)
        u2 = numberAt(doc, uvNode, 2, 16.0)
        v2 = numberAt(doc, uvNode, 3, 16.0)
      else:
        defaultUv(which, x0, y0, z0, x1, y1, z1, u1, v1, u2, v2)
      # Rule three lives in these four lines: the corners and the rectangle are
      # both chosen in unrotated box space, and only then does the box turn.
      var px: array[4, float] = [0.0, 0.0, 0.0, 0.0]
      var py: array[4, float] = [0.0, 0.0, 0.0, 0.0]
      var pz: array[4, float] = [0.0, 0.0, 0.0, 0.0]
      var i = 0
      while i < 4:
        let sel = Corners[which][i]
        var x = if sel[0] == 0: x0 else: x1
        var y = if sel[1] == 0: y0 else: y1
        var z = if sel[2] == 0: z0 else: z1
        turn(spin, x, y, z)
        px[i] = x
        py[i] = y
        pz[i] = z
        inc i
      var uu: array[4, float] = [u1, u1, u2, u2]
      var vv: array[4, float] = [v1, v2, v2, v1]
      # `rotation` on a face turns the picture on it, in ninety-degree steps,
      # by handing each corner the rectangle corner that many places along.
      let spun = int(number(doc, member(doc, entry, "rotation"), 0.0))
      var steps = (spun div 90) mod 4
      if steps < 0: steps = steps + 4
      if spun mod 90 != 0 and result.problem.len == 0:
        result.problem = "a face is rotated " & $spun & " degrees, not a quarter turn"
      if steps != 0:
        var ru: array[4, float] = [0.0, 0.0, 0.0, 0.0]
        var rv: array[4, float] = [0.0, 0.0, 0.0, 0.0]
        i = 0
        while i < 4:
          let src = (i + steps) mod 4
          ru[i] = uu[src]
          rv[i] = vv[src]
          inc i
        uu = ru
        vv = rv
      var nx = Normals[which][0]
      var ny = Normals[which][1]
      var nz = Normals[which][2]
      turnNormal(spin, nx, ny, nz)
      var cull = NoCull
      let cullNode = member(doc, entry, "cullface")
      if cullNode >= 0:
        cull = faceIndex(text(doc, cullNode))
        if cull < 0: cull = NoCull
      let tint = int(number(doc, member(doc, entry, "tintindex"), -1.0))
      emit(result, resolved, which, tint, cull, px, py, pz, nx, ny, nz, uu, vv)
  if result.count == 0 and result.problem.len == 0:
    result.problem = "this model's elements name no faces"

## Every distinct texture a bake refers to, in the order the faces first ask for
## them. That order is the atlas's tile order, so it is fixed here rather than
## discovered twice.
proc palette*(b: Bake): seq[string] =
  result = @[]
  var i = 0
  while i < b.count:
    let name = b.texture[i]
    inc i
    if name.len == 0: continue
    var seen = false
    var j = 0
    while j < result.len:
      if result[j] == name:
        seen = true
        break
      inc j
    if not seen: result.add name

proc tileOf*(b: Bake; face: int; names: seq[string]): int =
  if face < 0 or face >= b.count: return -1
  var i = 0
  while i < names.len:
    if names[i] == b.texture[face]: return i
    inc i
  -1

## Two bakes into one. A multipart block is a fence post plus a side per
## neighbour, and each of those is a model of its own with its own rotation, so
## the pieces are baked separately and joined here. The joined bake is one mesh
## with one palette, which is what the host's mesh builder wants.
##
## `problem` is carried across rather than dropped: a fence whose side model is
## broken must still put its post up, and still say what went wrong.
proc merge*(a: var Bake; b: Bake) =
  var f = 0
  while f < b.count:
    a.texture.add b.texture[f]
    a.face.add b.face[f]
    a.tint.add b.tint[f]
    a.cull.add b.cull[f]
    a.norm.add b.norm[f * 3]
    a.norm.add b.norm[f * 3 + 1]
    a.norm.add b.norm[f * 3 + 2]
    var i = 0
    while i < 12:
      a.pos.add b.pos[f * 12 + i]
      inc i
    i = 0
    while i < 8:
      a.uv.add b.uv[f * 8 + i]
      inc i
    inc a.count
    inc f
  a.skipped = a.skipped + b.skipped
  if b.problem.len > 0:
    if a.problem.len == 0: a.problem = b.problem
    elif a.problem != b.problem:
      # Through a temporary: `x = f(x)` is a live miscompile in this dialect.
      let both = a.problem & "; " & b.problem
      a.problem = both

proc emptyBake*(): Bake =
  Bake(count: 0, texture: @[], face: @[], tint: @[], cull: @[], pos: @[],
       norm: @[], uv: @[], problem: "", skipped: 0)

## Whether a model fills its whole block and hides everything behind it.
##
## This is the one physical fact a resource pack *does* carry. A pack has no
## hardness, no drop table and no idea whether you can walk through a block -
## those live in Minecraft's code, not its assets - but Minecraft's own
## occlusion test is a model question and it is answerable from here: a block is
## opaque when one of its elements is the whole cube from 0,0,0 to 16,16,16 and
## names all six faces with a `cullface` on each.
##
## The `cullface` is the load-bearing half. `glass` is a full cube with six
## faces and it is not opaque, and what says so in its own file is that its
## faces carry no `cullface` - which is Minecraft telling the mesher "do not
## hide what is behind this". Checking the box alone would make every window in
## the world solid.
proc isFullCube*(doc: Json; elements: int): bool =
  if elements < 0 or kindAt(doc, elements) != jArray: return false
  var e = 0
  while e < len(doc, elements):
    let element = item(doc, elements, e)
    inc e
    let fromNode = member(doc, element, "from")
    let toNode = member(doc, element, "to")
    if fromNode < 0 or toNode < 0: continue
    if numberAt(doc, fromNode, 0, 1.0) != 0.0: continue
    if numberAt(doc, fromNode, 1, 1.0) != 0.0: continue
    if numberAt(doc, fromNode, 2, 1.0) != 0.0: continue
    if numberAt(doc, toNode, 0, 0.0) != 16.0: continue
    if numberAt(doc, toNode, 1, 0.0) != 16.0: continue
    if numberAt(doc, toNode, 2, 0.0) != 16.0: continue
    if member(doc, element, "rotation") >= 0: continue
    let faces = member(doc, element, "faces")
    var seen = 0
    var f = 0
    while f < len(doc, faces):
      let entry = item(doc, faces, f)
      inc f
      let which = faceIndex(keyAt(doc, entry))
      if which < 0: continue
      if member(doc, entry, "cullface") < 0: continue
      seen = seen or (1 shl which)
    if seen == 63: return true
  false
