## Entities, and the one type in this protocol with no length prefix anywhere.
##
## Most of the entity packets are three fields. `set_entity_data` is not, and it
## is the reason this file exists:
##
##     repeat:
##       index : u8            0xFF ends the list
##       type  : VarInt        which of 39 value shapes follows
##       value : depends       and there is no length in front of it
##
## **There is no way to skip a value you do not understand.** Not one you do not
## care about - one you cannot *parse*. So a metadata reader is only correct if
## it knows the width of every one of the 39 types, and a reader that guesses at
## one of them does not produce one wrong field, it loses the rest of the list
## and every packet after it in the same frame. That is why the table below is
## written out in full, with the four it cannot read named and refused rather
## than stepped over.
##
## **THE TYPE NUMBERS ARE ORDINALS AND THEY MOVE.** They are the declaration
## order of the games own serializer registry, exactly like packet ids, and the
## list grew by four entries between 1.21 and 774 - every mob variant added in
## between pushed the ones after it along. So the numbers here are not spelled
## as literals in the reading code: `MetaByte`, `MetaItemStack` and the rest are
## constants that a caller can *override* from a version profile through
## `MetaLayout`, and `layoutFor774` is the one this build ships with. A caller
## with a different jar builds a different layout and the reader does not
## change.
##
## THE THREE THAT ARE NOT WHAT THEY LOOK LIKE, and each is a real bug someone
## has shipped:
##
##   * `optional_block_state` and `optional_unsigned_int` are a **plain VarInt**
##     where zero means absent. They are not a boolean followed by a value, the
##     way every other optional on this wire is. Reading a leading boolean eats
##     the low byte of the VarInt and leaves the rest.
##   * `optional_component`, `optional_block_pos`, `optional_uuid` and
##     `optional_global_pos` *are* the boolean form. The four above and these
##     four sit next to each other in the table and differ, which is the whole
##     trap.
##   * `painting_variant` is a registry entry holder: a VarInt that is `id + 1`,
##     or zero and then the whole variant inline.
##
## Nothing here allocates on a claimed length it has not checked, and a refusal
## sets `problem` on the reader so the packet - and the connection - stops rather
## than continuing from the wrong byte.

import netwire
import netnbt
import netslot

const
  MetaEnd* = 0xFF
    ## The index that ends a metadata list. It is an index, not a type, which is
    ## why it is 0xFF and not -1: the index field is one unsigned byte.
  MaxMetaEntries* = 256
    ## An entity has fewer than a hundred synched fields in vanilla. This is a
    ## bound on a list that claims to go on forever.

  # The 774 ordinals. Named so that the reader below never spells a number.
  MetaByte* = 0
  MetaInt* = 1
  MetaLong* = 2
  MetaFloat* = 3
  MetaString* = 4
  MetaComponent* = 5
  MetaOptionalComponent* = 6
  MetaItemStack* = 7
  MetaBoolean* = 8
  MetaRotations* = 9
  MetaBlockPos* = 10
  MetaOptionalBlockPos* = 11
  MetaDirection* = 12
  MetaOptionalUuid* = 13
  MetaBlockState* = 14
  MetaOptionalBlockState* = 15
  MetaParticle* = 16
  MetaParticles* = 17
  MetaVillagerData* = 18
  MetaOptionalUnsignedInt* = 19
  MetaPose* = 20
  MetaCatVariant* = 21
  MetaCowVariant* = 22
  MetaWolfVariant* = 23
  MetaWolfSoundVariant* = 24
  MetaFrogVariant* = 25
  MetaPigVariant* = 26
  MetaChickenVariant* = 27
  MetaZombieNautilusVariant* = 28
  MetaOptionalGlobalPos* = 29
  MetaPaintingVariant* = 30
  MetaSnifferState* = 31
  MetaArmadilloState* = 32
  MetaCopperGolemState* = 33
  MetaWeatheringCopperGolemState* = 34
  MetaVector3* = 35
  MetaQuaternion* = 36
  MetaResolvableProfile* = 37
  MetaHumanoidArm* = 38
  MetaTypeCount* = 39

  # What a value is made of, once the ordinal has been resolved through the
  # layout. These are this files own vocabulary and never appear on the wire.
  WireVarInt* = 0
  WireVarLong* = 1
  WireByte* = 2
  WireFloat* = 3
  WireString* = 4
  WireNbt* = 5
  WireOptionalNbt* = 6
  WireSlot* = 7
  WireBool* = 8
  WireThreeFloats* = 9
  WireFourFloats* = 10
  WireLong* = 11
  WireOptionalLong* = 12
  WireOptionalUuid* = 13
  WireOptVarInt* = 14
  WireThreeVarInts* = 15
  WireOptionalGlobalPos* = 16
  WireHolder* = 17
  WireUnsupported* = 18

type
  MetaLayout* = object
    ## ordinal -> wire shape. A caller with a different version replaces rows
    ## rather than editing this file, which is the same rule the packet table
    ## follows and for the same reason.
    shape*: seq[int]
    name*: seq[string]

  MetaEntry* = object
    index*: int            ## which synched field of the entity
    kind*: int             ## the ordinal as it arrived
    shape*: int            ## what this build resolved it to
    present*: bool         ## for the optional shapes
    num*: int
    dec*: float
    dec2*, dec3*, dec4*: float
    text*: string
    item*: SlotItem
    value*: Nbt
    at*, len*: int         ## the span the value occupied, for anything unread

  Equipment* = object
    slot*: int
    item*: SlotItem

proc emptyLayout*(): MetaLayout =
  MetaLayout(shape: @[], name: @[])

proc declareMeta*(l: var MetaLayout; ordinal, shape: int; name: string) =
  if ordinal < 0 or ordinal > 4096: return
  while l.shape.len <= ordinal:
    l.shape.add WireUnsupported
    l.name.add ""
  l.shape[ordinal] = shape
  l.name[ordinal] = name

proc shapeOfMeta*(l: MetaLayout; ordinal: int): int =
  if ordinal < 0 or ordinal >= l.shape.len: WireUnsupported
  else: l.shape[ordinal]

proc nameOfMeta*(l: MetaLayout; ordinal: int): string =
  if ordinal < 0 or ordinal >= l.name.len: "" else: l.name[ordinal]

proc layoutFor774*(): MetaLayout =
  ## The 39 serializers at protocol 774, in their declaration order. Four are
  ## `WireUnsupported`, and they are the four whose value is itself a tagged
  ## union deep enough to be its own file - the particle types, and a player
  ## profile with its skin patch. They are refused by name.
  result = emptyLayout()
  declareMeta(result, MetaByte, WireByte, "byte")
  declareMeta(result, MetaInt, WireVarInt, "int")
  declareMeta(result, MetaLong, WireVarLong, "long")
  declareMeta(result, MetaFloat, WireFloat, "float")
  declareMeta(result, MetaString, WireString, "string")
  declareMeta(result, MetaComponent, WireNbt, "component")
  declareMeta(result, MetaOptionalComponent, WireOptionalNbt,
              "optional_component")
  declareMeta(result, MetaItemStack, WireSlot, "item_stack")
  declareMeta(result, MetaBoolean, WireBool, "boolean")
  declareMeta(result, MetaRotations, WireThreeFloats, "rotations")
  declareMeta(result, MetaBlockPos, WireLong, "block_pos")
  declareMeta(result, MetaOptionalBlockPos, WireOptionalLong,
              "optional_block_pos")
  declareMeta(result, MetaDirection, WireVarInt, "direction")
  declareMeta(result, MetaOptionalUuid, WireOptionalUuid, "optional_uuid")
  declareMeta(result, MetaBlockState, WireVarInt, "block_state")
  # Not a boolean and a value. A plain VarInt, zero meaning none.
  declareMeta(result, MetaOptionalBlockState, WireOptVarInt,
              "optional_block_state")
  declareMeta(result, MetaParticle, WireUnsupported, "particle")
  declareMeta(result, MetaParticles, WireUnsupported, "particles")
  declareMeta(result, MetaVillagerData, WireThreeVarInts, "villager_data")
  declareMeta(result, MetaOptionalUnsignedInt, WireOptVarInt,
              "optional_unsigned_int")
  declareMeta(result, MetaPose, WireVarInt, "pose")
  declareMeta(result, MetaCatVariant, WireVarInt, "cat_variant")
  declareMeta(result, MetaCowVariant, WireVarInt, "cow_variant")
  declareMeta(result, MetaWolfVariant, WireVarInt, "wolf_variant")
  declareMeta(result, MetaWolfSoundVariant, WireVarInt, "wolf_sound_variant")
  declareMeta(result, MetaFrogVariant, WireVarInt, "frog_variant")
  declareMeta(result, MetaPigVariant, WireVarInt, "pig_variant")
  declareMeta(result, MetaChickenVariant, WireVarInt, "chicken_variant")
  declareMeta(result, MetaZombieNautilusVariant, WireVarInt,
              "zombie_nautilus_variant")
  declareMeta(result, MetaOptionalGlobalPos, WireOptionalGlobalPos,
              "optional_global_pos")
  declareMeta(result, MetaPaintingVariant, WireHolder, "painting_variant")
  declareMeta(result, MetaSnifferState, WireVarInt, "sniffer_state")
  declareMeta(result, MetaArmadilloState, WireVarInt, "armadillo_state")
  declareMeta(result, MetaCopperGolemState, WireVarInt, "copper_golem_state")
  declareMeta(result, MetaWeatheringCopperGolemState, WireVarInt,
              "weathering_copper_golem_state")
  declareMeta(result, MetaVector3, WireThreeFloats, "vector3")
  declareMeta(result, MetaQuaternion, WireFourFloats, "quaternion")
  declareMeta(result, MetaResolvableProfile, WireUnsupported,
              "resolvable_profile")
  declareMeta(result, MetaHumanoidArm, WireVarInt, "humanoid_arm")

proc metaRefusal*(l: MetaLayout; ordinal: int): string =
  let n = nameOfMeta(l, ordinal)
  if n.len == 0:
    "an entity metadata type this build does not know: " & $ordinal
  else:
    "no reader for the entity metadata type " & n

# ---------------------------------------------------------------------------

proc readMetaValue(r: var Reader; l: MetaLayout; t: ComponentTable;
                   e: var MetaEntry) =
  case e.shape
  of WireByte:
    e.num = readSByte(r)
  of WireVarInt:
    e.num = readVarInt(r)
  of WireVarLong:
    e.num = readVarLong(r)
  of WireLong:
    e.num = readLong(r)
  of WireFloat:
    e.dec = readFloat(r)
  of WireString:
    e.text = readString(r)
  of WireBool:
    e.num = readByte(r)
    e.present = e.num != 0
  of WireNbt:
    e.value = readNbt(r)
    if e.value.problem.len > 0: fail(r, e.value.problem)
    e.present = true
  of WireOptionalNbt:
    e.present = readBool(r)
    if e.present and ok(r):
      e.value = readNbt(r)
      if e.value.problem.len > 0: fail(r, e.value.problem)
  of WireSlot:
    e.item = readSlot(r, t)
    e.present = not e.item.empty
  of WireThreeFloats:
    e.dec = readFloat(r)
    e.dec2 = readFloat(r)
    e.dec3 = readFloat(r)
  of WireFourFloats:
    e.dec = readFloat(r)
    e.dec2 = readFloat(r)
    e.dec3 = readFloat(r)
    e.dec4 = readFloat(r)
  of WireOptionalLong:
    e.present = readBool(r)
    if e.present and ok(r): e.num = readLong(r)
  of WireOptionalUuid:
    e.present = readBool(r)
    if e.present and ok(r):
      discard readLong(r)
      discard readLong(r)
  of WireOptVarInt:
    # The trap. A plain VarInt; zero is absent and a present value is one more
    # than it is. No leading boolean.
    let v = readVarInt(r)
    e.present = v != 0
    e.num = if v > 0: v - 1 else: 0
  of WireThreeVarInts:
    e.num = readVarInt(r)
    discard readVarInt(r)
    discard readVarInt(r)
  of WireOptionalGlobalPos:
    e.present = readBool(r)
    if e.present and ok(r):
      e.text = readString(r)
      e.num = readLong(r)
  of WireHolder:
    let tag = readVarInt(r)
    if tag == 0:
      # The inline form carries a whole painting variant - width, height, the
      # asset id and an optional title and author. Refused rather than guessed,
      # because getting it wrong loses the rest of the list.
      fail(r, "an inline registry entry in entity metadata, which this build " &
              "does not read")
    else:
      e.present = true
      e.num = tag - 1
  else:
    fail(r, metaRefusal(l, e.kind))

proc readMetadata*(r: var Reader; l: MetaLayout;
                   t: ComponentTable): seq[MetaEntry] =
  ## The whole list, up to and including its 0xFF terminator.
  result = @[]
  if not ok(r): return
  while true:
    let index = readByte(r)
    if not ok(r):
      fail(r, "entity metadata ran off the end before its terminator")
      return
    if index == MetaEnd: return
    if result.len >= MaxMetaEntries:
      fail(r, "an entity metadata list longer than any entity has fields")
      return
    let kind = readVarInt(r)
    if not ok(r): return
    var e = MetaEntry(index: index, kind: kind, shape: shapeOfMeta(l, kind),
                      present: false, num: 0, dec: 0.0, dec2: 0.0, dec3: 0.0,
                      dec4: 0.0, text: "", item: emptySlot(),
                      value: emptyNbt(), at: r.at, len: 0)
    readMetaValue(r, l, t, e)
    if not ok(r): return
    e.len = r.at - e.at
    result.add e

proc metaAt*(entries: seq[MetaEntry]; index: int): int =
  ## Which entry carries synched field `index`, or -1. Entities send only the
  ## fields that changed, so asking by index is the only way to ask.
  var i = 0
  while i < entries.len:
    if entries[i].index == index: return i
    inc i
  result = -1

# ---------------------------------------------------------------------------
# The entity packets

type
  SpawnEntityPacket* = object
    entityId*: int
    uuid*: Uuid
    kind*: int
    x*, y*, z*: float
    pitch*, yaw*, headYaw*: float
    data*: int             ## meaning depends on `kind`, and often on nothing
    vx*, vy*, vz*: float   ## blocks per tick, from the 8000ths the wire sends

  MovePacket* = object
    ## `move_entity_pos` and `move_entity_pos_rot`. The deltas are in
    ## **1/4096ths of a block**, which is what lets a move be three shorts, and
    ## which caps a single move at eight blocks - past that the server sends a
    ## teleport instead.
    entityId*: int
    dx*, dy*, dz*: float
    yaw*, pitch*: float
    hasRotation*: bool
    onGround*: bool

  RotatePacket* = object
    entityId*: int
    yaw*, pitch*: float
    onGround*: bool

  TeleportPacket* = object
    entityId*: int
    x*, y*, z*: float
    yaw*, pitch*: float
    onGround*: bool

  SyncPositionPacket* = object
    ## `entity_position_sync`, which is the newer absolute form and carries
    ## velocity as well. Distinct from `teleport_entity`, and both exist.
    entityId*: int
    x*, y*, z*: float
    dx*, dy*, dz*: float
    yaw*, pitch*: float
    onGround*: bool

  VelocityPacket* = object
    entityId*: int
    vx*, vy*, vz*: float

  MetadataPacket* = object
    entityId*: int
    entries*: seq[MetaEntry]

  EquipmentPacket* = object
    entityId*: int
    items*: seq[Equipment]

  AnimatePacket* = object
    entityId*: int
    animation*: int

  EntityEventPacket* = object
    entityId*: int
    status*: int

  AttachPacket* = object
    entityId*, vehicleId*: int

  PassengersPacket* = object
    vehicleId*: int
    passengers*: seq[int]

  HeadRotationPacket* = object
    entityId*: int
    headYaw*: float

  RemoveEntitiesPacket* = object
    entityIds*: seq[int]

  TakeItemPacket* = object
    collectedId*, collectorId*, count*: int

const
  DeltaUnits* = 4096.0
    ## A relative move is three shorts of 1/4096th of a block, which is what
    ## caps a single relative move at eight blocks.

  QuantizedMax* = 32766.0
    ## The quantiser velocity is packed through. Not 32767 and not 32768: the
    ## packer divides by exactly this, and being one out puts a small error on
    ## every velocity in the world.
  LpScaleMask* = 3
  LpContinues* = 4

type
  Vec3* = object
    x*, y*, z*: float

proc lpUnpack(packed, shift: int): float =
  ## One component out of the 48-bit word. `and 0x7FFF` is the modulo the packer
  ## does, and the clamp after it is the packers own - a value of 32767 is out of
  ## range and is pulled back rather than read as slightly over one.
  var quantized = (packed shr shift) and 0x7FFF
  if quantized > 32766: quantized = 32766
  (float(quantized) * 2.0) / QuantizedMax - 1.0

proc readLpVec3*(r: var Reader): Vec3 =
  ## **Velocity is not three shorts any more, and this is what caught it.**
  ##
  ## Through 1.21.8 a velocity on the wire was three signed shorts of 1/8000th
  ## of a block per tick - six bytes, always. At 774 it is a *quantised* vector:
  ## a zero velocity is the single byte `0x00`, and any other velocity is a
  ## 48-bit word holding three 15-bit fractions of a common scale, with the
  ## scale itself in the low bits and a VarInt continuation when it exceeds
  ## three.
  ##
  ## This was not deduced from a document. The recorded join has 9,845
  ## `set_entity_motion` packets and 194 of them are **two bytes long**, which
  ## no fixed six-byte reader can explain; that is what sent us to look. The
  ## layout below is transcribed from the reference implementation, and the
  ## thing that checks it is that all 9,845 - and all 293 `add_entity` - now land
  ## exactly on their own last byte.
  ##
  ## The word is assembled little-endian for its first two bytes and big-endian
  ## for the next four, which is not a typo: the packer writes the low byte, the
  ## next byte, and then a big-endian 32-bit word above them.
  result = Vec3(x: 0.0, y: 0.0, z: 0.0)
  let a = readByte(r)
  if not ok(r): return
  if a == 0: return                    # the zero vector, in one byte
  let b = readByte(r)
  let c0 = readByte(r)
  let c1 = readByte(r)
  let c2 = readByte(r)
  let c3 = readByte(r)
  if not ok(r): return
  let c = (c0 shl 24) or (c1 shl 16) or (c2 shl 8) or c3
  let packed = (c shl 16) or (b shl 8) or a
  var scale = a and LpScaleMask
  if (a and LpContinues) == LpContinues:
    let more = readVarInt(r)
    if not ok(r): return
    scale = more * 4 + scale
  result.x = lpUnpack(packed, 3) * float(scale)
  result.y = lpUnpack(packed, 18) * float(scale)
  result.z = lpUnpack(packed, 33) * float(scale)

proc lpPack(value: float): int =
  ## The inverse, rounded to nearest the way the packer rounds.
  var v = (value * 0.5 + 0.5) * QuantizedMax
  if v < 0.0: v = v - 0.5 else: v = v + 0.5
  int(v)

proc putLpVec3*(w: var Writer; v: Vec3; scale: int) =
  ## Only the short form - a scale of one to three and no continuation - which
  ## is every velocity in the recorded join. Written so that the reader can be
  ## round-tripped against a vector this file did not decode.
  if scale <= 0:
    putByte(w, 0)
    return
  let markers = scale and LpScaleMask
  let packed = markers or (lpPack(v.x / float(scale)) shl 3) or
               (lpPack(v.y / float(scale)) shl 18) or
               (lpPack(v.z / float(scale)) shl 33)
  putByte(w, packed and 0xFF)
  putByte(w, (packed shr 8) and 0xFF)
  putByte(w, (packed shr 40) and 0xFF)
  putByte(w, (packed shr 32) and 0xFF)
  putByte(w, (packed shr 24) and 0xFF)
  putByte(w, (packed shr 16) and 0xFF)

proc readSpawnEntityPacket*(r: var Reader): SpawnEntityPacket =
  result = SpawnEntityPacket(entityId: 0, uuid: Uuid(hi: 0, lo: 0), kind: 0,
                             x: 0.0, y: 0.0, z: 0.0, pitch: 0.0, yaw: 0.0,
                             headYaw: 0.0, data: 0, vx: 0.0, vy: 0.0, vz: 0.0)
  result.entityId = readVarInt(r)
  result.uuid = readUuid(r)
  result.kind = readVarInt(r)
  result.x = readDouble(r)
  result.y = readDouble(r)
  result.z = readDouble(r)
  # Velocity comes *before* the angles here and after them in some older
  # descriptions of this packet. The 774 definition puts it here.
  let velocity = readLpVec3(r)
  result.vx = velocity.x
  result.vy = velocity.y
  result.vz = velocity.z
  result.pitch = readAngle(r)
  result.yaw = readAngle(r)
  result.headYaw = readAngle(r)
  result.data = readVarInt(r)

proc readMovePacket*(r: var Reader; withRotation: bool): MovePacket =
  result = MovePacket(entityId: 0, dx: 0.0, dy: 0.0, dz: 0.0, yaw: 0.0,
                      pitch: 0.0, hasRotation: withRotation, onGround: false)
  result.entityId = readVarInt(r)
  result.dx = float(readShort(r)) / DeltaUnits
  result.dy = float(readShort(r)) / DeltaUnits
  result.dz = float(readShort(r)) / DeltaUnits
  if withRotation:
    result.yaw = readAngle(r)
    result.pitch = readAngle(r)
  result.onGround = readBool(r)

proc readRotatePacket*(r: var Reader): RotatePacket =
  result = RotatePacket(entityId: 0, yaw: 0.0, pitch: 0.0, onGround: false)
  result.entityId = readVarInt(r)
  result.yaw = readAngle(r)
  result.pitch = readAngle(r)
  result.onGround = readBool(r)

proc readTeleportPacket*(r: var Reader): TeleportPacket =
  result = TeleportPacket(entityId: 0, x: 0.0, y: 0.0, z: 0.0, yaw: 0.0,
                          pitch: 0.0, onGround: false)
  result.entityId = readVarInt(r)
  result.x = readDouble(r)
  result.y = readDouble(r)
  result.z = readDouble(r)
  result.yaw = readAngle(r)
  result.pitch = readAngle(r)
  result.onGround = readBool(r)

proc readSyncPositionPacket*(r: var Reader): SyncPositionPacket =
  result = SyncPositionPacket(entityId: 0, x: 0.0, y: 0.0, z: 0.0, dx: 0.0,
                              dy: 0.0, dz: 0.0, yaw: 0.0, pitch: 0.0,
                              onGround: false)
  result.entityId = readVarInt(r)
  result.x = readDouble(r)
  result.y = readDouble(r)
  result.z = readDouble(r)
  result.dx = readDouble(r)
  result.dy = readDouble(r)
  result.dz = readDouble(r)
  # Degrees as full floats here, not the single angle byte the move packets use.
  result.yaw = readFloat(r)
  result.pitch = readFloat(r)
  result.onGround = readBool(r)

proc readVelocityPacket*(r: var Reader): VelocityPacket =
  result = VelocityPacket(entityId: 0, vx: 0.0, vy: 0.0, vz: 0.0)
  result.entityId = readVarInt(r)
  let velocity = readLpVec3(r)
  result.vx = velocity.x
  result.vy = velocity.y
  result.vz = velocity.z

proc readMetadataPacket*(r: var Reader; l: MetaLayout;
                         t: ComponentTable): MetadataPacket =
  result = MetadataPacket(entityId: 0, entries: @[])
  result.entityId = readVarInt(r)
  result.entries = readMetadata(r, l, t)

proc readEquipmentPacket*(r: var Reader; t: ComponentTable): EquipmentPacket =
  ## The slot byte's **top bit means another pair follows**, which is how a
  ## packet that usually carries one item and sometimes carries six needs no
  ## count. A reader that took the byte at face value stops after the first slot
  ## and leaves the rest of the packet unread.
  result = EquipmentPacket(entityId: 0, items: @[])
  result.entityId = readVarInt(r)
  var more = true
  var guard = 0
  while more and ok(r):
    let raw = readByte(r)
    if not ok(r): return
    more = (raw and 0x80) != 0
    let item = readSlot(r, t)
    if not ok(r): return
    result.items.add Equipment(slot: raw and 0x7F, item: item)
    inc guard
    if guard > 16:
      fail(r, "more equipment slots than an entity has")
      return

proc readAnimatePacket*(r: var Reader): AnimatePacket =
  result = AnimatePacket(entityId: 0, animation: 0)
  result.entityId = readVarInt(r)
  result.animation = readByte(r)

proc readEntityEventPacket*(r: var Reader): EntityEventPacket =
  result = EntityEventPacket(entityId: 0, status: 0)
  # An `int`, not a VarInt. This is one of the handful of packets that still
  # carries a fixed-width entity id, and reading it as a VarInt is off by bytes
  # rather than by a little.
  result.entityId = readInt(r)
  result.status = readSByte(r)

proc readAttachPacket*(r: var Reader): AttachPacket =
  result = AttachPacket(entityId: 0, vehicleId: 0)
  result.entityId = readInt(r)
  result.vehicleId = readInt(r)

proc readPassengersPacket*(r: var Reader): PassengersPacket =
  result = PassengersPacket(vehicleId: 0, passengers: @[])
  result.vehicleId = readVarInt(r)
  let n = readVarInt(r)
  if not ok(r): return
  if n < 0 or n > 256:
    fail(r, "a passenger list length out of range")
    return
  var i = 0
  while i < n:
    result.passengers.add readVarInt(r)
    inc i

proc readHeadRotationPacket*(r: var Reader): HeadRotationPacket =
  result = HeadRotationPacket(entityId: 0, headYaw: 0.0)
  result.entityId = readVarInt(r)
  result.headYaw = readAngle(r)

proc readRemoveEntitiesPacket*(r: var Reader): RemoveEntitiesPacket =
  result = RemoveEntitiesPacket(entityIds: @[])
  let n = readVarInt(r)
  if not ok(r): return
  if n < 0 or n > 65536:
    fail(r, "a remove-entities list length out of range")
    return
  var i = 0
  while i < n:
    result.entityIds.add readVarInt(r)
    inc i

proc readTakeItemPacket*(r: var Reader): TakeItemPacket =
  result = TakeItemPacket(collectedId: 0, collectorId: 0, count: 0)
  result.collectedId = readVarInt(r)
  result.collectorId = readVarInt(r)
  result.count = readVarInt(r)

# ---------------------------------------------------------------------------
# Serverbound

proc bodyInteract*(entityId, kind: int; x, y, z: float; hand: int;
                   sneaking: bool): seq[int] =
  ## `interact`, whose shape depends on `kind`: 0 is interact, 1 is attack and
  ## 2 is interact-at-a-point. Only 0 and 2 carry a hand, and only 2 carries the
  ## point - which is a switch on the wire and therefore three different packet
  ## lengths under one id.
  var w = writer()
  putVarInt(w, entityId)
  putVarInt(w, kind)
  if kind == 2:
    putFloat(w, x)
    putFloat(w, y)
    putFloat(w, z)
  if kind == 0 or kind == 2:
    putVarInt(w, hand)
  putBool(w, sneaking)
  w.data
