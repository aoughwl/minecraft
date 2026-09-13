## Blockstates: the file that says which model a block wears, and how it is
## turned.
##
## Pure: nothing here calls the host, so `Tests/minecraft_test.exe` proves it
## against fixtures in a second.
##
## ## Why this file has to exist
##
## Until it did, a catalog item was a *model*, so `oak_stairs` arrived as five
## loose shapes - `oak_stairs`, `oak_stairs_inner`, `oak_stairs_outer` and the
## abstract parents behind them - and `uvlock`, which is a blockstate property,
## had nothing to apply to. A blockstate file is the only place that says
## `oak_stairs` with `facing=east, half=top` is `oak_stairs_outer` turned 180
## degrees about Y with its textures held still. Without it there is no block,
## only parts of one.
##
## `assets/minecraft/blockstates/<name>.json` comes in exactly two shapes and
## both are read here.
##
## **`variants`** is a map from a *state string* to a placement:
##
##     {"variants": {
##        "facing=north,half=bottom": {"model": "block/oak_stairs"},
##        "facing=east,half=bottom":  {"model": "block/oak_stairs", "y": 90}}}
##
## A key names a subset of the block's properties, and a state matches a key
## when every property the key mentions has the value the key gives it. The
## empty key `""` matches everything, which is what `stone` is. A value may be
## an *array* of placements - the weighted random pick Minecraft makes for grass
## and stone - and `weight` is carried so a caller can make the same choice.
##
## **`multipart`** is a list of cases, each an optional `when` and an `apply`:
##
##     {"multipart": [
##        {"apply": {"model": "block/oak_fence_post"}},
##        {"when": {"north": "true"},
##         "apply": {"model": "block/oak_fence_side"}},
##        {"when": {"OR": [{"north": "true"}, {"south": "true"}]},
##         "apply": {"model": "block/x"}}]}
##
## A fence is not one model, it is a post plus a side per neighbour, and every
## case whose condition holds contributes. A `when` with no `OR`/`AND` is an AND
## of its own keys; a value of `"true|false"` is an OR of the alternatives.
## Those three forms cover everything vanilla ships and everything a pack can
## legally write.
##
## ## Rotation, and the one thing that is easy to get backwards
##
## `x` and `y` on a placement are quarter turns Minecraft applies as
## `rotationXYZ(-x, -y, 0)` - **negated**, and X before Y. Written out in the
## right-handed space Minecraft measures in, `y: 90` sends north to east, which
## is clockwise seen from above, and `x: 90` sends up to north. Those two
## sentences are the test, because a sign error here turns every stair in the
## world the wrong way and still looks plausible in a screenshot.
##
## The bake this is applied to is already in Unity's left-handed space with X
## mirrored, so the rotation is conjugated by that mirror on the way in. The
## algebra is four lines and it is written out in `spin()` below.
##
## ## uvlock
##
## `uvlock` means the *texture* does not turn with the model: a top slab rotated
## about Y keeps its top face's grain pointing the way the world does. Minecraft
## implements it as a transform of the face's uv; here it is the same thing
## derived from the geometry, which is both shorter and checkable. Each face has
## a u axis and a v axis in world space - they are exactly the axes Minecraft's
## own default-uv table walks - and a rotation carries them somewhere. Comparing
## where they landed against the axes the *destination* face already has gives a
## quarter-turn count, and turning the face's uv rectangle by that many places
## puts the texture back where the world had it.
##
## The test states it as the property rather than as the table: on a full cube
## with default uvs, a `y` rotation with `uvlock` leaves every corner's uv equal
## to what an unrotated cube would have given at that same world position.

import mcjson
import mcmodel

const
  MaxCases* = 256
    ## Vanilla's largest multipart is redstone at 60-odd cases. A pack that
    ## writes more than this is refused rather than walked.
  MaxPlacements* = 512

type
  Placement* = object
    ## One model, turned. `weight` is Minecraft's own relative weight for the
    ## random pick between the entries of one variant; it is 1 unless a file
    ## said otherwise.
    model*: string
    x*, y*: int      ## degrees, one of 0, 90, 180, 270
    uvlock*: bool
    weight*: float

  Choice* = object
    ## A variant key, or one multipart case, and the placements it names.
    key*: string       ## the variant key; "" for the always-on variant
    first*: int        ## into `place`
    count*: int
    firstClause*: int  ## into `clause`; multipart only
    clauseCount*: int

  Clause* = object
    ## One AND of conditions. A case matches when *any* of its clauses does.
    first*: int        ## into `cond`
    count*: int

  Condition* = object
    ## One property test. `values` are alternatives, so `north=true|false`
    ## is one condition with two values in it.
    key*: string
    values*: seq[string]

  BlockState* = object
    multipart*: bool
    choice*: seq[Choice]
    place*: seq[Placement]
    clause*: seq[Clause]
    cond*: seq[Condition]
    problem*: string

proc emptyState*(): BlockState =
  BlockState(multipart: false, choice: @[], place: @[], clause: @[],
             cond: @[], problem: "")

# ---------------------------------------------------------------------------
# Property strings
#
# A state is written the way a blockstate file writes it - `facing=north,half=top`
# - because that is the only spelling that is already in the data, and inventing
# a second one would mean two parsers that have to agree.

## Split `a=1,b=2` into keys and values. Whitespace around either is dropped.
## A fragment with no `=` in it is ignored rather than guessed at.
proc parseProps*(text: string; keys, vals: var seq[string]) =
  keys = @[]
  vals = @[]
  var field = ""
  var i = 0
  while i <= text.len:
    if i == text.len or text[i] == ',':
      var key = ""
      var value = ""
      var split = -1
      var j = 0
      while j < field.len:
        if field[j] == '=':
          split = j
          break
        inc j
      if split >= 0:
        j = 0
        while j < split:
          if field[j] != ' ': key.add field[j]
          inc j
        j = split + 1
        while j < field.len:
          if field[j] != ' ': value.add field[j]
          inc j
        if key.len > 0:
          keys.add key
          vals.add value
      field = ""
    else:
      field.add text[i]
    inc i

proc propOf*(keys, vals: seq[string]; key: string): string =
  var i = 0
  while i < keys.len:
    if keys[i] == key: return vals[i]
    inc i
  ""

## `a=1,b=2` again, from keys and values, with the keys in the order given. The
## catalog publishes this spelling, so a round trip through `parseProps` has to
## come back the same and the test says so.
proc formatProps*(keys, vals: seq[string]): string =
  result = ""
  var i = 0
  while i < keys.len:
    if result.len > 0: result.add ","
    result.add keys[i]
    result.add "="
    result.add vals[i]
    inc i

# ---------------------------------------------------------------------------
# Reading the file

proc readPlacement(doc: Json; node: int): Placement =
  result = Placement(model: "", x: 0, y: 0, uvlock: false, weight: 1.0)
  result.model = resourcePath(text(doc, member(doc, node, "model")))
  result.x = int(number(doc, member(doc, node, "x"), 0.0))
  result.y = int(number(doc, member(doc, node, "y"), 0.0))
  result.uvlock = truth(doc, member(doc, node, "uvlock"), false)
  result.weight = number(doc, member(doc, node, "weight"), 1.0)
  if result.weight <= 0.0: result.weight = 1.0

## `apply` is either one placement or an array of them, and both spellings mean
## the same thing to everything downstream: a list.
proc readApply(bs: var BlockState; doc: Json; node: int; first, count: var int) =
  first = bs.place.len
  count = 0
  if node < 0: return
  if kindAt(doc, node) == jArray:
    var i = 0
    while i < len(doc, node):
      if bs.place.len >= MaxPlacements:
        if bs.problem.len == 0:
          bs.problem = "more than " & $MaxPlacements & " placements in one file"
        return
      bs.place.add readPlacement(doc, item(doc, node, i))
      inc count
      inc i
  elif kindAt(doc, node) == jObject:
    bs.place.add readPlacement(doc, node)
    count = 1

## The alternatives in one condition value. `"true"` is one, `"true|false"` is
## two. A number is a string here, because a blockstate property is text even
## when it reads as a number - `level=3` and `level="3"` are the same property.
proc readValues(doc: Json; node: int): seq[string] =
  result = @[]
  var raw = ""
  if kindAt(doc, node) == jString: raw = text(doc, node)
  elif kindAt(doc, node) == jBool:
    raw = (if truth(doc, node): "true" else: "false")
  elif kindAt(doc, node) == jNumber:
    raw = $int(number(doc, node, 0.0))
  var piece = ""
  var i = 0
  while i <= raw.len:
    if i == raw.len or raw[i] == '|':
      if piece.len > 0: result.add piece
      piece = ""
    else:
      piece.add raw[i]
    inc i

## Fold one `{"facing": "north", "half": "top"}` object into a clause's
## conditions. Every key of it is an AND.
proc addConditions(bs: var BlockState; doc: Json; node: int; count: var int) =
  if node < 0 or kindAt(doc, node) != jObject: return
  var i = 0
  while i < len(doc, node):
    let entry = item(doc, node, i)
    inc i
    let key = keyAt(doc, entry)
    if key == "OR" or key == "AND": continue
    bs.cond.add Condition(key: key, values: readValues(doc, entry))
    inc count

## One `when`, in the three shapes a blockstate may write it: an OR of objects,
## an AND of objects, or a bare object which is an AND of its own keys.
proc readWhen(bs: var BlockState; doc: Json; node: int;
              firstClause, clauseCount: var int) =
  firstClause = bs.clause.len
  clauseCount = 0
  if node < 0 or kindAt(doc, node) != jObject: return
  let orNode = member(doc, node, "OR")
  let andNode = member(doc, node, "AND")
  if orNode >= 0 and kindAt(doc, orNode) == jArray:
    var i = 0
    while i < len(doc, orNode):
      let first = bs.cond.len
      var count = 0
      addConditions(bs, doc, item(doc, orNode, i), count)
      bs.clause.add Clause(first: first, count: count)
      inc clauseCount
      inc i
    return
  # AND, and the bare object, are both one clause. An AND's entries are folded
  # into the same clause because that is what an AND of conditions is.
  let first = bs.cond.len
  var count = 0
  if andNode >= 0 and kindAt(doc, andNode) == jArray:
    var i = 0
    while i < len(doc, andNode):
      addConditions(bs, doc, item(doc, andNode, i), count)
      inc i
  addConditions(bs, doc, node, count)
  if count == 0: return
  bs.clause.add Clause(first: first, count: count)
  clauseCount = 1

## A whole blockstate file. A file that is neither `variants` nor `multipart`
## comes back empty with a reason, never half-read.
proc parseBlockState*(doc: Json): BlockState =
  result = emptyState()
  if doc.root < 0:
    result.problem = "this blockstate would not parse"
    return result
  let variants = member(doc, doc.root, "variants")
  let multipart = member(doc, doc.root, "multipart")
  if variants >= 0 and kindAt(doc, variants) == jObject:
    var i = 0
    while i < len(doc, variants):
      if result.choice.len >= MaxCases:
        result.problem = "more than " & $MaxCases & " variants in one file"
        return result
      let entry = item(doc, variants, i)
      inc i
      var first = 0
      var count = 0
      readApply(result, doc, entry, first, count)
      result.choice.add Choice(key: keyAt(doc, entry), first: first,
        count: count, firstClause: 0, clauseCount: 0)
    return result
  if multipart >= 0 and kindAt(doc, multipart) == jArray:
    result.multipart = true
    var i = 0
    while i < len(doc, multipart):
      if result.choice.len >= MaxCases:
        result.problem = "more than " & $MaxCases & " multipart cases in one file"
        return result
      let entry = item(doc, multipart, i)
      inc i
      var firstClause = 0
      var clauseCount = 0
      readWhen(result, doc, member(doc, entry, "when"), firstClause, clauseCount)
      var first = 0
      var count = 0
      readApply(result, doc, member(doc, entry, "apply"), first, count)
      result.choice.add Choice(key: "", first: first, count: count,
        firstClause: firstClause, clauseCount: clauseCount)
    return result
  result.problem = "a blockstate must have 'variants' or 'multipart'"

# ---------------------------------------------------------------------------
# Matching a state

## Whether a variant key holds for a state. The key names a *subset* of the
## properties - `facing=north` on a stair says nothing about `half` - so every
## property the key mentions must match and every one it does not is free.
proc keyMatches*(key: string; keys, vals: seq[string]): bool =
  if key.len == 0: return true
  var wantKeys: seq[string] = @[]
  var wantVals: seq[string] = @[]
  parseProps(key, wantKeys, wantVals)
  var i = 0
  while i < wantKeys.len:
    if propOf(keys, vals, wantKeys[i]) != wantVals[i]: return false
    inc i
  true

proc condMatches(bs: BlockState; at: int; keys, vals: seq[string]): bool =
  let have = propOf(keys, vals, bs.cond[at].key)
  var i = 0
  while i < bs.cond[at].values.len:
    if bs.cond[at].values[i] == have: return true
    inc i
  false

proc clauseMatches(bs: BlockState; at: int; keys, vals: seq[string]): bool =
  var i = 0
  while i < bs.clause[at].count:
    if not condMatches(bs, bs.clause[at].first + i, keys, vals): return false
    inc i
  true

## Whether one multipart case applies. No clauses at all means "always", which
## is the fence post.
proc caseMatches*(bs: BlockState; at: int; keys, vals: seq[string]): bool =
  if bs.choice[at].clauseCount == 0: return true
  var i = 0
  while i < bs.choice[at].clauseCount:
    if clauseMatches(bs, bs.choice[at].firstClause + i, keys, vals): return true
    inc i
  false

## Every placement a state wears, as indices into `place`.
##
## For `variants` that is the *first* matching key's placements, because a
## variants map is a partition and a state belongs to one cell of it. For
## `multipart` it is every matching case's, in file order, because a multipart
## block is the sum of its parts.
proc placementsFor*(bs: BlockState; state: string): seq[int] =
  result = @[]
  var keys: seq[string] = @[]
  var vals: seq[string] = @[]
  parseProps(state, keys, vals)
  var i = 0
  while i < bs.choice.len:
    var hit = false
    if bs.multipart: hit = caseMatches(bs, i, keys, vals)
    else: hit = keyMatches(bs.choice[i].key, keys, vals)
    if hit:
      var j = 0
      while j < bs.choice[i].count:
        result.add bs.choice[i].first + j
        inc j
      if not bs.multipart: return result
    inc i

## Every state this file names, for a catalog to publish. A `variants` file
## names them outright. A `multipart` file does not - a fence's states are the
## product of its four booleans and only the block's own definition knows them -
## so it answers with the empty state, and the caller publishes one item whose
## parts are whatever holds with nothing set.
proc statesOf*(bs: BlockState): seq[string] =
  result = @[]
  if bs.multipart:
    result.add ""
    return result
  var i = 0
  while i < bs.choice.len:
    result.add bs.choice[i].key
    inc i

## The state a catalog should show when nothing has asked for one: the first
## variant, which is the one Minecraft's own files put first and is invariably
## the upright, unattached, default-facing form.
proc defaultState*(bs: BlockState): string =
  if bs.multipart or bs.choice.len == 0: return ""
  bs.choice[0].key

## Which of a variant's several placements to use, by weight. `roll` is any
## number; the same roll always gives the same answer, so a chunk that wants
## Minecraft's own scatter can hash a position into it and a caller that wants
## one shape can pass zero.
proc pickWeighted*(bs: BlockState; picks: seq[int]; roll: int): int =
  if picks.len == 0: return -1
  var total = 0
  var i = 0
  while i < picks.len:
    var w = int(bs.place[picks[i]].weight + 0.5)
    if w < 1: w = 1
    total = total + w
    inc i
  var at = roll mod total
  if at < 0: at = at + total
  i = 0
  while i < picks.len:
    var w = int(bs.place[picks[i]].weight + 0.5)
    if w < 1: w = 1
    if at < w: return picks[i]
    at = at - w
    inc i
  picks[picks.len - 1]

# ---------------------------------------------------------------------------
# Turning a bake
#
# Minecraft applies `rotationXYZ(-x, -y, 0)`: about X first, then about Y, both
# negated. In Minecraft's own right-handed space that is
#
#   Rx:  y' =  y cosX + z sinX      z' = -y sinX + z cosX
#   Ry:  x' =  x cosY - z sinY      z' =  x sinY + z cosY
#
# and `y: 90` therefore sends north (0,0,-1) to east (1,0,0) - clockwise from
# above - while `x: 90` sends up to north. Those are the two sentences the test
# checks, because everything else here is bookkeeping around them.
#
# The bake is in the mirrored space where a = -x, so conjugating by the mirror
# turns the X-axis rotation into itself and flips the sign of the Y-axis one's
# off-diagonal:
#
#   Rx:  b' =  b cosX + c sinX      c' = -b sinX + c cosX
#   Ry:  a' =  a cosY + c sinY      c' = -a sinY + c cosY

const
  QuarterCos: array[4, float] = [1.0, 0.0, -1.0, 0.0]
  QuarterSin: array[4, float] = [0.0, 1.0, 0.0, -1.0]

  # Where each face's u and v axes point, in Minecraft's space, read straight
  # off `defaultUv`: `u = x` is +X, `u = 16 - x` is -X, and so on.
  FaceU: array[6, array[3, int]] = [
    [1, 0, 0], [1, 0, 0], [-1, 0, 0], [1, 0, 0], [0, 0, 1], [0, 0, -1]]
  FaceV: array[6, array[3, int]] = [
    [0, 0, -1], [0, 0, 1], [0, -1, 0], [0, -1, 0], [0, -1, 0], [0, -1, 0]]
  FaceNormal: array[6, array[3, int]] = [
    [0, -1, 0], [0, 1, 0], [0, 0, -1], [0, 0, 1], [-1, 0, 0], [1, 0, 0]]

proc steps*(degrees: int): int =
  ## Quarter turns, from any of the four angles Minecraft allows, and from a
  ## negative or an over-wound one too rather than refusing them.
  var s = (degrees div 90) mod 4
  if s < 0: s = s + 4
  s

## One integer vector through the same rotation, in Minecraft's space. Used for
## culling faces and for the uv axes, where the answer is always another unit
## vector and floating point would only be a rounding risk.
proc spinInt*(v: array[3, int]; xs, ys: int): array[3, int] =
  let cx = int(QuarterCos[xs])
  let sx = int(QuarterSin[xs])
  let cy = int(QuarterCos[ys])
  let sy = int(QuarterSin[ys])
  var x = v[0]
  var y = v[1]
  var z = v[2]
  let y1 = y * cx + z * sx
  let z1 = -y * sx + z * cx
  y = y1
  z = z1
  let x2 = x * cy - z * sy
  let z2 = x * sy + z * cy
  x = x2
  z = z2
  [x, y, z]

proc faceOf(v: array[3, int]): int =
  var i = 0
  while i < 6:
    if FaceNormal[i][0] == v[0] and FaceNormal[i][1] == v[1] and
       FaceNormal[i][2] == v[2]: return i
    inc i
  -1

## Where a face ends up. A `cullface: north` on a model turned 90 degrees about
## Y is hidden by its east neighbour, and a chunk mesher that did not know that
## would leave a hole in the world.
proc rotateFace*(face, xs, ys: int): int =
  if face < 0 or face > 5: return face
  faceOf(spinInt(FaceNormal[face], xs, ys))

proc dot(a, b: array[3, int]): int = a[0] * b[0] + a[1] * b[1] + a[2] * b[2]

## How many quarter turns of the uv rectangle put the texture back where the
## world had it. Zero when the rotation left this face's axes alone, which is
## every face whose plane the rotation did not touch.
proc uvlockSteps*(face, xs, ys: int): int =
  if face < 0 or face > 5: return 0
  let landed = rotateFace(face, xs, ys)
  if landed < 0: return 0
  let u = spinInt(FaceU[face], xs, ys)
  let alongU = dot(u, FaceU[landed])
  let alongV = dot(u, FaceV[landed])
  # The rotation carried this face's u axis onto the destination's v axis, say.
  # That is the texture having turned one quarter one way, so the rectangle is
  # turned one quarter the *other* way to put it back - which is why the two
  # off-axis answers are 3 and 1 rather than 1 and 3.
  if alongU == 1: return 0
  if alongV == 1: return 3
  if alongU == -1: return 2
  if alongV == -1: return 1
  0

## Shift one face's four uv corners round by `by` places. The bake stores its
## corners back to front - that is what reverses the winding after the X mirror
## - so a shift of one place in the model's own order is a shift of minus one
## here, and this is the only place that has to know it.
proc shiftUv*(b: var Bake; face, by: int) =
  if face < 0 or face >= b.count: return
  var s = by mod 4
  if s < 0: s = s + 4
  if s == 0: return
  var u: array[4, float] = [0.0, 0.0, 0.0, 0.0]
  var v: array[4, float] = [0.0, 0.0, 0.0, 0.0]
  var i = 0
  while i < 4:
    u[i] = b.uv[face * 8 + i * 2]
    v[i] = b.uv[face * 8 + i * 2 + 1]
    inc i
  i = 0
  while i < 4:
    let src = (i + 4 - s) mod 4
    b.uv[face * 8 + i * 2] = u[src]
    b.uv[face * 8 + i * 2 + 1] = v[src]
    inc i

proc spin(xs, ys: int; a, b, c: var float) =
  let cx = QuarterCos[xs]
  let sx = QuarterSin[xs]
  let cy = QuarterCos[ys]
  let sy = QuarterSin[ys]
  let b1 = b * cx + c * sx
  let c1 = -b * sx + c * cx
  b = b1
  c = c1
  let a2 = a * cy + c * sy
  let c2 = -a * sy + c * cy
  a = a2
  c = c2

## Turn a whole bake the way a blockstate says to. The block is already centred
## on its own origin, so this is a rotation about the origin and nothing else.
##
## `cullface` turns with it, `tintindex` and the textures do not, and `uvlock`
## turns each face's picture back by however much the rotation turned it.
proc applyPlacement*(b: var Bake; p: Placement) =
  let xs = steps(p.x)
  let ys = steps(p.y)
  if xs == 0 and ys == 0: return
  var f = 0
  while f < b.count:
    var i = 0
    while i < 4:
      var a = b.pos[f * 12 + i * 3]
      var y = b.pos[f * 12 + i * 3 + 1]
      var c = b.pos[f * 12 + i * 3 + 2]
      spin(xs, ys, a, y, c)
      b.pos[f * 12 + i * 3] = a
      b.pos[f * 12 + i * 3 + 1] = y
      b.pos[f * 12 + i * 3 + 2] = c
      inc i
    var nx = b.norm[f * 3]
    var ny = b.norm[f * 3 + 1]
    var nz = b.norm[f * 3 + 2]
    spin(xs, ys, nx, ny, nz)
    b.norm[f * 3] = nx
    b.norm[f * 3 + 1] = ny
    b.norm[f * 3 + 2] = nz
    if b.cull[f] != NoCull:
      let turnedCull = rotateFace(b.cull[f], xs, ys)
      b.cull[f] = turnedCull
    if p.uvlock: shiftUv(b, f, uvlockSteps(b.face[f], xs, ys))
    # Written through a temporary on purpose: `x = f(x)` is a live miscompile in
    # this dialect, and while it is documented as losing a string field this is
    # not the file to find out where the edges of that are.
    let turnedFace = rotateFace(b.face[f], xs, ys)
    b.face[f] = turnedFace
    inc f
