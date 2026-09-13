## The world follows the player: which ground is real, which is horizon, and
## when either of those answers is allowed to change.
##
## Not one host call in this file, for the same reason `vxlod.nim` has none:
## every decision here is arithmetic on a position, and arithmetic can be held
## against an assertion. `Tests/voxel_test.exe` walks a player across several
## hundred blocks in this module alone - no Unity, no frame, no chunk - and
## checks that the ground under them is real, that a region they walk towards
## gets finer, that one they walk away from gets coarser, and that neither
## happens twice for one step across a boundary.
##
## ## The two windows
##
## There are two of them and they move independently, which is the whole design.
##
## **The near window** is the real blocks: `spanX` by `spanZ` chunks, and it is
## a *ring buffer*. Sliding it one chunk east does not allocate a chunk and does
## not free one; the column of chunks that fell off the west edge is renamed to
## the east edge, emptied, and generated again. So a walk of ten thousand blocks
## holds exactly as many chunks as standing still does, which is the property
## `slideWorld` exists to make true and the test asserts by counting.
##
## **The far window** is the horizon: a square of `LodScene` regions centred on
## a region, each drawn at the level its ring earns. It moves a whole region at
## a time, and when it does, every region that keeps its level *keeps its
## heightmap and keeps its meshes*, because a region is named by where it is in
## the world rather than by where it is in the array. Walking one region east
## therefore costs the far side almost nothing: the regions that change are the
## ones that crossed a level boundary, and those are the only ones re-sampled
## and the only ones that pop.
##
## They cannot be one window. The near one has to move every sixteen blocks or
## the player walks off it; the far one must not move every sixteen blocks,
## because a region grid that shifts by anything that is not a whole region
## renames every cell in every region and re-meshes the entire horizon. Sixteen
## and forty-eight are the two rates, and the thing that lets them disagree is
## `nearCovers`: the horizon simply does not draw the cells the real blocks are
## standing on, whatever those happen to be this frame.
##
## ## Hysteresis, and what it is for
##
## Both windows move on a *threshold with a dead band*, never on a bare
## comparison. A bare comparison is correct and unusable: a player standing on a
## boundary and swaying half a block - which is what walking into a wall looks
## like - crosses it every frame, and every crossing here is a column of chunks
## regenerated or a ring of regions re-sampled. `NearSlack` and `LodSlack` are
## how far past the line you have to be before the line moves, and the test
## proves the dead band by oscillating inside it and counting zero moves, then
## removing it and counting one per step.
##
## The size of `NearSlack` is not free. The near window is `spanX * 16` blocks
## wide and the player must stay inside it, so the slack has to be comfortably
## under half of that; twelve blocks against a half-width of twenty-four leaves
## the player never more than about thirteen blocks off centre and gives a dead
## band of nine blocks. `LodSlack` has no such ceiling - the horizon is six
## hundred blocks wide - so it is set by taste instead: eight blocks, enough
## that a doorway on a region boundary does not re-sample the sky.

import vxblocks
import vxworld
import vxlod

const
  NearSlack* = 12
    ## How far past the middle of the near window the player gets before it
    ## slides a chunk after them. See the note above on why this cannot simply
    ## be larger: the window is only `spanX * ChunkSize` wide and the player has
    ## to stay well inside it. The dead band this actually buys is
    ## `2 * NearSlack - ChunkSize` blocks - nine, with these numbers - which is
    ## the distance a player has to walk *back* before the window follows them
    ## back.
  LodSlack* = 8
    ## And how far outside the middle region the player gets before the horizon
    ## re-centres on the one they are actually in.

type
  LodKey* = object
    ## A region named by where it is in the world rather than by where it is in
    ## the array, which is what lets a re-centred scene keep the meshes it
    ## already has. Every mesh the horizon has spawned is filed under one of
    ## these; when a region changes level or leaves the square, its key comes
    ## back from `retargetLod` and its meshes go.
    rx*, rz*: int

# ---------------------------------------------------------------------------
# The near window
#
# A ring buffer, so the count of chunks is a constant and the cost of a slide is
# the column that changed rather than the world.

## Where the near window would sit if it were centred on this position exactly.
## In chunks, and it is the *origin* rather than the middle: the window runs
## `span` chunks from here.
proc centredOrigin*(span, p: int): int =
  floorDiv(p, ChunkSize) - (span div 2)

## Where the near window should start, given where it is now and where the
## player is. One chunk at a time and only once the player is `slack` blocks off
## the middle: the dead band is what stops a player standing on the line
## regenerating a column of chunks every frame.
##
## One chunk at a time rather than jumping straight to `centredOrigin` because a
## slide is paid for in generation, and a player who has moved four chunks in
## one frame has been teleported - `recentreWorld` is that case, and it throws
## the window away rather than sliding it four times.
proc nextOriginX*(w: World; px: int; slack = NearSlack): int =
  let middle = w.worldX0() + w.blocksWide() div 2
  if px - middle > slack: return w.originCx + 1
  if middle - px > slack: return w.originCx - 1
  w.originCx

proc nextOriginZ*(w: World; pz: int; slack = NearSlack): int =
  let middle = w.worldZ0() + w.blocksDeep() div 2
  if pz - middle > slack: return w.originCz + 1
  if middle - pz > slack: return w.originCz - 1
  w.originCz

## Whether the player is inside the near window at all, which is the guarantee
## every other shortcut in the voxel mod is built on: the real blocks are under
## the player's feet, the ray they aim with hits chunks, and the horizon never
## has to draw the ground they are standing on. Asserted over a whole walk.
proc holdsColumn*(w: World; px, pz: int): bool =
  px >= w.worldX0() and pz >= w.worldZ0() and
    px < w.worldX0() + w.blocksWide() and pz < w.worldZ0() + w.blocksDeep()

## Slide the near window to a new chunk origin, and answer which slots have to
## be generated again - which is exactly which meshes the caller has to take
## away first.
##
## Nothing is allocated and nothing is freed except the blocks of the columns
## that fell off: a slot outside the new window is renamed to the column that
## wrapped onto it, emptied, and marked ungenerated. `chunkIndex` does the same
## wrap when it is asked for a chunk, so the two agree by construction rather
## than by being kept in step.
##
## The remembered ground heights have to be forgotten for the columns that
## arrived, and that is not tidiness: `heightSlot` wraps too, so the slot an
## arriving column reads is the slot a departed column wrote, and a column that
## kept the old answer would generate terrain from another place - a cliff of
## unrelated ground at the seam, deterministic and wrong. The test breaks
## exactly this line to show it.
proc slideWorld*(w: var World; toCx, toCz: int): seq[int] =
  result = @[]
  if toCx == w.originCx and toCz == w.originCz: return result
  let fromCx = w.originCx
  let fromCz = w.originCz
  w.originCx = toCx
  w.originCz = toCz

  var i = 0
  while i < w.chunks.len:
    let cx = w.chunks[i].cx
    let cz = w.chunks[i].cz
    if cx < toCx or cx >= toCx + w.spanX or cz < toCz or cz >= toCz + w.spanZ:
      w.chunks[i].cx = toCx + floorMod(cx - toCx, w.spanX)
      w.chunks[i].cz = toCz + floorMod(cz - toCz, w.spanZ)
      # The blocks go back to the allocator rather than being kept for a column
      # that no longer exists. A walk exercises this thousands of times where a
      # fixed world exercised it never.
      w.chunks[i].blocks = @[]
      w.chunks[i].generated = false
      w.chunks[i].filled = 0
      w.chunks[i].sealed = false
      w.chunks[i].dirtyMask = 0
      result.add i
    inc i

  # And the columns that are new to the window forget what the columns that
  # used to own their slots remembered.
  let oldX0 = fromCx * ChunkSize
  let oldZ0 = fromCz * ChunkSize
  let oldX1 = oldX0 + w.blocksWide()
  let oldZ1 = oldZ0 + w.blocksDeep()
  var z = w.worldZ0()
  while z < w.worldZ0() + w.blocksDeep():
    var x = w.worldX0()
    while x < w.worldX0() + w.blocksWide():
      if x < oldX0 or x >= oldX1 or z < oldZ0 or z >= oldZ1:
        let slot = w.heightSlot(x, z)
        if slot >= 0: w.heights[slot] = -1
      inc x
    inc z

## The window put somewhere it has no overlap with - a teleport, a new seed.
## Everything is forgotten, because nothing that is there is about the place it
## is now.
proc recentreWorld*(w: var World; toCx, toCz: int): seq[int] =
  result = @[]
  w.originCx = toCx
  w.originCz = toCz
  var i = 0
  while i < w.chunks.len:
    w.chunks[i].cx = toCx + floorMod(w.chunks[i].cx - toCx, w.spanX)
    w.chunks[i].cz = toCz + floorMod(w.chunks[i].cz - toCz, w.spanZ)
    w.chunks[i].blocks = @[]
    w.chunks[i].generated = false
    w.chunks[i].filled = 0
    w.chunks[i].sealed = false
    w.chunks[i].dirtyMask = 0
    result.add i
    inc i
  var s = 0
  while s < w.heights.len:
    w.heights[s] = -1
    inc s

# ---------------------------------------------------------------------------
# The far window

## Which region the horizon should be centred on, given where it is centred now
## and where the player is. The same dead band as the near window and for the
## same reason, but the thing it is protecting is much dearer: re-centring the
## horizon re-samples every region that changed level, and a player pacing
## across a region boundary would pay for that every step.
proc nextCentre*(cur, p: int; slack = LodSlack): int =
  if p < cur * LodRegion - slack: return floorDiv(p, LodRegion)
  if p >= (cur + 1) * LodRegion + slack: return floorDiv(p, LodRegion)
  cur

proc holdsKey*(keys: seq[LodKey]; rx, rz: int): bool =
  var i = 0
  while i < keys.len:
    if keys[i].rx == rx and keys[i].rz == rz: return true
    inc i
  false

## Move the horizon onto a new centre, keeping everything that is still true.
##
## A region is named by `rx, rz` in the world, so the question for each slot of
## the new square is only "was this region in the old square, and is it drawn at
## the same level now?". If it was, its heightmap moves across untouched - the
## same cells, of the same columns, at the same resolution - and so does its
## count of handed-over bands, which means its meshes are still exactly right
## and are not touched either. Walking a region east therefore costs the horizon
## the regions that changed level and nothing else.
##
## What comes back is every region whose geometry on screen is now wrong and
## has to be taken away: the ones that changed level, the ones that left the
## square, **and the neighbours of the ones that changed level**. That last set
## is not defensive. A region's walls are dropped to the lowest ground across
## the edge - `seamFloor` - so a neighbour changing resolution changes what this
## region owes at the boundary even though nothing about this region moved. Miss
## them and the seam that `Tests/voxel_test.exe` proves hole-free at build time
## opens up at run time, on exactly the boundary that just moved.
##
## `done` is the caller's count of bands handed over per region and is permuted
## with the fields, because the two are indexed the same way and a scene whose
## bands belong to the wrong regions draws the horizon twice in one place and
## not at all in another.
proc retargetLod*(s: var LodScene; done: var seq[int]; cRx, cRz: int;
                  nearLevel = 0): seq[LodKey] =
  result = @[]
  if cRx == s.centreRx and cRz == s.centreRz: return result
  let radius = (s.wide - 1) div 2
  let minRx = cRx - radius
  let minRz = cRz - radius

  var fields: seq[LodField] = @[]
  var doneNext: seq[int] = @[]
  var changed: seq[LodKey] = @[]

  var rz = minRz
  while rz <= cRz + radius:
    var rx = minRx
    while rx <= cRx + radius:
      let level = levelForRegion(cRx, cRz, rx, rz, nearLevel)
      var span = 0
      if level > 0: span = LodRegion div lodStride(level)
      let old = s.slotAt(rx, rz)
      if old >= 0 and s.fields[old].level == level:
        # The same ground, at the same resolution, sampled out of the same
        # columns. Nothing to do to it at all.
        fields.add s.fields[old]
        doneNext.add done[old]
      else:
        if old >= 0 and s.fields[old].span > 0 and done[old] > 0:
          changed.add LodKey(rx: rx, rz: rz)
        var f = LodField(rx: rx, rz: rz, level: level, span: span, height: @[],
          kind: @[], rows: 0)
        var c = 0
        while c < span * span:
          f.height.add -1
          f.kind.add AirId
          inc c
        fields.add f
        doneNext.add 0
      inc rx
    inc rz

  # Regions that walked out of the square entirely.
  var i = 0
  while i < s.fields.len:
    let rx = s.fields[i].rx
    let rz = s.fields[i].rz
    if rx < minRx or rx > cRx + radius or rz < minRz or rz > cRz + radius:
      if s.fields[i].span > 0 and done[i] > 0:
        changed.add LodKey(rx: rx, rz: rz)
    inc i

  s.fields = fields
  s.minRx = minRx
  s.minRz = minRz
  s.centreRx = cRx
  s.centreRz = cRz
  done = doneNext

  # The seam: a region beside one that changed level has to draw its walls
  # again, even though its own heights did not move.
  result = changed
  var k = 0
  while k < changed.len:
    var d = 0
    while d < 4:
      var nx = changed[k].rx
      var nz = changed[k].rz
      if d == 0: inc nx
      elif d == 1: dec nx
      elif d == 2: inc nz
      else: dec nz
      if not holdsKey(result, nx, nz):
        let at = s.slotAt(nx, nz)
        if at >= 0 and s.fields[at].span > 0 and done[at] > 0:
          result.add LodKey(rx: nx, rz: nz)
          done[at] = 0
      inc d
    inc k

  s.reorderLod()

## Which regions have to draw themselves again because the real blocks moved
## under them. The near window covers whatever cells it covers - `nearCovers` -
## so a window that slid has uncovered ground in one region and covered it in
## another, and both of those were meshed on the old answer. The box handed in
## is the union of where the near window was and where it is now, grown by a
## block so that the regions merely *stitching* to it are caught as well.
proc lodTouchedByNear*(s: LodScene; x0, z0, x1, z1: int): seq[LodKey] =
  result = @[]
  var i = 0
  while i < s.fields.len:
    if s.fields[i].span > 0:
      let rx0 = s.fields[i].rx * LodRegion
      let rz0 = s.fields[i].rz * LodRegion
      if rx0 <= x1 and rx0 + LodRegion >= x0 and
         rz0 <= z1 and rz0 + LodRegion >= z0:
        result.add LodKey(rx: s.fields[i].rx, rz: s.fields[i].rz)
    inc i
