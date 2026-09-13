## What is out there: the table every consumer of this wire has to keep.
##
## `netentity.nim` reads the entity packets. This file is what a client does
## with them, and it exists because of one fact about the protocol that no
## amount of decoding gets around:
##
## **A relative move carries no absolute position.** `move_entity_pos` is three
## shorts of 1/4096th of a block and nothing else, and in a recorded join of the
## real vanilla client there are 18,498 of those against 867 absolute syncs and
## 293 spawns - twenty to one. So a client, ours or Mojang's, must hold
## `{id -> x, y, z, body yaw, head yaw, pitch}` and add into it, or it does not
## know where anything is. There is no design that avoids this table; the only
## question is who owns it, and it is protocol state, so it is here.
##
## Everything in this file is arithmetic over decoded packets. Nothing calls a
## host, nothing touches a socket, nothing knows what a renderer is, and the
## coordinates and angles stay in **Minecraft's own frame** - y from the world's
## own bottom, yaw clockwise from +Z through -X - because turning them into some
## engine's is the seam's job and not the protocol's. `vxmcplay.herdFeed` is
## where that conversion happens, once, beside the three conversions this client
## already makes for its own body.
##
## ## The dirty bit is one per entity, not one per field
##
## Body yaw and head yaw arrive in different packets, and `rotate_head` arrives
## more often than anything else on the wire - 13,223 times in that same join.
## A feed line carries all six numbers together, so a mob that only turned its
## head still emits a whole line. That is the cheap side of the trade: a line is
## smaller than the bookkeeping needed to avoid one, and "changed" is therefore
## a single bit per entity. See `docs/ENTITIES.md` §2.
##
## ## Finding an entity by its id
##
## A linear sweep would be right for tens of entities and is wrong for a real
## server: a loaded world is a few hundred, a move packet is a few hundred a
## second, and an interpreted loop step is about 0.7us - so the sweep alone
## would be tens of milliseconds a second before anything was drawn. Ids are
## handed out from one and upward and never reused inside a session, so the
## table below is indexed *by the id itself* up to `IndexCap` and swept only
## past it. A session long enough to pass sixty-five thousand ids gets the slow
## path for the tail rather than a wrong answer.

import netentity

const
  IndexCap* = 65536
    ## How far the id -> slot table reaches. Past it, a sweep. A fresh server
    ## hands out ids from one, so this is "the first sixty-five thousand
    ## entities of a session", which is every session anyone has played here.

  Missing* = -1

type
  Beast* = object
    id*: int
    kind*: int
      ## The `minecraft:entity_type` registry id, exactly as `add_entity` sent
      ## it. Naming it needs that registry, which is the caller's - see
      ## `Imported/entitytypes.txt` and `tools/mcindex.ps1`.
    x*, y*, z*: float
      ## Minecraft's own metres. The **feet**, which is what every entity packet
      ## carries and what a box model is authored from.
    yaw*, headYaw*, pitch*: float
      ## Minecraft's own degrees, clockwise from +Z through -X.
    onGround*: bool
      ## Whether the server said it was standing on something, the last time it
      ## said anything at all about where it was. Every move, rotate, teleport
      ## and sync packet carries this byte - which is why nothing here has to
      ## guess at it from a velocity. See the note on velocity at the foot.
    dead*: bool
    label*: string
    announced*: bool
      ## Whether a `+` has gone out for it yet.
    changed*: bool
      ## One bit for the whole entity: position, either yaw, pitch.
    stateChanged*: bool
      ## The same for what it *is* rather than where: alive or dead, in the air
      ## or on the ground.
    hurts*: int
      ## Hits the server has reported and the feed has not passed on yet. A
      ## count and not a flag, because two hits in one frame are two flinches
      ## and a flag would drop one.

  Herd* = object
    list*: seq[Beast]
    index*: seq[int]
      ## id -> slot, for ids below `IndexCap`. `Missing` for an id nobody has
      ## announced.
    gone*: seq[int]
      ## Ids removed since the last feed was taken. Held rather than acted on,
      ## because the consumer has to be told once and the removal has already
      ## taken the row away.
    mine*: int
      ## This client's own entity id, which is never in the table: the player's
      ## own body is drawn by whoever owns the camera, and a second copy of it
      ## standing in the same place is the classic way this goes wrong.
    tick*: int
      ## Bumped every time the feed is taken. The consumer hands it back and it
      ## is what makes an answer a delta rather than a census.
    spawns*, removes*, moves*, hurtsSeen*, deathsSeen*: int
      ## What has been seen, for a play script to assert about.
    newest*: int
      ## The last id the server announced. Kept for one reason and it is a
      ## testing one: a play script that summons something and then wants to ask
      ## the server about *that* thing needs to name it, and "the most recent
      ## spawn" is the only handle a producer can offer that a script can
      ## predict. "The nearest" cannot - another player standing closer changes
      ## the answer, which is how this was found out.
    orphans*: int
      ## Packets about an id that was never announced. Not an error - a join
      ## races the server's own entity tracker - but a number worth watching,
      ## because a large one means a decoder is reading the wrong field as an id.

proc emptyHerd*(): Herd =
  Herd(list: @[], index: @[], gone: @[], mine: -1, tick: 0,
       spawns: 0, removes: 0, moves: 0, hurtsSeen: 0, deathsSeen: 0,
       newest: -1, orphans: 0)

proc beastCount*(h: Herd): int = h.list.len

proc ownEntity*(h: var Herd; id: int) =
  ## Say which one is us. Called when `login` names it.
  h.mine = id

## Which slot holds that id, or `Missing`.
proc slotOf*(h: Herd; id: int): int =
  if id >= 0 and id < h.index.len: return h.index[id]
  # Past the indexed range, or below it, which cannot happen but is answered
  # rather than assumed. A sweep, and see the header for why it is acceptable.
  var i = 0
  while i < h.list.len:
    if h.list[i].id == id: return i
    inc i
  Missing

proc noteIndex(h: var Herd; id, slot: int) =
  if id < 0 or id >= IndexCap: return
  while h.index.len <= id: h.index.add Missing
  h.index[id] = slot

proc dropIndex(h: var Herd; id: int) =
  if id >= 0 and id < h.index.len: h.index[id] = Missing

## Take one out. The row is shuffled down, so every slot after it moves and the
## index has to be rewritten for them - which is the price of a flat list and is
## paid on a `remove_entities` and nowhere else.
proc forget*(h: var Herd; id: int) =
  let slot = slotOf(h, id)
  if slot < 0: return
  dropIndex(h, id)
  var j = slot
  while j + 1 < h.list.len:
    # Through a local: a seq element assigned straight from another element of
    # the same seq is two references to one buffer and the toolchain refuses it.
    let moved = h.list[j + 1]
    h.list[j] = moved
    noteIndex(h, moved.id, j)
    inc j
  h.list.setLen(h.list.len - 1)
  # A handle to something that is gone is worse than no handle: it answers
  # nothing for ever rather than answering wrongly once.
  if h.newest == id: h.newest = Missing
  h.gone.add id
  inc h.removes

proc forgetAll*(h: var Herd) =
  ## A dimension change, a respawn into another world, or leaving the server.
  ## Everything the consumer was told about is told to go.
  var i = 0
  while i < h.list.len:
    h.gone.add h.list[i].id
    inc i
  h.list.setLen(0)
  h.index.setLen(0)

## The slot for an id, making one if the server has talked about something it
## never announced. That happens on a join - the entity tracker starts sending
## moves the moment it can, and a spawn can be a packet behind - and the right
## answer is to keep what it said and fill the kind in when the spawn lands,
## which is exactly what the feed's own grammar does one level up.
proc slotFor(h: var Herd; id: int; made: var bool): int =
  made = false
  result = slotOf(h, id)
  if result >= 0: return
  made = true
  h.list.add Beast(id: id, kind: Missing, x: 0.0, y: 0.0, z: 0.0,
                   yaw: 0.0, headYaw: 0.0, pitch: 0.0, onGround: true,
                   dead: false, label: "", announced: false, changed: true,
                   stateChanged: true, hurts: 0)
  result = h.list.len - 1
  noteIndex(h, id, result)

# ---------------------------------------------------------------------------
# The packets

proc onAdd*(h: var Herd; p: SpawnEntityPacket) =
  if p.entityId == h.mine: return
  var made = false
  let slot = slotFor(h, p.entityId, made)
  h.list[slot].kind = p.kind
  h.list[slot].x = p.x
  h.list[slot].y = p.y
  h.list[slot].z = p.z
  h.list[slot].yaw = p.yaw
  h.list[slot].headYaw = p.headYaw
  h.list[slot].pitch = p.pitch
  h.list[slot].dead = false
  h.list[slot].announced = false
  h.list[slot].changed = true
  h.list[slot].stateChanged = true
  h.newest = p.entityId
  inc h.spawns

proc onMove*(h: var Herd; p: MovePacket) =
  if p.entityId == h.mine: return
  var made = false
  let slot = slotFor(h, p.entityId, made)
  if made: inc h.orphans
  h.list[slot].x = h.list[slot].x + p.dx
  h.list[slot].y = h.list[slot].y + p.dy
  h.list[slot].z = h.list[slot].z + p.dz
  if p.hasRotation:
    h.list[slot].yaw = p.yaw
    h.list[slot].pitch = p.pitch
  if h.list[slot].onGround != p.onGround:
    h.list[slot].onGround = p.onGround
    h.list[slot].stateChanged = true
  h.list[slot].changed = true
  inc h.moves

proc onRotate*(h: var Herd; p: RotatePacket) =
  if p.entityId == h.mine: return
  var made = false
  let slot = slotFor(h, p.entityId, made)
  if made: inc h.orphans
  h.list[slot].yaw = p.yaw
  h.list[slot].pitch = p.pitch
  if h.list[slot].onGround != p.onGround:
    h.list[slot].onGround = p.onGround
    h.list[slot].stateChanged = true
  h.list[slot].changed = true

proc onHeadRotation*(h: var Herd; p: HeadRotationPacket) =
  ## The most common entity packet on the wire, and the one that carries the
  ## least: one angle byte. It still dirties the whole entity - see the header.
  if p.entityId == h.mine: return
  var made = false
  let slot = slotFor(h, p.entityId, made)
  if made: inc h.orphans
  h.list[slot].headYaw = p.headYaw
  h.list[slot].changed = true

proc onTeleport*(h: var Herd; p: TeleportPacket) =
  if p.entityId == h.mine: return
  var made = false
  let slot = slotFor(h, p.entityId, made)
  if made: inc h.orphans
  h.list[slot].x = p.x
  h.list[slot].y = p.y
  h.list[slot].z = p.z
  h.list[slot].yaw = p.yaw
  h.list[slot].pitch = p.pitch
  if h.list[slot].onGround != p.onGround:
    h.list[slot].onGround = p.onGround
    h.list[slot].stateChanged = true
  h.list[slot].changed = true

proc onSync*(h: var Herd; p: SyncPositionPacket) =
  ## `entity_position_sync`, which is the newer absolute form and is what the
  ## server sends when its own copy has drifted from what the relative moves add
  ## up to. Its angles are whole floats and not angle bytes.
  if p.entityId == h.mine: return
  var made = false
  let slot = slotFor(h, p.entityId, made)
  if made: inc h.orphans
  h.list[slot].x = p.x
  h.list[slot].y = p.y
  h.list[slot].z = p.z
  h.list[slot].yaw = p.yaw
  h.list[slot].pitch = p.pitch
  if h.list[slot].onGround != p.onGround:
    h.list[slot].onGround = p.onGround
    h.list[slot].stateChanged = true
  h.list[slot].changed = true

proc onRemove*(h: var Herd; p: RemoveEntitiesPacket) =
  var i = 0
  while i < p.entityIds.len:
    forget(h, p.entityIds[i])
    inc i

proc onHurt*(h: var Herd; id: int) =
  ## `damage_event`, which is where a hit lives at this protocol. It was entity
  ## status 2 until 1.19.4 and is not any more; a client still reading status 2
  ## sees no flinch on a modern server and no error either.
  if id == h.mine: return
  let slot = slotOf(h, id)
  if slot < 0: return
  inc h.list[slot].hurts
  inc h.hurtsSeen

const
  StatusDeath* = 3
    ## `entity_event`. Three is "it died" and is what plays the death animation
    ## on the vanilla client. Everything else in that byte is a particle, a
    ## sound or a mob-specific flourish, and this file acts on none of them.

proc onEvent*(h: var Herd; p: EntityEventPacket) =
  if p.entityId == h.mine: return
  let slot = slotOf(h, p.entityId)
  if slot < 0: return
  if p.status == StatusDeath and not h.list[slot].dead:
    h.list[slot].dead = true
    h.list[slot].stateChanged = true
    inc h.deathsSeen

# ---------------------------------------------------------------------------
# Taking the delta
#
# The consumer says which tick it last heard about. Two answers are possible and
# the difference matters:
#
#   * it is up to date, and gets what has changed since - which is the whole
#     point and is usually a handful of lines;
#   * it is behind (it missed an answer, or it is new, or the world was thrown
#     away under it), and gets everything.
#
# Nothing here writes a line. The grammar's writer is `vxbeing.say*`, which is
# on the consumer's side of the seam, and a producer that spelled the lines out
# by hand would be a second dialect of the same grammar with nothing checking
# the two agree.

proc behind*(h: Herd; since: int): bool = since != h.tick

proc dirty*(h: Herd; slot: int): bool =
  h.list[slot].changed or h.list[slot].stateChanged or
    h.list[slot].hurts > 0 or not h.list[slot].announced

## Every change has been written out. Bumps the tick, so the next `since` that
## matches it asks for what happens after this moment and nothing before it.
proc taken*(h: var Herd) =
  var i = 0
  while i < h.list.len:
    h.list[i].announced = true
    h.list[i].changed = false
    h.list[i].stateChanged = false
    h.list[i].hurts = 0
    inc i
  h.gone.setLen(0)
  inc h.tick

# ---------------------------------------------------------------------------
# Velocity, and why there is no verb for it
#
# `set_entity_motion` arrives 9,845 times in seventy seconds of a real join,
# more often than any single position packet, and `netentity.readLpVec3` decodes
# every one of them. Nothing in this file stores one, deliberately.
#
# **It is not a position and adding it to one double-counts.** Server-side
# movement is integrated by the server, and the result is already on the wire as
# the next relative move. A client that also advanced by the velocity would be
# ahead of the server by exactly as much as it extrapolated, and would be pulled
# back on the following move - which is a stutter, not smoothing.
#
# **The one thing a consumer would reach for it to learn is already there.**
# "Is this thing in the air" is what a drawn mob needs - it is the difference
# between legs that swing and legs that hang - and every move, rotate, teleport
# and sync packet carries an `onGround` byte that says so exactly. A velocity
# threshold is a guess at a fact the wire states.
#
# So `docs/ENTITIES.md` records velocity as deliberately dropped rather than
# growing a `~` verb for it, and `onGround` is passed on through the `falling`
# state the grammar already had.
