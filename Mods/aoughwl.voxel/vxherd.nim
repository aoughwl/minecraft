## Putting the things that are not blocks on the screen.
##
## This is the only file of the entity work that touches the host. Everything
## it decides was decided somewhere else and proved there: `vxmodel` says what
## a box model is, `vxbeasts` is the models, `vxanim` says where every limb
## points this frame, `vxbeing` says what is out there and moves it between
## messages, and `Tests/entity_test.exe` settles all four in a millisecond.
## What is left here is spawning, transforms and one mesh - the parts that can
## only be checked by playing.
##
## ## How a mob is drawn, and why it is not one mesh
##
## **A part per moving limb, built once, and two host calls a frame each.**
##
## The alternative was the one the chips use: rebuild the whole thing every
## frame as one mesh. That is right for chips - twenty-seven quads, gone in
## under a second - and wrong here by an order of magnitude, because a zombie
## is 144 vertices and a vertex is a host crossing. `Tests/entity_test.exe`
## prints both numbers every time it runs:
##
##     a zombie costs 13us a frame as 7 transforms, against 685us as a mesh
##     rebuilt every frame
##     twenty of them: 263us against 13707us
##
## Thirteen milliseconds a frame is the whole frame. Two hundred and sixty
## microseconds is affordable, and it is affordable because **the host composes
## the matrices**: a limb is a child transform, so the mod hands over three
## angles in degrees and Unity does the trigonometry. That is also why nothing
## in `vxanim.nim` needs a sine.
##
## The flat ones - dropped items, arrows - go the other way and are **one mesh
## for all of them, rebuilt every frame**, because a billboard is four vertices
## and has to turn to face the camera anyway. That is exactly `resolveChips`
## and it is deliberately the same shape of code.
##
## ## The collider every part arrives with
##
## Every mesh a part spawns comes with a MeshCollider on it, and a mob is
## decoration: it must not push the player, and a player standing inside a
## chicken must not be stuck. So every part built here reaches through the
## `component`/`set` escape hatch and turns it off, exactly as the player's own
## model does.
##
## **That is two extra crossings per part at spawn** - about 1.4us - which for
## a zombie is seven parts and ten microseconds, once. At spawn it is nothing.
## It is still the wrong shape: the mod is undoing something the host did
## because the host was not asked. The right fix is a part scheme that says
## whether it wants a collider at all, and it belongs in the host rather than
## here; this file is a witness to that and not a workaround for it.
##
## ## Where the entities come from
##
## A service, `voxel.entities`, asked once a frame and answered by whichever
## mod knows - `aoughwl.mcnet`'s Play state when there is a server, and
## nobody at all when there is not, in which case there are no entities and
## this file does nothing. `docs/ENTITIES.md` is the contract. Nothing here
## parses a packet and nothing here knows what a zombie is.

import jester
import vec
import color
import draw
import catalogs
import services
import textures
import entities
import importing
import vxmodel
import vxbeasts
import vxanim
import vxbeing
import vxturn
import vxview

const
  Beasts* = "voxel.beasts"
    ## The parts a box model is drawn as. One catalog, one item, and which
    ## model and which limb is being asked for is carried in `pendingModel`
    ## and `pendingGroup` beside the spawn - the same trick the chunk bands
    ## and the player's two halves already use.
  Flock* = "voxel.flock"
    ## The single mesh every flat entity is drawn in.
  EntityFeed* = "voxel.entities"
    ## The service. See `docs/ENTITIES.md`.
  EntitySkins* = "voxel.entity.skins"
    ## What each kind wears: a row keyed by the model's name, holding a
    ## picture the same way `voxel.player.skin` does. **This repository fills
    ## in none of them.** A kind with no row is drawn in the flat colours its
    ## rows carry, which is what the box player already does.
  ModelFile* = "entities.conf"
    ## A file a modpack may drop beside this mod to add models or change them.
    ## The mod ships none, because the rows it ships are in `vxbeasts.nim`
    ## where the test can read them; this is the layer over those.
  PlateHeight* = 0.45
    ## How far above a thing its name floats, in metres.
  PlateSize* = 14.0
    ## And how big the letters are, at a metre.
  PlateFar* = 32.0
    ## How far away a nameplate stops being drawn. Minecraft's is 64 for
    ## players; this is nearer because every plate is a host crossing.
  FieldOfView* = 60.0
    ## What the camera's vertical field of view is taken to be when nothing
    ## says otherwise. Unity's default, and the only number in this file that
    ## is a guess - see `plateRules` in the docs for what it costs to be wrong
    ## about it.
  DrawFar* = 64.0
    ## How far away a mob is still built and driven. Past this its parts are
    ## taken away and it is rebuilt when it comes back, which is what stops a
    ## server's whole entity list turning into a thousand transforms.

var
  models = noModels()
  folk = noBeings()
  scheme = "voxel"
  skinKind = "aoughwl.entity.skin"
  ## Every part of every mob, flat and swept linearly: `partOwner` is whose it
  ## is, `partGroup` is which box of that model turns it (-1 for the root) and
  ## `partThing` is the transform. Tens of entries, swept once a frame, which
  ## is cheaper than an index and is one fewer thing to keep true.
  partOwner: seq[int] = @[]
  partGroup: seq[int] = @[]
  partThing: seq[Entity] = @[]
  ## What the resolver is about to be asked for. Set immediately before
  ## `spawnPart`, on this thread, exactly as the chunk bands set theirs.
  pendingModel = -1
  pendingGroup = -1
  ## The one mesh every flat entity is in, and the camera basis it is built
  ## against.
  flockThing = nothing()
  flockRight = vec3(1.0, 0.0, 0.0)
  flockUp = vec3(0.0, 1.0, 0.0)
  flockAhead = vec3(0.0, 0.0, 1.0)
  flockCount = 0
  ## Where the camera is this frame, for the nameplates.
  seatAt = vec3(0.0, 0.0, 0.0)
  focal = 600.0
  said = ""
  toldUnknown = 0
  ## A feed handed in from inside this mod rather than asked for across the
  ## boundary. See `feedHerd`.
  handedIn = ""
  handed = false

## Which row of a catalog has that id, or -1. The host answers a row by index
## and this mod wants one by name, and there is no call for that - so it is a
## sweep, over a catalog with one row per kind of entity, done when a mesh is
## built and never per frame.
proc rowFor(catalogName, id: string): string =
  var i = 0
  let rows = catalogCount(catalogName)
  while i < rows:
    if catalogItemId(catalogName, i) == id: return catalogText(catalogName, i)
    inc i
  ""

## A feed from a producer that is in this same mod.
##
## The seam in `docs/ENTITIES.md` is a service, and it stays one: anybody else's
## producer answers `voxel.entities` and nothing below changes. But this mod
## holds the socket - `vxmcplay` is the only file in the tree that knows both a
## server and this world - so when there IS a server the producer and the
## consumer are in one interpreter, and asking a service would be this mod
## calling itself through the host for a string it already has.
##
## **The grammar is unchanged and is still what crosses.** `vxmcplay.herdFeed`
## writes the same lines `example.herd` writes, with `vxbeing`'s own `say*`
## writers, and they are read by the same `applyFeed`. What is saved is one host
## crossing a frame, not a contract.
##
## A frame with a feed handed in does not also ask the service: two producers
## would be two `t` lines with two different meanings, and the delta cursor is
## one number.
proc feedHerd*(lines: string) =
  handedIn = lines
  handed = true

proc herdCount*(): int = beingCount(folk)
proc herdParts*(): int = partThing.len
proc herdTick*(): int = folk.tick

# ---------------------------------------------------------------------------
# Which boxes go on which transform

## `groupOf` - which transform a box is drawn on - is in `vxmodel.nim` rather
## than here, because it is the rule that decides what is drawn where and a
## rule like that belongs where `Tests/entity_test.exe` can reach it.

## Where a group's transform hangs, in metres from the model's origin.
proc groupPivot(m: Model; group: int; x, y, z: var float) =
  x = 0.0
  y = 0.0
  z = 0.0
  if group < 0: return
  x = pivotXOf(m, m.boxes[group])
  y = pivotYOf(m, m.boxes[group])
  z = pivotZOf(m, m.boxes[group])

# ---------------------------------------------------------------------------
# The meshes

## The mesh of one group of one model: every box that turns on that transform,
## with its corners moved from its own pivot onto the group's.
##
## Every corner and every texture coordinate comes from `vxmodel.boxQuad`,
## which `Tests/entity_test.exe` checks the winding and the unwrap of for every
## box of every model. Nothing about the layout is spelled twice.
proc resolveBeast*() =
  if pendingModel < 0 or pendingModel >= modelCount(models):
    # A mesh with no vertices throws, and a throw here takes the frame. One
    # degenerate quad is a thing nobody sees and nothing falls over for.
    beginMesh()
    let a = addVertex(0.0, 0.0, 0.0)
    addQuad(a, a, a, a)
    finishMesh()
    return
  let m = models.model[pendingModel]
  let dressed = rowFor(EntitySkins, m.name)
  var gx = 0.0
  var gy = 0.0
  var gz = 0.0
  groupPivot(m, pendingGroup, gx, gy, gz)
  beginMesh()
  var wrote = 0
  var i = 0
  while i < m.boxes.len:
    if groupOf(m, i) != pendingGroup:
      inc i
      continue
    # From this box's own pivot onto the group's, which is a subtraction
    # because both are measured from the model's origin.
    let ox = pivotXOf(m, m.boxes[i]) - gx
    let oy = pivotYOf(m, m.boxes[i]) - gy
    let oz = pivotZOf(m, m.boxes[i]) - gz
    var face = 0
    while face < 6:
      let q = boxQuad(m, m.boxes[i], face, dressed.len > 0)
      var corner: array[4, int] = [0, 0, 0, 0]
      var c = 0
      while c < 4:
        # Undressed, the flat colour rides the vertex: a model is one mesh per
        # transform and a mesh wears one colour, so a cow with no picture
        # granted would otherwise be one solid brown lozenge rather than an
        # animal.
        corner[c] = addVertex(
          q.pos[c * 3] + ox, q.pos[c * 3 + 1] + oy, q.pos[c * 3 + 2] + oz,
          q.nx, q.ny, q.nz, q.uv[c * 2], q.uv[c * 2 + 1],
          m.boxes[i].red, m.boxes[i].green, m.boxes[i].blue, 1.0)
        inc c
      addQuad(corner[0], corner[1], corner[2], corner[3])
      inc wrote
      inc face
    inc i
  if wrote == 0:
    let a = addVertex(0.0, 0.0, 0.0)
    addQuad(a, a, a, a)
  finishMesh()
  if dressed.len > 0: useTexture(dressed)

## Every flat entity, as one mesh of camera-facing quads.
##
## The same design and the same reasoning as `resolveChips`, and deliberately
## the same shape of code: one mesh a frame beats a part each, a billboard is
## what makes a flat quad read from every angle, and the basis is worked out
## once for the whole field rather than once per quad.
##
## They all read the same picture, because a mesh wears one material. A dropped
## diamond and a dropped cobblestone are two squares of one sheet, which is
## what `voxel.entity.skins` row `item` is for; with no row they are flat
## coloured squares.
proc resolveFlock*() =
  let dressed = rowFor(EntitySkins, "item")
  beginMesh()
  var wrote = 0
  var i = 0
  while i < folk.list.len:
    let at = folk.list[i].model
    if at < 0 or not models.model[at].flat:
      inc i
      continue
    let m = models.model[at]
    let halfW = m.flatW * 0.5
    let halfH = m.flatH * 0.5
    let rx = flockRight.x * halfW
    let ry = flockRight.y * halfW
    let rz = flockRight.z * halfW
    let ux = flockUp.x * halfH
    let uy = flockUp.y * halfH
    let uz = flockUp.z * halfH
    # Bobbing, because a dropped item that sits perfectly still on the ground
    # reads as part of the ground. The same wave everything else uses.
    let lift = halfH + 0.06 * bobLike(bobPhase(folk.list[i].walked +
      folk.list[i].offset * 2.0, 2.0))
    let cx = folk.list[i].x
    let cy = folk.list[i].y + lift
    let cz = folk.list[i].z
    let a = addVertex(cx - rx - ux, cy - ry - uy, cz - rz - uz,
      -flockAhead.x, -flockAhead.y, -flockAhead.z, 0.0, 0.0,
      1.0, 1.0, 1.0, 1.0)
    let b = addVertex(cx + rx - ux, cy + ry - uy, cz + rz - uz,
      -flockAhead.x, -flockAhead.y, -flockAhead.z, 1.0, 0.0,
      1.0, 1.0, 1.0, 1.0)
    let c = addVertex(cx + rx + ux, cy + ry + uy, cz + rz + uz,
      -flockAhead.x, -flockAhead.y, -flockAhead.z, 1.0, 1.0,
      1.0, 1.0, 1.0, 1.0)
    let d = addVertex(cx - rx + ux, cy - ry + uy, cz - rz + uz,
      -flockAhead.x, -flockAhead.y, -flockAhead.z, 0.0, 1.0,
      1.0, 1.0, 1.0, 1.0)
    addQuad(a, b, c, d)
    inc wrote
    inc i
  if wrote == 0:
    let a = addVertex(0.0, 0.0, 0.0)
    addQuad(a, a, a, a)
  finishMesh()
  if dressed.len > 0: useTexture(dressed)

## Which of the two the resolver is being asked for, or "" for neither. Called
## by the mod's own `resolvePart` before it decides anything else.
proc resolveHerd*(locator: string): bool =
  if locator == "beast":
    resolveBeast()
    return true
  if locator == "flock":
    resolveFlock()
    return true
  false

# ---------------------------------------------------------------------------
# Building and taking away

## A collider on a decoration is a wall you cannot see. See the header: this is
## two crossings a part and it is the host's job, not this file's.
proc unblock(thing: Entity) =
  if thing.isNothing(): return
  let hull = thing.component("UnityEngine.MeshCollider, UnityEngine.PhysicsModule")
  if not hull.isNothing(): hull.set("enabled", false)

proc dropParts(id: int) =
  var i = 0
  while i < partOwner.len:
    if partOwner[i] == id:
      partThing[i].destroy()
      var j = i
      while j + 1 < partOwner.len:
        let owner = partOwner[j + 1]
        let group = partGroup[j + 1]
        let thing = partThing[j + 1]
        partOwner[j] = owner
        partGroup[j] = group
        partThing[j] = thing
        inc j
      partOwner.setLen(partOwner.len - 1)
      partGroup.setLen(partGroup.len - 1)
      partThing.setLen(partThing.len - 1)
    else:
      inc i

proc partOf(id, group: int): Entity =
  var i = 0
  while i < partOwner.len:
    if partOwner[i] == id and partGroup[i] == group: return partThing[i]
    inc i
  nothing()

## Build every transform one mob is drawn as.
##
## The root goes at its feet with no rotation at all, and every moving limb is
## spawned **at its own pivot in the world** and then hung off the transform
## its group belongs to, keeping where it is. That is what turns an absolute
## pivot into the local offset the host wants, without this file ever
## subtracting one - and it is why the root must be square on when this runs.
proc buildParts(at: int) =
  let id = folk.list[at].id
  dropParts(id)
  let which = folk.list[at].model
  if which < 0: return
  let m = models.model[which]
  if m.flat: return
  let here = vec3(folk.list[at].x, folk.list[at].y, folk.list[at].z)
  pendingModel = which
  pendingGroup = -1
  let root = spawnPart(Beasts, "beast", here.x, here.y, here.z)
  root.rotation(0.0, 0.0, 0.0)
  unblock(root)
  partOwner.add id
  partGroup.add -1
  partThing.add root
  var i = 0
  while i < m.boxes.len:
    if m.boxes[i].role != RoleStill:
      pendingModel = which
      pendingGroup = i
      let limb = spawnPart(Beasts, "beast",
        here.x + pivotXOf(m, m.boxes[i]),
        here.y + pivotYOf(m, m.boxes[i]),
        here.z + pivotZOf(m, m.boxes[i]))
      limb.rotation(0.0, 0.0, 0.0)
      unblock(limb)
      var hang = root
      let above = groupOf(m, m.boxes[i].parent)
      if above >= 0:
        let found = partOf(id, above)
        if not found.isNothing(): hang = found
      attach(limb, hang, true)
      partOwner.add id
      partGroup.add i
      partThing.add limb
    inc i
  pendingModel = -1
  pendingGroup = -1

## Take away everything. What unloading a world wants, and what leaving a
## server wants.
proc forgetHerd*() =
  var i = 0
  while i < partThing.len:
    partThing[i].destroy()
    inc i
  partOwner.setLen(0)
  partGroup.setLen(0)
  partThing.setLen(0)
  if not flockThing.isNothing():
    flockThing.destroy()
    flockThing = nothing()
  folk = noBeings()

# ---------------------------------------------------------------------------
# One frame

## The camera's own three directions, once for the whole field.
##
## Handed in rather than read, because the camera is the mod's own `eye` and a
## library module that reached for it would be a module that only works in one
## mod. A flat quad that does not turn to face you is a quad you can lose by
## walking round it, and a hundred of them want one basis rather than a
## hundred.
proc cameraBasis(seat, ahead: Vec3) =
  seatAt = seat
  flockAhead = ahead
  var side = cross(ahead, vec3(0.0, 1.0, 0.0))
  if side.x * side.x + side.y * side.y + side.z * side.z < 0.0001:
    side = vec3(1.0, 0.0, 0.0)
  flockRight = side.norm()
  flockUp = cross(flockRight, ahead).norm()
  focal = focalLength(screenHeight(), FieldOfView)

## How far a mob is from the camera. Squared, because the only thing asked of
## it is a comparison and a square root a mob a frame is a square root a mob a
## frame too many.
proc farFrom(at: int): float =
  let dx = folk.list[at].x - seatAt.x
  let dy = folk.list[at].y - seatAt.y
  let dz = folk.list[at].z - seatAt.z
  dx * dx + dy * dy + dz * dz

## Ask the feed, move everything, and put every transform where the animation
## says.
##
## The order matters and is the order the player's own body follows: what the
## server said, then where that puts it this frame, then where its limbs are
## given where it is.
proc stepHerd*(seconds: float; seat, ahead: Vec3) =
  if handed:
    if handedIn.len > 0:
      let bad = applyFeed(folk, handedIn)
      if bad > 0: log("[voxel] " & $bad & " entity lines the feed said that " &
        "this client could not read")
    handedIn = ""
    handed = false
  elif serves(EntityFeed):
    let answer = callService(EntityFeed, askFor(folk))
    if answer.len > 0:
      let bad = applyFeed(folk, answer)
      if bad > 0: log("[voxel] " & $bad & " entity lines the feed said that " &
        "this client could not read")
  stepBeings(folk, seconds)
  resolveModels(folk, models)
  if folk.unknown.len > toldUnknown:
    while toldUnknown < folk.unknown.len:
      log("[voxel] no model for entity kind '" & folk.unknown[toldUnknown] &
        "'; add a row to entities.conf")
      inc toldUnknown
  # Anything the feed has stopped talking about takes its transforms with it.
  let went = forgetQuiet(folk)
  var g = 0
  while g < went.len:
    dropParts(went[g])
    inc g
  cameraBasis(seat, ahead)

  let now = gameTime()
  var i = 0
  while i < folk.list.len:
    let which = folk.list[i].model
    if which < 0:
      inc i
      continue
    let m = models.model[which]
    if m.flat:
      inc i
      continue
    let near0 = farFrom(i) <= DrawFar * DrawFar
    var root = partOf(folk.list[i].id, -1)
    if near0 and root.isNothing():
      buildParts(i)
      root = partOf(folk.list[i].id, -1)
    if not near0:
      if not root.isNothing(): dropParts(folk.list[i].id)
      inc i
      continue
    if root.isNothing():
      inc i
      continue
    let body = bodyPose(folk.list[i].bodyYaw, folk.list[i].deadFor,
      folk.list[i].hurtFor)
    root.position(vec3(folk.list[i].x, folk.list[i].y, folk.list[i].z))
    root.rotation(body.pitch, body.yaw, body.roll)
    # A creeper about to go off gets bigger and whiter. Both are on the root,
    # so both take every limb with them for one call rather than seven.
    let swell = creeperSwell(folk.list[i].fuse)
    if swell > 1.0001: root.scale(swell)
    let phase = strideAt(folk.list[i].walked)
    var p = 0
    while p < partOwner.len:
      if partOwner[p] == folk.list[i].id and partGroup[p] >= 0:
        let pose = poseOf(m.boxes[partGroup[p]], folk.list[i].bodyYaw,
          folk.list[i].drawnHeadYaw, folk.list[i].drawnPitch,
          phase, folk.list[i].pace, now, folk.list[i].offset,
          folk.list[i].falling)
        partThing[p].rotation(pose.pitch, pose.yaw, pose.roll)
      inc p
    # Hit, or primed. A tint is one crossing on the root and the children are
    # separate materials, so this is the honest limit of what a tint can do
    # here: the body reddens and the limbs do not. Said out loud rather than
    # hidden, because it is the sort of thing that looks like a bug.
    let glow = hurtGlow(folk.list[i].hurtFor)
    let white = creeperGlow(folk.list[i].fuse)
    if glow > 0.0:
      root.color(1.0, 1.0 - glow, 1.0 - glow, 1.0)
    elif white > 0.0:
      root.color(1.0, 1.0, 1.0, 1.0)
    inc i

  # And the flat ones, all in one mesh, exactly as the chips are.
  var flat = 0
  i = 0
  while i < folk.list.len:
    let which = folk.list[i].model
    if which >= 0 and models.model[which].flat: inc flat
    inc i
  if flat == 0:
    if not flockThing.isNothing():
      flockThing.destroy()
      flockThing = nothing()
  else:
    if not flockThing.isNothing(): flockThing.destroy()
    flockThing = spawnPart(Flock, "flock", 0.0, 0.0, 0.0)
    unblock(flockThing)
  flockCount = flat

  # What a run with no screen to look at reads back instead of a photograph.
  # Four numbers and not one: how many things there are, how many transforms
  # they cost, how many of them are flat, and how far they have all walked
  # between them. The last is the one that separates a world of mobs from a
  # world of statues - a still picture cannot, and neither can a count.
  var walked = 0.0
  var near = 0
  var away = -1.0
  i = 0
  while i < folk.list.len:
    walked = walked + folk.list[i].walked
    # And how far off the nearest one is, as three axes added rather than a
    # length, because a square root a frame to answer a diagnostic is a square
    # root too many. Zero entities near and this number large is a producer
    # putting its herd somewhere the camera is not, which is otherwise
    # indistinguishable from a renderer that has stopped building parts.
    let dx = folk.list[i].x - seatAt.x
    let dy = folk.list[i].y - seatAt.y
    let dz = folk.list[i].z - seatAt.z
    var reach = dx
    if reach < 0.0: reach = -reach
    var up = dy
    if up < 0.0: up = -up
    var along = dz
    if along < 0.0: along = -along
    let sum = reach + up + along
    if away < 0.0 or sum < away: away = sum
    # How many are near enough to be built at all. Worth its own number: a world
    # of twelve entities and no transforms reads as a renderer that has stopped
    # working, and is usually a producer that put its herd somewhere else - the
    # far ones are correctly not built, and nothing else says so.
    if folk.list[i].model >= 0 and not models.model[folk.list[i].model].flat and
       farFrom(i) <= DrawFar * DrawFar: inc near
    inc i
  let now0 = $beingCount(folk) & "/" & $partThing.len & "/" & $flat &
    "/" & $int(walked) & "/" & $near & "/" & $int(away)
  if now0 != said:
    said = now0
    log("[assert] voxel.entities=" & $beingCount(folk))
    log("[assert] voxel.entityparts=" & $partThing.len)
    log("[assert] voxel.entityflat=" & $flat)
    log("[assert] voxel.entitywalk=" & $int(walked))
    log("[assert] voxel.entitynear=" & $near)
    log("[assert] voxel.entityaway=" & $int(away))

# ---------------------------------------------------------------------------
# The names over their heads

## Every nameplate, as ordinary text on the screen.
##
## There is no world-space text on the host surface, so a plate is a world
## point put on the screen by hand: three dot products and a divide against the
## camera basis this frame (`vxturn.screenOf`), then one `drawText`. One
## crossing a plate, and only for the ones that are near enough and in front of
## the camera - a point behind the eye projects to a point in front of it,
## mirrored, which would hang the name of the thing at your back over the thing
## in front of you.
##
## Called from `drawGui` and not from the frame, because that is where drawing
## is allowed.
proc drawPlates*() =
  var i = 0
  while i < folk.list.len:
    if folk.list[i].label.len == 0:
      inc i
      continue
    let which = folk.list[i].model
    if which < 0:
      inc i
      continue
    if not models.model[which].plate:
      inc i
      continue
    let away0 = farFrom(i)
    if away0 > PlateFar * PlateFar:
      inc i
      continue
    let top = folk.list[i].y + models.model[which].height + PlateHeight
    let seen = screenOf(folk.list[i].x, top, folk.list[i].z,
      seatAt.x, seatAt.y, seatAt.z,
      flockRight.x, flockRight.y, flockRight.z,
      flockUp.x, flockUp.y, flockUp.z,
      flockAhead.x, flockAhead.y, flockAhead.z,
      screenWidth(), screenHeight(), focal)
    if not seen.on:
      inc i
      continue
    # Smaller with distance, the way anything in the world is, and floored so
    # that a name across a field is still a name and not a smear.
    var size = PlateSize * 4.0 / seen.ahead
    if size > PlateSize * 1.6: size = PlateSize * 1.6
    if size < 7.0: size = 7.0
    let wide = 220.0
    writeIn(folk.list[i].label,
      rect(seen.x - wide * 0.5, seen.y - size, wide, size * 1.4),
      size, AlignCentre, Color(r: 1.0, g: 1.0, b: 1.0, a: 0.9))
    inc i

# ---------------------------------------------------------------------------
# Starting

## Read the models, declare the catalogs, and say what is missing.
##
## `entities.conf` beside this mod, if a modpack has put one there, is layered
## over the shipped rows field by field - so a pack that wants a taller zombie
## ships one line rather than a model, and a pack that wants a mob nobody has
## heard of ships that too and nothing in this mod learns about it. This
## repository ships no such file: the rows it ships are in `vxbeasts.nim`,
## where the test can read them, and a second copy on disk would be a second
## copy to go stale.
proc ownFile(path: string): string =
  ## A file beside this mod, or "". `readBytes` and not `modelBytes`: the
  ## second opens only inside the proc answering a part request and the real
  ## host refuses it anywhere else, which is a thing that reads fine headless
  ## and takes `start()` down in the game.
  let handle = readBytes(path)
  if handle == 0: return ""
  result = textAt(handle, 0, byteCount(handle))
  closeBytes(handle)

proc startHerd*(usingScheme, usingSkinKind: string) =
  scheme = usingScheme
  skinKind = usingSkinKind
  models = readModels(Models)
  let body = ownFile(ModelFile)
  if body.len > 0:
    models = parseModels(body, models)
    log("[voxel] " & ModelFile & " layered over the shipped models")
  let problems = problemsIn(models)
  var i = 0
  while i < problems.len:
    log("[voxel] entity model problem: " & problems[i])
    inc i
  discard catalog(Beasts, "aoughwl.part", "The things in the world, as boxes")
    .put("beast", scheme & "://beast")
  discard catalog(Flock, "aoughwl.part",
    "Everything flat enough to be one square of a picture")
    .put("flock", scheme & "://flock")
  # And the rows somebody else fills with pictures for them. Declared here and
  # left empty here, for the reason the player's own skin row is: the picture
  # is out of the copy of Minecraft the player granted, so the mod that reads
  # that copy is the mod that fills these in.
  discard catalog(EntitySkins, skinKind,
    "What each kind of entity wears, by the name of its model")
  log("[voxel] " & $modelCount(models) & " entity models")
  log("[assert] voxel.entitymodels=" & $modelCount(models))
