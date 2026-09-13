## Distant terrain: the horizon, drawn without ever making a block.
##
## Not one host call in this file. Everything it decides is arithmetic on the
## same `surfaceHeight` the real chunks are made of, which is what lets
## `Tests/voxel_test.exe` assert the two things a level-of-detail scheme is
## always quietly wrong about: that a far cell really does stand for the blocks
## underneath it, and that the seam between two levels has no hole in it.
##
## ## Why a heightmap and not a voxel pyramid
##
## The obvious level-of-detail scheme merges 2x2x2 blocks into one and meshes
## the result. It cannot be afforded here, and the reason is measured rather
## than felt. A block of terrain costs a `terrainAt`, and a *column* costs a
## `surfaceHeight` - about a hundred and twenty interpreted calls, roughly a
## quarter of a millisecond in this interpreter. A voxel pyramid has to know
## what is in every block before it can merge any of them, so a 48x128x48 region
## of far terrain would be 294,912 `terrainAt` calls whatever resolution it was
## finally drawn at. Downsampling *after* generating is not level of detail at
## all; it is generating the world twice and throwing most of it away.
##
## So the far field is a heightmap, and it is sampled at the resolution it will
## be drawn at and no finer. One cell of a level-3 region is eight blocks across
## and costs exactly one `surfaceHeight` - the same price as one column of the
## near world, for sixty-four columns' worth of ground. That is the whole win: a
## 624-block view costs about four times the noise of the 48-block near world
## while covering a hundred and sixty-nine times the area.
##
## This is also, not by coincidence, what Distant Horizons does. A block world
## seen from four hundred blocks away is a landscape, not a pile of cubes, and a
## landscape is a height and a colour per patch.
##
## ## What a cell is
##
## One number: the height of the ground at the cell's own corner column, taken
## from `surfaceHeight` with nothing averaged and nothing approximated. A cell
## therefore *agrees exactly* with the real world at one column in it and is
## wrong by the terrain's own slope at the others - which is the honest trade,
## and the one the test asserts, rather than a filtered value that agrees with
## nothing at all.
##
## The colour is the block the real generator would put at that column's
## surface: `terrainAt` at the sampled height. Grass, sand, or water where the
## sea covers it. So the horizon is painted out of the same atlas as the near
## world and the two meet without a change of palette.
##
## ## The seam
##
## Two regions drawn at different resolutions do not meet. The classic crack: a
## level-1 cell two blocks across sits beside four level-3 cells eight blocks
## across, their tops are at different heights, and you can see the sky through
## the join.
##
## The fix here is stitching by wall, not a skirt of some guessed depth. Every
## cell drops a wall from its own top down to `seamFloor` - the *lowest*
## rendered top among the columns immediately across that edge, whatever level
## or whatever kind of geometry happens to be drawing them. Two facts make that
## airtight. The neighbour's rendered top is a thing this module can answer for
## any column in the scene, including the columns of the real block world, so a
## far region also stitches to the near one. And the lower of any two
## neighbours never needs a wall of its own, because the taller one has already
## covered the whole interval between them.
##
## A skirt was the alternative and was rejected: a skirt hides a crack by
## hanging a curtain of a guessed depth off every edge, which costs a quad on
## every boundary cell whether or not there was ever a hole, and is only correct
## as long as the guess is bigger than the worst height difference anybody ever
## generates. The wall costs the same quad, is exactly as deep as the hole it
## fills, and is provably right rather than probably right.
##
## `naiveFloor` beside it is the same decision made the way you would make it if
## you meshed one region on its own: the neighbouring *cell of the same field*,
## and no wall at all at the region's edge. It ships so that the test can build
## the same scene both ways and show the hole.
##
## ## What this does not do, and why
##
## **There is no fade between levels.** A cross-fade wants the same ground drawn
## at two resolutions at once with complementary alpha, which is twice the
## geometry for the duration, and the host can only set an alpha per *part* -
## there is no per-vertex colour and no submesh index, so the two copies would
## also have to be two more parts each. It is not affordable, and it is also not
## needed here yet: the level of a region is a function of which ring it is in,
## the rings are pinned to the near world, and the near world does not move, so
## no region ever changes level while you are looking at it. The moment this
## follows the player - which is the obvious next thing - a region crossing a
## ring boundary will pop, and that pop will have to be paid for.
##
## **A region is rebuilt, never re-meshed.** The host has no call that swaps the
## geometry of a part that already exists, so changing a region means destroying
## its parts and spawning new ones.
##
## **The horizon does not follow the player.** `newLodScene` is centred on the
## near world's own region because that is where the real chunks are; walking
## out of the near world is walking off the edge of the ground either way.

import vxblocks
import vxnoise
import vxatlas
import vxworld

const
  LodRegion* = 48
    ## How wide a region of far terrain is, in blocks. Three chunks, so the
    ## region grid and the chunk grid are the same grid and the near world is
    ## exactly one region - which is what lets `renderHeightAt` answer for any
    ## column without being told first whether it is near or far.
  LodBandCells* = 24
    ## How many *cells* are handed over as one mesh. The same idea as a chunk's
    ## slices and for the same reason, but counted in cells rather than rows,
    ## because a row means something different at every level: a row of a
    ## level-1 region is twenty-four cells and a row of a level-4 region is
    ## three.
    ##
    ## The number is measured, not chosen. Meshing a cell - the walls it owes
    ## its neighbours worked out, the quads written down - is about 310
    ## microseconds in this interpreter, so twenty-four cells is about seven
    ## milliseconds and a frame is sixteen. A whole level-1 region in one go
    ## would be a hundred and eighty, which is eleven dropped frames every time
    ## another piece of the horizon arrived.
  LodFloor* = 0
    ## Where a wall goes when there is nothing at all beyond it - the outer rim
    ## of the drawn world.
  RingLevel*: array[8, int] = [0, 1, 2, 3, 4, 4, 4, 4]
    ## The level drawn at each ring of regions out from the player. Ring 0 is
    ## the near world and is real blocks. Non-decreasing, which is the property
    ## `levelForRing` inherits and the test asserts: detail may never come back
    ## as you get further away.

type
  LodField* = object
    ## One region's heightmap, at one level. `height` and `kind` are one entry
    ## per cell, row-major in z then x, and are -1 until that row is sampled.
    rx*, rz*: int
    level*: int
    span*: int
      ## Cells per edge: `LodRegion div stride`. 48, 24, 12, 6 or 3.
    height*: seq[int]
    kind*: seq[int]
    rows*: int
      ## How many rows of cells have been sampled. A field is done when this
      ## reaches `span`, and nothing may be meshed against a field that is not.

  LodScene* = object
    ## The square of regions around the near world, and what has been done to
    ## each of them.
    fields*: seq[LodField]
    minRx*, minRz*, wide*: int
    centreRx*, centreRz*: int
      ## Which region the rings are counted out from - the one the player is
      ## in, and therefore the one the near world covers. Zero is the scene this
      ## mod shipped with, pinned to the near world at the origin, which is why
      ## every assertion about `newLodScene(6)` still holds unchanged.
      ##
      ## A region is named by `rx, rz` in the world rather than by where it sits
      ## in `fields`, so moving the centre is a rearrangement: a region that
      ## keeps its level keeps its heightmap and keeps its meshes, and only the
      ## ones that crossed a level boundary are paid for again. See
      ## `vxstream.retargetLod`.
    order*: seq[int]
      ## Region indices, nearest first. The order they are filled in, so the
      ## horizon arrives outward from the player.

# ---------------------------------------------------------------------------
# Levels and rings

proc lodStride*(level: int): int = 1 shl level

## The level for a ring of regions. Ring 0 is the near world; everything past
## the table is the coarsest level there is, so the answer is defined for any
## distance and never goes back down.
proc levelForRing*(ring: int): int =
  if ring <= 0: return 0
  if ring < 8: return RingLevel[ring]
  RingLevel[7]

## The same as a function of distance in blocks, which is the form the property
## is easiest to state in: monotone, and a step every `LodRegion`.
proc levelForDistance*(blocks: int): int =
  if blocks < 0: return 0
  levelForRing(blocks div LodRegion)

## How far out a region is from the middle, in regions. Chebyshev rather than
## Euclidean, so a ring really is a square ring and every region in it is drawn
## the same way - a ring whose corners were a level coarser than its sides would
## put a seam down the middle of flat ground for no reason.
proc ringOf*(rx, rz: int): int =
  var ax = rx
  if ax < 0: ax = -ax
  var az = rz
  if az < 0: az = -az
  if ax > az: return ax
  az

# ---------------------------------------------------------------------------
# A scene
#
# Everything below indexes `s.fields` rather than taking a `LodField`. That is
# not a style: a field owns two seqs of up to two thousand ints, a parameter is
# a copy, and `seamFloor` is called on every edge cell of every region.

proc slotAt*(s: LodScene; rx, rz: int): int =
  ## Where a region sits in the array, whether or not anything is drawn there.
  ## `rx, rz` are absolute - a region is named by where it is in the world - so
  ## this is what lets a scene that has just moved recognise a region it already
  ## holds and keep it.
  if rx < s.minRx or rz < s.minRz: return -1
  if rx >= s.minRx + s.wide or rz >= s.minRz + s.wide: return -1
  (rz - s.minRz) * s.wide + (rx - s.minRx)

proc fieldAt*(s: LodScene; rx, rz: int): int =
  ## Which field covers a region, or -1 when it is outside the drawn square or
  ## is a region nothing far is drawn in - the near world's own, when the near
  ## world is exactly one region.
  let i = s.slotAt(rx, rz)
  if i < 0: return -1
  if s.fields[i].level <= 0: return -1
  i

## The level a region is drawn at, given where the scene is centred. One
## spelling, called by the constructor and by the re-centring alike: a scene
## that has moved is then indistinguishable from one built at the new centre,
## which is the property that makes moving it a rearrangement rather than a
## second implementation of the same rule.
##
## `nearLevel` is what the middle region gets. Zero means nothing far is drawn
## there at all, which is right when the near world covers that region exactly;
## a near world that slides a chunk at a time does not, so it asks for a real
## level and lets `nearCovers` take out the cells the blocks are standing on.
proc levelForRegion*(cRx, cRz, rx, rz, nearLevel: int): int =
  let ring = ringOf(rx - cRx, rz - cRz)
  if ring == 0: return nearLevel
  levelForRing(ring)

proc fieldDone*(s: LodScene; index: int): bool =
  if index < 0 or index >= s.fields.len: return false
  s.fields[index].span > 0 and s.fields[index].rows >= s.fields[index].span

## The square of far regions around the near world. Nothing is sampled yet: this
## is the shape of the horizon, not the horizon.
##
## `radius` is in regions, so the drawn world is `(2*radius+1) * LodRegion`
## blocks across - a radius of six is a view six hundred and twenty four blocks
## wide, thirteen times the near world's edge and a hundred and sixty nine times
## its area.
##
## The order is built ring by ring rather than sorted, which is nearest-first by
## construction.
proc reorderLod*(s: var LodScene) =
  ## The order the regions are filled in and handed over: nearest first, ring by
  ## ring out from the centre, which is nearest-first by construction rather
  ## than by sorting. Rebuilt whenever the centre moves, because "nearest" then
  ## means somewhere else.
  s.order = @[]
  let radius = (s.wide - 1) div 2
  var ring = 0
  while ring <= radius:
    var z = s.centreRz - ring
    while z <= s.centreRz + ring:
      var x = s.centreRx - ring
      while x <= s.centreRx + ring:
        if ringOf(x - s.centreRx, z - s.centreRz) == ring:
          let i = s.slotAt(x, z)
          if i >= 0 and s.fields[i].span > 0: s.order.add i
        inc x
      inc z
    inc ring

proc newLodScene*(radius: int; cRx = 0; cRz = 0; nearLevel = 0): LodScene =
  result = LodScene(fields: @[], minRx: cRx - radius, minRz: cRz - radius,
    wide: radius * 2 + 1, centreRx: cRx, centreRz: cRz, order: @[])
  var rz = cRz - radius
  while rz <= cRz + radius:
    var rx = cRx - radius
    while rx <= cRx + radius:
      let level = levelForRegion(cRx, cRz, rx, rz, nearLevel)
      var span = 0
      if level > 0: span = LodRegion div lodStride(level)
      var f = LodField(rx: rx, rz: rz, level: level, span: span, height: @[],
        kind: @[], rows: 0)
      var c = 0
      while c < span * span:
        f.height.add -1
        f.kind.add AirId
        inc c
      result.fields.add f
      inc rx
    inc rz
  result.reorderLod()

# ---------------------------------------------------------------------------
# Sampling

## The top of one column as seen from a long way off, and what it is made of.
## Two answers out of one call, because the second one is free once the first
## has been paid for.
##
## The sea is the whole of the subtlety. A column whose ground is under the
## water line is drawn at the water line and painted water, because that is what
## `blockAt` answers at that height - so the test can hold this against the real
## world rather than against a second opinion. A column whose ground is exactly
## at the water line is beach, which is what `terrainAt` says too.
##
## Both take the ground height rather than working it out, because the noise is
## the expensive thing and the sampler has already paid for it once. The
## sampler calls these rather than repeating them, so there is one definition of
## what a cell stands for and the test is holding the shipped one.
proc lodTopOf*(w: World; ground: int): int =
  if ground < w.waterLevel: return w.waterLevel
  ground

proc lodKindOf*(w: World; x, z, ground: int): int =
  if ground < w.waterLevel: return w.palette.water
  var id = w.terrainAt(x, ground, z, ground)
  # A cave mouth at the surface reads as air, and air is not a colour. From
  # four hundred blocks away it is rock.
  if id == AirId: id = w.palette.stone
  id

## Sample one band of rows of one region. Costs exactly one `surfaceHeight` per
## cell - never one per block - which is the whole point of the module. Returns
## how many columns it evaluated, which is what the frame budget is spent in.
##
## The height and the kind come out of one evaluation rather than two: the noise
## is the expensive thing and asking it twice for the same column would double
## the price of the horizon.
proc sampleRows*(w: World; f: var LodField; fromCz, toCz: int): int =
  result = 0
  if f.span <= 0: return result
  let stride = lodStride(f.level)
  var cz = fromCz
  if cz < 0: cz = 0
  while cz <= toCz and cz < f.span:
    let z = f.rz * LodRegion + cz * stride
    var cx = 0
    while cx < f.span:
      let x = f.rx * LodRegion + cx * stride
      # The near world has already paid for the columns it stands on, and
      # `groundAt` wrote them down. Reading one back is the same number for
      # nothing instead of a quarter of a millisecond of noise, and it is not a
      # second opinion: the cache holds exactly what `surfaceHeight` answered.
      # It matters because the region the player is in is re-sampled every time
      # the horizon re-centres, and that region is almost all near world.
      var ground = -1
      let known = w.heightSlot(x, z)
      if known >= 0 and known < w.heights.len: ground = w.heights[known]
      if ground < 0: ground = w.surfaceHeight(x, z)
      f.height[cz * f.span + cx] = w.lodTopOf(ground)
      f.kind[cz * f.span + cx] = w.lodKindOf(x, z, ground)
      inc result
      inc cx
    inc cz
  if toCz + 1 > f.rows: f.rows = toCz + 1
  if f.rows > f.span: f.rows = f.span

proc sampleField*(w: World; f: var LodField): int =
  ## The whole region at once. What the test uses; the game samples a band at a
  ## time so a frame is never spent on it.
  sampleRows(w, f, 0, f.span - 1)

# ---------------------------------------------------------------------------
# What is drawn where

## Which cell of a field covers a world column, or -1 when the column is not in
## that region at all.
proc lodCellOf*(s: LodScene; index, x, z: int): int =
  if index < 0 or index >= s.fields.len: return -1
  if s.fields[index].span <= 0: return -1
  let stride = lodStride(s.fields[index].level)
  let lx = x - s.fields[index].rx * LodRegion
  let lz = z - s.fields[index].rz * LodRegion
  if lx < 0 or lz < 0 or lx >= LodRegion or lz >= LodRegion: return -1
  (lz div stride) * s.fields[index].span + (lx div stride)

## The top of the world at a column, as the player would actually see it drawn -
## the real block surface inside the near world, the covering cell's height
## outside it, and -1 where nothing is drawn at all.
##
## The near world's answer reads the height cache when it is warm, because that
## is the same number `groundAt` remembered while the chunks were being made and
## re-deriving it is a quarter of a millisecond a column.
##
## This one function is what makes the seam work: a wall never has to know
## whether the thing across it is a coarser region, a finer one, or a wall of
## real blocks.
proc nearCovers*(w: World; x, z, stride: int): bool =
  ## Whether a cell this wide, with this corner, is standing entirely on real
  ## blocks - in which case the horizon does not draw it, because the near world
  ## already has.
  ##
  ## This one test is what lets the two windows move at different rates. The
  ## near window slides a chunk at a time or the player walks off it; the region
  ## grid must not, because a grid that shifted by anything short of a whole
  ## region would rename every cell of every region and re-mesh the entire
  ## horizon. So the grid stays where it is and the horizon simply skips
  ## whatever the blocks happen to be under this frame.
  ##
  ## *Entirely* is not a hedge, it is a fact worth knowing: a cell is either
  ## wholly covered or wholly clear and can never straddle the edge, because
  ## every stride - 1, 2, 4, 8, 16 - divides `ChunkSize`, cells sit on multiples
  ## of their own stride, and the near window's edges are chunks. The test
  ## asserts that over every level and every window offset.
  if x < w.worldX0() or z < w.worldZ0(): return false
  if x + stride > w.worldX0() + w.blocksWide(): return false
  if z + stride > w.worldZ0() + w.blocksDeep(): return false
  true

proc renderHeightAt*(s: LodScene; w: World; x, z: int): int =
  let slot = w.heightSlot(x, z)
  if slot >= 0:
    var h = -1
    if slot < w.heights.len: h = w.heights[slot]
    if h < 0: h = w.surfaceHeight(x, z)
    if h < w.waterLevel: h = w.waterLevel
    return h
  let i = s.fieldAt(floorDiv(x, LodRegion), floorDiv(z, LodRegion))
  if i < 0: return -1
  if not s.fieldDone(i): return -1
  let c = s.lodCellOf(i, x, z)
  if c < 0: return -1
  s.fields[i].height[c]

# ---------------------------------------------------------------------------
# The seam
#
# `dir` is 0 +X, 1 -X, 2 +Z, 3 -Z, in the same order the walls are emitted.

## The lowest rendered top among the columns immediately across one edge of one
## cell. A wall dropped to this height cannot leave a crack: every column on the
## other side has its surface at or above it.
##
## The `min` is what a level seam needs. One edge of a level-3 cell is eight
## columns long and the level-1 region across it draws four different heights
## along that edge; a wall that stopped at any one of them would show sky over
## the other three.
##
## -1 means there is nothing drawn across that edge at all, which is the outer
## rim of the world and asks for a wall down to `LodFloor`.
proc seamFloor*(s: LodScene; w: World; index, cx, cz, dir: int): int =
  if index < 0 or index >= s.fields.len: return -1
  let stride = lodStride(s.fields[index].level)
  let x0 = s.fields[index].rx * LodRegion + cx * stride
  let z0 = s.fields[index].rz * LodRegion + cz * stride
  var low = -1
  var have = false
  var i = 0
  while i < stride:
    var x = x0
    var z = z0
    if dir == 0:
      x = x0 + stride
      z = z0 + i
    elif dir == 1:
      x = x0 - 1
      z = z0 + i
    elif dir == 2:
      x = x0 + i
      z = z0 + stride
    else:
      x = x0 + i
      z = z0 - 1
    let h = s.renderHeightAt(w, x, z)
    if h < 0: return -1
    if not have or h < low:
      low = h
      have = true
    inc i
  if not have: return -1
  low

## The same decision made the wrong way, and it ships so the test can prove it
## is wrong: the neighbouring cell **of this field only**, and no wall at all
## where the region ends. That is everything one region meshed in isolation
## knows, and it is exactly the classic level-of-detail crack - the hole is not
## in the middle of a region, it is at every join.
##
## -1 here means "emit no wall", which is the bug; -1 from `seamFloor` means
## "wall to the floor", which is not.
proc naiveFloor*(s: LodScene; index, cx, cz, dir: int): int =
  if index < 0 or index >= s.fields.len: return -1
  var nx = cx
  var nz = cz
  if dir == 0: inc nx
  elif dir == 1: dec nx
  elif dir == 2: inc nz
  else: dec nz
  let span = s.fields[index].span
  if nx < 0 or nz < 0 or nx >= span or nz >= span: return -1
  s.fields[index].height[nz * span + nx]

# ---------------------------------------------------------------------------
# The mesh
#
# The same `Faces` a chunk produces, so a far region is handed to the host by
# exactly the code that hands a chunk over - one mesh per material, the atlas
# through the uvs, and nothing in `main.nim` branching on which it is.

const
  WallFace*: array[4, int] = [0, 1, 4, 5]
    ## The face number a wall in each direction wears: +X, -X, +Z, -Z. A top is
    ## face 2, +Y. `FaceCorner` and `FaceUv` are indexed by these and are the
    ## same tables the chunk mesher and the winding test use, so a far quad is
    ## wound outward for the same reason a block face is.

## One band of rows of one region, as geometry in region-local blocks.
##
## `stitched` false is the control: the walls are decided by `naiveFloor`
## instead, which is what a region meshed on its own would draw. Nothing in the
## game passes false; `Tests/voxel_test.exe` passes it to show the crack.
proc buildLodFaces*(s: LodScene; w: World; skins: seq[Skin]; index: int;
                    fromCz = 0; toCz = 1 shl 24; stitched = true): Faces =
  result = emptyFaces()
  if index < 0 or index >= s.fields.len: return result
  if not s.fieldDone(index): return result
  let span = s.fields[index].span
  let stride = lodStride(s.fields[index].level)
  let side = float(stride)
  var lowZ = fromCz
  var highZ = toCz
  if lowZ < 0: lowZ = 0
  if highZ > span - 1: highZ = span - 1
  var cz = lowZ
  while cz <= highZ:
    var cx = 0
    while cx < span:
      let h = s.fields[index].height[cz * span + cx]
      let id = s.fields[index].kind[cz * span + cx]
      # Where the real blocks are, the horizon draws nothing: a far cell's top
      # is the same height as the ground it stands for, so drawing both would be
      # two surfaces in one plane fighting over every pixel.
      let wx = s.fields[index].rx * LodRegion + cx * stride
      let wz = s.fields[index].rz * LodRegion + cz * stride
      if h >= 0 and id != AirId and not w.nearCovers(wx, wz, stride):
        # The sheet's numbers, once per cell rather than once per corner. The
        # same arithmetic `buildChunk` unrolls, and for the same reason.
        var texColumns = 0
        var texSide = DefaultSide
        var texPitch = float(DefaultSide + 2 * Pad)
        if id < skins.len and skins[id].columns > 0 and skins[id].atlas.len > 0:
          texColumns = skins[id].columns
          texSide = skins[id].side
          texPitch = float(texSide + 2 * Pad)
        let x0 = float(cx * stride)
        let z0 = float(cz * stride)
        let x1 = x0 + side
        let z1 = z0 + side
        let top = float(h + 1)

        # Five quads at most: the top, and a wall on each side down to whatever
        # is drawn beyond it. Every one goes out through the same corner table
        # the block mesher uses, so a cell is a box with its lid on and its
        # winding is the winding the test already checks.
        var slot = 0
        while slot < 5:
          var face = 2
          var yLo = top
          var draw = false
          if slot == 0:
            draw = true
          else:
            let dir = slot - 1
            face = WallFace[dir]
            var floorY = LodFloor
            var skip = false
            if stitched:
              # The fast path is the whole of the inside of a region: the
              # neighbouring cell is the same level and covers every column
              # across that edge, so its height *is* the minimum and one seq
              # read is the answer `seamFloor` would walk the edge for. Only
              # the region's own border pays for the walk.
              var nx = cx
              var nz = cz
              if dir == 0: inc nx
              elif dir == 1: dec nx
              elif dir == 2: inc nz
              else: dec nz
              # ...and the fast path is off when the neighbouring cell is one of
              # the ones the near world covers, because then what is drawn
              # across that edge is not that cell at all - it is up to `stride`
              # columns of real blocks at up to `stride` different heights, and
              # only the walk knows the lowest of them.
              if nx >= 0 and nz >= 0 and nx < span and nz < span and
                 not w.nearCovers(wx + (nx - cx) * stride,
                                  wz + (nz - cz) * stride, stride):
                floorY = s.fields[index].height[nz * span + nx]
              else:
                let beyond = s.seamFloor(w, index, cx, cz, dir)
                if beyond >= 0: floorY = beyond
                else: floorY = LodFloor
            else:
              let beyond = s.naiveFloor(index, cx, cz, dir)
              if beyond < 0: skip = true
              else: floorY = beyond
            if not skip and floorY < h:
              draw = true
              yLo = float(floorY + 1)
          if draw:
            var uLo = 0.0
            var uHi = 1.0
            var vLo = 0.0
            var vHi = 1.0
            if texColumns > 0:
              let across = texPitch * float(texColumns)
              let left = float(skins[id].tile[face]) * texPitch + float(Pad)
              uLo = left / across
              uHi = (left + float(texSide)) / across
              vLo = float(Pad) / texPitch
              vHi = (float(Pad) + float(texSide)) / texPitch
            var c = 0
            while c < 4:
              if FaceCorner[face][c * 3] == 0: result.pos.add x0
              else: result.pos.add x1
              if FaceCorner[face][c * 3 + 1] == 0: result.pos.add yLo
              else: result.pos.add top
              if FaceCorner[face][c * 3 + 2] == 0: result.pos.add z0
              else: result.pos.add z1
              if FaceUv[face][c * 2] > 0.5: result.uv.add uHi
              else: result.uv.add uLo
              if FaceUv[face][c * 2 + 1] > 0.5: result.uv.add vHi
              else: result.uv.add vLo
              # Flat lit. A far cell is a column of terrain rather than a block,
              # so it has no neighbours to be occluded by - the three blocks
              # ambient occlusion counts do not exist at this resolution - and a
              # region four hundred blocks away is a handful of pixels tall
              # anyway. Ones, so the colour channel multiplies into nothing.
              result.ao.add 1.0
              inc c
            result.norm.add float(FaceNormal[face][0])
            result.norm.add float(FaceNormal[face][1])
            result.norm.add float(FaceNormal[face][2])
            result.kind.add id
            inc result.count
          inc slot
      inc cx
    inc cz

## How many rows of one region go into one mesh: as many as fit in
## `LodBandCells`, and never fewer than one however wide the region is.
proc lodBandRows*(s: LodScene; index: int): int =
  if index < 0 or index >= s.fields.len: return 0
  let span = s.fields[index].span
  if span <= 0: return 0
  var rows = LodBandCells div span
  if rows < 1: rows = 1
  if rows > span: rows = span
  rows

proc lodBands*(s: LodScene; index: int): int =
  ## How many meshes one region becomes.
  if index < 0 or index >= s.fields.len: return 0
  let span = s.fields[index].span
  if span <= 0: return 0
  let rows = s.lodBandRows(index)
  (span + rows - 1) div rows

## Whether a region can be meshed yet: itself and everything it will have to
## stitch to. A region meshed before its neighbours were sampled would wall down
## to `LodFloor` along that edge - a mile of black cliff hanging in the air
## rather than a hole, which is at least honest, but wrong. The near world
## always counts as arrived, and so does the outside of the drawn square.
proc lodReady*(s: LodScene; index: int): bool =
  if not s.fieldDone(index): return false
  let rx = s.fields[index].rx
  let rz = s.fields[index].rz
  var d = 0
  while d < 4:
    var nx = rx
    var nz = rz
    if d == 0: inc nx
    elif d == 1: dec nx
    elif d == 2: inc nz
    else: dec nz
    let other = s.fieldAt(nx, nz)
    if other >= 0 and not s.fieldDone(other): return false
    inc d
  true

proc lodCells*(s: LodScene): int =
  ## How many columns the whole horizon costs, which is the number the whole
  ## design has to be justified by.
  result = 0
  var i = 0
  while i < s.fields.len:
    result = result + s.fields[i].span * s.fields[i].span
    inc i

proc lodBlocksWide*(s: LodScene): int = s.wide * LodRegion
