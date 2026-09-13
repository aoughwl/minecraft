## The world: chunks, the terrain that fills them, and the mesh that comes out.
##
## Not one host call in this file either. Everything the player can see is
## decided here and handed to `main.nim` as numbers, which is what lets
## `Tests/voxel_test.exe` assert that a face is wound the right way round and
## that no interior face is ever emitted - two things that are otherwise settled
## by squinting at a play session.
##
## ## The three rules that matter
##
## **A chunk is 16x16x16 and the world is a box of them.** A column would be
## 16x256x16, which is Minecraft's shape and wrong for this host: a chunk is one
## mesh, a mesh is one `spawnPart`, and rebuilding a column because somebody
## broke one block at the top would re-cross the boundary for two hundred and
## fifty six blocks' worth of faces. The cube keeps a rebuild to what changed.
##
## **A face is emitted only when the block beyond it is see-through.** That is
## the whole of the interior cull, and it reaches across a chunk boundary by
## asking the world rather than the chunk, so two chunks side by side do not
## draw the wall between them.
##
## **A chunk is meshed once per block kind in it.** The host gives a mesh one
## material and one colour, so a chunk of grass and stone is two meshes: the
## alternative is a texture atlas and per-face uv remapping, which this mod does
## not have yet and which `aoughwl.minecraft` already knows how to build.

import vxblocks
import vxnoise
import vxray
import vxatlas

const
  ChunkSize* = 16
  ChunkArea* = ChunkSize * ChunkSize
  ChunkVolume* = ChunkArea * ChunkSize
  SliceHeight* = 4
    ## A chunk is meshed in horizontal bands this tall, and a band is its own
    ## mesh. Breaking one block therefore hands over a quarter of a chunk rather
    ## than all of it.
    ##
    ## The number is a measured trade and not a taste. A whole 16x16x16 chunk is
    ## about 89ms - 20ms of walking it, 51ms of crossings, 18ms of Unity - which
    ## is five dropped frames every time somebody digs. Four bands is about 22ms
    ## and four times as many mesh objects; sixteen would be 6ms and sixteen
    ## times as many. Four is where the two curves crossed.
  SliceCount* = ChunkSize div SliceHeight

type
  Chunk* = object
    cx*, cy*, cz*: int
    blocks*: seq[int]
    generated*: bool
    dirtyMask*: int
      ## One bit per slice: set means that band of this chunk has to be meshed
      ## again. A whole-chunk rebuild is every bit; a broken block is one, or
      ## two when it was against the seam between two bands.
    filled*: int
      ## How many of its blocks are not air. A chunk with none has no mesh at
      ## all, which is most of a world made of sky.
    sealed*: bool
      ## Every one of its blocks hides what is behind it. A sealed chunk whose
      ## six neighbours are all sealed can show nothing at all, and is skipped
      ## without being walked - which is most of a world made of rock.
    top*: int
      ## The highest of its own rows that can hold anything, local to the
      ## chunk; -1 when it holds nothing at all. Every row above it is air,
      ## because generation knows the highest ground and the highest water in
      ## the chunk's own columns before it lays a single block down.
      ##
      ## What it buys is bands that are never meshed. A band of pure air emits
      ## nothing - a face belongs to the solid block that owns it, and the
      ## block below the band is in the band below - so walking one is six
      ## sixteen-by-sixteen masks built, found empty and thrown away. The
      ## chunks this saves are the ones straddling the surface, which is most
      ## of the ones a slide brings in.

  Palette* = object
    ## The block numbers the generator lays down. They are fields rather than
    ## names looked up here, so a game that registers `mars.regolith` instead of
    ## `dirt` gets the same terrain out of the same generator.
    stone*, dirt*, grass*, sand*, water*, bedrock*, wood*, leaves*: int

  World* = object
    seed*: int
    spanX*, spanY*, spanZ*: int
      ## The size of the world in chunks - how many are held, never where they
      ## are. Where they are is `originCx`/`originCz`.
    originCx*, originCz*: int
      ## Which chunk the near window starts at. Zero is the world this mod
      ## shipped with, whose blocks ran 0 .. span*16-1; a window that follows
      ## the player has an origin that moves, and its blocks run
      ## `originCx*16 .. originCx*16 + span*16 - 1`.
      ##
      ## The chunks behind it are a **ring buffer**: `chunkIndex` wraps, so a
      ## window that has slid a thousand chunks east holds exactly as many
      ## chunks as one that has never moved, in the same slots. Nothing else in
      ## this file knows that, because everything else asks `chunkIndex` for a
      ## chunk by where it is in the world. See `vxstream.slideWorld`.
    waterLevel*: int
    caves*: bool
    sealSides*: bool
      ## Whether the four vertical walls of the near window are a lid rather
      ## than a cliff face.
      ##
      ## A chunk on the edge of the window looks sideways at nothing, reads it
      ## as air, and draws its whole 16x16 wall - and *every* column of a window
      ## three chunks across is an edge column, so those walls are a large part
      ## of everything the mesher emits. Nobody ever sees one: the horizon draws
      ## the ground beyond the window (`nearCovers` is exactly the cells the
      ## window does *not* cover), and it stitches its edge down to the ground
      ## across the join, so the volume immediately outside the window is
      ## already solid on screen. The near wall is inside it.
      ##
      ## So with this on, a sideways look that leaves the window is *hidden*
      ## rather than air. The world's floor and ceiling are not affected - up
      ## and down leave the world for a different reason and there is no horizon
      ## under the map - and neither is anything inside the window, which is why
      ## a slide still re-meshes the column that gained a neighbour: the face
      ## against a real chunk is a real face again the moment there is a real
      ## chunk there.
      ##
      ## Off by default, because a world that is not a window - the fixed world
      ## every existing test builds - has no horizon behind it and its walls are
      ## the only thing there is.
    palette*: Palette
    chunks*: seq[Chunk]
    heights*: seq[int]
      ## The ground height of every column, worked out once. A world four
      ## chunks tall asks for the same column four times otherwise, and the
      ## noise behind it is the most expensive thing in generation. Empty until
      ## the first ask; -1 means "not yet".

  Faces* = object
    ## A chunk's geometry, in chunk-local coordinates, ready to be read out one
    ## crossing at a time. Four corners and eight texture coordinates per face,
    ## one normal per face.
    count*: int
    pos*: seq[float]
    norm*: seq[float]
    uv*: seq[float]
    ao*: seq[float]
      ## The shading multiplier at each of a face's four corners, in the same
      ## corner order `pos` and `uv` use. One number rather than three, because
      ## ambient occlusion darkens without tinting: the host is handed
      ## `(s, s, s, 1)`. A flat-lit walk fills this with ones, which multiplies
      ## into whatever the material wears and changes nothing.
    kind*: seq[int]
      ## Which block each face belongs to. One walk of a chunk produces every
      ## face in it; the mesh for one kind is that walk read back with the rest
      ## skipped.

# ---------------------------------------------------------------------------
# The six faces
#
# Corner order is the right-handed one the host asks for: (b-a) x (c-a) points
# along the face's outward normal, so the face is solid from outside and
# invisible from within. `voxel_test` recomputes that cross product for all six
# rather than trusting this comment.

const
  FaceNormal*: array[6, array[3, int]] = [
    [1, 0, 0], [-1, 0, 0], [0, 1, 0], [0, -1, 0], [0, 0, 1], [0, 0, -1]]
  FaceCorner*: array[6, array[12, int]] = [
    # +X
    [1, 0, 0,  1, 1, 0,  1, 1, 1,  1, 0, 1],
    # -X
    [0, 0, 0,  0, 0, 1,  0, 1, 1,  0, 1, 0],
    # +Y
    [0, 1, 0,  0, 1, 1,  1, 1, 1,  1, 1, 0],
    # -Y
    [0, 0, 0,  1, 0, 0,  1, 0, 1,  0, 0, 1],
    # +Z
    [0, 0, 1,  1, 0, 1,  1, 1, 1,  0, 1, 1],
    # -Z
    [0, 0, 0,  0, 1, 0,  1, 1, 0,  1, 0, 0]]
  FaceUv*: array[6, array[8, float]] = [
    # A texture coordinate per corner, per face, and it has to be per face:
    # `v` must run *up the world* on the four sides, or a grass block wears its
    # band of green down one edge instead of along its top. The corner orders
    # above are wound for the outward normal and are not free to be reordered,
    # so the uvs follow them rather than the other way round.
    #
    # +X and -X: u is z, v is y.
    [0.0, 0.0,  0.0, 1.0,  1.0, 1.0,  1.0, 0.0],
    [0.0, 0.0,  1.0, 0.0,  1.0, 1.0,  0.0, 1.0],
    # +Y and -Y: there is no up, so u is x and v is z.
    [0.0, 0.0,  0.0, 1.0,  1.0, 1.0,  1.0, 0.0],
    [0.0, 0.0,  1.0, 0.0,  1.0, 1.0,  0.0, 1.0],
    # +Z and -Z: u is x, v is y.
    [0.0, 0.0,  1.0, 0.0,  1.0, 1.0,  0.0, 1.0],
    [0.0, 0.0,  0.0, 1.0,  1.0, 1.0,  1.0, 0.0]]

const
  FaceAxis*: array[6, int] = [0, 0, 1, 1, 2, 2]
    ## Which axis a face's normal runs along: 0 is x, 1 is y, 2 is z.
  FaceUAxis*: array[6, int] = [2, 2, 0, 0, 0, 0]
    ## Which axis the face's `u` runs along, and which its `v`. These are not a
    ## second opinion about `FaceUv`: they are the same statement said as axis
    ## numbers, so that a merged quad can be grown along them and know which of
    ## its two extents belongs to which texture coordinate. `voxel_test`
    ## re-derives both out of `FaceCorner` and `FaceUv` rather than reading them
    ## here, so the three cannot drift apart.
  FaceVAxis*: array[6, int] = [1, 1, 2, 2, 1, 1]

## Which face points that way, or -1. Used to turn the normal a ray came in by
## back into a face number.
proc faceOfNormal*(nx, ny, nz: int): int =
  var f = 0
  while f < 6:
    if FaceNormal[f][0] == nx and FaceNormal[f][1] == ny and
       FaceNormal[f][2] == nz: return f
    inc f
  -1

# ---------------------------------------------------------------------------
# Indexing

proc localIndex*(x, y, z: int): int = (y * ChunkSize + z) * ChunkSize + x

# ---- slices ----------------------------------------------------------------

proc sliceOf*(ly: int): int =
  ## Which band a local height is in. Clamped, because a caller reaching one
  ## above the top of a chunk means the bottom band of the one above.
  if ly < 0: return 0
  if ly >= ChunkSize: return SliceCount - 1
  ly div SliceHeight

proc wholeChunk*(): int = (1 shl SliceCount) - 1

## Every band of this chunk that could show a face - which is every band up to
## and including the one holding its highest possible block, and none above it.
## `wholeChunk()` for a chunk full to the ceiling, zero for one that is all sky.
proc filledBands*(c: Chunk): int =
  if c.top < 0: return 0
  var mask = 0
  var s = 0
  while s < SliceCount:
    if s * SliceHeight <= c.top: mask = mask or (1 shl s)
    inc s
  mask
proc sliceBit*(slice: int): int = 1 shl slice
proc needsMesh*(c: Chunk): bool = c.dirtyMask != 0
proc sliceNeedsMesh*(c: Chunk; slice: int): bool =
  (c.dirtyMask and sliceBit(slice)) != 0
proc firstDirtySlice*(c: Chunk): int =
  var s = 0
  while s < SliceCount:
    if c.sliceNeedsMesh(s): return s
    inc s
  -1

proc floorDiv*(a, b: int): int =
  ## Floor division, so a block at -1 is in chunk -1 rather than chunk 0. The
  ## world box starts at zero, but a ray leaving it does not, and a traversal
  ## that folded -1 onto 0 would report the far wall as the near one.
  var q = a div b
  if (a mod b) != 0 and ((a < 0) != (b < 0)): dec q
  q

proc floorMod*(a, b: int): int =
  var m = a mod b
  if m != 0 and ((m < 0) != (b < 0)): m = m + b
  m

proc chunkCount*(w: World): int = w.spanX * w.spanY * w.spanZ

## Which slot holds a chunk, by where that chunk is in the world - or -1 when
## the window is not over it.
##
## The horizontal wrap is what makes the window a ring buffer: two chunks
## `spanX` apart share a slot, and only one of them is ever inside the window,
## so the sharing is never observable. A window at the origin is exactly the
## world this mod shipped with, which is why every existing assertion about
## chunk indexing still holds without a word changed.
proc chunkIndex*(w: World; cx, cy, cz: int): int =
  if cy < 0 or cy >= w.spanY: return -1
  if cx < w.originCx or cx >= w.originCx + w.spanX: return -1
  if cz < w.originCz or cz >= w.originCz + w.spanZ: return -1
  (cy * w.spanZ + floorMod(cz, w.spanZ)) * w.spanX + floorMod(cx, w.spanX)

proc chunkOf*(w: World; x, y, z: int): int =
  w.chunkIndex(floorDiv(x, ChunkSize), floorDiv(y, ChunkSize),
    floorDiv(z, ChunkSize))

proc blocksWide*(w: World): int = w.spanX * ChunkSize
proc blocksHigh*(w: World): int = w.spanY * ChunkSize
proc blocksDeep*(w: World): int = w.spanZ * ChunkSize

proc worldX0*(w: World): int = w.originCx * ChunkSize
proc worldZ0*(w: World): int = w.originCz * ChunkSize

## Whether face `f` of this chunk is one of the window's own outward faces, and
## therefore something nobody can see. See `World.sealSides`.
##
## The four sides, and the underside. The sides are covered by the horizon; the
## underside is the bottom of the bedrock, which is only visible from below a
## world you cannot get below. The **top** is not sealed and must not be: there
## is nothing above the world to draw over it, and a mountain that reached the
## ceiling would lose its summit.
##
## Asked once per chunk per direction - six times for a whole chunk - rather
## than once per block, which is why it is allowed to be a call at all.
proc sealedSide*(w: World; index, f: int): bool =
  if not w.sealSides: return false
  if FaceNormal[f][1] > 0: return false
  if FaceNormal[f][1] < 0: return w.chunks[index].cy == 0
  w.chunkIndex(w.chunks[index].cx + FaceNormal[f][0], w.chunks[index].cy,
    w.chunks[index].cz + FaceNormal[f][2]) < 0

proc inWorld*(w: World; x, y, z: int): bool =
  x >= w.worldX0() and z >= w.worldZ0() and y >= 0 and
    x < w.worldX0() + w.blocksWide() and
    y < w.blocksHigh() and z < w.worldZ0() + w.blocksDeep()

## Where a column's remembered ground lives, or -1 when the window is not over
## that column. The same wrap `chunkIndex` does and for the same reason, and it
## is one proc rather than the arithmetic written out in three places because
## the three places disagreeing is how a column ends up generated out of another
## column's noise.
proc heightSlot*(w: World; x, z: int): int =
  if x < w.worldX0() or z < w.worldZ0(): return -1
  if x >= w.worldX0() + w.blocksWide(): return -1
  if z >= w.worldZ0() + w.blocksDeep(): return -1
  floorMod(z, w.blocksDeep()) * w.blocksWide() + floorMod(x, w.blocksWide())

## The block at a world coordinate. Everything outside the world is air, which
## is what makes a traversal that leaves the world stop rather than fault.
## A chunk holding no blocks at all reads as air, and that is two different
## chunks answering the same way on purpose: one not generated yet, and one
## generated and found to be nothing but sky. See `generateChunk`.
proc blockAt*(w: World; x, y, z: int): int =
  let c = w.chunkOf(x, y, z)
  if c < 0: return AirId
  if w.chunks[c].blocks.len == 0: return AirId
  w.chunks[c].blocks[localIndex(floorMod(x, ChunkSize), floorMod(y, ChunkSize),
    floorMod(z, ChunkSize))]

## Put a block somewhere and mark what has to be rebuilt: this chunk, and any
## neighbouring chunk whose own faces the change can uncover. False when the
## coordinate is outside the world or the block is already that.
proc setBlockAt*(w: var World; x, y, z: int; id: int): bool =
  let c = w.chunkOf(x, y, z)
  if c < 0: return false
  if not w.chunks[c].generated: return false
  # A chunk that was all sky holds nothing; the first block put into it is what
  # buys it its four thousand slots.
  if w.chunks[c].blocks.len == 0:
    if id == AirId: return false
    var air: seq[int] = @[]
    var n = 0
    while n < ChunkVolume:
      air.add AirId
      inc n
    w.chunks[c].blocks = air
  let lx = floorMod(x, ChunkSize)
  let ly = floorMod(y, ChunkSize)
  let lz = floorMod(z, ChunkSize)
  let at = localIndex(lx, ly, lz)
  let was = w.chunks[c].blocks[at]
  if was == id: return false
  w.chunks[c].blocks[at] = id
  if was == AirId and id != AirId: w.chunks[c].filled = w.chunks[c].filled + 1
  elif was != AirId and id == AirId: w.chunks[c].filled = w.chunks[c].filled - 1
  # A chunk somebody has dug into is no longer trusted to be sealed. Working
  # out whether it has become sealed again would mean walking it, which is the
  # walk the flag exists to avoid, and a chunk wrongly called unsealed only
  # costs one mesh.
  w.chunks[c].sealed = false
  # A block put down above where generation said anything could be raises the
  # chunk's air line with it, or the band it landed in would never be meshed.
  if id != AirId and ly > w.chunks[c].top: w.chunks[c].top = ly
  w.chunks[c].dirtyMask = w.chunks[c].dirtyMask or sliceBit(sliceOf(ly))
  # Every one of the six neighbours may just have had a face uncovered, and the
  # band that has to be re-meshed is the band *that neighbour* is in - which is
  # sometimes another chunk, sometimes the band above or below inside this one,
  # and asked the same way in both cases. Getting this wrong is a hole in the
  # world with a wall you can see through behind it.
  var f = 0
  while f < 6:
    let nx = x + FaceNormal[f][0]
    let ny = y + FaceNormal[f][1]
    let nz = z + FaceNormal[f][2]
    let other = w.chunkOf(nx, ny, nz)
    if other >= 0:
      w.chunks[other].dirtyMask = w.chunks[other].dirtyMask or
        sliceBit(sliceOf(floorMod(ny, ChunkSize)))
    inc f
  true

# ---------------------------------------------------------------------------
# Making one

proc newWorld*(seed, spanX, spanY, spanZ: int; palette: Palette;
               waterLevel = 30; caves = true; sealSides = false): World =
  result = World(seed: seed, spanX: spanX, spanY: spanY, spanZ: spanZ,
    waterLevel: waterLevel, caves: caves, sealSides: sealSides,
    palette: palette, chunks: @[], heights: @[])
  var column = 0
  while column < spanX * spanZ * ChunkArea:
    result.heights.add(-1)
    inc column
  var cy = 0
  while cy < spanY:
    var cz = 0
    while cz < spanZ:
      var cx = 0
      while cx < spanX:
        result.chunks.add Chunk(cx: cx, cy: cy, cz: cz, blocks: @[],
          generated: false, dirtyMask: 0, filled: 0, sealed: false, top: -1)
        inc cx
      inc cz
    inc cy

# ---------------------------------------------------------------------------
# What the land looks like

## The height of the ground at a column, in blocks. Two fields of noise: broad
## hills everywhere, and a ridge field on a much longer wavelength that puts a
## range of mountains through part of the map instead of a field of identical
## lumps.
proc surfaceHeight*(w: World; x, z: int): int =
  let fx = float(x)
  let fz = float(z)
  # The flat spellings, and the reason is that this is the hottest line in the
  # mod: the readable `fbm2`/`ridged2`/`valueNoise2` are about a hundred and
  # twenty interpreted calls between them, and these three are three. They are
  # the *same* arithmetic in the same order - `Tests/voxel_test.nim` asserts
  # every one of these three lines is bit-identical to the layered spelling
  # over thousands of columns, so this stays honest or the build goes red.
  # `fbm2Flat(.., 1)` is `valueNoise2`: one octave weighs 1.0 at frequency 1.0
  # and is divided by 1.0 again, which is exact.
  let hills = fbm2Flat(w.seed, fx * 0.021, fz * 0.021, 4)
  let mountains = ridged2Flat(w.seed + 7777, fx * 0.0065, fz * 0.0065, 3)
  let plateau = fbm2Flat(w.seed + 313, fx * 0.004, fz * 0.004, 1)
  # Everything is a fraction of how tall the world is, so a small world is the
  # same landscape at a smaller scale rather than the same landscape with its
  # mountains cut off flat against the ceiling.
  let ceiling = float(w.blocksHigh())
  let height = ceiling * 0.35 + hills * ceiling * 0.2 +
    mountains * ceiling * 0.35 * plateau
  var h = floorInt(height)
  if h < 1: h = 1
  if h > w.blocksHigh() - 3: h = w.blocksHigh() - 3
  h

## The same, remembered. `surfaceHeight` stays a plain function of the seed and
## the place - that is the property the test asserts - and this is the one
## generation actually calls, so a column four chunks tall costs one evaluation
## rather than four.
proc groundAt*(w: var World; x, z: int): int =
  let slot = w.heightSlot(x, z)
  if slot < 0: return w.surfaceHeight(x, z)
  if w.heights[slot] >= 0: return w.heights[slot]
  let h = w.surfaceHeight(x, z)
  w.heights[slot] = h
  h

## Whether the rock at this place was eaten away. Kept off near the surface, so
## a cave never opens the ground out from under the player's feet the moment
## they spawn, and off near bedrock so the floor of the world stays a floor.
##
## One octave, not four, and that is a budget rather than a taste: this is the
## only thing in generation asked once per *block* rather than once per column,
## and every octave is eight more hashes on every block of stone in the world.
## In the interpreter that is the difference between a chunk arriving inside a
## frame and a chunk arriving inside a second.
proc isCave*(w: World; x, y, z: int; surface: int): bool =
  if not w.caves: return false
  if y < 3 or y > surface - 3: return false
  valueNoise3(w.seed + 31, float(x) * 0.062, float(y) * 0.1, float(z) * 0.062) > 0.66

## One block of terrain, as a pure function of the seed and the place. Nothing
## in it reads the chunk it is going into, which is what makes a chunk
## generated on its own identical to the same chunk generated beside its
## neighbours.
proc terrainAt*(w: World; x, y, z: int; surface: int): int =
  if y == 0: return w.palette.bedrock
  if y > surface:
    if y <= w.waterLevel: return w.palette.water
    return AirId
  if w.isCave(x, y, z, surface): return AirId
  if y == surface:
    if surface <= w.waterLevel + 1: return w.palette.sand
    return w.palette.grass
  if y > surface - 4:
    if surface <= w.waterLevel + 1: return w.palette.sand
    return w.palette.dirt
  w.palette.stone

## Fill one chunk in. Heights are computed once per column rather than once per
## block, which is the difference between 256 noise evaluations and 4096.
##
## The inner loop is `terrainAt` written out rather than called, and that is the
## same trade the mesher already made with `isOpaque`: four thousand blocks
## times four interpreted calls - `terrainAt`, `isCave`, `localIndex`,
## `isOpaque` - is 34,000 calls at 2.1 microseconds each, which is most of what
## a chunk costs and none of what a chunk is. `terrainAt` stays exactly where it
## was, it is still the definition of what a block is made of, and
## `Tests/voxel_test.nim` asserts a generated chunk agrees with it block for
## block. If you change one, change both.
##
## The blocks are appended in the order `localIndex` numbers them - y, then z,
## then x - so there is no prefill pass and no index arithmetic per block, and a
## row of sky above the highest ground in the chunk is filled a row at a time
## without asking anything about it.
proc generateChunk*(w: var World; r: Registry; index: int) =
  if index < 0 or index >= w.chunks.len: return
  if w.chunks[index].generated: return
  let baseX = w.chunks[index].cx * ChunkSize
  let baseY = w.chunks[index].cy * ChunkSize
  let baseZ = w.chunks[index].cz * ChunkSize

  # The columns first, once. `groundAt` remembers them for the five other
  # chunks stacked over this one, so this is the only place the noise is paid
  # for and only the first chunk of a stack pays it.
  var surf: seq[int] = @[]
  var topMax = -1
  var surfMin = 1 shl 30
  var lz = 0
  while lz < ChunkSize:
    var lx = 0
    while lx < ChunkSize:
      let s = w.groundAt(baseX + lx, baseZ + lz)
      surf.add s
      if s < surfMin: surfMin = s
      var top = s
      if w.waterLevel > top: top = w.waterLevel
      if top > topMax: topMax = top
      inc lx
    inc lz

  # Sky. A chunk entirely above the highest ground and the highest water in its
  # own columns is four thousand blocks of air, and the cheapest way to write
  # four thousand of the same number down is not to.
  #
  # Measured on this landscape: the top layer of a six-chunk window is air in
  # every one of its chunks at every window position sampled, and the layer
  # below it in more than half of them - a quarter of the near window is sky,
  # and it was costing a full chunk's worth of appends each.
  #
  # An empty chunk reads as air through `blockAt` exactly as an ungenerated one
  # does, which is also why the neighbour sweep below is skipped for it: a
  # neighbour that read this chunk as air before it arrived reads it as air
  # after, so there is nothing it could have uncovered and nothing to re-mesh.
  # `setBlockAt` gives it its slots the moment somebody builds up there.
  if baseY > topMax:
    w.chunks[index].blocks = @[]
    w.chunks[index].filled = 0
    w.chunks[index].sealed = false
    w.chunks[index].top = -1
    w.chunks[index].generated = true
    w.chunks[index].dirtyMask = 0
    return

  # Everything the inner loop reads, read once. A field of `w` is a load and a
  # `w.palette.stone` is two, four thousand times over.
  let waterLevel = w.waterLevel
  let caves = w.caves
  let caveSeed = w.seed + 31
  let bedrock = w.palette.bedrock
  let water = w.palette.water
  let sand = w.palette.sand
  let grass = w.palette.grass
  let dirt = w.palette.dirt
  let stone = w.palette.stone
  let opaqueCount0 = r.opaqueFlag.len

  var blocks: seq[int] = @[]
  var filled = 0
  var opaqueCount = 0

  # Rock, and it is the sky above read upside down: a chunk every row of which
  # is under the dirt and over the bedrock is four thousand of one number, and
  # *which* number does not depend on the column - so there is no `surf` to
  # look up and no chain of five tests to walk down. `surfMin` is the lowest
  # ground over the chunk, so `surfMin >= baseY + ChunkSize + 3` says the
  # highest row of the chunk is still four blocks under the shallowest ground
  # there is; `baseY >= 1` keeps the bedrock row out of it, and caves are the
  # one thing that would put a hole in it.
  #
  # These are the chunks under the player's feet, and there are two layers of
  # them in a six-layer window. Nothing here is ever *drawn* - a sealed chunk
  # between sealed chunks is buried - but it has to exist to be stood on and
  # dug into, and this is what it costs to exist.
  let solidRock = not w.caves and baseY >= 1 and
    surfMin >= baseY + ChunkSize + 3
  if solidRock:
    let onlyId = w.palette.stone
    var n = 0
    while n < ChunkVolume:
      blocks.add onlyId
      inc n
    filled = ChunkVolume
    if r.isOpaque(onlyId): opaqueCount = ChunkVolume

  var ly = 0
  while ly < ChunkSize and not solidRock:
    let y = baseY + ly
    # Above the highest ground and the highest water in this whole chunk there
    # is nothing but air, and sky is most of a world.
    if y > topMax:
      var n = 0
      while n < ChunkArea:
        blocks.add AirId
        inc n
      inc ly
      continue
    var cz = 0
    while cz < ChunkSize:
      var cx = 0
      while cx < ChunkSize:
        let surface = surf[cz * ChunkSize + cx]
        # `terrainAt`, inlined. The order of the tests is its order.
        var id = AirId
        if y == 0:
          id = bedrock
        elif y > surface:
          if y <= waterLevel: id = water
        elif caves and y >= 3 and y <= surface - 3 and
             valueNoise3(caveSeed, float(baseX + cx) * 0.062, float(y) * 0.1,
                         float(baseZ + cz) * 0.062) > 0.66:
          id = AirId
        elif y == surface:
          if surface <= waterLevel + 1: id = sand else: id = grass
        elif y > surface - 4:
          if surface <= waterLevel + 1: id = sand else: id = dirt
        else:
          id = stone
        blocks.add id
        if id != AirId:
          inc filled
          # `isOpaque`, inlined: the flat array it answers out of is right here.
          if id >= 0 and id < opaqueCount0 and r.opaqueFlag[id]: inc opaqueCount
        inc cx
      inc cz
    inc ly
  w.chunks[index].blocks = blocks
  w.chunks[index].filled = filled
  w.chunks[index].sealed = opaqueCount == ChunkVolume
  var top = topMax - baseY
  if top > ChunkSize - 1: top = ChunkSize - 1
  w.chunks[index].top = top
  w.chunks[index].generated = true
  # Only the bands that hold something. The rows above `top` are air and a band
  # of air draws nothing, so meshing one is a walk with no result.
  w.chunks[index].dirtyMask = filledBands(w.chunks[index])
  # A neighbour meshed while this chunk was still empty drew the wall between
  # them, because an ungenerated chunk reads as air. Now that there is something
  # there, that wall is interior and has to go. A whole chunk arriving can
  # uncover any band of the chunks beside it, so those are marked whole; the
  # ones above and below meet it on one face and lose only the band against it.
  var f = 0
  while f < 6:
    let other = w.chunkIndex(w.chunks[index].cx + FaceNormal[f][0],
      w.chunks[index].cy + FaceNormal[f][1],
      w.chunks[index].cz + FaceNormal[f][2])
    if other >= 0 and w.chunks[other].generated:
      # And the same rule the other way round: whatever this chunk may have
      # uncovered over there, it cannot have uncovered a band of that chunk
      # which holds nothing. `filledBands` is the neighbour's own air line.
      let can = filledBands(w.chunks[other])
      if FaceNormal[f][1] == 1:
        w.chunks[other].dirtyMask = w.chunks[other].dirtyMask or
          (sliceBit(0) and can)
      elif FaceNormal[f][1] == -1:
        w.chunks[other].dirtyMask = w.chunks[other].dirtyMask or
          (sliceBit(SliceCount - 1) and can)
      else:
        w.chunks[other].dirtyMask = w.chunks[other].dirtyMask or can
    inc f

## Take a chunk's blocks from somewhere that is not this generator - a server's
## chunk column, a save, a test - and leave the world in exactly the state
## `generateChunk` leaves it in.
##
## It is the tail of `generateChunk` and nothing else, which is the whole point:
## the flags a chunk carries are not decoration. `filled` decides whether it
## gets a mesh at all, `top` decides which of its four bands are walked,
## `sealed` decides whether it is skipped entirely, and the six neighbours have
## to be dirtied or the wall between this chunk and the one meshed before it
## stays drawn. A caller that set `blocks` and `generated` by hand would get a
## world that looked right until it did not.
##
## The three totals are **given** rather than counted here. Blocks arrive from a
## server as runs of equal state, and a run knows its own length, so counting
## them costs nothing there and four thousand interpreted steps here.
##
## `top` is the highest local row holding anything, or -1 for a chunk of pure
## air; `opaqueCount` is how many of its blocks hide what is behind them.
proc adoptChunk*(w: var World; index: int; blocks: seq[int];
                 filled, top, opaqueCount: int): bool =
  if index < 0 or index >= w.chunks.len: return false
  if blocks.len != 0 and blocks.len != ChunkVolume: return false
  w.chunks[index].blocks = blocks
  w.chunks[index].filled = filled
  w.chunks[index].sealed = opaqueCount == ChunkVolume
  var t = top
  if t > ChunkSize - 1: t = ChunkSize - 1
  if t < -1: t = -1
  w.chunks[index].top = t
  w.chunks[index].generated = true
  w.chunks[index].dirtyMask = filledBands(w.chunks[index])
  # Word for word the rule `generateChunk` ends with, and for its reason: a
  # neighbour meshed while this chunk was still empty drew the wall between
  # them, and that wall is interior now.
  var f = 0
  while f < 6:
    let other = w.chunkIndex(w.chunks[index].cx + FaceNormal[f][0],
      w.chunks[index].cy + FaceNormal[f][1],
      w.chunks[index].cz + FaceNormal[f][2])
    if other >= 0 and w.chunks[other].generated:
      let can = filledBands(w.chunks[other])
      if FaceNormal[f][1] == 1:
        w.chunks[other].dirtyMask = w.chunks[other].dirtyMask or
          (sliceBit(0) and can)
      elif FaceNormal[f][1] == -1:
        w.chunks[other].dirtyMask = w.chunks[other].dirtyMask or
          (sliceBit(SliceCount - 1) and can)
      else:
        w.chunks[other].dirtyMask = w.chunks[other].dirtyMask or can
    inc f
  true

proc generateAll*(w: var World; r: Registry) =
  var i = 0
  while i < w.chunks.len:
    w.generateChunk(r, i)
    inc i

# ---------------------------------------------------------------------------
# Meshing

## Whether the face of `mine` looking at `neighbour` is worth drawing. An opaque
## neighbour hides it; so does a neighbour of exactly the same kind, which is
## what stops a sea drawing a grid of faces through its own middle.
proc faceShows*(r: Registry; mine, neighbour: int): bool =
  if neighbour == AirId: return true
  if neighbour == mine: return false
  not r.isOpaque(neighbour)

proc emptyFaces*(): Faces =
  Faces(count: 0, pos: @[], norm: @[], uv: @[], ao: @[], kind: @[])

## Every visible face in one chunk, of every kind of block in it, in one walk.
##
## This is the shape the game actually calls, and the reason it exists is
## arithmetic: `buildFaces` walks all 4096 blocks once per kind, and a chunk of
## grass, dirt and stone is three walks for one chunk. The neighbour lookup is
## the other half - a block in the middle of a chunk has all six of its
## neighbours in the same array, so only the 5% on a chunk's own faces pay for
## `blockAt` and its two divisions per axis.
## Whether meshing this chunk now would be meshing it for the last time.
##
## A chunk reads an ungenerated neighbour as air, so it draws the wall between
## them, and generating that neighbour dirties it again. Meshing a chunk the
## moment it is generated therefore costs up to seven meshes per chunk rather
## than one - measured, that was most of the time a world took to appear. So a
## chunk waits until everything that can still change its faces has arrived.
## The edge of the world counts as arrived: there is nothing out there and
## there never will be.
proc meshReady*(w: World; index: int): bool =
  if index < 0 or index >= w.chunks.len: return false
  if not w.chunks[index].generated: return false
  var f = 0
  while f < 6:
    let other = w.chunkIndex(w.chunks[index].cx + FaceNormal[f][0],
      w.chunks[index].cy + FaceNormal[f][1],
      w.chunks[index].cz + FaceNormal[f][2])
    if other >= 0 and not w.chunks[other].generated: return false
    inc f
  true

proc buriedChunk*(w: World; index: int): bool =
  ## Whether nothing in this chunk could possibly be seen: every block in it
  ## hides what is behind it, and so does every block of all six neighbours.
  ## Answered in seven flags rather than in four thousand blocks, which is what
  ## makes the inside of a world free rather than the most expensive part of it.
  if not w.chunks[index].sealed: return false
  var f = 0
  while f < 6:
    let other = w.chunkIndex(w.chunks[index].cx + FaceNormal[f][0],
      w.chunks[index].cy + FaceNormal[f][1],
      w.chunks[index].cz + FaceNormal[f][2])
    # A wall of the window hides what is behind it exactly as an opaque
    # neighbour does, so the outer ring of a sealed layer is buried rather than
    # meshed - which is where most of the walls this saves were.
    if other < 0:
      if w.sealedSide(index, f):
        inc f
        continue
      return false
    if not w.chunks[other].sealed: return false
    inc f
  true

# ---------------------------------------------------------------------------
# Ambient occlusion
#
# A block world lit by one ambient term is uniformly bright everywhere, and the
# eye reads uniform brightness as flat: a doorway, an overhang and a step all
# vanish, because nothing tells you that a surface has geometry standing over
# it. The fix voxel games have used since Minecraft is per-corner ambient
# occlusion, and it is arithmetic rather than a light: a face's corner is
# darkened by how many of the THREE blocks that touch it, on the near side of
# the face, are solid.
#
# ## The three
#
# Take a face with outward normal N, and one of its four corners. The corner
# sits where the face's u axis and v axis both begin or both end, so it has a
# sign along each: su and sv, either -1 or +1. Step off the face into the open
# air at p+N and the three blocks that can shadow that corner are
#
#     side  = p + N + su*U
#     side' = p + N + sv*V
#     corner= p + N + su*U + sv*V
#
# and the corner's OCCLUSION is how many of the three are solid, except that two
# sides both solid mean the corner is boxed in whatever the diagonal does, which
# is the full three. That exception is the whole reason this is not just a sum:
# without it an inside corner is one step brighter than the flat wall beside it,
# which reads as a highlight in exactly the place that should be darkest.
#
# ## Counted as darkness rather than as light, deliberately
#
# The usual spelling of this is a level 0..3 with 3 meaning "unoccluded". Here
# it is the other way up - 0 means nothing occludes this corner - and that is
# load bearing rather than taste: a packed code of zero has to mean "no shading
# at all", because that is what a flat-lit walk produces and what makes an
# unlit merge key byte-identical to the block-id key this mesher used before
# ambient occlusion existed. Under the other convention an unlit chunk would key
# on zero and come out at the darkest shade there is.
#
# ## Solid, and which "solid"
#
# The same opaque test the face cull uses, so glass and water shadow nothing.
# One rule, asked twice, rather than two rules that could drift.
#
# ## Eight lookups, not twelve
#
# The four corners share their occluders: all nine cells of the 3x3 plane at
# p+N are read, the middle one is the block the face already knows is not
# hiding it, and the eight around it serve all four corners. So a face costs
# eight neighbour reads rather than the twelve a corner-at-a-time walk would.

const
  AoShade*: array[4, float] = [1.0, 0.8, 0.6, 0.4]
    ## What a corner occluded by 0, 1, 2 or 3 neighbours multiplies its surface
    ## by: `1.0 - 0.2 * occlusion`, so an unoccluded corner is untouched and a
    ## fully boxed-in one keeps 40%. Written out rather than computed because it
    ## is read once per corner per face.

## The four corners' occlusion counts for one face, packed two bits each in
## corner order - corner 0 in the low pair. Zero is "nothing occludes anything",
## which is what a flat-lit walk uses and what makes an unlit merge key the same
## key it always was.
##
## `lx, ly, lz` are chunk-local; `baseX, baseY, baseZ` are that chunk's origin,
## so a lookup that leaves the chunk falls through to the world.
##
## This is a proc and not eight lines inlined into each of the two meshers,
## which is the one place this file spends a call on purpose: an interpreted
## call is 2.1us, and this one is amortised over eight neighbour reads and the
## arithmetic on them, where `isOpaque` as a call was 2.1us for a single seq
## read. It is called once per VISIBLE face rather than once per neighbour test,
## and a chunk has some thousands of the former against its eighteen thousand
## of the latter.
proc faceAoCode*(w: World; r: Registry; index: int; lx, ly, lz: int;
                 baseX, baseY, baseZ, f: int): int =
  let ua = FaceUAxis[f]
  let va = FaceVAxis[f]
  # The open cell the face looks into. Everything that can shadow this face is
  # in the 3x3 plane around it.
  let ox = lx + FaceNormal[f][0]
  let oy = ly + FaceNormal[f][1]
  let oz = lz + FaceNormal[f][2]
  let opaqueCount = r.opaqueFlag.len
  # `solid[(du+1) * 3 + (dv+1)]`, du and dv running -1, 0, +1 along the face's
  # own two in-plane axes. The middle is read and thrown away rather than
  # branched around: a branch in here costs more than the read it saves.
  var solid: array[9, bool] = [false, false, false, false, false,
                               false, false, false, false]
  var du = -1
  while du <= 1:
    var dv = -1
    while dv <= 1:
      var cx = ox
      var cy = oy
      var cz = oz
      if ua == 0: cx = cx + du elif ua == 1: cy = cy + du else: cz = cz + du
      if va == 0: cx = cx + dv elif va == 1: cy = cy + dv else: cz = cz + dv
      var id = AirId
      if cx >= 0 and cx < ChunkSize and cy >= 0 and cy < ChunkSize and
         cz >= 0 and cz < ChunkSize:
        id = w.chunks[index].blocks[(cy * ChunkSize + cz) * ChunkSize + cx]
      else:
        id = w.blockAt(baseX + cx, baseY + cy, baseZ + cz)
      solid[(du + 1) * 3 + (dv + 1)] =
        id != AirId and id >= 0 and id < opaqueCount and r.opaqueFlag[id]
      inc dv
    inc du
  result = 0
  var c = 0
  while c < 4:
    # A corner sits at 0 or 1 along each in-plane axis; 0 means it is shadowed
    # by the neighbours on the minus side and 1 by those on the plus side.
    var su = -1
    if FaceCorner[f][c * 3 + ua] != 0: su = 1
    var sv = -1
    if FaceCorner[f][c * 3 + va] != 0: sv = 1
    let sideU = solid[(su + 1) * 3 + 1]
    let sideV = solid[1 * 3 + (sv + 1)]
    let diagonal = solid[(su + 1) * 3 + (sv + 1)]
    var dark = 0
    if sideU and sideV:
      dark = 3
    else:
      if sideU: dark = dark + 1
      if sideV: dark = dark + 1
      if diagonal: dark = dark + 1
    result = result + dark * (1 shl (c * 2))
    inc c

## One corner's occlusion back out of a packed code.
proc aoDarkOf*(code, corner: int): int = (code shr (corner * 2)) and 3

## And its shading multiplier.
proc aoShadeOf*(code, corner: int): float = AoShade[aoDarkOf(code, corner)]

## Whether a quad has to be split along its OTHER diagonal.
##
## The host makes two triangles of a quad by fanning from the first corner -
## `abc` and `acd` - so the split runs 0-2. Interpolation across a triangle is
## linear, so the quad's interior is decided by whichever pair of opposite
## corners the split joins, and the two choices are visibly different whenever
## the two diagonals do not agree: with one corner dark and three light, a 0-2
## split drags that darkness in a band right across the face, and a 1-3 split
## leaves it in the corner it belongs to. So the split takes the BRIGHTER
## diagonal, and a quad whose 1-3 pair is brighter is flipped.
##
## Flipping costs nothing, because a fan from corner 1 - `bcd` and `bda` - is
## the same four corners with the other diagonal, and the winding is unchanged.
## `addQuad(b, c, d, a)` is the whole of it.
proc quadFlipped*(f: Faces; at: int): bool =
  f.ao[at * 4] + f.ao[at * 4 + 2] < f.ao[at * 4 + 1] + f.ao[at * 4 + 3]

## `skins` is indexed by block id and says what each kind wears. A block whose
## skin is untextured keeps the plain 0..1 corner coordinates it always had and
## is painted a colour instead, so a world that ships no pictures behaves
## exactly as it did before there were any.
## `fromY`..`toY` are local heights, so one band of a chunk can be re-meshed
## without walking the rest of it. `buildChunk` is the whole of it.
##
## ## Why this reads the way it does
##
## Everything small in the inner loop is written out rather than called. That is
## not a style: an interpreted call in this runtime is 2.1 microseconds, a bare
## loop step is 0.28 and a seq read is 0.42, and this loop makes about eighteen
## thousand neighbour tests per chunk. Measured on a real 16-cubed chunk, the
## walk with `localIndex` and `isOpaque` as calls was 72ms and the same walk with
## them written out was 20ms - **three and a half times**, for nothing but
## source. So `localIndex` appears here as its own arithmetic, the opaque test
## reads `opaqueFlag` directly, and the sheet's numbers are pulled out once per
## face and the four corners mapped with scalars rather than by handing a `Skin`
## across a signature four times.
##
## The crossings are the other half of a chunk and are not reducible the same
## way: the seam charges per *number*, not per call, so a wider call carries the
## same numbers for the same price and a packed buffer costs as much to build in
## the interpreter as the crossings it would save. A texture atlas is the one
## free win in that direction - `addUv` is already being sent, and sending a
## different pair of numbers costs nothing at all - which is why a block wears
## its picture through the uvs below and not through its colour.
##
## The per-vertex colour that DOES go over is shading rather than picture, and it
## is the one thing worth four more numbers a vertex: it rides the vertex call
## that was crossing anyway - `addVertex` with a colour on the end is 1.2us more,
## where an `addColor` of its own would be 1.88 - and it is what stops a world
## lit by a single ambient term from looking like one.
## `lit` is whether the corners are shaded. False fills `ao` with ones - the
## flat-lit walk this was before ambient occlusion existed - which is what the
## far horizon uses, and what `voxel_test`'s control compares against.
proc buildChunk*(w: World; r: Registry; skins: seq[Skin]; index: int;
                 fromY = 0; toY = ChunkSize - 1; lit = true): Faces =
  result = emptyFaces()
  if index < 0 or index >= w.chunks.len: return result
  if not w.chunks[index].generated or w.chunks[index].filled == 0: return result
  if w.buriedChunk(index): return result
  let baseX = w.chunks[index].cx * ChunkSize
  let baseY = w.chunks[index].cy * ChunkSize
  let baseZ = w.chunks[index].cz * ChunkSize
  var lowY = fromY
  var highY = toY
  if lowY < 0: lowY = 0
  if highY > ChunkSize - 1: highY = ChunkSize - 1
  # Which of the six directions leave the window altogether. A property of the
  # chunk and not of the block, so it is six `chunkIndex` calls here rather than
  # eighteen thousand of anything below - and where it is true it *replaces* the
  # `blockAt` the inner loop would have made, so the sealed side is cheaper than
  # the open one as well as smaller.
  var sealFace: seq[bool] = @[]
  var sf = 0
  while sf < 6:
    sealFace.add w.sealedSide(index, sf)
    inc sf
  var ly = lowY
  while ly <= highY:
    var lz = 0
    while lz < ChunkSize:
      # `localIndex` written out, and hoisted as far up the loop nest as it
      # goes: the row's base is fixed for the whole of the x sweep.
      let rowBase = (ly * ChunkSize + lz) * ChunkSize
      # A chunk every block of which hides what is behind it can only show its
      # own six walls: a face in the middle of it looks at another opaque block
      # of the same chunk and is culled, and finding that out costs a neighbour
      # test each time. So a row that is interior on both of its other axes is
      # two blocks long rather than sixteen - which is 2744 of a chunk's 4096
      # blocks skipped, and sixteen thousand of its twenty-four thousand
      # neighbour tests. `buriedChunk` already answers the case where the walls
      # cannot be seen either; this is the far commoner one where they can.
      let edgeRow = w.chunks[index].sealed and ly > 0 and ly < ChunkSize - 1 and
        lz > 0 and lz < ChunkSize - 1
      var lx = 0
      while lx < ChunkSize:
        let mine = w.chunks[index].blocks[rowBase + lx]
        if mine != AirId:
          var texColumns = 0
          var texSide = DefaultSide
          var texPitch = float(DefaultSide + 2 * Pad)
          if mine < skins.len and skins[mine].columns > 0 and
             skins[mine].atlas.len > 0 and not skins[mine].whole:
            texColumns = skins[mine].columns
            texSide = skins[mine].side
            texPitch = float(texSide + 2 * Pad)
          var f = 0
          while f < 6:
            let stepX = FaceNormal[f][0]
            let stepY = FaceNormal[f][1]
            let stepZ = FaceNormal[f][2]
            let ax = lx + stepX
            let ay = ly + stepY
            let az = lz + stepZ
            var beyond = AirId
            if ax >= 0 and ax < ChunkSize and ay >= 0 and ay < ChunkSize and
               az >= 0 and az < ChunkSize:
              beyond = w.chunks[index].blocks[(ay * ChunkSize + az) * ChunkSize + ax]
            elif sealFace[f]:
              # A wall of the window. `mine` is the one value that is hidden
              # whatever `mine` happens to be, so this is the same two lines
              # below deciding it rather than a third branch in them.
              beyond = mine
            else:
              beyond = w.blockAt(baseX + ax, baseY + ay, baseZ + az)
            # `faceShows` and `isOpaque` both written out. This is the line that
            # runs eighteen thousand times a chunk.
            var hidden = beyond == mine
            if not hidden and beyond != AirId:
              hidden = beyond >= 0 and beyond < r.opaqueFlag.len and
                r.opaqueFlag[beyond]
            if not hidden:
              # The tile's two edges on the sheet, worked out once for the face
              # rather than once for each of its four corners. `tileUAt` and
              # `tileVAt` are the same arithmetic and are what the test checks;
              # this is them unrolled for the loop that cannot afford the call.
              var uLo = 0.0
              var uHi = 1.0
              var vLo = 0.0
              var vHi = 1.0
              if texColumns > 0:
                let across = texPitch * float(texColumns)
                let left = float(skins[mine].tile[f]) * texPitch + float(Pad)
                uLo = left / across
                uHi = (left + float(texSide)) / across
                vLo = float(Pad) / texPitch
                vHi = (float(Pad) + float(texSide)) / texPitch
              var aoCode = 0
              if lit:
                aoCode = faceAoCode(w, r, index, lx, ly, lz,
                  baseX, baseY, baseZ, f)
              var c = 0
              while c < 4:
                result.pos.add float(lx + FaceCorner[f][c * 3])
                result.pos.add float(ly + FaceCorner[f][c * 3 + 1])
                result.pos.add float(lz + FaceCorner[f][c * 3 + 2])
                # FaceUv's corners are only ever 0 or 1, so the map is a pick.
                if FaceUv[f][c * 2] > 0.5: result.uv.add uHi
                else: result.uv.add uLo
                if FaceUv[f][c * 2 + 1] > 0.5: result.uv.add vHi
                else: result.uv.add vLo
                # Unlit, `aoCode` is zero and this is 1.0 four times over.
                result.ao.add AoShade[(aoCode shr (c * 2)) and 3]
                inc c
              result.norm.add float(stepX)
              result.norm.add float(stepY)
              result.norm.add float(stepZ)
              result.kind.add mine
              inc result.count
            inc f
        if edgeRow and lx == 0: lx = ChunkSize - 1
        else: inc lx
      inc lz
    inc ly

# ---------------------------------------------------------------------------
# Greedy meshing
#
# Sixteen blocks of flat grass are sixteen quads, and they are the same quad
# sixteen times: one rectangle would draw them all. Merging them is worth more
# here than in an engine that owns its own vertex buffer, because the seam
# charges per *argument*: a quad is four `addVertex` of eight numbers and one
# `addQuad` of four - 0.68us of fixed cost five times over and 0.30us for each
# of thirty-six numbers, about 14us - and merging sixteen into one does not make
# the crossing cheaper, it removes fifteen of them.
#
# ## What stops it being unconditional: the sheet
#
# A merged quad has to *repeat* its picture across the run it covers. A quad
# that covers four blocks and carries one tile's uvs is that tile stretched over
# four blocks, which is worse than the sixteen quads it replaced.
#
# `vxatlas` cannot repeat. A tile lives inside a padded slot of a shared sheet,
# and a `u` past the end of that slot is not the tile again - it is the tile
# next door, which is exactly the failure the padding exists to prevent and
# which `tileUAt` clamps against (`atlasMapRules` asserts the clamp). Nothing a
# mod can say changes that: the host takes a mesh, a picture and nothing else,
# so there is no wrap mode to set, no second uv channel, and no per-tile
# texture. A textured run therefore cannot be merged **today**, and the mesher
# does not pretend otherwise: `mergeableSkin` says so, and a block on a sheet is
# emitted one face per block exactly as before.
#
# What *is* mergeable is a block painted a flat colour, which is every block
# whose catalog row carries no sheet - and the uvs a merged quad carries are the
# honest ones, `0..width` and `0..height` rather than `0..1`, so the day the
# host grows a way to repeat a tile, this is already right and only
# `mergeableSkin` has to change. `greedyRules` asserts that too.

## Whether a merged quad of this block could carry its picture correctly. A
## block on a sheet cannot (see above); a block painted a flat colour has no
## picture to stretch and can.
proc mergeableSkin*(skins: seq[Skin]; id: int): bool =
  if id < 0 or id >= skins.len: return true
  skins[id].repeats()

## Whether merging could pay for its walk at all in this world. The greedy sweep
## builds a mask per layer per face - the same order of work as the plain walk
## and then some - so a world whose every block is on a sheet must not pay for
## it. Answered in as many flags as there are kinds of block rather than in
## anything per chunk.
proc anyMergeable*(r: Registry; skins: seq[Skin]): bool =
  if r.blockCount() > skins.len: return true
  var i = 1
  while i < skins.len:
    if skins[i].repeats(): return true
    inc i
  false

## Every visible face in one chunk, coplanar runs of the same block merged into
## single quads where the block's skin allows it. Same surface, fewer quads.
##
## `fromY`..`toY` are local heights, exactly as `buildChunk` takes them, and the
## sweep is clipped to them: for the four sideways faces the band limits the
## `v` axis, and for the top and bottom faces it limits which layers are swept.
##
## Falls back to `buildChunk` when nothing in the world can be merged, so a
## world entirely on one sheet pays nothing for this file existing.
##
## ## Ambient occlusion and merging, which are enemies
##
## Shading varies per VERTEX, and merging exists because a run of faces is the
## same face over and over. Fold nothing in and a merged quad wears one corner's
## shading stretched across sixteen blocks, which is worse than wrong - it is
## wrong in a way that looks like a lighting bug rather than a meshing one. Give
## up and emit a quad per block and the shipped world is 17100 quads where
## merging made it 1309, which is thirteen times the crossings for the same
## picture. `Tests/voxel_test.exe` prints all three of those numbers, this one
## among them, and `CLAIMS.tsv` holds them to it.
##
## Neither, here. The mask cell carries the block id AND the four corner levels
## packed into a byte - `id * 256 + code` - so two cells merge only when they
## are the same block *lit the same way*. A flat plain is uniformly lit and
## still collapses to one quad; a row along the foot of a wall is uniformly lit
## ALONG the wall and still collapses to one long quad; only the cells where the
## shading actually changes are left one to a block, which is the handful of
## faces next to real geometry.
##
## **And the merged quad's shading is exactly right, not approximately.** Two
## cells adjacent along u with the same code cannot have a gradient along u:
## their shared edge is one pair of corners read twice, so the code's u=0 pair
## and u=1 pair have to be equal for the two cells to agree at all. Equal codes
## therefore mean the shading is constant along the direction of the run, which
## is the condition for stretching it to be a no-op. `voxel_test` asserts that
## corner by corner against a per-block walk rather than taking this paragraph's
## word for it.
##
## `lit` false is the flat-lit sweep, keyed on the block id alone exactly as it
## was before any of this - which is what the far horizon builds and what the
## test's control compares against.
proc buildChunkMerged*(w: World; r: Registry; skins: seq[Skin]; index: int;
                       fromY = 0; toY = ChunkSize - 1; lit = true): Faces =
  if not anyMergeable(r, skins):
    return buildChunk(w, r, skins, index, fromY, toY, lit)
  result = emptyFaces()
  if index < 0 or index >= w.chunks.len: return result
  if not w.chunks[index].generated or w.chunks[index].filled == 0: return result
  if w.buriedChunk(index): return result
  let baseX = w.chunks[index].cx * ChunkSize
  let baseY = w.chunks[index].cy * ChunkSize
  let baseZ = w.chunks[index].cz * ChunkSize
  var lowY = fromY
  var highY = toY
  if lowY < 0: lowY = 0
  if highY > ChunkSize - 1: highY = ChunkSize - 1
  if highY < lowY: return result

  # One 16x16 plane of "which block wants a face here", reused for every layer
  # of every direction. Zero is air and therefore "no face", which is what makes
  # a cleared cell and an empty cell the same thing.
  var mask: seq[int] = @[]
  var m = 0
  while m < ChunkArea:
    mask.add 0
    inc m

  # The chunk's blocks, once. The mask below reads them twice per cell and
  # builds about six thousand cells for a band, and `w.chunks[index].blocks` is
  # a seq inside an object inside a seq - three loads to reach the one that
  # matters, twelve thousand times over.
  let blocks = w.chunks[index].blocks
  let sealed = w.chunks[index].sealed

  var f = 0
  while f < 6:
    let na = FaceAxis[f]
    let ua = FaceUAxis[f]
    let va = FaceVAxis[f]
    let sealHere = w.sealedSide(index, f)
    let stepX = FaceNormal[f][0]
    let stepY = FaceNormal[f][1]
    let stepZ = FaceNormal[f][2]
    # The band clips whichever of the three axes is y. `ua` is never y - u runs
    # along x or z on every one of the six - so only the layer axis and the v
    # axis can be the one that moves.
    var loN = 0
    var hiN = ChunkSize - 1
    if na == 1:
      loN = lowY
      hiN = highY
    # And the same fast path the plain walk takes: a sealed chunk shows one
    # layer per direction - the outermost one - and nothing behind it. Every
    # other layer's mask would be built, found empty, and thrown away.
    if sealed:
      var only = 0
      if FaceNormal[f][na] > 0: only = ChunkSize - 1
      if only < loN or only > hiN:
        loN = 1
        hiN = 0
      else:
        loN = only
        hiN = only
    var loV = 0
    var hiV = ChunkSize - 1
    if va == 1:
      loV = lowY
      hiV = highY
    let uSpan = ChunkSize
    let vSpan = hiV - loV + 1
    # Walking the plane by stride rather than by coordinate. `blocks` is indexed
    # `(y * ChunkSize + z) * ChunkSize + x`, so one step along x is +1, along z
    # is +ChunkSize and along y is +ChunkArea, and a step along *any* of the
    # three axes is a constant added to the index. That turns the nine branches
    # and the multiply this loop used to do per cell into one addition.
    #
    # It is worth the trouble because this loop is the whole cost of meshing: a
    # band builds about six thousand of these cells, and with the quads
    # switched off entirely a band still costs the same half-second. The
    # rectangle growing below and the crossings after it are noise beside it.
    var strideN = 1
    if na == 1: strideN = ChunkArea elif na == 2: strideN = ChunkSize
    var strideU = 1
    if ua == 1: strideU = ChunkArea elif ua == 2: strideU = ChunkSize
    var strideV = 1
    if va == 1: strideV = ChunkArea elif va == 2: strideV = ChunkSize
    let stepIndex = stepX + stepY * ChunkArea + stepZ * ChunkSize
    let opaqueLen = r.opaqueFlag.len
    var layer = loN
    while layer <= hiN:
      # Only the layer axis can leave the chunk - `u` and `v` run inside the
      # plane - so whether the block beyond is somebody else's is a property of
      # the *layer*, asked once here instead of six thousand times below.
      let ahead = layer + FaceNormal[f][na]
      let outside = ahead < 0 or ahead >= ChunkSize
      # And a layer that leaves the *window* rather than the chunk shows
      # nothing at all, so its whole mask is skipped rather than built and found
      # empty. See `World.sealSides`.
      if outside and sealHere:
        inc layer
        continue
      # ---- the mask: one cell per face position in this layer --------------
      var jv = 0
      var rowBase = layer * strideN + loV * strideV
      while jv < vSpan:
        var iu = 0
        var at = rowBase
        let maskRow = jv * uSpan
        while iu < uSpan:
          let mine = blocks[at]
          var key = 0
          if mine != AirId:
            # The local coordinate of this cell. Working it out costs three
            # branches, and the flattened walk below exists precisely so that
            # the common cell never pays them: it is filled in only where
            # something actually asks - a layer that leaves the chunk, or a
            # visible face that has to be shaded.
            var cx = 0
            var cy = 0
            var cz = 0
            var haveCoord = false
            var beyond = AirId
            if outside:
              # The one case that needs a world coordinate, and it is one layer
              # in sixteen. Working it out here rather than for every cell is
              # what the whole rearrangement buys.
              if na == 0: cx = layer elif na == 1: cy = layer else: cz = layer
              if ua == 0: cx = iu elif ua == 1: cy = iu else: cz = iu
              if va == 0: cx = loV + jv
              elif va == 1: cy = loV + jv
              else: cz = loV + jv
              haveCoord = true
              beyond = w.blockAt(baseX + cx + stepX, baseY + cy + stepY,
                baseZ + cz + stepZ)
            else:
              beyond = blocks[at + stepIndex]
            var hidden = beyond == mine
            if not hidden and beyond != AirId:
              hidden = beyond >= 0 and beyond < opaqueLen and
                r.opaqueFlag[beyond]
            # The key is the block AND how it is lit, so a run merges only where
            # both agree. Unlit, the code is zero and this is `mine * 256`,
            # which orders and compares exactly as `mine` did.
            if not hidden:
              var code = 0
              if lit:
                if not haveCoord:
                  if na == 0: cx = layer elif na == 1: cy = layer else: cz = layer
                  if ua == 0: cx = iu elif ua == 1: cy = iu else: cz = iu
                  if va == 0: cx = loV + jv
                  elif va == 1: cy = loV + jv
                  else: cz = loV + jv
                  haveCoord = true
                code = faceAoCode(w, r, index, cx, cy, cz, baseX, baseY, baseZ, f)
              key = mine * 256 + code
          mask[maskRow + iu] = key
          at = at + strideU
          inc iu
        rowBase = rowBase + strideV
        inc jv
      # ---- grow rectangles out of it ---------------------------------------
      jv = 0
      while jv < vSpan:
        var iu = 0
        while iu < uSpan:
          let key = mask[jv * uSpan + iu]
          if key == 0:
            inc iu
            continue
          # The key is `block * 256 + shading`; everything below that asks what
          # kind of block this is wants the block back out of it.
          let id = key div 256
          let aoCode = key mod 256
          var wide = 1
          var tall = 1
          if mergeableSkin(skins, id):
            # As far right as the same block wants the same face...
            while iu + wide < uSpan and mask[jv * uSpan + iu + wide] == key:
              inc wide
            # ...then down, one whole row at a time, because a row that is short
            # by one cell cannot be taken at all without leaving a hole.
            var growing = true
            while growing and jv + tall < vSpan:
              var k = 0
              var whole = true
              while k < wide:
                if mask[(jv + tall) * uSpan + iu + k] != key: whole = false
                inc k
              if whole: inc tall
              else: growing = false
          # Taken: never look at these cells again.
          var b = 0
          while b < tall:
            var a = 0
            while a < wide:
              mask[(jv + b) * uSpan + iu + a] = 0
              inc a
            inc b
          # ---- one quad ------------------------------------------------------
          # The corner table is the unit face; a merged quad is that face with
          # its two in-plane axes stretched. Scaling by two positive numbers
          # cannot turn a winding round, so the quad is wound exactly as the
          # unit face `windingRules` checks.
          var bx = 0
          var by = 0
          var bz = 0
          if na == 0: bx = layer elif na == 1: by = layer else: bz = layer
          if ua == 0: bx = iu elif ua == 1: by = iu else: bz = iu
          if va == 0: bx = loV + jv elif va == 1: by = loV + jv else: bz = loV + jv
          var ex = 1
          var ey = 1
          var ez = 1
          if ua == 0: ex = wide elif ua == 1: ey = wide else: ez = wide
          if va == 0: ex = tall elif va == 1: ey = tall else: ez = tall
          # A merged run carries `0..width` and `0..height`, which is one tile
          # per block along it. A single block is 0..1, which is what every
          # untextured face has always carried.
          var uLo = 0.0
          var uHi = float(wide)
          var vLo = 0.0
          var vHi = float(tall)
          if id < skins.len and skins[id].columns > 0 and
             skins[id].atlas.len > 0 and not skins[id].whole:
            # On a sheet, and therefore never merged: the tile's own two edges,
            # the same arithmetic `buildChunk` inlines. A whole picture keeps
            # the 0..width and 0..height above, which is one repeat per block.
            let texSide = skins[id].side
            let texPitch = float(texSide + 2 * Pad)
            let across = texPitch * float(skins[id].columns)
            let left = float(skins[id].tile[f]) * texPitch + float(Pad)
            uLo = left / across
            uHi = (left + float(texSide)) / across
            vLo = float(Pad) / texPitch
            vHi = (float(Pad) + float(texSide)) / texPitch
          var c = 0
          while c < 4:
            result.pos.add float(bx + FaceCorner[f][c * 3] * ex)
            result.pos.add float(by + FaceCorner[f][c * 3 + 1] * ey)
            result.pos.add float(bz + FaceCorner[f][c * 3 + 2] * ez)
            if FaceUv[f][c * 2] > 0.5: result.uv.add uHi
            else: result.uv.add uLo
            if FaceUv[f][c * 2 + 1] > 0.5: result.uv.add vHi
            else: result.uv.add vLo
            # Every cell of this run carried this code - that is what made it a
            # run - so the run's corners are the cell's corners, stretched over
            # a rectangle the shading is constant along.
            result.ao.add AoShade[(aoCode shr (c * 2)) and 3]
            inc c
          result.norm.add float(stepX)
          result.norm.add float(stepY)
          result.norm.add float(stepZ)
          result.kind.add id
          inc result.count
          iu = iu + wide
        inc jv
      inc layer
    inc f

## The area a walk covers, in square blocks. One block's face is 1; a merged
## quad of four is 4. This is what makes "the greedy mesh is the same surface"
## a number rather than an opinion: it is derived from the corners themselves,
## through the cross product of the quad's own two edges, so a quad that was
## grown wrong in either axis is caught by it.
proc surfaceArea*(faces: Faces): float =
  result = 0.0
  var i = 0
  while i < faces.count:
    let ax = faces.pos[i * 12]
    let ay = faces.pos[i * 12 + 1]
    let az = faces.pos[i * 12 + 2]
    let bx = faces.pos[i * 12 + 3] - ax
    let by = faces.pos[i * 12 + 4] - ay
    let bz = faces.pos[i * 12 + 5] - az
    let dx = faces.pos[i * 12 + 9] - ax
    let dy = faces.pos[i * 12 + 10] - ay
    let dz = faces.pos[i * 12 + 11] - az
    # Axis aligned, so the cross product has one non-zero component and its
    # size is the area. Summed as a magnitude rather than signed, because a
    # face that came out backwards must not cancel one that did not.
    let nx = by * dz - bz * dy
    let ny = bz * dx - bx * dz
    let nz = bx * dy - by * dx
    var size = nx
    if size < 0.0: size = -size
    var other = ny
    if other < 0.0: other = -other
    if other > size: size = other
    other = nz
    if other < 0.0: other = -other
    if other > size: size = other
    result = result + size
    inc i

## Every visible face of one kind of block in one chunk, in chunk-local
## coordinates. `wantId` picks the kind because the host paints a mesh one
## colour; passing `AirId` gives nothing back.
proc buildFaces*(w: World; r: Registry; index, wantId: int): Faces =
  result = emptyFaces()
  if index < 0 or index >= w.chunks.len: return result
  if not w.chunks[index].generated or w.chunks[index].filled == 0: return result
  if wantId == AirId: return result
  let baseX = w.chunks[index].cx * ChunkSize
  let baseY = w.chunks[index].cy * ChunkSize
  let baseZ = w.chunks[index].cz * ChunkSize
  var ly = 0
  while ly < ChunkSize:
    var lz = 0
    while lz < ChunkSize:
      var lx = 0
      while lx < ChunkSize:
        if w.chunks[index].blocks[localIndex(lx, ly, lz)] == wantId:
          let x = baseX + lx
          let y = baseY + ly
          let z = baseZ + lz
          var f = 0
          while f < 6:
            let n = FaceNormal[f]
            let beyond = w.blockAt(x + n[0], y + n[1], z + n[2])
            if faceShows(r, wantId, beyond):
              var c = 0
              while c < 4:
                result.pos.add float(lx + FaceCorner[f][c * 3])
                result.pos.add float(ly + FaceCorner[f][c * 3 + 1])
                result.pos.add float(lz + FaceCorner[f][c * 3 + 2])
                result.uv.add FaceUv[f][c * 2]
                result.uv.add FaceUv[f][c * 2 + 1]
                inc c
              result.norm.add float(n[0])
              result.norm.add float(n[1])
              result.norm.add float(n[2])
              result.kind.add wantId
              inc result.count
            inc f
        inc lx
      inc lz
    inc ly

## The material one block wants: its sheet if it has one, its colour if it does
## not. Two blocks that answer the same string can be one mesh.
proc materialOf*(r: Registry; skins: seq[Skin]; id: int): string =
  var skin = plainSkin()
  if id >= 0 and id < skins.len: skin = skins[id]
  materialKey(skin, colourKey(r.defOf(id)))

## The same, per face. A block wearing whole pictures wants a different mesh per
## picture, and which picture a face wears is the face's business - so this, and
## not `materialOf`, is what the game groups by.
proc faceMaterialOf*(r: Registry; skins: seq[Skin]; id, face: int): string =
  var skin = plainSkin()
  if id >= 0 and id < skins.len: skin = skins[id]
  faceMaterialKey(skin, face, colourKey(r.defOf(id)))

## Every block's material, worked out once, so that asking a face for its
## material is a seq read rather than two string joins. `materialOf` builds a
## string, and a chunk has a few thousand faces; the same mistake as answering
## `isOpaque` out of a `BlockDef`, one layer up.
proc materialTable*(r: Registry; skins: seq[Skin]): seq[string] =
  result = @[]
  var id = 0
  while id < r.blockCount():
    result.add materialOf(r, skins, id)
    inc id

## Every block's material for every one of its six faces, worked out once, and
## indexed `id * 6 + face`. Six entries per block rather than one because a
## block wearing whole pictures is a different mesh per picture; a block on a
## sheet, and a block painted a colour, simply answer the same string six times.
proc faceMaterialTable*(r: Registry; skins: seq[Skin]): seq[string] =
  result = @[]
  var id = 0
  while id < r.blockCount():
    var f = 0
    while f < 6:
      result.add faceMaterialOf(r, skins, id, f)
      inc f
    inc id

## Which face of the world a quad belongs to, recovered from the normal it was
## emitted with. The mesher knows; a reader of `Faces` has to ask.
proc faceOfQuad*(f: Faces; at: int): int =
  if at < 0 or at >= f.count: return -1
  faceOfNormal(int(f.norm[at * 3]), int(f.norm[at * 3 + 1]),
    int(f.norm[at * 3 + 2]))

## Which entry of `faceMaterialTable` a quad wants.
proc materialSlot*(f: Faces; at: int): int =
  let face = faceOfQuad(f, at)
  if face < 0: return -1
  f.kind[at] * 6 + face

## Which *materials* a walk of a chunk produced faces for, in the order they
## were first met, keyed per face. One mesh comes out of the chunk per entry.
proc faceMaterialsIn*(f: Faces; table: seq[string]): seq[string] =
  result = @[]
  var i = 0
  while i < f.count:
    let slot = materialSlot(f, i)
    if slot >= 0 and slot < table.len:
      var seen = false
      var k = 0
      while k < result.len:
        if result[k] == table[slot]:
          seen = true
          break
        inc k
      if not seen: result.add table[slot]
    inc i

## The same answer as `faceMaterialsIn`, with its working kept: which materials
## a walk produced faces for, *and* which quads each of them is made of.
##
## `order` comes back as every quad index that goes into a mesh, one material's
## run after another, and `start` as where each run begins - so `start[k]`
## .. `start[k+1]` is material `k`'s quads and a mesh reads its own geometry
## instead of scanning the whole walk for it. `start` always has one more entry
## than there are materials, so the last run has an end.
##
## Why it exists at all: a band at the ground is a thousand quads and ten
## materials, and asking "is this quad this material?" once per quad per
## material - which the caller did three separate times over - is thirty
## thousand string compares to hand over one band, and was most of what the
## six-hundred-millisecond frames were made of. This is one pass, and no string
## is compared more than once per *slot* rather than once per quad.
##
## `Tests/voxel_test.nim` asserts this agrees with `faceMaterialsIn` and with
## `materialSlot` quad for quad. That matters more than the speed: deciding the
## materials one way and then re-selecting the quads another way is what once
## handed `jester_mesh_finish` a material with no quads in it, and a mesh
## with no vertices throws, and a chunk that threw has no collider, and a player
## standing on a chunk with no collider is at y=-402. One pass cannot disagree
## with itself, and a group here exists only because a quad made it.
proc faceGroupsIn*(f: Faces; table: seq[string]; order: var seq[int];
                   start: var seq[int]): seq[string] =
  result = @[]
  order = @[]
  start = @[]
  ## Which group a table slot ended up in, or -1 for a slot this walk has not
  ## met. This is the table that turns per-quad string work into per-slot work.
  var slotGroup: seq[int] = @[]
  var i = 0
  while i < table.len:
    slotGroup.add(-1)
    inc i
  var counts: seq[int] = @[]
  var group: seq[int] = @[]
  var at = 0
  while at < f.count:
    # `faceOfQuad`, inlined: it searches `FaceNormal` for a match, and this is
    # the innermost line of handing a chunk over.
    var face = 5
    let nx = f.norm[at * 3]
    if nx > 0.5: face = 0
    elif nx < -0.5: face = 1
    else:
      let ny = f.norm[at * 3 + 1]
      if ny > 0.5: face = 2
      elif ny < -0.5: face = 3
      elif f.norm[at * 3 + 2] > 0.5: face = 4
    let slot = f.kind[at] * 6 + face
    var g = -1
    if slot >= 0 and slot < table.len:
      g = slotGroup[slot]
      if g < 0:
        # A slot met for the first time. Two slots can name the same picture -
        # all six faces of stone do - so this is where the strings are compared,
        # once per slot rather than once per quad.
        let key = table[slot]
        var k = 0
        while k < result.len:
          if result[k] == key:
            g = k
            break
          inc k
        if g < 0:
          g = result.len
          result.add key
          counts.add 0
        slotGroup[slot] = g
    group.add g
    if g >= 0: counts[g] = counts[g] + 1
    inc at
  # A counting sort into one contiguous run per group, so a mesh's quads are a
  # slice rather than a search.
  var total = 0
  var g = 0
  while g < counts.len:
    start.add total
    total = total + counts[g]
    inc g
  start.add total
  var cursor: seq[int] = @[]
  g = 0
  while g < counts.len:
    cursor.add start[g]
    inc g
  i = 0
  while i < total:
    order.add 0
    inc i
  at = 0
  while at < group.len:
    let gg = group[at]
    if gg >= 0:
      order[cursor[gg]] = at
      cursor[gg] = cursor[gg] + 1
    inc at

## The same as `materialsSeen`, from the table rather than from the registry.
proc materialsIn*(f: Faces; table: seq[string]): seq[string] =
  result = @[]
  var i = 0
  while i < f.count:
    let id = f.kind[i]
    if id >= 0 and id < table.len:
      var seen = false
      var k = 0
      while k < result.len:
        if result[k] == table[id]:
          seen = true
          break
        inc k
      if not seen: result.add table[id]
    inc i

## Which *materials* a walk of a chunk produced faces for, in the order they
## were first met. One mesh comes out of the chunk per entry.
##
## This is the number that decides how many meshes a chunk becomes, and it is
## not the number of block kinds in it. Blocks packed into one sheet share one
## material and therefore one mesh - so a world whose whole block set is on a
## single sheet is **one mesh per chunk**, and a world where every block brought
## its own picture is one per block. The mesher knows nothing about either case;
## both fall out of comparing this string.
proc materialsSeen*(f: Faces; r: Registry; skins: seq[Skin]): seq[string] =
  result = @[]
  var i = 0
  while i < f.count:
    let key = materialOf(r, skins, f.kind[i])
    var seen = false
    var k = 0
    while k < result.len:
      if result[k] == key:
        seen = true
        break
      inc k
    if not seen: result.add key
    inc i

## Which kinds of block a walk of a chunk actually produced faces for, in the
## order they were first met. One mesh comes out of the chunk per entry, and
## this is what the game reads rather than `kindsIn`: a kind that is entirely
## buried has no faces and needs no mesh.
proc kindsSeen*(f: Faces): seq[int] =
  result = @[]
  var i = 0
  while i < f.count:
    let id = f.kind[i]
    var seen = false
    var k = 0
    while k < result.len:
      if result[k] == id:
        seen = true
        break
      inc k
    if not seen: result.add id
    inc i

## Which kinds of block a chunk holds, in the order they are first met, whether
## any of them can be seen or not.
proc kindsIn*(w: World; index: int): seq[int] =
  result = @[]
  if index < 0 or index >= w.chunks.len: return result
  if w.chunks[index].blocks.len == 0: return result
  var i = 0
  while i < ChunkVolume:
    let id = w.chunks[index].blocks[i]
    if id != AirId:
      var seen = false
      var k = 0
      while k < result.len:
        if result[k] == id:
          seen = true
          break
        inc k
      if not seen: result.add id
    inc i

# ---------------------------------------------------------------------------
# Looking at it

## Walk a ray until it meets a block the player could break, and say which face
## it came in by. `wantSolid` false picks liquids too, which is how a boat would
## find the water; the game uses true, so a crosshair reaches through a sea to
## the sand under it.
proc traceWorld*(w: World; r: Registry; ox, oy, oz, dx, dy, dz: float;
                 reach: float; wantSolid = true): Pick =
  result = noPick()
  var walk = beginWalk(ox, oy, oz, dx, dy, dz)
  var guard = 0
  let limit = int(reach * 3.0) + 8
  while walk.travelled <= reach and guard < limit:
    let id = w.blockAt(walk.x, walk.y, walk.z)
    if id != AirId and ((not wantSolid) or r.isSolid(id)):
      return pickAt(walk)
    stepOn(walk)
    inc guard

## Whether a body of this size standing here would be inside anything solid.
## The host's own capsule sweep does the real collision - a chunk mesh arrives
## with a MeshCollider on it - and this is what a spawn point is chosen with,
## and what a placement is refused by so a player cannot brick themselves in.
proc boxBlocked*(w: World; r: Registry; x, y, z: float;
                 radius, height: float): bool =
  let minX = floorInt(x - radius)
  let maxX = floorInt(x + radius)
  let minZ = floorInt(z - radius)
  let maxZ = floorInt(z + radius)
  let minY = floorInt(y)
  let maxY = floorInt(y + height - 0.001)
  var bx = minX
  while bx <= maxX:
    var by = minY
    while by <= maxY:
      var bz = minZ
      while bz <= maxZ:
        if r.isSolid(w.blockAt(bx, by, bz)): return true
        inc bz
      inc by
    inc bx
  false

## The first place above the ground at this column where a character fits.
## Answers the world's own ceiling when the column is full, which is a column
## nobody should be spawned in and a caller that has to check.
proc standingHeight*(w: World; r: Registry; x, z: int; height = 2): int =
  var y = w.blocksHigh() - height - 1
  while y > 0:
    if r.isSolid(w.blockAt(x, y - 1, z)):
      var clear = true
      var k = 0
      while k < height:
        if r.isSolid(w.blockAt(x, y + k, z)): clear = false
        inc k
      if clear: return y
    dec y
  1
