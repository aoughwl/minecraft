## Walking a ray through a grid of blocks, one block at a time.
##
## This is Amanatides and Woo's traversal, and it is here rather than in the
## world because it is the piece that is easy to get subtly wrong and hard to
## see wrong: an off-by-one at a negative coordinate puts the highlight one
## block behind the one you are looking at, and a face normal read from the
## wrong axis places a block inside the wall instead of against it.
##
## The walk is an object with a `stepOn` rather than a callback taking a
## predicate, because the interpreter is happier with a loop the caller owns and
## because it lets the caller stop for any reason it likes - reach, a chunk that
## has not been generated, a block that is liquid.
##
##   var walk = beginWalk(eye.x, eye.y, eye.z, ahead.x, ahead.y, ahead.z)
##   while walk.travelled <= Reach:
##     if solid(walk.x, walk.y, walk.z): break
##     stepOn(walk)
##
## The direction must be unit length; `travelled` is then in world units.

const
  FarAway* = 1.0e30

type
  Walk* = object
    ## Where the ray is now.
    x*, y*, z*: int
      ## The block the ray is inside.
    nx*, ny*, nz*: int
      ## The face it came in through, as the direction that face points: the
      ## outward normal of the block, and therefore the offset to the empty
      ## block a placement goes in. Zero on the first cell, which the ray began
      ## inside rather than entered.
    travelled*: float
      ## How far along the ray the entry into this block was.
    stepX, stepY, stepZ: int
    tMaxX, tMaxY, tMaxZ: float
    tDeltaX, tDeltaY, tDeltaZ: float

proc cellOf*(v: float): int =
  let t = int(v)
  if v < 0.0 and float(t) != v: return t - 1
  t

proc absOf(v: float): float =
  if v < 0.0: return -v
  v

## How far from `origin` along `direction` the first boundary crossing on one
## axis is. `cell` is the block index the origin is in.
proc firstCrossing(origin: float; cell, step: int; delta: float): float =
  if step == 0: return FarAway
  if step > 0: return (float(cell + 1) - origin) * delta
  (origin - float(cell)) * delta

## Start a walk at a place, going a way. The direction must be unit length.
proc beginWalk*(ox, oy, oz, dx, dy, dz: float): Walk =
  result = Walk(x: cellOf(ox), y: cellOf(oy), z: cellOf(oz),
    nx: 0, ny: 0, nz: 0, travelled: 0.0,
    stepX: 0, stepY: 0, stepZ: 0,
    tMaxX: FarAway, tMaxY: FarAway, tMaxZ: FarAway,
    tDeltaX: FarAway, tDeltaY: FarAway, tDeltaZ: FarAway)
  if dx > 0.0: result.stepX = 1
  elif dx < 0.0: result.stepX = -1
  if dy > 0.0: result.stepY = 1
  elif dy < 0.0: result.stepY = -1
  if dz > 0.0: result.stepZ = 1
  elif dz < 0.0: result.stepZ = -1
  if result.stepX != 0: result.tDeltaX = 1.0 / absOf(dx)
  if result.stepY != 0: result.tDeltaY = 1.0 / absOf(dy)
  if result.stepZ != 0: result.tDeltaZ = 1.0 / absOf(dz)
  result.tMaxX = firstCrossing(ox, result.x, result.stepX, result.tDeltaX)
  result.tMaxY = firstCrossing(oy, result.y, result.stepY, result.tDeltaY)
  result.tMaxZ = firstCrossing(oz, result.z, result.stepZ, result.tDeltaZ)

## Move to the next block the ray enters, and say which face it came in by.
##
## A ray that is going nowhere - every step zero - would otherwise spin here
## forever, so it is pushed past any reach instead.
proc stepOn*(walk: var Walk) =
  if walk.stepX == 0 and walk.stepY == 0 and walk.stepZ == 0:
    walk.travelled = FarAway
    return
  if walk.tMaxX <= walk.tMaxY and walk.tMaxX <= walk.tMaxZ:
    walk.travelled = walk.tMaxX
    walk.x = walk.x + walk.stepX
    walk.tMaxX = walk.tMaxX + walk.tDeltaX
    walk.nx = -walk.stepX
    walk.ny = 0
    walk.nz = 0
  elif walk.tMaxY <= walk.tMaxZ:
    walk.travelled = walk.tMaxY
    walk.y = walk.y + walk.stepY
    walk.tMaxY = walk.tMaxY + walk.tDeltaY
    walk.nx = 0
    walk.ny = -walk.stepY
    walk.nz = 0
  else:
    walk.travelled = walk.tMaxZ
    walk.z = walk.z + walk.stepZ
    walk.tMaxZ = walk.tMaxZ + walk.tDeltaZ
    walk.nx = 0
    walk.ny = 0
    walk.nz = -walk.stepZ

type
  Pick* = object
    ## What is under the crosshair: the block that stopped the ray, and the
    ## empty block against the face it was hit on, which is where a placement
    ## goes.
    found*: bool
    x*, y*, z*: int
    placeX*, placeY*, placeZ*: int
    nx*, ny*, nz*: int
    distance*: float

proc noPick*(): Pick =
  Pick(found: false, x: 0, y: 0, z: 0, placeX: 0, placeY: 0, placeZ: 0,
    nx: 0, ny: 0, nz: 0, distance: 0.0)

## Fill in the placement side of a pick from a finished walk.
proc pickAt*(walk: Walk): Pick =
  Pick(found: true, x: walk.x, y: walk.y, z: walk.z,
    placeX: walk.x + walk.nx, placeY: walk.y + walk.ny,
    placeZ: walk.z + walk.nz,
    nx: walk.nx, ny: walk.ny, nz: walk.nz, distance: walk.travelled)
