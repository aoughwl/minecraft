## A world made of blocks, that you can dig into and build back up.
##
## This is the host seam and nothing else. Every rule the world obeys - what the
## land looks like, which faces are worth drawing and which way round they go,
## which block the crosshair is on - is next door in four files that call no
## host at all and are settled by `Tests/voxel_test.exe` in under a second:
##
##   `vxblocks.nim`  what a block is, how a catalog row spells one, and the
##                   registry other mods fill
##   `vxnoise.nim`   the terrain's noise: integer hashing, value noise, fbm and
##                   a ridge, all deterministic in the seed
##   `vxworld.nim`   chunks, indexing, generation, the interior face cull and
##                   the mesh that comes out of it
##   `vxray.nim`     the voxel traversal that finds the block under the
##                   crosshair and the empty one beside it
##
## ## The blocks are not this mod's
##
## `aoughwl.voxel` declares a catalog *kind* - `aoughwl.block` - and
## creates one catalog of it, `voxel.blocks`, with a starting set in it. That is
## the same shape as `aoughwl.character`: a schema and an opinion. Any mod
## that lists this one as a dependency can put its own blocks in the same
## catalog, and they are in the world without a line of this file changing,
## which is what `aoughwl.minecraft` will do with the block models a player
## imported from their own copy. A row's value is text, because a catalog value
## is one scalar and a block is eight things:
##
##   addToCatalog("voxel.blocks", "stone",
##     "label=Stone;hardness=1.5;colour=#7d7d7d;drops=cobblestone")
##
## The catalog is re-read whenever it grows, so a mod that loads after this one
## still lands. Ids are handed out in registration order and a name that comes
## round again keeps its number, so the blocks already in the ground go on
## meaning what they meant.
##
## ## A chunk is a part, and there is one item in the parts catalog
##
## The only way to put a mesh in the world is `spawnPart`, which resolves a
## catalog row through a scheme this mod provides. A row's value is fixed when
## it is added, so a row per chunk would mean a row per *rebuild* - the same
## `(id, owner)` cannot be registered twice - and the catalog would grow for as
## long as somebody kept digging. So there is one row, `voxel://chunk`, and the
## resolver reads which chunk and which kind of block out of a variable this
## file sets immediately before the spawn. The resolve happens inside the
## `spawnPart` call, on this thread, so nothing can come between them.
##
## Keys: left click digs, right click places, 1-9 pick what to place,
## Tab gives the pointer back, G shows the numbers, N starts a new world.

import jester
import character
import catalogs
import services
import aoughwl_inventory/inventory
import aoughwl_handoff/handoff
import aoughwl_grid/gridspace
import vec
import color
import input
import entities
import draw
import textures
import vxdefaults
import vxblocks
import vxnoise
import vxray
import vxatlas
import vxworld
import vxlod
import vxfeel
import vxstream
import vxview
import vxskin
import vxmcmap
import vxmcplay
import vxtune
import importing
# The things in the world that are not blocks. Every decision they involve is
# in a pure module `Tests/entity_test.exe` settles - the box model as data
# (`vxmodel`), the models themselves (`vxbeasts`), where every limb points
# (`vxanim`), and what is out there (`vxbeing`) - and `vxherd` is the only one
# of the five that touches the host.
import vxmodel
import vxanim
import vxbeing
import vxturn
import vxherd

const
  BlockKind = "aoughwl.block"
  Blocks = "voxel.blocks"
  Chunks = "voxel.chunks"
  Drops = "voxel.drops"
  ## The two things breaking a block *looks* like, as parts of their own: the
  ## crack that grows on the block being mined, and the chips that come off it.
  ## Both are meshes and the only way to put a mesh in the world is a spawn, so
  ## both are catalogs like the chunks are, answered by the same resolver under
  ## the same scheme and told apart by their locator.
  Cracks = "voxel.cracks"
  Chips = "voxel.chips"
  ## The player, for the two views in which there is one to look at. Two parts
  ## and not six: everything below the neck turns with where you are walking
  ## and the head turns with where you are looking, so a body and a head are
  ## exactly the two transforms third person needs. `vxskin.nim` has the boxes
  ## and which rectangle of the skin each of their faces reads.
  Bodies = "voxel.player"
  Items = "voxel.items"
  Scheme = "voxel"
  ## Where the player's skin comes from. A row here is a `data:` URI or a file
  ## inside the mod that contributed it, exactly as `voxel.blocks.atlas` is -
  ## and this repository contributes no row at all. The skin is Mojang's
  ## picture out of the copy of the game the player granted, so the mod that
  ## reads that copy is the mod that fills this in; with nothing in it the
  ## player is the same six boxes in flat colours.
  Skins = "voxel.player.skin"
  SkinKind = "aoughwl.entity.skin"
  ## What the hand in the corner is, in metres. Small, because it is a block
  ## held in a fist and not a block in the world.
  HandSize = 0.14
  ## The two facets of the block catalog that carry a picture. Spelled the way
  ## `aoughwl.inventory` spells a facet - the base catalog's id plus a
  ## suffix - so a mod that fills them never has to name this one.
  AtlasKind = "aoughwl.block.atlas"
  TilesKind = "aoughwl.block.tiles"
  AtlasFacet = ".atlas"
  TilesFacet = ".tiles"
  ## And a third facet: the pictures a block wears while it is being broken, in
  ## order, `|` separated - `block/destroy_stage_0` .. `_9` out of a granted
  ## Minecraft, and anything else a provider has.
  ##
  ## It is read per block like the other two and **falls back to the first row
  ## in the catalog** when a block has none of its own, which is what makes one
  ## row dress a whole world without anybody spelling a magic name: a provider
  ## with one set of crack pictures puts one row and every block wears it, and a
  ## provider that wants a different crack on obsidian adds a row called
  ## `obsidian` beside it. `vxfeel.crackPicture` then maps the ten stages onto
  ## however many pictures the row actually holds.
  WearKind = "aoughwl.block.wear"
  WearFacet = ".wear"
  ## The sheet this mod ships: thirteen sixteen-pixel tiles in a row, each
  ## padded by a pixel of its own edge, in the order `DefaultTiles` names.

  ## How big the world is, in chunks. Every one of these is a measured budget
  ## rather than a taste, and the measurement is
  ## `tools/run_mod.exe --time <this mod> start update...`: 130 updates fill
  ## the near world nearest-the-player-first, and the 52 chunks that takes
  ## arrive in 9.6 - 10.8 seconds of interpreter over six runs, against
  ## 18.3 - 20.2 before the window's own walls, its sky and its solid rock
  ## stopped being paid for. Six runs and not one, because the spread between
  ## them is a tenth of the gap between the two. Turn these up and the world
  ## gets bigger and the wait gets longer in exact proportion.
  ##
  ## Do not read a rate off `ChunkCost` and `BandCost` below: those are frame
  ## *prices* and they have not been re-measured since, so a chunk that is now
  ## nothing but sky or nothing but rock is still charged what a chunk full of
  ## coastline costs. That is safe - it only ever makes a frame end early - but
  ## it is throughput left on the floor in the real, paced game, and re-pricing
  ## it needs a measurement with frames in it rather than this one.
  SpanX = 3
  SpanY = 6
  SpanZ = 3
  SeaLevel = 44
  ## Six chunks tall rather than three, and the sea line moved with them. Both
  ## are the horizon's doing: `surfaceHeight` scales the whole landscape by how
  ## tall the world is, so a world 48 blocks high has 30 blocks of relief in it
  ## and a six-hundred-block view of that is a car park. Ninety-six gives the
  ## mountains something to be. It costs 54 chunks near the player instead of
  ## 27, and almost nothing per chunk: the ones entirely above the ground lay
  ## no blocks down at all.
  ## Caves are off by default because they are the one thing in generation that
  ## is asked once per *block* rather than once per column, and switching them
  ## on measures out at roughly half again on top of every chunk. `docs` calls
  ## them optional; this is what optional costs.
  Caves = false
  Reach = 5.0
  PlaceDelay = 0.18
  DropReach = 2.0
  DropLife = 180.0
  ## How much *work* one frame may spend filling the world in. Not how many
  ## chunks and not how many faces: see `workChunks` for why a count of things
  ## is not a budget and what the prices below are. This is the number to turn
  ## down if the world arriving makes the game stutter, and up if it arrives too
  ## slowly - it trades one directly for the other.
  FaceBudget = 900
  ## What generating one chunk and meshing one band are charged against that
  ## budget. Both are in the same units as a quad, and both are measured rather
  ## than chosen: with `FaceBudget` at 900, a generated chunk plus one band is a
  ## frame, and a frame never takes two fat bands - which is what the old
  ## quads-only price let it do, and what the six-hundred-millisecond frames
  ## were made of.
  ChunkCost = 500
  BandCost = 400
  ## ---- starting up ------------------------------------------------------
  ## The last stage number `beginStage` knows. One more than this and the world
  ## is up; it is a constant rather than a count of a list because the stages
  ## are a `case` and a `case` cannot be counted.
  BootStages = 13
  ## When to slow the start-up down and when to let it go faster, in
  ## milliseconds of the frame that just went by. 33ms is two frames at sixty,
  ## which is the point at which the start-up is visibly costing the person
  ## watching it; 12ms is a frame with room to spare in it.
  BootSlowMs = 33
  BootFastMs = 12
  ## How many block rows stage 0 may read in one frame, before the same pacing
  ## multiplies it. 48 rather than a round hundred because the rows are not the
  ## same size - a block with a sheet costs a parse that a plain one does not -
  ## and the budget has to be the slow row's.
  BootRowsPerFrame = 48
  ## How many frames the start-up may be spread over before it stops asking
  ## permission, and what the rate becomes when it does. See `paceBegin`: this
  ## is the guard against pacing against somebody else's long frames.
  BootPatience = 12
  BootImpatientStages = 4
  ## And the most stages one frame may ever do, however fast the machine looks.
  ## The cap is what keeps this honest on a machine quick enough to report a
  ## short frame and still slow enough to stutter on a chunk: without it the
  ## rate climbs until the frame it climbed for is the long one.
  BootMaxStages = 3
  MaxKinds = 12
  ## How much bigger than the block the crack overlay is. Two millimetres out,
  ## so the depth test picks it from every angle and it does not stand proud of
  ## the blocks beside it.
  CrackSpan = 1.004

  ## ---- the horizon ------------------------------------------------------
  ## How many rings of far regions are drawn round the near world. A region is
  ## `LodRegion` (48) blocks, so six rings is a view 624 blocks across - the
  ## near world is the middle 48 of it.
  ##
  ## What that costs is one `surfaceHeight` per *cell*, and a cell is 2, 4, 8 or
  ## 16 blocks across depending how far out it is: about 8,900 columns for the
  ## whole horizon against the near world's 2,304. Four times the noise for a
  ## hundred and sixty-nine times the ground.
  ##
  ## This is where the horizon starts, not where it stays: an options screen
  ## sets `lodRadius` beside it - see `vxtune.lodRadiusFor` for the chunks a
  ## ring is worth.
  LodRadius = 6
  ## How many far columns may be sampled in one frame. Sampling is the same
  ## noise the chunks are made of, so this is the number to turn down if the
  ## horizon filling in makes the world stutter, and the reason the whole
  ## 8,856-column horizon arrives over several seconds rather than in one frame.
  ##
  ## A row of a region always costs more than this, so a frame that samples at
  ## all samples exactly one row - which is what `workLod` relies on to give the
  ## other half of the horizon's work the next frame instead of this one.
  LodSamples = 16
  ## What the middle region - the one the player is standing in - is drawn at.
  ##
  ## It used to be nothing at all, because the near world was pinned to the
  ## origin and covered that region exactly, so there was never any of it left
  ## over to draw. A near world that follows the player slides a chunk at a time
  ## while the region grid stays where it is, so the middle region is only ever
  ## *mostly* covered and the L-shaped remainder has to be drawn by something.
  ## Level 1 is the finest the horizon has: two blocks to a cell, against the
  ## real blocks it is standing beside.
  LodNearLevel = 1

  Ink = Color(r: 0.04, g: 0.05, b: 0.07, a: 0.76)
  Paper = Color(r: 0.88, g: 0.91, b: 0.96, a: 1.0)
  Quiet = Color(r: 0.62, g: 0.68, b: 0.78, a: 1.0)
  Accent = Color(r: 0.42, g: 0.90, b: 0.52, a: 1.0)
  Warm = Color(r: 0.98, g: 0.82, b: 0.38, a: 1.0)
  Crosshair = Color(r: 0.95, g: 0.97, b: 1.0, a: 0.85)

var
  registry = newRegistry()
  world: World
  player = newCharacter()
  eye: Entity
  started = false

  ## ---- starting up, a frame at a time ------------------------------------
  ## How far through `beginStage` the first frames have got, and how many stages
  ## one frame may do. See `workBegin` for why this is staged at all and why the
  ## rate is read off the frame that just went by.
  bootStage = 0
  bootSaid = -1         ## the last stage number said out loud
  rowSaid = 0           ## and how far into the catalogs it was when it said it
  bootPerFrame = 1
  bootFrames = 0        ## how many frames the start-up has taken so far
  bootStanding = 0.0
  ## What `planSpawn` worked out, kept between stages because the stages that
  ## use it are no longer in the same frame as the stage that found it.
  spawnFeet = -1
  spawnHead = -1
  spawnSlice = 0
  spawnMidX = 0
  spawnMidZ = 0

  ## ---- reading the block catalogs, a slice at a time ---------------------
  ## Where a part-finished read of `readBlocks` got to. Only the world's first
  ## frames ever leave one part-finished; the steady path reads in one go.
  readingBlocks = false
  blockRows = 0         ## how many rows there were when this read started
  blockRow = 0          ## how many of them have been registered
  skinRow = 0           ## and how many blocks have had their skin built
  sheetText: seq[string] = @[]
  tilesText: seq[string] = @[]
  dressedWith: seq[bool] = @[]

  catalogSeen = -1
  ## How far into the registry the item catalog has been kept up with. A block
  ## is published as an item exactly once, however many times its own row is
  ## contributed over.
  itemsPublished = 1
  seed = 0

  ## The mesh entities. One chunk becomes one mesh per kind of block in it,
  ## because the host paints a mesh one colour. Kept flat and swept linearly:
  ## a few hundred rows, and a rebuild touches one chunk's worth.
  meshChunk: seq[int]
  meshSlice: seq[int]
  meshThing: seq[Entity]

  ## What each kind of block wears, indexed by block id, read out of the two
  ## facet catalogs. A block with no row here is painted its flat colour.
  skins: seq[Skin]
  ## And each block's material, worked out once beside them, so that asking a
  ## face which mesh it belongs in is a seq read rather than two string joins.
  materialKeys: seq[string]

  ## Which material the resolver is about to be asked for, and the geometry it
  ## will answer with. Set immediately before `spawnPart`.
  pendingFaces = emptyFaces()
  pendingMaterial = ""
  pendingAtlas = ""
  ## The band's quads, bucketed by which mesh each belongs to. `pendingOrder` is
  ## every quad index that goes into a mesh, one group's run after another, and
  ## `pendingStart` says where each run begins - so a mesh reads its own quads
  ## rather than scanning the whole band looking for them. `pendingAt` is the
  ## group `resolvePart` is currently being asked for.
  ##
  ## This is what stops the surface bands costing most of a second. A band at the
  ## ground has a thousand quads and ten materials in it, and the old spelling
  ## asked `materialAt` - an interpreted call, a normal decoded, a string
  ## compared - once per quad per material, three separate times over: in
  ## `faceMaterialsIn`, in the search for the quad that says which picture to
  ## wear, and again in `resolvePart`. Thirty thousand string compares to hand
  ## over a thousand quads. One pass answers all three questions.
  ##
  ## It also closes a hole. Deciding the materials with `materialSlot` and then
  ## re-selecting the quads with `materialAt` was two spellings of one rule, and
  ## when they disagreed a material came back with no quads at all,
  ## `finishMesh` threw, and every chunk lost its collider. There is one
  ## spelling now and a mesh cannot be empty, because a group exists only
  ## because a quad made it.
  pendingOrder: seq[int] = @[]
  pendingStart: seq[int] = @[]
  pendingAt = -1

  ## What is in the player's hand, and how much of everything they have. Indexed
  ## by block id, so it grows with the registry.
  pouch: seq[int]
  hotbar: seq[int]
  holding = 0

  ## Digging.
  aimed = noPick()
  digging = false
  digX = 0
  digY = 0
  digZ = 0
  digProgress = 0.0
  digNeeded = 1.0
  sincePlace = 0.0
  highlight = nothing()

  ## ---- what breaking a block feels like ---------------------------------
  ## The crack: which stage is on the screen, the entity wearing it, and the
  ## pictures the catalog gave us for the block being mined. `crackShown` is
  ## kept because the overlay is a *mesh* and a mesh cannot be re-textured in
  ## place - changing the stage is a destroy and a spawn, so it must happen ten
  ## times a block and not sixty times a second.
  crackThing = nothing()
  crackShown = -2
    ## The stage that has been *said*, which is a fact about the hardness timer.
    ##
    ## Minus *two* to begin with, and not minus one. "Nothing is being mined"
    ## is minus one and is a thing worth saying: a run that has never heard
    ## `voxel.crack` at all cannot tell "the crack is off" from "this modpack
    ## has no crack in it". Starting one below the first real value is what
    ## makes the first frame say so.
  crackWorn = -1
    ## And the stage the overlay entity is actually built for, which is a fact
    ## about the pictures. The two are apart on purpose: a modpack that has
    ## been granted no Minecraft still has a crack timer, still says what stage
    ## it is at, and simply has nothing to draw for it.
  crackTop = -1
    ## The highest stage ever reached, which never goes back down. It is what a
    ## headless run asserts against: catching a particular stage on a particular
    ## frame is a race, and "the crack got at least this far" is not.
  crackWearing = ""
  crackPics: seq[string] = @[]
  crackRow = ""

  ## The chips, and the one mesh they are drawn as. `chipPicture` is what that
  ## mesh wears: a mesh carries one texture, so a field holding chips off two
  ## different blocks wears the newer one - which is what a burst landing on
  ## top of a burst looks like anyway.
  chips = newMotes()
  chipThing = nothing()
  chipPicture = ""
  sinceChip = 0.0
  chipsSaid = -1

  ## The beat. `sinceBreak` is what stops a held button walking a tunnel; the
  ## other two are the swing, which nothing here draws - they are published for
  ## whichever mod owns the held-item view.
  sinceBreak = 99.0
  sinceSwing = 99.0
  swings = 0
  puffs = 0
    ## How many placements have puffed. Its own count rather than a reading of
    ## the chip total, because the chip total moves for three different reasons
    ## and a number that moves for three reasons proves none of them.

  ## The camera's own axes, read once a frame and used by every chip. A quad
  ## that does not face the camera is a quad you can look at edge-on and lose,
  ## and sixteen chips is one basis rather than sixteen.
  chipRight = vec3(1.0, 0.0, 0.0)
  chipUp = vec3(0.0, 1.0, 0.0)
  chipAhead = vec3(0.0, 0.0, 1.0)

  ## Dropped blocks, waiting to be walked into.
  dropThing: seq[Entity]
  dropBlock: seq[int]
  dropAge: seq[float]

  ## The horizon. One heightmap per far region, one part per band of it, and a
  ## cursor into the nearest-first order for each of the two things that have to
  ## happen to a region - being sampled, and being handed over.
  lodScene = newLodScene(0)
  lodThing: seq[Entity]
  lodRegionX: seq[int]
  lodRegionZ: seq[int]
    ## Which region each of those meshes belongs to, by where that region is in
    ## the world. Not by its slot in `lodScene.fields`: the slots are shuffled
    ## every time the horizon re-centres, and a mesh filed under a slot would
    ## then be taken away from whichever region inherited its index. Filed under
    ## the place instead, and a place does not move.
  lodDone: seq[int]
  lodFill = 0
  lodMeshCursor = 0
  lodQuads = 0
  lodMeshTurn = false
    ## Whose turn the horizon's frame is. Sampling a far region and handing one
    ## of its bands over are the same kind of interpreter work, and a frame that
    ## did one of each was a frame five hundred milliseconds long while the near
    ## world's were sixty. They take alternate frames instead - see `workLod`.
  nearDone = false
  ## How many times the two windows have moved, which is what a headless walk
  ## reads back to prove the world followed the player at all.
  slides = 0
  recentres = 0

  ## What the last host cast said, which is the cross-check on the walk.
  hostHit = false
  hostDistance = 0.0
  hostPoint = vec3(0.0, 0.0, 0.0)

  showNumbers = false
  note = ""
  built = 0
  generated = 0

  ## ---- the seam with whoever keeps the player -------------------------------
  ##
  ## This world knows a block broke. It does not know what an inventory is. When
  ## a mod that does keep one is loaded - `aoughwl.hud` in the survival
  ## modpack - it says so on the handoff queue before the first frame, and from
  ## then on the bag below is not used: what is dug goes to that mod, what is
  ## placed is spent there, and the hotbar this file draws is that mod's to
  ## draw. With nothing listening, everything here works exactly as it did.
  handsOff = false
  heldItem = ""
  heldCount = 0
  handoffSeen = 0

  ## Whether the mouse is this world's. It is asked of this mod and not of the
  ## host, which is a correctness fix rather than a convenience: `lockPointer()`
  ## is a request, and a host with no window - a headless run, a server, a game
  ## view nobody has focused - cannot honour it, so `pointerLocked()` comes back
  ## false and every gate built on it is shut for ever. What a mod actually
  ## wants to know is whether *it* asked for the mouse and nobody has taken it,
  ## and only the mod knows the first half. The real cursor is still locked and
  ## freed beside this; this is the answer to the question.
  captured = false
  worldInMenu = false
  someoneElseHasIt = false

  ## What is reported to whoever keeps the player's health. The rules - how far
  ## is a safe fall, how much walking costs - are not this mod's; the geometry
  ## is, because nothing else can see this body.
  wasGrounded = true
  fellFrom = 0.0
  walkedSince = 0.0
  lastAt = vec3(0.0, 0.0, 0.0)

  ## ---- F5: which of the three views this is, and what it takes -----------
  ##
  ## The camera is moved *after* `player.step()` has put the eye back on the
  ## head, every frame, so nothing here has to undo itself: the character's own
  ## `lookFrom` is the clean state this starts from. `headAt` and `headAhead`
  ## are that clean state, kept because the crosshair still fires from the
  ## player's eye once the camera has walked four metres away from it - aiming
  ## from the camera would let you mine a block behind you in front view.
  view = Inside
  headAt = vec3(0.0, 0.0, 0.0)
  headAhead = vec3(0.0, 0.0, 1.0)
  pullDistance = 0.0
  saidView = ""
  ## The model, and the two transforms it is drawn as. `bodyYaw` is where the
  ## shoulders point, which is not where the head points - see
  ## `vxview.bodyYawFor`.
  headThing = nothing()
  trunkThing = nothing()
  handThing = nothing()
  bodyYaw = 0.0
  skinPicture = ""
  ## Which limb the resolver is about to be asked for: -1 the whole body below
  ## the neck, or `HeadLimb`. Set immediately before `spawnPart`, the same way
  ## the chunk bands set theirs.
  pendingLimb = -1
  ## How far the feet have walked, ever, and how fast they are going as a
  ## fraction of a walk. The bob is a function of the first and is scaled by
  ## the second, so a player who stops mid-stride stops waving.
  bobWalked = 0.0
  bobAt = vec3(0.0, 0.0, 0.0)
  ## Where the neck is above the feet, in metres, worked out once out of the
  ## box model rather than every frame - `limbs()` builds a sequence, and a
  ## sequence a frame for one number is a sequence a frame too many.
  neckHeight = 0.0

  ## What a headless run reads back instead of a photograph.
  brokeCount = 0
  placedCount = 0
  givenCount = 0
  saidAim = ""
  saidHead = ""

const
  StateIndexFile = "Imported/blockstates.txt"
  PlayPacketsFile = "Imported/playpackets.txt"
  ItemsFile = "Imported/items.txt"
  ComponentsFile = "Imported/components.txt"
  EntityTypesFile = "Imported/entitytypes.txt"
    ## The two the *bag* needs. Missing, this joins and plays exactly as it did
    ## and only cannot read a container packet - so they are not a reason to
    ## refuse a join, which is why they are read separately from the two above.
  DefaultMcPort = 25565
  McBudget = 12000
    ## What the Minecraft client may spend of a frame, in the same units
    ## `workChunks` charges generation and meshing in. A column is
    ## `vxmcplay.ColumnCost`, so this is ten columns a frame and the rest of
    ## `FaceBudget` still goes on meshing them - which is the ordering that
    ## matters: a world that adopts faster than it meshes is a world nobody can
    ## see yet.
    ##
    ## Ten, and not the two it was, and the number has a deadline behind it
    ## rather than a preference. `step` reads packets in arrival order and stops
    ## the moment this budget is gone, so everything the server sent AFTER the
    ## columns it stopped on waits for the next frame - and `keep_alive` is one
    ## of those things. A server sends a keep alive every fifteen seconds and
    ## disconnects a client that has not answered the last one when the next
    ## falls due. At two columns a frame, the join burst of twenty-five columns
    ## is thirteen frames, and thirteen frames of a headless editor meshing a
    ## world is three quarters of a minute - so the session ended, every time,
    ## with "Timed out" in the server's log and "the server closed the
    ## connection" in ours. Ten columns a frame puts that burst inside three
    ## frames, which is inside the deadline with room to spare.

## Whether this world is somebody else's. Declared here rather than beside the
## procs that use it because `nextChunk` reads it, and `nextChunk` is where the
## generator is turned off - see `joinServer`.
var client = newClient()
var serverMode = false
var serverWanted = ""
var serverPlaced = false
var placedTeleport = -1
var serverDigging = false
  ## Whether a `dig start` is outstanding, which is this file's own question
  ## and not the client's: the client is told when one begins and when one
  ## ends, and it is this that notices the frame the button came up.
var serverHotbar = 0
  ## The hotbar cell the *server* believes is up. Kept beside `holding` rather
  ## than instead of it because they are different things: `holding` indexes
  ## this mod's own nine blocks, and this indexes the player's real inventory.
var toldVitals = ""
var serverDigFace = 1
var serverFinished = false
  ## Whether the `dig finish` for the block being dug has already gone out. See
  ## the end of `dig`: sending a second `dig start` for a block the server is
  ## already breaking resets the server's own timer, so a client whose
  ## hardness runs faster than the server's would dig forever.
  ## Which face the crosshair was on when this dig began. Remembered rather
  ## than re-derived when the block finally breaks: the player is still turning
  ## while a block is being dug, and the face read at the end is not the face
  ## the dig started on.

## ---- what a settings screen has changed ---------------------------------
##
## Every one of these is what the world is *running with* and not what somebody
## asked for, which is the whole of what makes `voxel.settings` answerable: the
## service says `ok` only where the value below has reached the thing it names,
## and a sentence saying what is missing everywhere else.
##
## They are remembered rather than pushed straight through because an options
## screen is reachable from a title menu, before `begin()` has made a world, a
## camera or a character to push anything into - and because `player.configure`
## takes a control scheme in which later entries win, so a binding set before
## it ran would be quietly thrown away by the scheme it arrived ahead of.
var
  lodRadius = LodRadius
  renderChunks = renderChunksFor(LodRadius)
    ## The distance in Minecraft's own units, said back on the debug service
    ## and in the log, because that is the number the screen shows.
  fovWanted = 0
    ## Whole degrees, and zero for "nobody has said" - a camera left with
    ## whatever field of view the host made it with.
  sensitivity = 100
  baseLookSpeed = 0.0
    ## What the control scheme tuned, taken once before anything scales it, so
    ## a hundred per cent is exactly the feel this world shipped with however
    ## the scheme changes.
  invertMouse = false
  viewBobbing = true
  autoJump = false
  bindForward = ""
  bindBack = ""
  bindLeft = ""
  bindRight = ""
  bindJump = ""
  bindSprint = ""
    ## Empty for "whatever the control scheme said".

proc say(message: string) =
  note = message
  log("[voxel] " & message)

## One fact about this mod, in the shape `expect state` reads. Said when it
## changes and not every frame, because the aim changes every time the head
## moves and a line a frame is a log nobody can read.
proc tell(name, value: string) =
  log("[assert] " & name & "=" & value)

## A value with spaces in it, as the play harness reads one. `Pick` in
## `JesterPlay.cs` takes everything up to the first space, or everything
## between a pair of double quotes - so three numbers have to arrive quoted or
## they arrive as one number.
proc cell(value: string): string = "\"" & value & "\""

## Newton's method, because how far the feet moved this frame is a length and
## there is no square root on this side of the boundary.
## Whether a click on the world is a click on the world.
proc mine(): bool = captured and not someoneElseHasIt

proc takeMouse() =
  captured = true
  lockPointer()

proc dropMouse() =
  captured = false
  freePointer()

proc squareRoot(value: float64): float64 =
  if value <= 0.0: return 0.0
  var guess = value
  var step = 0
  while step < 16:
    guess = 0.5 * (guess + value / guess)
    inc step
  guess

# ---------------------------------------------------------------------------
# The blocks other mods contribute

## The starting set. Nothing else in this mod knows these names: the palette is
## looked up by name out of the registry afterwards, exactly as another mod's
## blocks would be.
proc publishBlocks() =
  defineCatalogKind(BlockKind, "text",
    "A kind of block: what it is called, how hard it is, what colour it is, " &
    "and what breaking it gives you.")
  # The rows themselves are in `vxdefaults.nim`, which calls no host and which
  # the test can therefore read: every spec is parsed, every tile index is
  # checked against the sheet that ships beside them, and a grass block whose
  # top and sides read the same tile is a failing check rather than a thing you
  # notice in a play session.
  let names = defaultNames()
  let specs = defaultSpecs()
  let rows = catalog(Blocks, BlockKind, "The blocks this world is made of")
  var i = 0
  while i < names.len and i < specs.len:
    discard rows.put(names[i], specs[i])
    inc i

## The picture half, and the shape of the row another mod fills.
##
## A mesh has one material, so a block whose six faces are six pictures is a
## sheet with each face's texture coordinates moved into its own tile. The
## packing is `aoughwl.minecraft`'s - `mcatlas.nim` already builds exactly
## this sheet out of a block model and `Tests/minecraft_test.exe` already proves
## it - and what is declared here is the row that carries one:
##
##   `voxel.blocks.atlas`  the picture, as `useTexture` takes it: a `data:` URI,
##                         or a file inside the mod that contributed the row
##   `voxel.blocks.tiles`  `<columns>x<side>|<+X>,<-X>,<+Y>,<-Y>,<+Z>,<-Z>`
##
## A `data:` URI is the spelling that works across a mod boundary today: a file
## path is resolved against the folder of the mod that contributed the *part*,
## which is always this one, so a sheet another mod ships cannot be named from
## here. `mcatlas` already ends in `dataUri(encodePng(sheet.image))`, which is
## precisely the value this row wants.
##
## Neither facet is required. No atlas is a block painted its flat colour, which
## is what every block did before this existed.
proc publishSkins() =
  defineCatalogKind(AtlasKind, "text",
    "The sheet a block wears: a data: URI, or a file inside the mod that " &
    "contributed the row.")
  defineCatalogKind(TilesKind, "text",
    "Which tile of that sheet each of a block's six faces reads, as " &
    "<columns>x<side>|+X,-X,+Y,-Y,+Z,-Z.")
  let sheets = catalog(Blocks & AtlasFacet, AtlasKind, "Sheets for " & Blocks)
  discard catalog(Blocks & TilesFacet, TilesKind, "Face tiles for " & Blocks)
  defineCatalogKind(WearKind, "text",
    "The pictures a block wears as it is broken, in order, | separated.")
  discard catalog(Blocks & WearFacet, WearKind, "Break stages for " & Blocks)
  # Every block this mod ships names its own pictures and no sheet, and that is
  # a measured choice rather than a taste. A sheet makes a chunk one mesh, which
  # is the cheaper thing to *spawn*; but a tile in a padded sheet cannot repeat,
  # so every block face has to be its own quad, and quads cost five crossings
  # each. Whole pictures cost one more mesh per picture and let sixteen blocks
  # of flat ground be one quad. Over the same twenty frames: 45 meshes and
  # 52,009 crossings on the sheet, 72 meshes and 4,457 with pictures.
  #
  # The tiles facet is still declared, and `blocks.png` still ships, because a
  # provider that has only a sheet to give must still be able to give one -
  # `aoughwl.minecraft` builds exactly that out of a resource pack. It is
  # read by `parseSkin` and meshed the old way, one quad per face.
  let names = defaultNames()
  let rows = defaultPictures()
  var i = 0
  while i < names.len and i < rows.len:
    discard sheets.put(names[i], rows[i])
    inc i

## Every block is also an *item*, and the item identity is not this mod's to
## invent. `aoughwl.inventory` owns what an item is and `aoughwl.grid`
## owns the register of who published a catalog of them, so a block registered
## here turns up in `aoughwl.hud`'s hotbar and on its crafting bench
## without either mod naming the other. What stays here is the block-shaped
## half - hardness, solidity, what hides what - which an inventory has no
## business knowing.
##
## The rows are added as the block catalog is read, so a block another mod
## contributes becomes an item on the same frame it becomes a block.
proc publishItem(id: int) =
  let d = registry.defOf(id)
  if not d.solid: return
  defineItem(named(Items), d.name, d.label, stack = 64, tags = "block")

## Read the catalog into the registry. Called whenever it has grown, so a mod
## that loads after this one is still in the world.
## Read the block catalogs, in `budget` rows of work or in one go when `budget`
## is zero. Answers true when there is nothing left to read.
##
## **Why it is resumable at all.** Every row of it is per-block work that no
## index makes go away: `registerSpec` parses a spec string, `publishItem` is a
## host call, and `parseSkin` parses a sheet. With the twelve blocks this mod
## ships that is nothing; with a granted copy of Minecraft it is 1172 of each,
## and it all used to happen inside the one `update()` that starts the world.
## Measured through `tools/playtest.exe` on `minecraft-blocks.txt`, that call was
## 3779ms with the quadratic in it and 1785ms once the quadratic was gone - one
## frame either way, and one frame that long is a window Windows is entitled to
## grey out and call not responding.
##
## The steady path calls it with no budget and it behaves exactly as it did: it
## is only the world's first frames that spend it a slice at a time, and nothing
## reads `skins` or `materialKeys` until `beginStage` has finished with it.
proc readBlocks(budget: int): bool =
  if not readingBlocks:
    let rows = catalogCount(Blocks)
    # The facets are counted too, because a mod may dress a block somebody else
    # already registered - a resource pack over a vanilla block is exactly that -
    # and the base catalog does not grow when it does.
    let dressed = catalogCount(Blocks & AtlasFacet) +
      catalogCount(Blocks & TilesFacet) +
      catalogCount(Blocks & WearFacet)
    if rows + dressed == catalogSeen: return true
    catalogSeen = rows + dressed
    # How many rows there were when this read started, and not a count asked
    # again each frame: a catalog that grows mid-read is read to the end it had,
    # and the growth moves `catalogSeen` so the next call reads it all again.
    # A cursor against a moving end is the one way this could never finish.
    blockRows = rows
    blockRow = 0
    skinRow = 0
    readingBlocks = true
  let unlimited = budget <= 0
  var left = budget
  while blockRow < blockRows and (unlimited or left > 0):
    let id = registry.registerSpec(catalogItemId(Blocks, blockRow),
      catalogText(Blocks, blockRow), catalogItemProvider(Blocks, blockRow))
    if id >= itemsPublished:
      publishItem(id)
      itemsPublished = id + 1
    inc blockRow
    dec left
  if blockRow < blockRows: return false
  while pouch.len < registry.blockCount(): pouch.add 0
  # Each facet catalog is read ONCE and filed under the block it dresses, rather
  # than each block searching the catalog for itself.
  #
  # `Catalog.find` is a scan with a host call a row, and it does not stop early -
  # a later row of the same name wins, so it has to reach the end. "For each
  # block, find its facet row" was therefore blockCount x facetRows host calls:
  # twelve blocks is 144 and nobody noticed, a granted copy of Minecraft is 1172
  # and it is 2.7 million, which is where this mod's four-and-a-half-second first
  # frame came from. It is now one pass over each catalog and one indexed lookup
  # per row. `browser.Titles` in `aoughwl.spawner` is the same fix written
  # out at length, and `Registry.slots` is the index this leans on.
  if skinRow == 0:
    # The two facet catalogs, once, now that every block they could dress has a
    # number. One pass each, not one pass per block.
    let sheetCat = Blocks & AtlasFacet
    let tilesCat = Blocks & TilesFacet
    sheetText = @[]
    tilesText = @[]
    dressedWith = @[]
    var slot = 0
    while slot < registry.blockCount():
      sheetText.add ""
      tilesText.add ""
      dressedWith.add false
      inc slot
    var row = 0
    let sheetRows = catalogCount(sheetCat)
    while row < sheetRows:
      # A later row of the same name overwrites an earlier one, which is exactly
      # what `find` answered and what every configure() walk does: a resource
      # pack dressing a vanilla block IS a second row for a name that already
      # had one.
      let at = registry.idOf(catalogItemId(sheetCat, row))
      if at >= 0:
        sheetText[at] = catalogText(sheetCat, row)
        dressedWith[at] = true
      inc row
    row = 0
    let tilesRows = catalogCount(tilesCat)
    while row < tilesRows:
      let at = registry.idOf(catalogItemId(tilesCat, row))
      if at >= 0: tilesText[at] = catalogText(tilesCat, row)
      inc row
    skins = @[]
  # One skin per block, and `skinRow` is `skins.len`: a read that stops half way
  # leaves a `skins` that is short rather than wrong, and the only code that
  # indexes it is the mesher, which does not run until `beginStage` is past this.
  while skinRow < dressedWith.len and (unlimited or left > 0):
    if dressedWith[skinRow]:
      let skin = parseSkin(sheetText[skinRow], tilesText[skinRow])
      if skin.problem.len > 0:
        log("[voxel] " & registry.defOf(skinRow).name & ": " & skin.problem)
      skins.add skin
    else:
      skins.add plainSkin()
    inc skinRow
    dec left
  if skinRow < dressedWith.len: return false
  materialKeys = faceMaterialTable(registry, skins)
  # The crack pictures. One row dresses the world, so the fallback is the first
  # row rather than a name - see `WearFacet`. Read here rather than per block
  # because a break happens once and this catalog is one row long.
  let worn = catalogCount(Blocks & WearFacet)
  if worn > 0:
    let firstRow = catalogText(Blocks & WearFacet, 0)
    crackRow = firstRow
    crackPics = splitStages(firstRow)
  else:
    crackRow = ""
    crackPics = @[]
  # Anything solid that can be broken can be carried and put back, so the bar
  # is derived rather than written down and a contributed block appears in it.
  hotbar = @[]
  var id = 1
  while id < registry.blockCount():
    if registry.isSolid(id) and registry.breakable(id) and hotbar.len < 9:
      hotbar.add id
    inc id
  if holding >= hotbar.len: holding = 0
  # Said here, at the end, and not when the first loop finished: `voxel.blocks`
  # is what `minecraft-blocks.txt` reads to know the world has the granted copy's
  # blocks in it, and a count said while the skins were still being built would
  # be a promise the mesher could not yet keep. Said every read for the reason
  # the old comment gives: the registry grows after the world has started, an
  # importer filling this catalog a few rows at a time is exactly that, and a
  # number said once at the beginning is a number about the twelve blocks this
  # mod ships with for ever after.
  tell("voxel.blocks", $registry.blockCount())
  readingBlocks = false
  true

proc palletteOf(): Palette =
  Palette(
    stone: registry.idOf("stone"), dirt: registry.idOf("dirt"),
    grass: registry.idOf("grass"), sand: registry.idOf("sand"),
    water: registry.idOf("water"), bedrock: registry.idOf("bedrock"),
    wood: registry.idOf("wood"), leaves: registry.idOf("leaves"))

# ---------------------------------------------------------------------------
# Handing a chunk over

## The scheme. Everything it needs was decided before the spawn that called it:
## the chunk was walked once, and this reads that walk back keeping the faces of
## the one kind of block this mesh is for.
## Which of the six the quad at `at` faces, out of the normal it was emitted
## with. `faceOfQuad` says the same thing by searching the table; this is it
## written out, because it is asked once per quad in the loop below and an
## interpreted call is 2.1 microseconds.
proc faceIndexOf(at: int): int =
  let nx = pendingFaces.norm[at * 3]
  if nx > 0.5: return 0
  if nx < -0.5: return 1
  let ny = pendingFaces.norm[at * 3 + 1]
  if ny > 0.5: return 2
  if ny < -0.5: return 3
  if pendingFaces.norm[at * 3 + 2] > 0.5: return 4
  5

## There was a `materialAt` here - the material one quad wants, worked out from
## its normal and its block - and it is deliberately gone. It was the *second*
## spelling of a rule `materialSlot` already stated, and this file used it to
## re-select the quads for a material that `faceMaterialsIn` had decided some
## other way. Two spellings of one rule is a bug waiting for a Tuesday: when
## they disagreed a material reached the host with no quads in it, a mesh with
## no vertices threw, and every chunk lost its collider. `faceGroupsIn` decides
## and selects in one pass, so there is nothing left to disagree with.
## Bucket the band's quads by the mesh each belongs in, and answer which
## materials those are - `faceGroupsIn` over the geometry that is about to be
## handed across, filling in the two cursors `resolvePart` reads.
proc groupPendingFaces(): seq[string] =
  pendingAt = -1
  faceGroupsIn(pendingFaces, materialKeys, pendingOrder, pendingStart)

## The crack, as a cube a whisker larger than the block it sits on, wearing the
## stage picture on all six faces.
##
## A whisker and no more. At 1.004 the overlay stands two millimetres outside
## the block's own faces, which is enough that the depth test picks it every
## time from every angle and little enough that it does not stand proud of the
## blocks beside it.
##
## The corners come out of `vxworld.FaceCorner` rather than being written here
## as a cube. That is the winding `Tests/voxel_test.exe` recomputes the cross
## product of for all six faces, and a second spelling of it in this file would
## be a second thing to get inside-out.
##
## What makes it *an overlay* rather than a slightly larger block is the alpha
## on the colour set beside the spawn: the host switches the Standard shader's
## mode, its blend factors, its depth write and its keywords together the moment
## a colour arrives with an alpha under one
## (`Runtime/Unity/UnityApi.cs`, `Transparency`), and the stage picture is
## mostly transparent. So the cracks land on the block and the rest of the
## picture does not.
proc resolveCrack() =
  beginMesh()
  var f = 0
  while f < 6:
    var corner: array[4, int] = [0, 0, 0, 0]
    var c = 0
    while c < 4:
      corner[c] = addVertex(
        (float(FaceCorner[f][c * 3]) - 0.5) * CrackSpan,
        (float(FaceCorner[f][c * 3 + 1]) - 0.5) * CrackSpan,
        (float(FaceCorner[f][c * 3 + 2]) - 0.5) * CrackSpan,
        float(FaceNormal[f][0]), float(FaceNormal[f][1]),
        float(FaceNormal[f][2]),
        FaceUv[f][c * 2], FaceUv[f][c * 2 + 1])
      inc c
    addQuad(corner[0], corner[1], corner[2], corner[3])
    inc f
  finishMesh()
  if crackWearing.len > 0: useTexture(crackWearing)

## Every chip in the air, as one mesh of camera-facing quads.
##
## **One mesh, rebuilt every frame, and not one spawned part per chip.** That is
## the whole design decision and `vxfeel.meshFrameCost` and
## `vxfeel.partBurstCost` are the arithmetic it was made on, printed by
## `Tests/feel_test.exe`. A part each is cheaper over the burst - 399us against
## 9,849us - and spends every one of those microseconds on the single frame the
## block breaks on, which is the frame a player is already watching for a
## stutter; it also asks the host for sixteen GameObjects, sixteen meshes and
## sixteen rigid bodies at once. A mesh a frame never costs more than 235us on
## any frame and costs nothing at all on the frames there are no chips, which is
## almost all of them.
##
## `chipRight` and `chipUp` are the camera's own axes, read once a frame in
## `showChips` - a billboard is what makes a flat quad read as a particle from
## every angle, and computing the basis per chip would be sixteen times the
## trigonometry for one answer.
proc resolveChips() =
  beginMesh()
  var i = 0
  while i < moteCount(chips):
    let s = chips.size[i]
    let rx = chipRight.x * s
    let ry = chipRight.y * s
    let rz = chipRight.z * s
    let ux = chipUp.x * s
    let uy = chipUp.y * s
    let uz = chipUp.z * s
    # The chip wears a small square of the block's own picture rather than the
    # whole of it, and which square comes off the face it broke from - so a
    # burst is sixteen different pieces of one texture instead of sixteen
    # copies of it shrunk to nothing.
    let u0 = float(chips.face[i]) * 0.16
    let v0 = float(chips.face[i] mod 3) * 0.16
    let a = addVertex(chips.x[i] - rx - ux, chips.y[i] - ry - uy,
      chips.z[i] - rz - uz, -chipAhead.x, -chipAhead.y, -chipAhead.z,
      u0, v0)
    let b = addVertex(chips.x[i] + rx - ux, chips.y[i] + ry - uy,
      chips.z[i] + rz - uz, -chipAhead.x, -chipAhead.y, -chipAhead.z,
      u0 + 0.16, v0)
    let c = addVertex(chips.x[i] + rx + ux, chips.y[i] + ry + uy,
      chips.z[i] + rz + uz, -chipAhead.x, -chipAhead.y, -chipAhead.z,
      u0 + 0.16, v0 + 0.16)
    let d = addVertex(chips.x[i] - rx + ux, chips.y[i] - ry + uy,
      chips.z[i] - rz + uz, -chipAhead.x, -chipAhead.y, -chipAhead.z,
      u0, v0 + 0.16)
    addQuad(a, b, c, d)
    inc i
  finishMesh()
  if chipPicture.len > 0: useTexture(chipPicture)

## The player, as boxes.
##
## `pendingLimb` says which of the two halves is being asked for: `HeadLimb` is
## the head on its own, anything else is the five boxes below the neck. They are
## two parts rather than one because they turn independently - the body follows
## where you are walking, the head follows where you are looking - and two
## transforms is the cheapest way to say that.
##
## The head's corners come out relative to its own pivot, so turning the head
## transform turns it about the neck rather than about the feet. The other five
## are moved back onto their pivots, because they are one mesh whose origin is
## the feet.
##
## Every corner and every texture coordinate comes from `vxskin.limbQuad`, which
## `Tests/view_test.exe` checks the winding and the unwrap of. Nothing about the
## layout is spelled twice.
proc resolvePlayer() =
  let parts = limbs()
  let dressed = skinPicture.len > 0
  beginMesh()
  var limb = 0
  while limb < parts.len:
    let isHead = limb == HeadLimb
    if isHead != (pendingLimb == HeadLimb):
      inc limb
      continue
    var ox = 0.0
    var oy = 0.0
    var oz = 0.0
    if not isHead:
      ox = pivotXOf(parts[limb])
      oy = pivotYOf(parts[limb])
      oz = pivotZOf(parts[limb])
    var face = 0
    while face < 6:
      let q = limbQuad(parts[limb], face, dressed)
      var corner: array[4, int] = [0, 0, 0, 0]
      var c = 0
      while c < 4:
        # Undressed, the flat colour rides the vertex: the six boxes are one
        # mesh and a mesh wears one colour, so a player with no skin granted
        # would otherwise be one solid lozenge rather than a person.
        corner[c] = addVertex(
          q.pos[c * 3] + ox, q.pos[c * 3 + 1] + oy, q.pos[c * 3 + 2] + oz,
          q.nx, q.ny, q.nz, q.uv[c * 2], q.uv[c * 2 + 1],
          parts[limb].red, parts[limb].green, parts[limb].blue, 1.0)
        inc c
      addQuad(corner[0], corner[1], corner[2], corner[3])
      inc face
    inc limb
  finishMesh()
  if dressed: useTexture(skinPicture)

proc resolvePart() =
  # Three things spawn under this scheme now and the locator says which. The
  # chunk band is the one with a whole band of pending geometry behind it; the
  # other two are their own shapes and carry no `pending` state at all.
  let asked = partLocator()
  if asked == "crack":
    resolveCrack()
    return
  if asked == "chips":
    resolveChips()
    return
  if asked == "player":
    resolvePlayer()
    return
  # The mobs, the other players and everything flat. Answered in `vxherd`,
  # which knows which model and which limb it was asked for the same way this
  # file knows which chunk band it was asked for.
  if resolveHerd(asked): return
  beginMesh()
  var slot = pendingStart.len - 1
  if pendingAt >= 0 and pendingAt < slot: slot = pendingAt else: slot = -1
  var cursor = 0
  var stop = 0
  if slot >= 0:
    cursor = pendingStart[slot]
    stop = pendingStart[slot + 1]
  while cursor < stop:
    let f = pendingOrder[cursor]
    inc cursor
    let nx = pendingFaces.norm[f * 3]
    let ny = pendingFaces.norm[f * 3 + 1]
    let nz = pendingFaces.norm[f * 3 + 2]
    var corner: array[4, int] = [0, 0, 0, 0]
    var c = 0
    while c < 4:
      # The shading rides the vertex rather than going over as a call of its
      # own. The seam is 0.68us to cross and 0.30us an argument, so four numbers
      # on the end of a crossing that was happening anyway are 1.2us, where an
      # addColor beside it would be 1.88 - and this loop runs four times a quad,
      # thousands of quads a chunk.
      let shade = pendingFaces.ao[f * 4 + c]
      corner[c] = addVertex(
        pendingFaces.pos[f * 12 + c * 3],
        pendingFaces.pos[f * 12 + c * 3 + 1],
        pendingFaces.pos[f * 12 + c * 3 + 2],
        nx, ny, nz,
        pendingFaces.uv[f * 8 + c * 2], pendingFaces.uv[f * 8 + c * 2 + 1],
        shade, shade, shade, 1.0)
      inc c
    # A quad becomes the two triangles a fan from its first corner makes, so the
    # split runs 0-2 - and which diagonal a quad is split along is visible as
    # soon as its corners are shaded differently. A fan from corner 1 is the
    # same four corners split the other way, at no cost at all, so a quad whose
    # 1-3 pair is the brighter one is handed over rotated. Without this an
    # occluded corner smears its darkness in a band right across the face, which
    # is the seam every voxel renderer has to answer for.
    if quadFlipped(pendingFaces, f):
      addQuad(corner[1], corner[2], corner[3], corner[0])
    else:
      addQuad(corner[0], corner[1], corner[2], corner[3])
  finishMesh()
  # After the geometry, exactly as `aoughwl.minecraft` hands its own sheet
  # over. An empty one is a mesh that will be painted a flat colour instead.
  if pendingAtlas.len > 0: useTexture(pendingAtlas)

## Take away the meshes of one band of one chunk. `slice` below zero is the
## whole chunk, which is what forgetting a world wants.
proc dropMeshes(index, slice: int) =
  var i = 0
  while i < meshChunk.len:
    if meshChunk[i] == index and (slice < 0 or meshSlice[i] == slice):
      meshThing[i].destroy()
      var j = i
      while j + 1 < meshChunk.len:
        let nextChunk = meshChunk[j + 1]
        let nextSlice = meshSlice[j + 1]
        let nextThing = meshThing[j + 1]
        meshChunk[j] = nextChunk
        meshSlice[j] = nextSlice
        meshThing[j] = nextThing
        inc j
      meshChunk.setLen(meshChunk.len - 1)
      meshSlice.setLen(meshSlice.len - 1)
      meshThing.setLen(meshThing.len - 1)
    else:
      inc i

## One chunk, as one mesh per *material*. Answers how many faces it cost, which
## is what the frame budget is spent in.
##
## How many meshes that is, is not this file's decision and not the number of
## kinds of block in the chunk: it is how many distinct sheets-or-colours those
## kinds want. Every block this mod ships is packed into one sheet, so a chunk
## of them is **one mesh**; a block that arrived with a `data:` sheet of its own
## is one more. Nothing here branches on which case it is.
proc rebuildSlice(index, slice: int): int =
  result = 0
  dropMeshes(index, slice)
  world.chunks[index].dirtyMask =
    world.chunks[index].dirtyMask and (not sliceBit(slice))
  if world.chunks[index].filled == 0: return result
  let atX = float(world.chunks[index].cx * ChunkSize)
  let atY = float(world.chunks[index].cy * ChunkSize)
  let atZ = float(world.chunks[index].cz * ChunkSize)
  pendingFaces = buildChunkMerged(world, registry, skins, index,
    slice * SliceHeight, slice * SliceHeight + SliceHeight - 1)
  let wanted = groupPendingFaces()
  var k = 0
  while k < wanted.len and k < MaxKinds:
    pendingAt = k
    pendingMaterial = wanted[k]
    # The material's key says whether it is a sheet or a colour, and its own
    # first two characters are the only place that is read.
    pendingAtlas = ""
    # The first quad of the group, which the bucketing already knows: no search.
    let painted = pendingFaces.kind[pendingOrder[pendingStart[k]]]
    let paintedFace = faceIndexOf(pendingOrder[pendingStart[k]])
    # Which picture, not just which block: a mesh of grass tops wears the grass
    # top, and the mesh of that same block's sides wears the side.
    if painted >= 0 and painted < skins.len and skins[painted].textured():
      pendingAtlas = skins[painted].facePicture(paintedFace)
    let thing = spawnPart(Chunks, "chunk", atX, atY, atZ)
    if pendingAtlas.len == 0:
      let d = registry.defOf(painted)
      thing.color(Color(r: d.red, g: d.green, b: d.blue, a: 1.0))
    thing.surface(Surface(metal: 0.0, gloss: 0.12))
    meshChunk.add index
    meshSlice.add slice
    meshThing.add thing
    inc k
  result = pendingFaces.count
  pendingFaces = emptyFaces()
  pendingMaterial = ""
  pendingAtlas = ""
  pendingOrder = @[]
  pendingStart = @[]
  pendingAt = -1
  inc built

## The chunk most worth working on: the one nearest the player that either has
## not been generated or has a band waiting for a mesh. A chunk that is dirty
## but whose neighbours have not all arrived is skipped, because meshing it now
## would only mean meshing it again.
proc nextChunk(): int =
  let here = player.position()
  var best = -1
  var bestScore = 0.0
  var i = 0
  while i < world.chunks.len:
    let wants = (not serverMode and not world.chunks[i].generated) or
      (world.chunks[i].needsMesh() and meshReady(world, i))
    if wants:
      let dx = float(world.chunks[i].cx * ChunkSize + 8) - here.x
      let dy = float(world.chunks[i].cy * ChunkSize + 8) - here.y
      let dz = float(world.chunks[i].cz * ChunkSize + 8) - here.z
      var score = dx * dx + dy * dy * 4.0 + dz * dz
      # A chunk somebody just dug into jumps the queue: it is the one they are
      # looking at.
      if world.chunks[i].generated: score = score - 100000.0
      if best < 0 or score < bestScore:
        best = i
        bestScore = score
    inc i
  best

## One budget, and it is a budget of *work* rather than a count of things.
##
## The distinction is the whole difference between a world that arrives and a
## world that stutters. "One chunk a frame" is a unit, not a budget: if a chunk
## costs three hundred milliseconds then one a frame is a three hundred
## millisecond hitch, eighteen frames long, once per chunk. What the player
## needs is that no frame is long, whatever a chunk happens to cost.
##
## So every piece of work is charged what it costs and the frame stops when the
## money runs out. The prices are measured, in the same units, against
## `tools/run_mod.exe --time`:
##
##   - generating a chunk is `ChunkCost`, and it is by far the dearest thing
##     here: a hundred and thirty milliseconds of interpreter for the first
##     chunk of a stack, which is the one that pays for the noise, and less for
##     the five above it.
##   - meshing a band is `BandCost` plus its quads. The fixed part is the walk -
##     six directions over a sixteen-wide plane, which a band pays whether it
##     produces one quad or a thousand - and it is most of what a band costs
##     now that the quads are merged. Charging only the quads, which is what
##     this did when a quad was a block face, let a frame take three fat bands
##     at once and those were the six-hundred-millisecond frames.
##
## `FaceBudget` is therefore a spend per frame, and turning it down makes the
## world arrive more slowly and more smoothly. It is deliberately small enough
## that one expensive thing ends the frame on its own.
proc workChunks(budget: int) =
  var spent = 0
  while spent < budget:
    let index = nextChunk()
    if index < 0:
      nearDone = true
      return
    if not serverMode and not world.chunks[index].generated:
      world.generateChunk(registry, index)
      inc generated
      spent = spent + ChunkCost
      log("[assert] voxel.chunks=" & $generated)
    if world.chunks[index].needsMesh() and meshReady(world, index):
      let slice = firstDirtySlice(world.chunks[index])
      if slice >= 0:
        spent = spent + BandCost + rebuildSlice(index, slice)
    spent = spent + 40

## One band of one far region, handed over exactly the way a chunk's band is:
## `buildLodFaces` produces the same `Faces` a chunk does, so this is
## `rebuildSlice` with the geometry coming from the heightmap instead of from
## blocks, and `resolvePart` cannot tell the difference.
proc spawnLodBand(index, band: int) =
  let atX = float(lodScene.fields[index].rx * LodRegion)
  let atZ = float(lodScene.fields[index].rz * LodRegion)
  let rows = lodBandRows(lodScene, index)
  pendingFaces = buildLodFaces(lodScene, world, skins, index,
    band * rows, band * rows + rows - 1)
  lodQuads = lodQuads + pendingFaces.count
  let wanted = groupPendingFaces()
  var k = 0
  while k < wanted.len and k < MaxKinds:
    pendingAt = k
    pendingMaterial = wanted[k]
    pendingAtlas = ""
    let painted = pendingFaces.kind[pendingOrder[pendingStart[k]]]
    let paintedFace = faceIndexOf(pendingOrder[pendingStart[k]])
    # Which picture, not just which block: a mesh of grass tops wears the grass
    # top, and the mesh of that same block's sides wears the side.
    if painted >= 0 and painted < skins.len and skins[painted].textured():
      pendingAtlas = skins[painted].facePicture(paintedFace)
    let thing = spawnPart(Chunks, "chunk", atX, 0.0, atZ)
    if pendingAtlas.len == 0:
      let d = registry.defOf(painted)
      thing.color(Color(r: d.red, g: d.green, b: d.blue, a: 1.0))
    thing.surface(Surface(metal: 0.0, gloss: 0.12))
    lodThing.add thing
    lodRegionX.add lodScene.fields[index].rx
    lodRegionZ.add lodScene.fields[index].rz
    inc k
  pendingFaces = emptyFaces()
  pendingMaterial = ""
  pendingAtlas = ""
  pendingOrder = @[]
  pendingStart = @[]
  pendingAt = -1

## Take away everything the horizon has drawn of one region, and forget that it
## was drawn. `dropMeshes` for the far side, and swept the same way and for the
## same reason: a few hundred rows, and one region's worth of them at a time.
##
## Destroying the entity is what actually gives the memory back - it takes its
## Mesh and its Material with it - and this path is the difference between a
## world that is a diorama and one you can walk across: the fixed world called
## it never and a streaming one calls it thousands of times.
proc dropLodRegion(rx, rz: int) =
  var i = 0
  while i < lodThing.len:
    if lodRegionX[i] == rx and lodRegionZ[i] == rz:
      lodThing[i].destroy()
      var j = i
      while j + 1 < lodThing.len:
        let nextThing = lodThing[j + 1]
        let nextX = lodRegionX[j + 1]
        let nextZ = lodRegionZ[j + 1]
        lodThing[j] = nextThing
        lodRegionX[j] = nextX
        lodRegionZ[j] = nextZ
        inc j
      lodThing.setLen(lodThing.len - 1)
      lodRegionX.setLen(lodRegionX.len - 1)
      lodRegionZ.setLen(lodRegionZ.len - 1)
    else:
      inc i
  let slot = lodScene.slotAt(rx, rz)
  if slot >= 0 and slot < lodDone.len: lodDone[slot] = 0

## The horizon, a slice of a frame at a time. Two cursors over the same
## nearest-first order: one sampling the far ground, one handing the meshes that
## draw it over.
##
## **A frame does one of the two, not both.** Sampling a row and meshing a band
## are the same kind of interpreter work in the same interpreter, and a frame
## that did one of each was three to five hundred milliseconds long while the
## near world's frames were sixty. So they take alternate frames. Alternate
## rather than in sequence: sampling everything first and then meshing
## everything would be smooth too, but it would leave the whole horizon invisible
## until the last region had been walked, and take a third again as many frames
## to finish. `lodMeshTurn` is which of the two this frame belongs to, and
## whichever side has run out gives its turns to the other - so the last of the
## sampling and the last of the meshing both get every frame.
##
## A region is not handed over until it and its four neighbours are sampled,
## which is `meshReady` one layer up: a region meshed early would stitch its
## edge down to the floor of the world and hang a cliff there. Since sampling
## runs nearest-first and finishes, waiting cannot deadlock.
proc workLod(budget: int) =
  var spent = 0
  lodMeshTurn = not lodMeshTurn
  if not lodMeshTurn:
    while lodFill < lodScene.order.len and spent < budget:
      let index = lodScene.order[lodFill]
      let span = lodScene.fields[index].span
      let row = lodScene.fields[index].rows
      if row >= span:
        inc lodFill
        continue
      spent = spent + sampleRows(world, lodScene.fields[index], row, row)
  # `spent` above zero means this frame sampled, and that is a whole frame's
  # work. Zero means either it was the meshing's turn or there is nothing left
  # to sample, and in both cases the band below is what this frame is for.
  if spent == 0 and lodMeshCursor < lodScene.order.len:
    let index = lodScene.order[lodMeshCursor]
    if lodReady(lodScene, index):
      let band = lodDone[index]
      if band < lodBands(lodScene, index):
        spawnLodBand(index, band)
        lodDone[index] = band + 1
      if lodDone[index] >= lodBands(lodScene, index):
        inc lodMeshCursor
        if lodMeshCursor >= lodScene.order.len:
          tell("voxel.lod.regions", $lodScene.order.len)
          tell("voxel.lod.cells", $lodCells(lodScene))
          tell("voxel.lod.quads", $lodQuads)
          tell("voxel.lod.parts", $lodThing.len)
          tell("voxel.lod.blocks", $lodBlocksWide(lodScene))

## The far regions, and everything already sampled about them, thrown away.
##
## The centre is a parameter because this is also how the horizon is resized:
## a new world starts at the origin, and a render distance changed mid-walk has
## to come back round the player rather than round where the world began.
proc forgetLod(cRx = 0; cRz = 0) =
  while lodThing.len > 0:
    lodThing[lodThing.len - 1].destroy()
    lodThing.setLen(lodThing.len - 1)
  lodRegionX = @[]
  lodRegionZ = @[]
  lodScene = newLodScene(lodRadius, cRx, cRz, LodNearLevel)
  lodDone = @[]
  var i = 0
  while i < lodScene.fields.len:
    lodDone.add 0
    inc i
  lodFill = 0
  lodMeshCursor = 0
  lodQuads = 0
  lodMeshTurn = false
  nearDone = false

proc forgetWorld() =
  forgetLod()
  while meshChunk.len > 0:
    meshThing[meshChunk.len - 1].destroy()
    meshChunk.setLen(meshChunk.len - 1)
    meshSlice.setLen(meshSlice.len - 1)
    meshThing.setLen(meshThing.len - 1)
  while dropThing.len > 0:
    dropThing[dropThing.len - 1].destroy()
    dropThing.setLen(dropThing.len - 1)
    dropBlock.setLen(dropBlock.len - 1)
    dropAge.setLen(dropAge.len - 1)

## Move the world under the player, if they have gone far enough to have earned
## it. Everything that decides *whether* and *where* is in `vxstream` and calls
## no host; this is the part that can only be done here - taking meshes away and
## letting the two work loops put them back.
##
## The two windows move at their own rates and do not wait for each other. The
## near one slides a chunk when the player is `NearSlack` blocks off its middle,
## which is every sixteen blocks of walking; the far one re-centres a region
## when they leave the middle region by `LodSlack`, which is every forty-eight.
## What lets them disagree is that the horizon skips whatever cells the blocks
## are standing on this frame rather than being told which region that is.
##
## Both work by taking geometry away and resetting a cursor. Nothing is built
## here: `workChunks` and `workLod` already spend a measured budget per frame
## nearest-the-player-first, and putting a slide's worth of generation in one
## frame is exactly the six-hundred-millisecond hitch those budgets exist to
## prevent. So a slide costs this frame a few destroys and the *next* several
## frames their ordinary budget.
proc streamWorld() =
  let here = player.position()
  let px = floorInt(here.x)
  let pz = floorInt(here.z)

  # -- the real blocks -----------------------------------------------------
  let toCx = nextOriginX(world, px)
  let toCz = nextOriginZ(world, pz)
  if toCx != world.originCx or toCz != world.originCz:
    let wasX0 = world.worldX0()
    let wasZ0 = world.worldZ0()
    let retired = slideWorld(world, toCx, toCz)
    var i = 0
    while i < retired.len:
      dropMeshes(retired[i], -1)
      inc i
    inc slides
    tell("voxel.stream.slides", $slides)
    tell("voxel.stream.origin", $world.originCx & "," & $world.originCz)
    tell("voxel.stream.chunks", $world.chunks.len)
    # The horizon has to draw the ground the near window just let go of, and
    # stop drawing the ground it just took. Both are the same question - which
    # regions overlap where the window was or is - and the box is grown by a
    # block so the regions that merely *stitch* to it are caught too: their
    # walls are dropped to the lowest ground across the edge, and that ground
    # just changed from a cell to a column of blocks or back.
    var lowX = wasX0
    if world.worldX0() < lowX: lowX = world.worldX0()
    var lowZ = wasZ0
    if world.worldZ0() < lowZ: lowZ = world.worldZ0()
    var highX = wasX0 + world.blocksWide()
    if world.worldX0() + world.blocksWide() > highX:
      highX = world.worldX0() + world.blocksWide()
    var highZ = wasZ0 + world.blocksDeep()
    if world.worldZ0() + world.blocksDeep() > highZ:
      highZ = world.worldZ0() + world.blocksDeep()
    let touched = lodTouchedByNear(lodScene, lowX - 1, lowZ - 1,
      highX + 1, highZ + 1)
    var k = 0
    while k < touched.len:
      dropLodRegion(touched[k].rx, touched[k].rz)
      inc k
    # Nearest first, and the regions that just lost their geometry are the
    # nearest there are, so the hole closes before anything further out is
    # touched. That is the whole of the priority scheme and it costs a cursor.
    lodMeshCursor = 0

  # -- the horizon ---------------------------------------------------------
  let cRx = nextCentre(lodScene.centreRx, px)
  let cRz = nextCentre(lodScene.centreRz, pz)
  if cRx != lodScene.centreRx or cRz != lodScene.centreRz:
    let stale = retargetLod(lodScene, lodDone, cRx, cRz, LodNearLevel)
    var k = 0
    while k < stale.len:
      dropLodRegion(stale[k].rx, stale[k].rz)
      inc k
    lodFill = 0
    lodMeshCursor = 0
    inc recentres
    tell("voxel.stream.recentres", $recentres)
    tell("voxel.stream.centre", $lodScene.centreRx & "," & $lodScene.centreRz)
    tell("voxel.stream.restitched", $stale.len)

# ---------------------------------------------------------------------------
# Digging and building

proc emitDrop(id: int; x, y, z: int) =
  let what = registry.dropOf(id)
  if what == AirId: return
  let thing = spawnPart(Drops, "nugget", float(x) + 0.5, float(y) + 0.5,
    float(z) + 0.5)
  thing.scale(0.28)
  let d = registry.defOf(what)
  thing.color(Color(r: d.red, g: d.green, b: d.blue, a: 1.0))
  thing.physics(0.4)
  thing.push(vec3(0.0, 2.2, 0.0))
  dropThing.add thing
  dropBlock.add what
  dropAge.add 0.0

proc takeDrop(at: int) =
  dropThing[at].destroy()
  var j = at
  while j + 1 < dropThing.len:
    let nextThing = dropThing[j + 1]
    let nextBlock = dropBlock[j + 1]
    let nextAge = dropAge[j + 1]
    dropThing[j] = nextThing
    dropBlock[j] = nextBlock
    dropAge[j] = nextAge
    inc j
  dropThing.setLen(dropThing.len - 1)
  dropBlock.setLen(dropBlock.len - 1)
  dropAge.setLen(dropAge.len - 1)

proc gatherDrops(seconds: float64) =
  let here = player.position()
  var i = 0
  while i < dropThing.len:
    dropAge[i] = dropAge[i] + seconds
    let at = dropThing[i].position()
    let dx = at.x - here.x
    let dy = at.y - (here.y + 0.9)
    let dz = at.z - here.z
    if dx * dx + dy * dy + dz * dz < DropReach * DropReach:
      let what = dropBlock[i]
      # The line that closes the loop. Whoever keeps the player's bag is handed
      # the item; when nobody does, this world keeps it in the pouch below.
      # This is the call that becomes a service call when there is one.
      handOver("give", registry.defOf(what).name, 1)
      givenCount = givenCount + 1
      tell("voxel.gave", registry.defOf(what).name)
      tell("voxel.given", $givenCount)
      if handsOff:
        say("picked up " & registry.defOf(what).label)
      else:
        pouch[what] = pouch[what] + 1
        say("picked up " & registry.defOf(what).label & " (" & $pouch[what] & ")")
      takeDrop(i)
    elif dropAge[i] > DropLife:
      takeDrop(i)
    else:
      inc i

## Which picture one face of one block wears, or "" for a block that is painted
## a flat colour instead. The chips and the block they came off have to agree
## about this, so it is asked in one place rather than worked out twice.
proc pictureOfFace(id, face: int): string =
  if id < 0 or id >= skins.len: return ""
  if not skins[id].textured(): return ""
  skins[id].facePicture(face)

proc stopDigging() =
  # The server is told the moment the button comes up, and only then: it is
  # running its own break timer from the `dig start` and a client that walks
  # away without saying so leaves it running. Guarded on `serverDigging` rather
  # than on `digging`, because this is called on every frame nothing is being
  # dug and a `dig cancel` a frame would be a packet a frame.
  if serverMode and serverDigging:
    serverDigging = false
    digCancelAt(client)
  digging = false
  digProgress = 0.0

## Which of Minecraft's six faces an outward normal is. Written out rather than
## reached for through `faceOfOffset`, which is this mod's own texture ordering
## and a different set of numbers entirely - and a dig sent with the wrong face
## is not refused, it is applied to the wrong side, which reads as a bug in the
## ray walk rather than as a bug here.
proc mcFaceOf(nx, ny, nz: int): int =
  if ny < 0: return FaceDown
  if ny > 0: return FaceUp
  if nz < 0: return FaceNorth
  if nz > 0: return FaceSouth
  if nx < 0: return FaceWest
  if nx > 0: return FaceEast
  FaceUp

proc breakBlock(x, y, z: int) =
  let id = world.blockAt(x, y, z)
  if not registry.breakable(id): return
  # Somebody else's world: say so and wait. Nothing is removed here - the
  # server decides whether that block goes, and when it does it says so with a
  # `block_update`, which is the one path in this mod that changes a server
  # world's blocks. See the head of the "Doing things" section in `vxmcplay`.
  if serverMode:
    serverDigging = false
    digFinishAt(client, x, y, z, serverDigFace)
    chipPicture = pictureOfFace(id, 2)
    burstMotes(chips, float(x) + 0.5, float(y) + 0.5, float(z) + 0.5, id,
      BurstMotes)
    tell("voxel.chipped", $chips.made)
    # And **nothing else**. Not `stopDigging`, which would send a `dig cancel`
    # over the finish that has just gone out, and not the beat - which gates
    # `dig` itself, so resetting it would take this mod out of the loop for a
    # quarter of a second and `stopDigging` would run in the branch that does
    # the gating. The dig stays open on this client's side until the server
    # answers with the block, which is the only thing that moves the crosshair
    # off it.
    return
  # The chips first, while the block is still in the world to be asked what it
  # looks like. `burstMotes` throws what fits and no more: the cap is a cap on
  # the frame, so a block broken on top of a burst still in the air shortens
  # the second burst rather than going over the budget.
  chipPicture = pictureOfFace(id, 2)
  burstMotes(chips, float(x) + 0.5, float(y) + 0.5, float(z) + 0.5, id,
    BurstMotes)
  # How many chips have ever been made. It only goes up, so it is what a
  # headless run can assert the burst by: the chips themselves are gone seven
  # tenths of a second later and nothing that reads a state afterwards would
  # ever see one.
  tell("voxel.chipped", $chips.made)
  discard world.setBlockAt(x, y, z, AirId)
  emitDrop(id, x, y, z)
  brokeCount = brokeCount + 1
  say("broke " & registry.defOf(id).label)
  tell("voxel.broke", $brokeCount)
  # The beat. Without it a held button walks a tunnel at a block a frame the
  # moment two soft blocks are in a line: the hardness timer restarts at zero
  # on a new block, and zero is already enough for dirt.
  sinceBreak = 0.0
  stopDigging()

## Where the player's own capsule is, as a box, so a placement cannot be made
## inside them. The host would let it: a `CharacterController` is pushed out of
## a collider that appears around it, or wedged in it.
proc wouldTrapPlayer(x, y, z: int): bool =
  let here = player.position()
  let minX = floorInt(here.x - player.radius)
  let maxX = floorInt(here.x + player.radius)
  let minZ = floorInt(here.z - player.radius)
  let maxZ = floorInt(here.z + player.radius)
  let minY = floorInt(here.y)
  let maxY = floorInt(here.y + player.height - 0.01)
  x >= minX and x <= maxX and y >= minY and y <= maxY and z >= minZ and z <= maxZ

## What the right button puts down. Which block that is comes from the hand -
## this mod's own when nothing else keeps one, and whatever the other mod last
## said is in it when something does. The mirror of the count is optimistic by
## a frame on purpose: the authority is over there, and a placement that turns
## out to have been the last one is corrected by the next `hold` that arrives.
proc putBlock() =
  if not aimed.found: return
  # Somebody else's world again, and the same rule: the block that goes down is
  # whatever the *server* thinks is in the player's hand, so there is nothing
  # here to look up and nothing here to spend. It arrives as a `block_update`
  # if the server agrees and as silence if it does not - an empty hand, a
  # protected region, a cell it will not accept - and silence is the correct
  # outcome rather than a block this client alone can see.
  if serverMode:
    placeAt(client, aimed.x, aimed.y, aimed.z,
            mcFaceOf(aimed.nx, aimed.ny, aimed.nz))
    sincePlace = 0.0
    let what0 = heldName(client)
    say(if what0.len > 0: "placing " & what0 else: "nothing in hand")
    return
  var what = AirId
  if handsOff:
    if heldCount <= 0:
      say("nothing in hand")
      return
    what = registry.idOf(heldItem)
    if what == AirId or not registry.isSolid(what):
      say("you cannot build with " & heldItem)
      return
  else:
    if hotbar.len == 0: return
    what = hotbar[holding]
    if pouch[what] <= 0:
      say("no " & registry.defOf(what).label & " left")
      return
  if not world.inWorld(aimed.placeX, aimed.placeY, aimed.placeZ):
    say("that is the edge of the world")
    return
  let there = world.blockAt(aimed.placeX, aimed.placeY, aimed.placeZ)
  if registry.isSolid(there):
    return
  if wouldTrapPlayer(aimed.placeX, aimed.placeY, aimed.placeZ):
    say("you are standing there")
    return
  if world.setBlockAt(aimed.placeX, aimed.placeY, aimed.placeZ, what):
    if handsOff:
      heldCount = heldCount - 1
      handOver("spend", heldItem, 1)
    else:
      pouch[what] = pouch[what] - 1
    placedCount = placedCount + 1
    say("placed " & registry.defOf(what).label)
    tell("voxel.placed", $placedCount)
    chipPicture = pictureOfFace(what, 2)
    puffMotes(chips, float(aimed.placeX) + 0.5, float(aimed.placeY) + 0.5,
      float(aimed.placeZ) + 0.5, what, PuffMotes)
    puffs = puffs + 1
    tell("voxel.puffed", $puffs)
    tell("voxel.chipped", $chips.made)
    sincePlace = 0.0

# ---------------------------------------------------------------------------
# What the crosshair is on

## The walk decides, and the host's own cast is asked beside it. They answer
## different questions - the walk knows which *block* and which face, the cast
## knows whether something that is not the world is in the way - and a thing
## the cast found closer than the block is a thing between the player and it.
# ---------------------------------------------------------------------------
# F5: the three views, and the player you can only see in two of them
#
# The state machine, the camera offset, the collision shortening, the
# head-and-body split and the walking bob are all in `vxview.nim` and the box
# model is in `vxskin.nim`, because none of the five needs a host and all five
# are the kind of arithmetic that is wrong by a little rather than wrong
# outright. `Tests/view_test.exe` settles them. What is left here is the part
# that has to touch entities: reading the catalogs, spawning two meshes, and
# putting five transforms where the arithmetic said.

## A collider on something the player is standing inside is a player who cannot
## move. Every mesh a part spawns arrives with a MeshCollider on it, so the
## player's own model - which is by definition wherever the player is - has to
## have its turned off the moment it exists.
proc unblock(thing: Entity) =
  if thing.isNothing(): return
  let hull = thing.component("UnityEngine.MeshCollider, UnityEngine.PhysicsModule")
  if not hull.isNothing(): hull.set("enabled", false)

## Whose picture the player wears. Nothing in this repository fills this in; a
## mod that has read the player's own copy of Minecraft does. Read every frame
## the model is rebuilt rather than once, so a grant that finishes after the
## world has started still dresses the player.
proc readSkin(): bool =
  var picture = ""
  if catalogCount(Skins) > 0: picture = catalogText(Skins, 0)
  if picture == skinPicture: return false
  skinPicture = picture
  true

proc dropPlayerModel() =
  if not headThing.isNothing():
    headThing.destroy()
    headThing = nothing()
  if not trunkThing.isNothing():
    trunkThing.destroy()
    trunkThing = nothing()

proc buildPlayerModel() =
  dropPlayerModel()
  let here = player.position()
  pendingLimb = -1
  trunkThing = spawnPart(Bodies, "body", here.x, here.y, here.z)
  pendingLimb = HeadLimb
  headThing = spawnPart(Bodies, "head", here.x, here.y, here.z)
  pendingLimb = -1
  unblock(trunkThing)
  unblock(headThing)
  # Hidden until somebody presses F5. A model standing where the camera is, in
  # first person, is the inside of your own head.
  trunkThing.active(false)
  headThing.active(false)

proc buildHand() =
  handThing = shape(Cube, "Hand")
  handThing.scale(HandSize)
  let box = handThing.component("UnityEngine.BoxCollider, UnityEngine.PhysicsModule")
  if not box.isNothing(): box.set("enabled", false)
  handThing.active(false)

## Where the camera goes this frame.
##
## Called straight after `player.step()`, which has just put the eye back on the
## head and turned it to where the head is looking. That is the clean state
## everything here is derived from, and it is why nothing here has to undo what
## it did last frame.
##
## The two things worth saying out loud:
##
##   * `headAt` and `headAhead` are kept, because the crosshair fires from the
##     *player's eye* and not from the camera. Aiming from a camera that is four
##     metres in front of you looking back would let you mine the block behind
##     your own head.
##   * `pullDistance` is what `vxview.pullBack` allowed, not what was asked for.
##     Everything after it - the camera, the state that is told, the numbers on
##     the debug panel - reads the allowed distance, so there is one answer to
##     "how far back is the camera" and not two.
proc driveCamera() =
  headAt = eye.position()
  headAhead = eye.forward().norm()
  pullDistance = pullBack(world, registry, headAt.x, headAt.y, headAt.z,
    headAhead.x, headAhead.y, headAhead.z, view)
  let seat = cameraPlacement(view, headAt.x, headAt.y, headAt.z,
    headAhead.x, headAhead.y, headAhead.z, player.pitch, player.yaw,
    pullDistance)
  eye.position(vec3(seat.x, seat.y, seat.z))
  eye.rotation(seat.pitch, seat.yaw, 0.0)

## The model, and the hand, each in exactly one of the two states that has one.
##
## The body follows the way the feet are actually travelling rather than the way
## the keys are pressed, which is what makes strafing read as strafing; standing
## still it keeps the way it was pointing until the head drags it round.
proc showPlayer(seconds: float64) =
  let here = player.position()
  let speed = player.speed()
  let flat = squareRoot(speed.x * speed.x + speed.z * speed.z)
  var pace = 0.0
  if player.walkSpeed > 0.0: pace = flat / player.walkSpeed
  if pace > 1.0: pace = 1.0
  # How far the feet have gone, for the bob. Measured off the transform rather
  # than integrated from the speed, so a player walking into a wall does not bob
  # on the spot.
  let stepX = here.x - bobAt.x
  let stepZ = here.z - bobAt.z
  bobWalked = bobWalked + squareRoot(stepX * stepX + stepZ * stepZ)
  bobAt = here

  # Where the shoulders point. A body that is barely moving is not walking
  # anywhere in particular, and taking a direction off a metre a second of
  # sliding would spin it.
  var moving = false
  var moveYaw = bodyYaw
  if flat > 0.35:
    moving = true
    # In the head's own frame: how much of the velocity is along the way the
    # head points, and how much across it. The body only ever yaws, so its
    # forward is already flat and unit length and its right is that turned a
    # quarter - the same two the character's own step() walks by.
    let facingX = player.body.forwardX()
    let facingZ = player.body.forwardZ()
    let along = speed.x * facingX + speed.z * facingZ
    let across = speed.x * facingZ - speed.z * facingX
    moveYaw = wrapAngle(player.yaw + walkYawFor(along, across))
  bodyYaw = bodyYawFor(bodyYaw, player.yaw, moveYaw, moving,
    seconds * BodyTurnRate)

  let seen = drawsPlayer(view)
  if not trunkThing.isNothing():
    trunkThing.active(seen)
    if seen:
      trunkThing.position(here)
      trunkThing.rotation(0.0, bodyYaw, 0.0)
  if not headThing.isNothing():
    headThing.active(seen)
    if seen:
      # The neck is on the model's own axis, so where it is does not depend on
      # which way the body is pointing.
      headThing.position(vec3(here.x, here.y + neckHeight, here.z))
      headThing.rotation(player.pitch, player.yaw, 0.0)

  if handThing.isNothing(): return
  let holds = drawsHand(view)
  handThing.active(holds)
  if not holds: return
  # The bob is scaled by how fast you are going and by nothing else, so a pace
  # of nothing is the resting hand exactly - which is what "no view bobbing"
  # means, rather than a smaller bob. See `vxview.handAt`.
  var bobPace = pace
  if not viewBobbing: bobPace = 0.0
  let hand = handAt(view, bobWalked, bobPace)
  # The camera's own three directions, worked out the same way the chips'
  # billboard basis is. The hand rides the camera and not the head, which is the
  # same thing in the one view that has a hand and would not be if that changed.
  let seat = eye.position()
  let ahead = eye.forward().norm()
  var side = cross(vec3(0.0, 1.0, 0.0), ahead)
  if side.x * side.x + side.y * side.y + side.z * side.z < 0.0001:
    side = vec3(1.0, 0.0, 0.0)
  let right = side.norm()
  let up = cross(ahead, right).norm()
  handThing.position(seat + right * hand.right + up * hand.up +
    ahead * hand.ahead)
  handThing.rotation(player.pitch, player.yaw, hand.roll)
  var tint = Color(r: 0.7, g: 0.7, b: 0.7, a: 1.0)
  if hotbar.len > 0 and holding >= 0 and holding < hotbar.len:
    let d = registry.defOf(hotbar[holding])
    tint = Color(r: d.red, g: d.green, b: d.blue, a: 1.0)
  handThing.color(tint)

## Which view this is, and how far back the camera actually got, in the shape
## `expect state` reads. Both, because the first without the second cannot tell
## "the camera went behind you" from "the camera tried and a wall stopped it".
proc tellView() =
  let said = perspectiveName(view) & "/" & $int(pullDistance * 10.0)
  if said == saidView: return
  saidView = said
  tell("voxel.view", perspectiveName(view))
  tell("voxel.viewback", $int(pullDistance * 10.0))

proc takeAim() =
  let from0 = headAt
  let ahead = headAhead
  aimed = traceWorld(world, registry, from0.x, from0.y, from0.z,
    ahead.x, ahead.y, ahead.z, Reach)
  # The host's own cast is fired from the camera and is only a cross-check on
  # the walk, so it is only asked for while the camera *is* the eye. In third
  # person it would be a ray from four metres behind the player, and every one
  # of its answers - including the player's own model, which is now in the way -
  # would be about a different line than the crosshair's.
  hostHit = false
  if view == Inside: hostHit = eye.aim(Reach)
  hostDistance = 0.0
  if hostHit:
    hostDistance = aimDistance()
    hostPoint = vec3(aimX(), aimY(), aimZ())
    # Something the host found nearer than the block, and that is not one of
    # this mod's chunk meshes, is between the player and the world.
    if aimed.found and hostDistance < aimed.distance - 0.05:
      let target = aimTarget()
      var isChunk = false
      var i = 0
      while i < meshThing.len:
        if meshThing[i].isSame(target): isChunk = true
        inc i
      if not isChunk and not target.isNothing(): aimed = noPick()

proc showHighlight() =
  if highlight.isNothing(): return
  if not aimed.found:
    highlight.active(false)
    return
  highlight.active(true)
  highlight.position(vec3(float(aimed.x) + 0.5, float(aimed.y) + 0.5,
    float(aimed.z) + 0.5))
  var glow = 0.0
  if digging and digNeeded > 0.0: glow = digProgress / digNeeded
  if glow > 1.0: glow = 1.0
  highlight.color(Color(r: glow, g: glow * 0.9, b: glow * 0.6,
    a: 0.22 + glow * 0.4))

## The crack on the block being mined, growing through the ten pictures the
## catalog gave us.
##
## The overlay is a mesh and a mesh cannot be re-textured where it stands, so a
## change of stage is a destroy and a spawn. `crackShown` is remembered for
## exactly that reason: it turns sixty spawns a second into nine over a whole
## block, and nine is how often the picture actually changes.
proc showCrack() =
  var stage = -1
  if digging and aimed.found and digX == aimed.x and digY == aimed.y and
      digZ == aimed.z:
    stage = crackStage(digProgress, digNeeded)
  # **The stage is said whether or not anything has dressed this world.** It is
  # a fact about the hardness timer and not about a picture, and separating the
  # two is what lets a modpack with no Minecraft granted to it still prove that
  # mining advances - which is what
  # `Assets/Editor/PlayScripts/survival-loop.txt` asserts. Only the overlay
  # below needs pictures, and a world without them keeps the highlight it
  # always had, exactly as every block did before this existed.
  if stage != crackShown:
    crackShown = stage
    if stage < 0: tell("voxel.crack", "none")
    else: tell("voxel.crack", $stage)
    if stage > crackTop:
      crackTop = stage
      tell("voxel.cracked", $crackTop)
  # The overlay is a mesh and a mesh cannot be re-textured where it stands, so
  # a change of stage is a destroy and a spawn. `crackWorn` is remembered for
  # exactly that reason: it turns sixty spawns a second into nine over a whole
  # block, and nine is how often the picture actually changes.
  var wanted = stage
  if crackPics.len == 0: wanted = -1
  if wanted == crackWorn:
    if wanted >= 0 and not crackThing.isNothing():
      crackThing.position(vec3(float(digX) + 0.5, float(digY) + 0.5,
        float(digZ) + 0.5))
    return
  crackWorn = wanted
  if not crackThing.isNothing():
    crackThing.destroy()
    crackThing = nothing()
  if wanted < 0: return
  crackWearing = crackPicture(crackPics, wanted)
  crackThing = spawnPart(Cracks, "crack", float(digX) + 0.5,
    float(digY) + 0.5, float(digZ) + 0.5)
  # The alpha is the whole of the request. The host reads `a < 1` and switches
  # the Standard shader's mode, its blend factors, its depth write and its
  # keywords together (`Runtime/Unity/UnityApi.cs`, `Transparency`); the stage
  # picture's own transparency then decides which pixels are cracks.
  crackThing.color(Color(r: 1.0, g: 1.0, b: 1.0, a: 0.999))

## Every chip in the air, as one mesh of camera-facing quads, rebuilt this
## frame and thrown away the next.
##
## Nothing is spawned at all on a frame with no chips on it, which is almost
## every frame; `Tests/feel_test.exe` prints what the frames that do cost, and
## what the design this is not - a spawned part per chip - would have cost on
## the one frame the block breaks.
proc showChips() =
  if moteCount(chips) == 0:
    if not chipThing.isNothing():
      chipThing.destroy()
      chipThing = nothing()
      chipsSaid = 0
      tell("voxel.chips", "0")
    return
  # The camera's own axes, once for the whole field. A flat quad that does not
  # turn to face you is a quad you can lose by walking round it, and sixteen
  # chips want one basis rather than sixteen.
  let ahead = eye.forward().norm()
  chipAhead = ahead
  var side = cross(ahead, vec3(0.0, 1.0, 0.0))
  if side.x * side.x + side.y * side.y + side.z * side.z < 0.0001:
    side = vec3(1.0, 0.0, 0.0)
  let sideways = side.norm()
  chipRight = sideways
  chipUp = cross(sideways, ahead).norm()
  if not chipThing.isNothing(): chipThing.destroy()
  chipThing = spawnPart(Chips, "chips", 0.0, 0.0, 0.0)
  chipThing.surface(Surface(metal: 0.0, gloss: 0.0))
  if moteCount(chips) != chipsSaid:
    chipsSaid = moteCount(chips)
    tell("voxel.chips", $chipsSaid)

## What the crosshair is on, in words, for a run with no screen to look at.
## Said when it changes, which is what keeps a per-frame fact out of the log.
proc tellAim() =
  var label = "none"
  if aimed.found: label = registry.defOf(world.blockAt(aimed.x, aimed.y, aimed.z)).label
  if label != saidAim:
    saidAim = label
    tell("voxel.aim", label)
  # Where the head is pointing and whether the pointer is held, said the same
  # way. Without these a run that aims at nothing cannot tell "the crosshair is
  # on the sky" from "nothing in this modpack reads mouse movement".
  let head = $mine() & "/" & $int(player.pitch) & "/" & $int(player.yaw)
  if head == saidHead: return
  saidHead = head
  tell("voxel.locked", $mine())
  tell("voxel.pitch", $int(player.pitch))
  tell("voxel.yaw", $int(player.yaw))

## The two things about this body that only this mod can see, handed to whoever
## keeps the player's health. The rules stay over there - what a safe fall is
## and what walking costs are that mod's numbers - and these are the
## measurements they are applied to. Both are events rather than a per-frame
## reading, because the channel between two mods is an append-only queue: a
## landing is one row, and four metres of walking is one row.
proc reportBody() =
  if not handsOff: return
  let here = player.position()
  let onGround = player.body.grounded()
  if onGround:
    if not wasGrounded:
      let drop = fellFrom - here.y
      if drop > 0.5: handOver("fell", "", int(drop * 10.0))
    fellFrom = here.y
  elif wasGrounded:
    fellFrom = here.y
  elif here.y > fellFrom:
    fellFrom = here.y
  wasGrounded = onGround
  let dx = here.x - lastAt.x
  let dz = here.z - lastAt.z
  lastAt = here
  walkedSince = walkedSince + squareRoot(dx * dx + dz * dz)
  if walkedSince >= 4.0:
    let whole = int(walkedSince)
    handOver("walked", "", whole)
    walkedSince = walkedSince - float64(whole)

## Anything the mod that keeps the player said since the last frame. The only
## verb this world listens for is `hold`: what is in the hand, and how much of
## it is left. Hearing one at all is what tells this mod that somebody else is
## keeping the bag.
var wantedSeed = 0
var seedWanted = false
  ## A world chosen on the menu. A seed *is* the world, so this is not a
  ## setting being changed - it is a different world - and it is acted on in
  ## `update`, where `makeWorld` is in scope.

# ---------------------------------------------------------------------------
# Somebody else's world
#
# Everything about speaking Minecraft's protocol is in `vxmcplay`, and
# everything about turning its block numbers into this world's is in
# `vxmcmap`. What is left here is the three things only this file can do: find
# the two generated tables, ask this session's own block registry what each
# name means, and spend part of the frame budget on the client instead of on
# the generator.
#
# **The generator is off while a server is on.** Not disabled as a special
# case - `workChunks` simply stops choosing ungenerated chunks, because a chunk
# in this mode is generated by the server arriving rather than by noise. A
# world that did both would be a world made of two worlds with a seam down the
# middle wherever a column had not turned up yet.

var dressedAt = 0

## What every block on the wire is, asked of the one registry this session has.
##
## Re-asked whenever the block catalog has grown, and that is not caution: the
## catalog is filled by whichever mods are in the pack, on whatever frame their
## own `start()` gets to it, and `aoughwl.minecraft` fills it with the
## player's own game a good many frames in. A map built once at join time is a
## map built before the blocks existed - which is exactly the bug this had: it
## answered nothing for every name, every block on the wire became the
## fallback, and the fallback was `idOf("stone")` on an empty registry, which
## is not a block at all.
proc dressBlocks() =
  if client.ix.names.len == 0: return
  if registry.blockCount() == dressedAt: return
  dressedAt = registry.blockCount()
  let names = wantedNames(client)
  var resolved: seq[int] = @[]
  var i = 0
  while i < names.len:
    resolved.add registry.idOf(names[i])
    inc i
  # And nothing else. There is no fallback block: a name this session does not
  # carry becomes air and is counted - see `vxmcmap` - because the fallback
  # that used to be here was stone, and a client with eleven blocks in its
  # catalog adopting a real server's chunks was sealed in a solid cube of it,
  # unable to walk sixteen blocks and unable to tell that stone from the
  # server's own ground.
  useBlocks(client, resolved)
  log("[assert] voxel.server.known=" & $client.map.known &
      " unknown=" & $client.map.unknown &
      " of " & $client.ix.names.len &
      " against " & $registry.blockCount() & " blocks in " & Blocks)

## Read the tables, ask the registry about every name in them, and open the
## socket. Everything that can be missing is named rather than worked around:
## without the tables this is a client that would guess a packet id, and
## guessing one is how you send the wrong packet to a real server.
proc joinServer(address: string) =
  var host = ""
  var port = 0
  if not splitHostPort(address, DefaultMcPort, host, port):
    log("[voxel] '" & address & "' is not a host and a port")
    return
  let indexText = importRead(StateIndexFile)
  if indexText.len == 0:
    log("[voxel] no " & StateIndexFile &
        " - run tools/mcindex.ps1 against your own copy of the game")
    return
  let packetsText = importRead(PlayPacketsFile)
  if packetsText.len == 0:
    log("[voxel] no " & PlayPacketsFile & " - run tools/mcindex.ps1")
    return
  client = newClient()
  loadTables(client, indexText, packetsText)
  if client.problem.len > 0:
    log("[voxel] " & client.problem)
    return
  # What every block on the wire is, asked of the one registry this session
  # has. `aoughwl.minecraft` fills it from the player's own game when they
  # have granted it, and `dressBlocks` is re-asked every time the catalog grows
  # for exactly that reason; without that mod in the pack it is the eleven
  # blocks this one ships and eleven hundred of Mojang's names answer to
  # nothing, which is why the pack that plays on a server names it.
  dressBlocks()
  # And what the player's own jar calls every item and every data component.
  # Read here, not in `loadTables`, because neither is worth failing a join
  # over: a client with no item table plays this world exactly as before and
  # only cannot name what is in its hand.
  loadItemTables(client, importRead(ItemsFile), importRead(ComponentsFile))
  if client.invProblem.len > 0:
    log("[voxel] the bag will stay empty: " & client.invProblem)
  # And what it calls every kind of entity, which is the same bargain a third
  # time: without it the world arrives and is empty of everything that is not a
  # block, and that is a sentence rather than a failed join.
  loadEntityTable(client, importRead(EntityTypesFile))
  if client.kindProblem.len > 0:
    log("[voxel] nobody will be drawn: " & client.kindProblem)
  connect(client, host, port)
  if client.problem.len > 0:
    log("[voxel] " & client.problem)
    return
  serverMode = true
  log("[voxel] joining " & host & ":" & $port & ", " &
      $client.ix.names.len & " block names off the wire, " &
      $client.map.known & " of them in this world")

## Everything the play script and the debug screen can ask about the join. The
## counts are what a check is made of: "some blocks arrived" is true of a
## decoder that read every run through the wrong palette slot, and a count and
## a named block are not.
proc tellServer() =
  tell("voxel.server.phase", client.phase)
  # What this world generated for itself, which in server mode must stay zero:
  # a world that is somebody else's and this engine's at once has a seam down
  # the middle wherever a column has not turned up yet.
  tell("voxel.generated", $generated)
  tell("voxel.server.columns", $client.columns)
  tell("voxel.server.blocks", $client.serverBlocks)
  tell("voxel.server.edits", $client.edits)
  # How many of Mojang's blocks this session can name, and how many it cannot.
  # The pair, and never just the first: `known` going up says a catalog was
  # filled and only `unknown` says how much of it is still missing. And
  # `holes` is that in blocks rather than in names - the count of what actually
  # arrived off the socket and was dropped on the floor for want of a name.
  tell("voxel.server.known", $client.map.known)
  tell("voxel.server.unknown", $client.map.unknown)
  tell("voxel.server.holes", $client.holes)
  tell("voxel.server.outside", $client.outside)
  tell("voxel.server.refused", $client.refused)
  tell("voxel.server.floor", $client.floorY)
  if client.groundKnown:
    tell("voxel.server.ground", groundName(client))
    tell("voxel.server.groundstate", $groundState0(client))
    tell("voxel.server.groundat", cell(groundWhere(client)))
  if client.problem.len > 0: tell("voxel.server.problem", client.problem)
  # What this client *said*, and what the server did about it. Both halves, and
  # never one number for the two: `sent` going up says the socket is being
  # written to, and only `agreed` says the world on the other end changed. A
  # check on the first alone passes against a server that has hung up.
  tell("voxel.server.moved", $client.moved)
  # And the one number in this block that is the server's rather than ours:
  # how far the server has moved the chunk cache centre of the player it is
  # keeping. See `vxmcplay.driftMax`.
  tell("voxel.server.drift", $client.driftMax)
  tell("voxel.server.acked", $client.acked)
  tell("voxel.server.digs", $client.digsFinished)
  tell("voxel.server.broke", $client.breaksAgreed)
  tell("voxel.server.placesent", $client.placesSent)
  tell("voxel.server.placed", $client.placesAgreed)
  # A cell is three numbers with spaces in it, and it is quoted for that reason
  # alone: the harness reads `name=value` up to the first space unless the value
  # is in quotes, so an unquoted one answers "-150" to a question about a cell.
  # And a cell that reads as one word is a cell a play script can hand straight
  # back to the server - `rcon execute if block {voxel.server.brokeat} ...` -
  # which is the only way an assertion about somebody else's world is made of
  # anything but our own arithmetic.
  if client.breaksAgreed > 0: tell("voxel.server.brokeat", cell(brokeWhere(client)))
  if client.placesAgreed > 0:
    tell("voxel.server.placedat", cell(putWhere(client)))
    tell("voxel.server.placedwhat", putName(client))
  # Where the server says the body is, in its own coordinates, so that a
  # transcript can be laid beside what the server itself answers over rcon.
  tell("voxel.server.at", cell($int(client.play.x) & " " &
    $int(client.play.y) & " " & $int(client.play.z)))
  # The bag, and the body.
  tell("voxel.server.slots", $stacksHeld(client))
  tell("voxel.server.slotwrites", $client.slotWrites)
  tell("voxel.server.contentwrites", $client.contentWrites)
  tell("voxel.server.held", $client.heldSlot)
  tell("voxel.server.helditem", (if heldName(client).len > 0: heldName(client)
                                 else: "nothing"))
  tell("voxel.server.helditems", $heldCount0(client))
  tell("voxel.server.health", $int(serverHealth(client)))
  tell("voxel.server.deaths", $serverDeaths(client))
  tell("voxel.server.food", $serverFood(client))
  tell("voxel.server.xp", $serverExperience(client))
  tell("voxel.server.gamemode", $serverGamemode(client))
  if client.invProblem.len > 0: tell("voxel.server.invproblem", client.invProblem)
  # And everything out there that is not a block. `entities` is what the wire
  # said is there; `voxel.entities` beside it is what got drawn, and the two
  # being different is the whole of what can go wrong between them.
  tell("voxel.server.entities", $herdCount0(client))
  tell("voxel.server.spawns", $herdSpawns(client))
  tell("voxel.server.despawns", $herdRemoves(client))
  tell("voxel.server.entitymoves", $herdMoves(client))
  tell("voxel.server.orphans", $herdOrphans(client))
  tell("voxel.server.entityhurts", $herdHurts(client))
  tell("voxel.server.entitydeaths", $herdDeaths(client))
  tell("voxel.server.unnamedkinds", $client.unnamed)
  tell("voxel.server.feedlines", $client.fedLines)
  if client.kindProblem.len > 0: tell("voxel.server.kindproblem", client.kindProblem)
  # The one readout here that somebody else can be asked about: what the nearest
  # thing is and where this client thinks it is, written as the tail of an
  # `execute if entity` selector. See `vxmcplay.herdWhere`.
  let near = herdNearestKind(client)
  if near.len > 0:
    tell("voxel.herd.kind", near)
    # QUOTED, and it is the whole difference between an oracle and a formality.
    # The harness reads an unquoted value up to the first space OR COMMA, and a
    # selector tail is nothing but commas: `x=-153,y=41,z=-63,distance=..3`
    # arrives as `x=-153`, and `@e[type=minecraft:cow,x=-153]` selects every cow
    # in the world, because `x=` on its own moves the search origin and narrows
    # nothing. That passed, and meant only "a cow exists somewhere".
    tell("voxel.herd.where", cell(herdWhere(client, 3)))
  # And the same about the newest thing out there rather than the closest, which
  # is the pair a script can predict: it summons something, and that something is
  # the newest. See `vxmcplay.herdNewKind`.
  let fresh0 = herdNewKind(client)
  if fresh0.len > 0:
    tell("voxel.herd.newkind", fresh0)
    tell("voxel.herd.newat", cell(herdNewWhere(client, 3)))
  # And one row per KIND that is out there: where the nearest cow is, where the
  # nearest player is, one line each, named after the kind. This is the handle a
  # play script can actually use - it summons a cow and asks about a cow - and
  # the two handles above it cannot be, because both are moving targets in a live
  # world: a player walking past takes "nearest", and a chicken spawning and
  # despawning in a chunk nobody is watching takes "newest".
  #
  # Bounded by how many kinds are near rather than by how many things are, which
  # is a handful.
  var kindAt = 0
  let kinds0 = herdKindCount(client)
  while kindAt < kinds0:
    let what = herdKindAt(client, kindAt)
    if what.len > 0:
      tell("voxel.herd.at." & what, cell(herdWhereKind(client, what, 3)))
      tell("voxel.herd.count." & what, $herdKinds(client, what))
    inc kindAt
  # The block under the player's feet, by name. This is the assertion with no
  # counting in it: a world that adopted the right blocks in the wrong order
  # has the right total and the wrong ground.
  let here = player.position()
  let under = world.blockAt(int(here.x), int(here.y) - 1, int(here.z))
  tell("voxel.server.under", registry.defOf(under).name)

## Where the player is, said to the server twenty times a second.
##
## The rate is counted off the frame that has just happened and not off a clock
## read here, because a mod cannot time its own work: the clock it can read was
## sampled at the top of the frame and would say the same thing twice.
##
## Three conversions and all three are one-way. The height is this world's,
## which sits `floorY` below Minecraft's - `vxmcplay.sendMovement` does that
## one. The yaw is negated: this engine turns clockwise from +Z through +X and
## Minecraft turns clockwise from +Z through -X, so the same heading is the
## same number with the sign flipped. The pitch is not - both call looking down
## positive.
##
## `stepMovement` sends nothing at all when nothing moved, so a player standing
## still costs one comparison a tick and no bytes.
proc pushMovement(seconds: float64) =
  if not placedYet(client): return
  if not movementDue(client, seconds): return
  let here = player.position()
  sendMovement(client, here.x, here.y, here.z,
    -player.yaw, player.pitch, grounded(player.body))

## The body the server is keeping, handed to whichever mod in this pack draws
## one. Said on change and never every frame - the queue is append-only, and a
## row a frame is a catalog that grows for as long as the session lasts.
##
## Nothing here draws a heart. This world does not own a survival HUD and must
## not grow one: what it owns is the connection, and what a connection can say
## is what the server said.
proc tellVitals() =
  let line = $int(serverHealth(client)) & "|" & $serverFood(client) & "|" &
    $serverExperience(client)
  if line == toldVitals: return
  toldVitals = line
  handOver("vitals", line, int(serverHealth(client)))

proc readHandoffs() =
  for one in handed(handoffSeen):
    if one.verb == "world":
      worldInMenu = one.subject == "menu"
    elif one.verb == "server":
      # A modpack says which server this world is, by handing the address over
      # on its own start(). Nothing here knows which mod said it, which is the
      # point: a join is a thing a modpack decides, not a thing this mod is
      # compiled with.
      serverWanted = one.subject
    elif one.verb == "hold":
      handsOff = true
      heldItem = one.subject
      heldCount = one.amount
    elif one.verb == "seed":
      wantedSeed = one.amount
      seedWanted = true
    elif one.verb == "pointer":
      # Somebody else's screen took the mouse, or handed it back. Digging
      # through an open inventory is the thing this prevents.
      someoneElseHasIt = one.subject == "free"

proc dig(seconds: float64) =
  if not aimed.found:
    stopDigging()
    return
  let id = world.blockAt(aimed.x, aimed.y, aimed.z)
  if not registry.breakable(id):
    stopDigging()
    return
  if (not digging) or digX != aimed.x or digY != aimed.y or digZ != aimed.z:
    digging = true
    digX = aimed.x
    digY = aimed.y
    digZ = aimed.z
    digProgress = 0.0
    digNeeded = registry.hardnessOf(id)
    if digNeeded < 0.02: digNeeded = 0.02
    # A new block under the crosshair is a new dig, and the server has to be
    # told at the start and not only at the end: in survival it runs the break
    # timer itself from this packet, and a `dig finish` with no `dig start`
    # before it is refused with the block left where it is.
    if serverMode:
      serverDigFace = mcFaceOf(aimed.nx, aimed.ny, aimed.nz)
      serverDigging = true
      serverFinished = false
      digStartAt(client, digX, digY, digZ, serverDigFace)
  digProgress = digProgress + seconds
  # The arm. Nothing here draws one - the held-item view belongs to whichever
  # mod owns the first-person camera - and what is published is the count and
  # the beat, so that view and this timer agree about when a swing is over
  # without either of them owning the other.
  if not swinging(sinceSwing):
    sinceSwing = 0.0
    swings = swings + 1
    handOver("swing", "mine", swings)
    tell("voxel.swings", $swings)
  # And a chip off the face being hit, every so often, while the button is
  # held. The game does this too, and without it a block that takes two seconds
  # to break is two seconds of nothing happening.
  sinceChip = sinceChip + seconds
  if chipDue(sinceChip):
    sinceChip = 0.0
    let hitFace = faceOfOffset(float(aimed.nx), float(aimed.ny),
      float(aimed.nz))
    chipPicture = pictureOfFace(id, hitFace)
    chipMote(chips, float(digX) + 0.5, float(digY) + 0.5, float(digZ) + 0.5,
      float(aimed.nx), float(aimed.ny), float(aimed.nz), id, hitFace)
  if digProgress < digNeeded: return
  if not serverMode:
    breakBlock(digX, digY, digZ)
    return
  # Somebody else's world, and the one rule that is easy to get backwards.
  #
  # A `dig finish` is sent ONCE per block and a `dig start` is never re-sent for
  # a block already being dug. The server runs its own break timer from the
  # start packet and **resets it on every start packet**, so a client that
  # re-announced a dig each time its own timer ran out would push the server's
  # progress back to zero every time and the block would never break at all.
  # This client's hardness is its own registry's and the server's is Mojang's;
  # they do not have to agree, and this is what makes not agreeing harmless.
  if serverFinished: return
  serverFinished = true
  breakBlock(digX, digY, digZ)

# ---------------------------------------------------------------------------
# Starting, and starting over

proc makeWorld(withSeed: int) =
  forgetWorld()
  seed = withSeed
  # `sealSides` last, and true, because this world is a *window*: the horizon
  # draws the ground outside it, so the four walls the window would otherwise
  # draw round itself are behind that ground and were never visible. They were
  # two thirds of everything the mesher emitted - see `World.sealSides`.
  world = newWorld(seed, SpanX, SpanY, SpanZ, palletteOf(), SeaLevel, Caves,
    true)
  built = 0
  generated = 0

## Enough ground under the player to stand on, before they are put on it - and
## no more, because every block of this is paid for before the first frame is
## drawn and the player is looking at nothing while it happens.
##
## It used to be the whole 16x96x16 column: six chunks generated and all
## twenty-four of their bands meshed, most of them sky and rock nobody can see,
## for 1.4 seconds of black screen before anything moved. It is now the one
## chunk the player's feet are in, the one over their head, and the two bands
## either side of the ground. The other twenty-two bands are exactly the work
## `workChunks` already does nearest-the-player-first, so they arrive in the
## next few frames instead of before the first one - and the player is standing
## and looking around while they do.
##
## Where the ground is does not need a chunk to answer: `groundAt` is the noise
## and the noise is a function of the seed and the place. That is what lets this
## generate the right chunk rather than all of them.
## **Which** chunks and bands those are, and nothing else.
##
## Split out from the generating and the meshing because each of those is a
## stage of its own now - see `workBegin`. This one is pure arithmetic over the
## noise and costs nothing, which is exactly why it can share a frame with
## whatever comes after it.
proc planSpawn() =
  # A server's world has no ground under the player until the server sends
  # some, and generating a chunk of this engine's own noise to stand on would
  # put a hill of somebody else's rock in the middle of theirs. So the player
  # starts in the air, in the middle of the window, and the first teleport puts
  # them where the server says - see `serverPlaced` in `update`.
  spawnFeet = -1
  spawnHead = -1
  spawnSlice = 0
  spawnMidX = world.worldX0() + world.blocksWide() div 2
  spawnMidZ = world.worldZ0() + world.blocksDeep() div 2
  if serverMode:
    bootStanding = float64(world.blocksHigh()) / 2.0
    return
  var top = world.groundAt(spawnMidX, spawnMidZ)
  if world.waterLevel > top: top = world.waterLevel
  let cx = floorDiv(spawnMidX, ChunkSize)
  let cz = floorDiv(spawnMidZ, ChunkSize)
  var cy = top div ChunkSize
  if cy > SpanY - 1: cy = SpanY - 1
  # The chunk with the ground in it, and the one above so there is headroom to
  # stand up in rather than a ceiling at the chunk seam.
  spawnFeet = world.chunkIndex(cx, cy, cz)
  spawnHead = world.chunkIndex(cx, cy + 1, cz)
  # Only the bands that have the surface in them. A band below the one the
  # ground is in is a band of rock under a floor the player cannot fall through.
  spawnSlice = sliceOf(floorMod(top, ChunkSize))

# ---------------------------------------------------------------------------
# The settings a Minecraft options screen may change
#
# Two rules hold this together. The first is that nothing here decides what a
# screen looks like: it answers what this world can honestly do, and says what
# is missing where it cannot, and the screen greys that row and prints the
# reason in place of a control. The second is that a value is remembered here
# only once it has been applied, or once `begin()` is certain to apply it,
# because a reply of `ok` over a value nobody reads is worse than no setting at
# all - it is a control that lies, and nothing outside can tell.

## The field of view, on the camera the character made. It is a real Unity
## Camera and a scalar property on one goes through the escape hatch by
## reflection - see `docs/HOST-SURFACE.md`. Re-applied wherever the eye is
## made, so an eye built after the value arrived still wears it.
proc applyFov() =
  if fovWanted == 0 or eye.isNothing(): return
  eye.set("fieldOfView", fovFor(fovWanted))

## How fast the mouse turns the head, as a fraction of what the control scheme
## tuned. `baseLookSpeed` is taken before this ever runs, so a hundred per cent
## is the number the scheme said and not the last number this wrote.
proc applySensitivity() =
  if baseLookSpeed <= 0.0: return
  player.tune("lookSpeed", lookSpeedFor(baseLookSpeed, sensitivity))

## The movement keys, over whatever the control scheme bound. A key nobody has
## changed is left alone rather than cleared, so a screen that sends only the
## one binding a player edited does not silently unbind the other five.
proc applyBinds() =
  if bindForward.len > 0: player.bindKey("forward", bindForward)
  if bindBack.len > 0: player.bindKey("back", bindBack)
  if bindLeft.len > 0: player.bindKey("left", bindLeft)
  if bindRight.len > 0: player.bindKey("right", bindRight)
  if bindJump.len > 0: player.bindKey("jump", bindJump)
  if bindSprint.len > 0: player.bindKey("run", bindSprint)

## The horizon, rebuilt at the new radius around wherever the player is now.
##
## Everything the old horizon drew is destroyed first, the way a re-centre drops
## the regions it loses: a mesh is filed under the region it belongs to and not
## under a slot, and a scene of a different width has different slots, so a mesh
## left behind would never be found again and never be taken away. The two
## cursors go back to the start, which is nearest-first, so the hole closes from
## the player outwards.
proc resizeLod() =
  forgetLod(lodScene.centreRx, lodScene.centreRz)
  tell("voxel.lod.blocks", $lodBlocksWide(lodScene))

proc flagText(on: bool): string =
  if on: return "1"
  "0"

## Every setting this world is actually running with, in the shape
## `expect state` reads. The bindings are read back off the character rather
## than out of what was asked for, because the point of the line is to prove the
## key reached something that is read every frame.
proc tellSettings() =
  tell("voxel.renderdistance", $renderChunks)
  # How wide the horizon actually is, beside the distance that was asked for:
  # the first is what a screen shows and the second is what moved, and a run
  # that reads only the first cannot tell a stored number from an applied one.
  tell("voxel.lod.blocks", $lodBlocksWide(lodScene))
  if fovWanted > 0: tell("voxel.fov", $int(fovFor(fovWanted)))
  tell("voxel.sensitivity", $sensitivity)
  tell("voxel.invertmouse", flagText(invertMouse))
  tell("voxel.viewbobbing", flagText(viewBobbing))
  tell("voxel.autojump", flagText(autoJump))
  tell("voxel.bind.forward", player.forwardKey)
  tell("voxel.bind.back", player.backKey)
  tell("voxel.bind.left", player.leftKey)
  tell("voxel.bind.right", player.rightKey)
  tell("voxel.bind.jump", player.jumpKey)
  tell("voxel.bind.sprint", player.runKey)

## Everything a settings screen may have said, pushed into a world that now
## exists. Called at the end of `begin()`: the character is configured and
## placed and the eye is made by then, which is exactly what these need and what
## none of them had before the first frame.
proc applySettings() =
  baseLookSpeed = player.lookSpeed
  applySensitivity()
  applyBinds()
  applyFov()
  tellSettings()

## Turning the head with the mouse, with the pitch the other way up.
##
## `Character.look` subtracts the mouse's Y from the pitch and there is no sign
## anywhere on it, so this is that same turn with the one sign changed, run in
## place of the step's own - `player.step(false)` skips it. Undoing the step's
## turn afterwards instead would be wrong exactly at the pitch limit, where what
## the step moved was clamped and is no longer what the mouse asked for.
proc lookInverted() =
  player.yaw = player.yaw + lookX() * player.lookSpeed
  player.pitch = player.pitch + lookY() * player.lookSpeed
  if player.pitchLimit > 0.0:
    if player.pitch > player.pitchLimit: player.pitch = player.pitchLimit
    if player.pitch < -player.pitchLimit: player.pitch = -player.pitchLimit
  player.body.rotation(0.0, player.yaw, 0.0)

## Minecraft's auto-jump: walk into a one-block step and go up it without
## touching the jump key.
##
## It is a jump over there and it is a jump here - the speed the jump key gives,
## so a ledge this climbs is exactly a ledge you could have climbed yourself.
## What makes it a step rather than a hop at every wall is the second test: the
## same body one block higher has to fit. `boxBlocked` answers both, and it is
## what a spawn point and a refused placement are already chosen with, so a body
## that fits here is a body the host's own sweep will let stand.
proc autoJumpLedge() =
  if not autoJump: return
  if player.body.isNothing() or not player.body.grounded(): return
  let going = player.speed()
  let flat = squareRoot(going.x * going.x + going.z * going.z)
  if flat < 0.4: return
  let here = player.position()
  # Far enough ahead to be past the body's own skin and no further: a reach of a
  # whole block would jump at a wall you are still a stride away from.
  let reach = player.radius + 0.2
  let atX = here.x + going.x / flat * reach
  let atZ = here.z + going.z / flat * reach
  if not boxBlocked(world, registry, atX, here.y, atZ,
    player.radius, player.height): return
  if boxBlocked(world, registry, atX, here.y + 1.0, atZ,
    player.radius, player.height): return
  player.speedY = squareRoot(2.0 * -player.gravity * player.jumpHeight)


## Starting the world up, one stage per call, in the order `begin()` used to do
## them in one go.
##
## **Why it is not one go any more.** All of this used to run inside the first
## `update()`, and the host does not repaint the window while a mod is running -
## it says so itself over any callback past a quarter of a second. Measured in a
## real player launching Minecraft Survival, this mod's first frame was 4382ms:
## four and a half seconds of a window that does not answer the mouse, does not
## redraw, and which Windows is entitled to grey out and call not responding. It
## was reported as a crash, which is the correct reading of what it looked like.
##
## Nothing here got faster. It is the same work in the same order; it is just
## spread over frames that each end, so the window repaints, the loading screen
## the boot shell left on it is still being painted, and the world appears
## rather than arriving all at once after a freeze.
##
## The order is load-bearing and is exactly the old one: the world before the
## spawn column, the spawn column before the player is put on it, the player
## before anything that reads `player.position()`, and `started` last of all -
## `update` branches on it, so a stage that ran before the previous one would be
## a half-built world with the whole of `update` running over it.
##
## Answers true when there is nothing left to do.
proc beginStage(): bool =
  case bootStage
  of 0:
    # The one stage that is not one frame. With a granted copy of Minecraft this
    # is 1172 spec parses, 1172 host calls and 1172 sheet parses - per-block work
    # that no index removes - so it is the one stage big enough to need a budget
    # of its own inside it, and it stays on this stage until it says it is done.
    # No budget once patience has run out, for the reason `paceBegin` gives.
    if not readBlocks(if bootPerFrame > BootMaxStages: 0 else: BootRowsPerFrame):
      return false
  of 1:
    makeWorld(seed)
  of 2:
    planSpawn()
  of 3:
    if spawnFeet >= 0: world.generateChunk(registry, spawnFeet)
  of 4:
    if spawnHead >= 0: world.generateChunk(registry, spawnHead)
  of 5:
    if spawnFeet >= 0: discard rebuildSlice(spawnFeet, spawnSlice)
  of 6:
    if spawnFeet >= 0 and spawnSlice > 0:
      discard rebuildSlice(spawnFeet, spawnSlice - 1)
  of 7:
    if not serverMode:
      bootStanding = float64(
        standingHeight(world, registry, spawnMidX, spawnMidZ, 2))
    player.configure("character.controls", "character.movement")
    player.place("Digger",
      float64(spawnMidX) + 0.5, bootStanding + 0.2, float64(spawnMidZ) + 0.5)
    eye = player.eye
  of 8:
    # After `configure` and after the eye, because that is the first moment
    # there is anything for a setting to reach. A screen that spoke at a title
    # menu is honoured here, which is what lets it answer `ok` before there was
    # a world.
    applySettings()
  of 9:
    highlight = shape(Cube, "Highlight")
    highlight.scale(1.006)
    highlight.color(Color(r: 0.0, g: 0.0, b: 0.0, a: 0.28))
    # A primitive comes with a collider, and a box round the block you are
    # looking at is a box you would walk into. The escape hatch is the only way
    # to turn one off from a mod.
    let box = highlight.component(
      "UnityEngine.BoxCollider, UnityEngine.PhysicsModule")
    if not box.isNothing(): box.set("enabled", false)
    highlight.active(false)
  of 10:
    # Whether the bag is this mod's at all. A mod that keeps one says so on the
    # handoff queue during its own start(), and every start() has run by the
    # time this first frame does - which is what makes this independent of load
    # order.
    handsOff = anybodySaid("keeps")
    lastAt = player.position()
    fellFrom = lastAt.y
    if not handsOff:
      # Enough of everything to build with before digging any of it. A modpack
      # with a real inventory in it starts you with an empty one instead.
      var i = 0
      while i < hotbar.len:
        pouch[hotbar[i]] = pouch[hotbar[i]] + 16
        inc i
  of 11:
    # The player you can look at, and the hand you cannot. Built here rather
    # than in start() for the same reason the world is: the skin arrives on a
    # catalog another mod fills, and that mod's start() may not have run when
    # this one did.
    bobAt = player.position()
    neckHeight = pivotYOf(limbs()[HeadLimb])
    discard readSkin()
    buildPlayerModel()
  of 12:
    buildHand()
  of 13:
    driveCamera()
    takeMouse()
    started = true
    tellView()
    tell("voxel.handsoff", $handsOff)
    tell("voxel.blocks", $registry.blockCount())
    # How many frames the world took to build. This is the whole of what the
    # staging buys, said as a number a play script can hold down: one means the
    # world was built inside a single `update()` again, which is the frozen
    # window this was broken up to stop. `block-feel.txt` asserts it is not one.
    log("[assert] voxel.bootframes=" & $bootFrames)
    if handsOff:
      say("dig with the left button, build with the right - the bag is next door")
    else:
      say("dig with the left button, build with the right, 1-9 to pick")
  else:
    discard
  inc bootStage
  bootStage > BootStages

## How many stages the next frame may do.
##
## The same shape as `sources.pacePump` in `aoughwl.spawner`, and for the
## same reason: a mod cannot time its own work. `jester_time` is sampled
## at the top of the frame and does not move while the mod runs, so a stage
## cannot ask how long it took - and a budget in milliseconds spent inside one
## frame would be a budget measured with a stopped clock. What a mod *can* read
## is how long the frame before it was, which is the whole of the evidence and
## is enough: a machine that is keeping up gets more stages, and the first one
## that runs long takes the rate straight back down to one.
##
## It starts at one and not at the cap, because the frame this is first asked on
## is the frame after every mod in the pack ran its `start()` - the longest
## frame of the whole launch - and starting fast off the back of that would be
## reading the one frame in the session that says nothing about the machine.
## `frameMs > 0` and not just `frameMs < BootFastMs`, because a frame that
## measured zero did not measure anything. A host with no clock on this call -
## `tools/run_mod` is one, and it says so: `jester_time` is in its
## "unserved host calls" line - reports every frame as nought milliseconds, and
## a rate that reads that as "this machine is idle" goes straight to the cap on
## a host that has told it nothing at all. Reading no evidence as no speed-up is
## also what makes the headless measurement the worst case rather than a lucky
## one: one stage a frame is exactly what a real player gets after a long frame.
## And a deadline, which is the half that stops the pacing becoming the problem.
##
## The rule above reads a long frame as "do less", and that is right only when
## this mod is what made the frame long. It is not always: `aoughwl.minecraft`
## reading a granted jar spends seconds in a single `update()`, and while it does,
## every frame this mod sees is a long one. Pacing against that stretches a
## start-up over twenty-five of somebody else's two-second frames - fifty seconds
## of "Building the world" - and buys the player nothing at all, because the
## window was not repainting in any of them for a reason this mod cannot fix.
##
## So patience runs out. Past `BootPatience` frames the rate stops asking and
## doubles, and past twice that the rest is done in one go: a start-up still
## going then is no longer being paced for anybody's benefit, and one long frame
## is better than a loading screen that does not end.
proc paceBegin(frameMs: int) =
  inc bootFrames
  if frameMs > BootSlowMs:
    bootPerFrame = 1
  elif frameMs > 0 and frameMs < BootFastMs and bootPerFrame < BootMaxStages:
    inc bootPerFrame
  let over = bootFrames div BootPatience
  if over >= 2:
    bootPerFrame = BootStages + 1
  elif over == 1 and bootPerFrame < BootImpatientStages:
    bootPerFrame = BootImpatientStages

## What the screen says while the world is being built.
##
## No percentage: `BootStages` is a count of steps and not of work, and the two
## stages that mesh a band cost more than the seven around them put together, so
## a bar off the stage number would sit at a tenth and then jump. A line that
## says what is happening promises nothing and is true.
proc paintBuilding() =
  let area = screen()
  writeIn("Building the world", rect(0.0, area.height * 0.5 - 16.0,
    area.width, 32.0), 20.0, AlignCentre, Crosshair)

proc workBegin() =
  ## One frame's worth of starting up. Paced off the frame that just went by,
  ## before any of this frame is spent, exactly as `spawner`'s reader is.
  paceBegin(int(deltaTime() * 1000.0))
  var left = bootPerFrame
  while left > 0:
    if beginStage(): return
    dec left

# ---------------------------------------------------------------------------
# What this world has to say on a debug screen
#
# Six of Minecraft's F3 lines are about the world, and this is the mod that has
# one. Nothing below knows what a debug screen looks like, whether one is
# loaded, or whether anybody is looking: each line is a ROW saying which column
# it belongs in and what order, and a SERVICE that answers when it is asked.
# A modpack with no debug mod in it pays one catalog at start-up and is never
# asked anything.
#
# The row is the declaration and the service is the value, because a catalog is
# a noticeboard - append-only, read when the reader gets round to it - and a
# debug screen is nothing but "what is this worth right now". That is the same
# division `ModSdk/services.nim` was added for.

const
  DebugKind = "aoughwl.debugline"
  DebugCatalog = "aoughwl.debug.lines"
  DebugService = "voxel.debug"
  SettingsService = "voxel.settings"
    ## Nothing declares this and nothing has to be loaded for it to work: a
    ## settings screen asks by name, and a modpack with no screen in it never
    ## asks. See `settingsAnswer` for what is honoured and what is not.

## Rounding towards minus infinity: the block a player standing at x = -0.4 is
## in is block -1, and `int()` truncates towards zero and would say 0.
proc blockOf(value: float64): int =
  let t = int(value)
  if value < 0.0 and float64(t) != value: return t - 1
  t

## The first mod to load owns the catalog and everyone after it adds to it -
## the rule `provideScheme` follows - so this world and a debug screen may load
## in either order, and a third mod may turn up later still.
proc publishDebug() =
  # The kind and the catalog under ONE guard, never separately. A kind belongs
  # to the mod that declared it and a second mod declaring the same id is
  # refused outright, which takes the whole boot down. Three mods in this pack
  # publish debug lines and any of them may load first, so every one of them
  # must be willing to make the catalog and none may declare the kind on any
  # other path.
  if catalogSignature(DebugCatalog).len == 0:
    defineCatalogKind(DebugKind, "text",
      "One line on a debug screen: where it goes and who to ask for it.")
    createCatalog(DebugCatalog, DebugKind,
      "What every mod has to say about itself, a line at a time.")
  # The order numbers are the game's own order for these lines. `every` is
  # frames between refreshes and it is here because this mod knows which of
  # these move every frame and which do not: the seed never does.
  addToCatalog(DebugCatalog, "voxel.chunks",
    "order=60 key=debug.chunks service=voxel.debug arg=chunks every=20")
  addToCatalog(DebugCatalog, "voxel.seed",
    "order=70 key=debug.seed service=voxel.debug arg=seed every=120")
  addToCatalog(DebugCatalog, "voxel.block",
    "order=110 key=debug.block service=voxel.debug arg=block")
  addToCatalog(DebugCatalog, "voxel.chunk",
    "order=120 key=debug.chunk service=voxel.debug arg=chunk")
  addToCatalog(DebugCatalog, "voxel.facing",
    "order=130 key=debug.facing service=voxel.debug arg=facing every=2")
  addToCatalog(DebugCatalog, "voxel.target",
    "order=200 key=debug.targeted_block service=voxel.debug arg=target")
  provideService(DebugService)

## The world's own settings, for whoever draws an options screen.
proc publishSettings() =
  provideService(SettingsService)

proc debugAnswer(what: string): string =
  if not started: return ""
  if what == "chunks": return $generated & " / " & $world.chunkCount()
  if what == "seed": return $seed
  if what == "facing":
    return $int(player.yaw) & " / " & $int(player.pitch)
  if what == "target":
    # Nothing in reach is a real answer and not a missing one, so it is said
    # with an empty value rather than left out: the screen can tell a provider
    # that answered nothing on purpose from a provider that never spoke.
    if not aimed.found: return ""
    return registry.defOf(world.blockAt(aimed.x, aimed.y, aimed.z)).label &
      " " & $aimed.x & " " & $aimed.y & " " & $aimed.z
  let here = player.position()
  let bx = blockOf(here.x)
  let by = blockOf(here.y)
  let bz = blockOf(here.z)
  if what == "block":
    return $bx & " " & $by & " " & $bz & " [" &
      $floorMod(bx, ChunkSize) & " " & $floorMod(by, ChunkSize) & " " &
      $floorMod(bz, ChunkSize) & "]"
  if what == "chunk":
    return $floorDiv(bx, ChunkSize) & " " & $floorDiv(by, ChunkSize) & " " &
      $floorDiv(bz, ChunkSize)
  ""

## The whole list in one call and a table back - one `<argument><TAB><value>` a
## line. Six lines from this mod are one crossing and one re-entry of the
## interpreter, not six of each, and the shape is the one `minecraft.gui`
## already answers `lang` in.
## Which of the character's controls a `bind.*` key names, and an empty string
## for a key that is not one. `bind.sprint` is the character's `"run"`, which is
## the one place the two vocabularies disagree.
proc bindAction(what: string): string =
  if what == "bind.forward": return "forward"
  if what == "bind.back": return "back"
  if what == "bind.left": return "left"
  if what == "bind.right": return "right"
  if what == "bind.jump": return "jump"
  if what == "bind.sprint": return "run"
  ""

## One setting, applied where it can be, and what to say about it.
##
## A key with no value is the question "do you honour this at all": it changes
## nothing and answers exactly what the change would have answered, so a screen
## can find out what to draw before it draws it.
##
## Every `no` names what is missing rather than saying no, because the screen
## prints it in place of the control, and a reason nobody can act on is a greyed
## row with a shrug in it.
proc settingsAnswer(what, value: string; given: bool): string =
  if what == "renderDistance":
    if not given: return "ok"
    if not isWhole(value):
      return "no a render distance is a whole number of chunks"
    renderChunks = clampWhole(wholeOf(value), MinRender, MaxRender)
    let radius = lodRadiusFor(renderChunks)
    if radius != lodRadius:
      lodRadius = radius
      # Before the world begins there is no horizon to take away, and
      # `forgetLod` builds the first one at whatever `lodRadius` says.
      if started: resizeLod()
    tell("voxel.renderdistance", $renderChunks)
    return "ok"
  if what == "fov":
    if not given: return "ok"
    if not isWhole(value):
      return "no a field of view is a whole number of degrees"
    fovWanted = clampWhole(wholeOf(value), MinFov, MaxFov)
    applyFov()
    tell("voxel.fov", $int(fovFor(fovWanted)))
    return "ok"
  if what == "sensitivity":
    if not given: return "ok"
    if not isWhole(value):
      return "no a sensitivity is a whole percentage, a hundred for no change"
    sensitivity = clampWhole(wholeOf(value), 0, MaxSensitivity)
    applySensitivity()
    tell("voxel.sensitivity", $sensitivity)
    return "ok"
  if what == "invertMouse":
    if not given: return "ok"
    if not isFlag(value): return "no invertMouse is 0 or 1"
    invertMouse = value == "1"
    tell("voxel.invertmouse", flagText(invertMouse))
    return "ok"
  if what == "viewBobbing":
    if not given: return "ok"
    if not isFlag(value): return "no viewBobbing is 0 or 1"
    viewBobbing = value == "1"
    tell("voxel.viewbobbing", flagText(viewBobbing))
    return "ok"
  if what == "autoJump":
    if not given: return "ok"
    if not isFlag(value): return "no autoJump is 0 or 1"
    autoJump = value == "1"
    tell("voxel.autojump", flagText(autoJump))
    return "ok"
  if what == "brightness":
    # Not a shortcoming of this mod: there is no door. See docs/SKY.md, which
    # specifies the call that would be one.
    return "no RenderSettings.ambientLight is a static class and the escape " &
      "hatch binds instance members only, so no host call reaches it - " &
      "docs/SKY.md specifies jester_sky_ambient, which would"
  if what == "difficulty":
    return "no nothing in this world reads it: it spawns no mobs, deals no " &
      "damage and keeps no hunger, and the beings it draws are the server's"
  let action = bindAction(what)
  if action.len > 0:
    if not given: return "ok"
    let bound = key(value)
    if bound == NoKey:
      return "no " & value & " is not a key the input system knows"
    # The input system's own spelling, so a screen that sent a name this mod
    # would not have written back reads its own row correctly afterwards.
    let spelled = name(bound)
    if what == "bind.forward": bindForward = spelled
    if what == "bind.back": bindBack = spelled
    if what == "bind.left": bindLeft = spelled
    if what == "bind.right": bindRight = spelled
    if what == "bind.jump": bindJump = spelled
    if what == "bind.sprint": bindSprint = spelled
    # Live, on the very next frame: the character reads its key names every
    # step, so there is nothing to restart and nothing to rebuild.
    if started: player.bindKey(action, spelled)
    tell("voxel." & what, spelled)
    return "ok"
  "no unknown setting"

## The whole request, one `key<SPACE>value` a line, and one `key<TAB>status` a
## line back - the same shape the debug service answers in, because a settings
## screen changing nine things is one crossing of the interpreter and not nine.
proc settingsReply(asked: string): string =
  var reply = ""
  var one = ""
  var i = 0
  while i <= asked.len:
    if i == asked.len or asked[i] == '\n':
      if one.len > 0:
        var what = ""
        var value = ""
        var given = false
        var j = 0
        while j < one.len:
          if not given and one[j] == ' ': given = true
          elif given: value.add one[j]
          else: what.add one[j]
          inc j
        reply = reply & what & "\t" & settingsAnswer(what, value, given) & "\n"
      one = ""
    elif asked[i] != '\r':
      one.add asked[i]
    inc i
  reply

proc serveRequest() =
  let asking = serviceName()
  if asking == SettingsService:
    answerService(settingsReply(serviceArgument()))
    return
  if asking != DebugService: return
  var reply = ""
  var one = ""
  let asked = serviceArgument()
  var i = 0
  while i <= asked.len:
    if i == asked.len or asked[i] == '\n':
      if one.len > 0: reply = reply & one & "\t" & debugAnswer(one) & "\n"
      one = ""
    else:
      one.add asked[i]
    inc i
  answerService(reply)

proc start() =
  publishBlocks()
  # The picture half. This was written and never called, so every block in the
  # world was painted its flat colour and no shipped texture ever reached the
  # host. It is called now, and what it publishes is a picture per face rather
  # than a shared sheet - see `publishSkins`.
  publishSkins()
  # The item half. `itemCatalog` makes the definition catalog and its facets;
  # `publishItems` is what tells every other mod it exists, because a library's
  # module-level register has one copy per mod that imports it and the host's
  # word for agreement is a catalog.
  discard itemCatalog(Items, "Blocks of the voxel world, as items")
  publishItems(Items)
  provideScheme(Scheme)
  discard catalog(Chunks, "aoughwl.part", "One chunk of the voxel world")
    .put("chunk", Scheme & "://chunk")
  discard catalog(Drops, "aoughwl.part", "What a broken block leaves behind")
    .put("nugget", "builtin://cube")
  # Both answered by `resolvePart` under the same scheme as the chunks, and
  # told apart there by their locator.
  discard catalog(Cracks, "aoughwl.part",
    "The crack on a block being broken").put("crack", Scheme & "://crack")
  discard catalog(Chips, "aoughwl.part",
    "The chips a broken block throws").put("chips", Scheme & "://chips")
  # The player, in the two halves third person turns independently. Both are
  # answered by `resolvePart` under the same scheme and told apart there by
  # `pendingLimb`, the way the chunk bands are told apart by `pendingAt`.
  discard catalog(Bodies, "aoughwl.part", "The player, as boxes")
    .put("body", Scheme & "://player")
    .put("head", Scheme & "://player")
  # And the row somebody else fills with a picture for them. Declared here and
  # left empty here: the skin is out of the copy of Minecraft the player
  # granted, so the mod that reads that copy is the mod that fills it in.
  defineCatalogKind(SkinKind, "text",
    "The skin an entity wears: a data: URI, or a file inside the mod that " &
    "contributed the row. 64x64, laid out the way a Minecraft skin is.")
  discard catalog(Skins, SkinKind, "What the player wears")
  # And everybody else: the models, their part catalogs, and the rows another
  # mod fills with their pictures. Nothing is drawn until something serves
  # `voxel.entities` - see `docs/ENTITIES.md`.
  startHerd(Scheme, SkinKind)
  seed = int(remember("seed", 20260910'i64))
  # F5 is deliberately **not** remembered across sessions. Minecraft does not
  # remember it either, and the reason is the same: third person is something
  # you go into to look at something and come out of again, and a game that
  # starts you outside your own body because of what you did last week is a
  # game that starts wrong. It also means a run of the play script begins in a
  # known view rather than in whichever one the run before it ended in.
  view = Inside
  # Say that this mod places and drives the character, so a HUD in the same
  # modpack does not place a second one beside it. Said in start() and read by
  # the other mod on its first frame, so neither has to load first.
  handOver("owns", "player")
  # Six lines for whatever debug screen is loaded, if one is. See publishDebug.
  publishDebug()
  publishSettings()
  log("voxel: " & $SpanX & "x" & $SpanY & "x" & $SpanZ & " chunks, seed " & $seed)

proc update() =
  readHandoffs()
  if worldInMenu and started and serverWanted.len == 0: return
  # The world is made on the first frame rather than in start(), because the
  # blocks it is made of arrive from mods that have not run their own start()
  # yet when this one runs.
  if not started:
    # Before `begin`, not after: whether this world is a server's changes what
    # `begin` does with it. Every mod's `start()` has run by the time this
    # first frame does, so whatever a modpack handed over is already here.
    readHandoffs()
    # Only before the world is made. Whether this is a server's world changes
    # what `makeWorld` and `planSpawn` do with it, and those are stages 1 and 2
    # now - a join that landed at stage 5 would be answering a question that had
    # already been answered. A handoff that arrives after that keeps `serverWanted`
    # set and is joined by the steady path below on the first real frame.
    if bootStage == 0 and serverWanted.len > 0:
      joinServer(serverWanted)
      serverWanted = ""
    workBegin()
    # How far in, said once per stage. Six lines on a normal boot and the one
    # thing worth having when a boot does not finish: "it is on stage 0" and "it
    # is on stage 7" are different bugs, and a screen that says "Building the
    # world" either way cannot tell them apart. A play script can wait on it.
    # Stage 0 is the one that stays put for many frames - it is reading the
    # block catalogs a slice at a time - so it says where it has got to as well,
    # every few hundred rows. A boot that is working and a boot that is stuck
    # look identical from outside otherwise.
    if bootStage != bootSaid or blockRow >= rowSaid + 480:
      bootSaid = bootStage
      rowSaid = blockRow
      log("[assert] voxel.bootstage=" & $bootStage &
          " rows=" & $blockRow & " of=" & $blockRows & " skins=" & $skinRow)
    # And say so on the screen, because these frames are now frames: the window
    # repaints between them, and a world that takes a second to appear with
    # nothing said is the same "is it broken?" the freeze was, drawn at sixty
    # frames a second instead of not at all. The boot shell's loading screen
    # cannot cover this - it is gone by the time the first of these runs.
    paintBuilding()
    return
  if not readBlocks(BootRowsPerFrame): return
  readHandoffs()
  if serverWanted.len > 0:
    joinServer(serverWanted)
    serverWanted = ""
  # A skin that arrives after the world started still dresses the player. The
  # read is a string compare against what is already worn, so the rebuild
  # happens on the one frame the row changes and never again.
  if readSkin(): buildPlayerModel()
  if seedWanted:
    seedWanted = false
    if wantedSeed != seed:
      seed = wantedSeed
      save("seed", int64(seed))
      log("voxel: the menu chose seed " & $seed)
      makeWorld(seed)
      return
  let seconds = deltaTime()
  sincePlace = sincePlace + seconds
  sinceBreak = sinceBreak + seconds
  sinceSwing = sinceSwing + seconds
  # The chips move whether or not anything is digging, because they outlive the
  # break that threw them. Pure arithmetic over a field that is empty on almost
  # every frame.
  stepMotes(chips, seconds)

  if pressed(Tab):
    if captured: dropMouse() else: takeMouse()
  if pressed(G): showNumbers = not showNumbers
  # F5. Three states in a ring - your own head, over your shoulder, and in front
  # looking back - and the ring is in `vxview.nextPerspective` rather than here,
  # so a modpack that wants a fourth adds it in one place with a test round it.
  if pressed(F5):
    view = nextPerspective(view)
  if pressed(N):
    save("seed", int64(seed + 1))
    makeWorld(seed + 1)
    player.teleport(vec3(
      float64(world.worldX0() + world.blocksWide() div 2) + 0.5,
      float64(world.blocksHigh()) - 2.0,
      float64(world.worldZ0() + world.blocksDeep() div 2) + 0.5))
    say("a new world, seed " & $seed)
    return

  # The mouse is this world's only while nobody else has it, and an inverted
  # look is this mod's own turn in place of the step's - see `lookInverted`.
  let turning = mine()
  if turning and invertMouse: lookInverted()
  player.step(turning and not invertMouse)
  autoJumpLedge()
  # Straight after the step, because the step has just put the eye back on the
  # head: the camera is pushed off that clean state every frame, and the
  # crosshair keeps firing from the head whatever the camera does.
  driveCamera()
  showPlayer(seconds)
  tellView()
  # Where the world is, before anything is spent on filling it in: a frame that
  # generated a chunk the player has just walked away from is a frame wasted.
  streamWorld()
  # The server, before the meshing: a column adopted this frame is a column the
  # same frame can start meshing, and the budget is shared so that the two
  # cannot both have the whole of it.
  if serverMode:
    dressBlocks()
    discard step(client, world, registry, McBudget)
    paceFor(client, McBudget, seconds)
    # Where the server says you are. Done once, when the first teleport lands,
    # because the world's floor is fixed on the same teleport and everything
    # already in the world is measured from it.
    # Every teleport, not only the first. A server moves a player it does not
    # believe - and while the world is still arriving there is nothing under
    # their feet, so they fall, and the server teleports them back. Answering
    # only the first one leaves the character somewhere the server stopped
    # believing in several seconds ago.
    if placedYet(client) and
       (not serverPlaced or client.play.lastTeleportId != placedTeleport):
      let first = not serverPlaced
      serverPlaced = true
      placedTeleport = client.play.lastTeleportId
      player.teleport(vec3(placeX(client), placeY(client), placeZ(client)))
      let px = floorInt(placeX(client))
      let pz = floorInt(placeZ(client))
      # The window moves in one jump, and **only** when it has to. A recentre
      # throws every chunk in the window away, so doing it on every teleport
      # would discard the world on each of the corrections a server sends while
      # the ground is still arriving. `streamWorld` handles the walking case a
      # chunk at a time; this is the case it refuses - a player who moved
      # further in one frame than the window is wide.
      if first or not holdsColumn(world, px, pz):
        let retired = recentreWorld(world,
          centredOrigin(world.spanX, px), centredOrigin(world.spanZ, pz))
        var i = 0
        while i < retired.len:
          dropMeshes(retired[i], -1)
          inc i
        nearDone = false
        log("[voxel] the server put us at " & $placeX(client) & ", " &
            $placeY(client) & ", " & $placeZ(client) & "; the window is at " &
            $world.originCx & "," & $world.originCz)
    # And back the other way. After the teleport handling, so that a frame the
    # server moved us on reports where it put us rather than where we were -
    # and `stepMovement` then sees no change at all and sends nothing, which is
    # exactly right: the server does not need to be told its own teleport.
    pushMovement(seconds)
    tellVitals()
    tellServer()
  workChunks(FaceBudget)
  # The horizon waits for the near world. A player who cannot stand up yet does
  # not care what is four hundred blocks away, and the two would otherwise be
  # spending the same frame.
  # The horizon is this generator's own noise, which is not the server's ground.
  # Drawing it under somebody else's world would be a different landscape
  # stitched to the edge of the real one.
  if nearDone and not serverMode: workLod(LodSamples)
  takeAim()
  showHighlight()
  tellAim()
  gatherDrops(seconds)
  reportBody()

  # The hotbar keys are only this mod's while the bag is. When another mod
  # keeps it, the same digits pick a slot over there and arrive back here as a
  # `hold`, so reading them here as well would fight it.
  if serverMode:
    # The digits pick a cell of the *server's* hotbar, and the server is told:
    # it resolves every placement and every dig against its own idea of which
    # cell is up, so a client that changed the highlight without saying so
    # would put down whatever was in the old one.
    var cell = 0
    while cell < HotbarSlots:
      if pressed(key("Digit" & $(cell + 1))):
        holdSlot(client, cell)
        serverHotbar = cell
      inc cell
  elif not handsOff:
    var slot = 0
    while slot < hotbar.len:
      if pressed(key("Digit" & $(slot + 1))): holding = slot
      inc slot

  if mine():
    if held(LeftButton) and mayBreakAgain(sinceBreak): dig(seconds)
    else: stopDigging()
    if held(RightButton) and sincePlace > PlaceDelay: putBlock()
  else:
    stopDigging()

  # After the digging, so the crack on the screen is this frame's progress and
  # not the last frame's, and after `stepMotes` above, so the chips are drawn
  # where they are rather than where they were.
  showCrack()
  showChips()
  # Everything that is not made of blocks: ask the feed, move what it said,
  # and put every limb where the animation says. After the camera, because the
  # billboards and the nameplates are built against the camera's own basis.
  #
  # On a server the feed is this session's own Play state, handed straight in -
  # `vxherd.feedHerd` says why that is not a hole in the seam. Off one, nothing
  # is handed in and `vxherd` asks `voxel.entities` as it always did, which is
  # what `example.herd` answers.
  if serverMode: feedHerd(herdFeed(client, herdTick()))
  stepHerd(seconds, eye.position(), eye.forward().norm())

  # The screen is drawn from here rather than from `drawGui`, which is not a
  # style choice: `OnGUI` never runs without a game view, so a mod that draws
  # its crosshair there draws nothing at all in batch mode and nothing a
  # headless capture can see. Drawing issued from `update` is recorded and
  # replayed when a camera renders, so it survives (`docs/MOD-API.md`,
  # *Drawing*). None of this HUD is clickable, which is the one thing that
  # would want the event passes `OnGUI` brings.
  paint()
  # The names over their heads, after the rest of the screen so a plate is
  # never behind the crosshair.
  drawPlates()

# ---------------------------------------------------------------------------
# The screen

proc drawCrosshair(middle: Vec2) =
  fill(rect(middle.x - 9.0, middle.y - 1.0, 18.0, 2.0), Crosshair)
  fill(rect(middle.x - 1.0, middle.y - 9.0, 2.0, 18.0), Crosshair)
  if digging and digNeeded > 0.0:
    var part = digProgress / digNeeded
    if part > 1.0: part = 1.0
    let bar = rect(middle.x - 30.0, middle.y + 18.0, 60.0, 6.0)
    fill(bar, Ink)
    fill(rect(bar.x, bar.y, bar.width * part, bar.height), Warm)

proc drawHotbar(area: Rect) =
  let slots = hotbar.len
  if slots == 0: return
  let wide = 54.0
  let span = wide * float64(slots)
  var x = area.x + (area.width - span) * 0.5
  let y = area.y + area.height - 74.0
  var i = 0
  while i < slots:
    let cell = rect(x, y, wide - 4.0, 50.0)
    let d = registry.defOf(hotbar[i])
    fill(cell, Ink)
    fill(rect(cell.x + 6.0, cell.y + 6.0, cell.width - 12.0, 26.0),
      Color(r: d.red, g: d.green, b: d.blue, a: 1.0))
    writeIn($pouch[hotbar[i]], rect(cell.x, cell.y + 30.0, cell.width, 18.0),
      13.0, AlignCentre, Paper)
    if i == holding: outline(cell, Accent, 2.0)
    x = x + wide
    inc i
  writeIn(registry.defOf(hotbar[holding]).label,
    rect(area.x, y - 24.0, area.width, 20.0), 15.0, AlignCentre, Paper)

## The server's own nine cells. Drawn from `set_slot` and `container_set_content`
## and from nothing else: there is no local bag in this mode, so an empty cell
## here is an empty cell over there and a client that drew its own blocks would
## be showing the player a hotbar the server has never heard of.
proc drawServerHotbar(area: Rect) =
  let wide = 74.0
  let span = wide * float64(HotbarSlots)
  var x = area.x + (area.width - span) * 0.5
  let y = area.y + area.height - 74.0
  var cell = 0
  while cell < HotbarSlots:
    let box = rect(x, y, wide - 4.0, 50.0)
    fill(box, Ink)
    let name = hotbarName(client, cell)
    if name.len > 0:
      writeIn(name, rect(box.x + 2.0, box.y + 4.0, box.width - 4.0, 26.0),
        10.0, AlignCentre, Paper)
      writeIn($hotbarCount(client, cell),
        rect(box.x, box.y + 30.0, box.width, 18.0), 13.0, AlignCentre, Quiet)
    if cell == client.heldSlot: outline(box, Accent, 2.0)
    x = x + wide
    inc cell
  writeIn($int(serverHealth(client)) & " health   " & $serverFood(client) &
    " food   level " & $serverExperience(client),
    rect(area.x, y - 24.0, area.width, 20.0), 15.0, AlignCentre, Paper)

proc paint() =
  if not started: return
  let area = screen()
  drawCrosshair(centre(area))
  # One hotbar on the screen. When another mod keeps the bag it draws the bar
  # too, in the same place, and two of them is worse than either.
  if serverMode: drawServerHotbar(area)
  elif not handsOff: drawHotbar(area)

  var under = "nothing in reach"
  if aimed.found:
    under = registry.defOf(world.blockAt(aimed.x, aimed.y, aimed.z)).label &
      "  at " & $aimed.x & "," & $aimed.y & "," & $aimed.z
  let strip = rect(0.0, area.height - 24.0, area.width, 24.0)
  fill(strip, Ink)
  writeIn(under, rect(12.0, strip.y, area.width * 0.5, 24.0), 13.0,
    AlignLeft, Quiet)
  writeIn(note, rect(area.width * 0.5, strip.y, area.width * 0.5 - 12.0, 24.0),
    13.0, AlignRight, Quiet)

  if not showNumbers: return
  openPanel(rect(16.0, 16.0, 330.0, 232.0))
  heading("Voxel")
  label("seed " & $seed)
  label($generated & " of " & $world.chunkCount() & " chunks generated")
  label($built & " chunk builds, " & $meshThing.len & " meshes")
  label($registry.blockCount() & " blocks in " & Blocks)
  # How much of somebody else's world this session can actually name. Two
  # numbers and not one: a palette that names a thousand blocks and a palette
  # that names eleven both draw a world, and only the second one is mostly
  # missing. The third is that same fact in blocks - how many came off the
  # socket and went in as nothing - because a name nobody sends costs nothing
  # and a name in every chunk costs a wall.
  if serverMode:
    label($client.map.known & " named, " & $client.map.unknown &
      " unknown of " & $client.ix.names.len & " on the wire")
    label($client.holes & " blocks dropped for want of a name")
  label($dropThing.len & " dropped")
  label($moteCount(chips) & " chips of " & $MoteCap & ", " & $chips.made &
    " thrown")
  label("crack stage " & (if crackShown < 0: "none" else: $crackShown) &
    " of " & $Stages & ", " & $crackPics.len & " pictures")
  let here = player.position()
  label("at " & $int(here.x) & "," & $int(here.y) & "," & $int(here.z))
  if hostHit:
    label("host cast: " & $hostDistance & " at y " & $hostPoint.y)
  else: label("host cast: nothing")
  label("view " & perspectiveName(view) & ", camera " &
    $int(pullDistance * 10.0) & " tenths back")
  hint("Tab pointer  G these numbers  N a new world  F5 the view")
  closeMenu()

proc stop() =
  forgetWorld()
  if not highlight.isNothing(): highlight.destroy()
  if not crackThing.isNothing(): crackThing.destroy()
  if not chipThing.isNothing(): chipThing.destroy()
  dropPlayerModel()
  if not handThing.isNothing():
    handThing.destroy()
    handThing = nothing()
