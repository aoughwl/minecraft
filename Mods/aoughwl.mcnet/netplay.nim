## Play: everything after the configuration handshake finishes.
##
## This is the state the game is actually in. Handshake, Status, Login and
## Configuration are a few dozen packets that happen once; Play is 139
## clientbound and 66 serverbound at protocol 774 and it never ends.
##
## THREE RULES SHAPE THIS FILE, AND ALL THREE ARE THE SAME RULE.
##
## **1. Nothing here knows a packet id.** Every packet is named by the games own
## resource name - `minecraft:level_chunk_with_light`, not 44 - and the number
## is looked up in a `netproto.Table` a caller filled from the players own
## `packets.json`. 165 of the 251 shared ids moved between 774 and 776, so an id
## written into this file would be a number that is right today, wrong at the
## next release, and wrong on every modded server in between. `declarePlayFrom`
## is how a profile is loaded and `playName` is how a decoder asks what arrived.
##
## **2. Nothing here touches a socket.** A packet arrives as a name and a
## `netwire.Reader` over its body, and a packet leaves as a name and a body. The
## transport - which by design is the host, not this mod - does the framing, the
## compression and the id lookup. That is what makes every line below provable
## against a hand-built byte vector, and it is why the session below can be
## driven by a recorded transcript exactly as it is driven by a live server.
##
## **3. Chunk *data* never becomes bytes in here.** `readChunkHeader` reads the
## position and the heightmaps and then stops at the section array, reporting
## where it starts and how long it is. On the live path the host decodes that
## span off its own cursor and hands back runs; `netchunk` decodes it offline,
## as the independent check that the two agree. Materialising 34KB of packet
## into interpreter memory costs about 27ms before a single block is decoded,
## which is the measurement that made this a seam rather than a call.
##
## WHAT IS PROVEN HERE AND WHAT IS NOT. The decoders below were written against
## the 774 type definitions, field by field, and `Tests/mcplay_test.nim` builds
## each packet body from *those definitions* rather than from these decoders and
## asserts the two agree. Where a shape has no machine-readable definition the
## test says so out loud rather than comparing this file to itself.

import netwire
import netnbt
import netproto

# ---------------------------------------------------------------------------
# The names.
#
# Constants rather than string literals at every call site, because a typo in a
# literal is a packet that silently never arrives - `idOf` answers -1 and a
# dispatch on the name never matches - and a typo in a constant does not
# compile. Every one of these is a key in the jars own `packets.json`.

const
  # Clientbound, the world you stand in
  PlayLogin* = "minecraft:login"
  PlayRespawn* = "minecraft:respawn"
  PlayPlayerPosition* = "minecraft:player_position"
  PlayPlayerRotation* = "minecraft:player_rotation"
  PlayKeepAlive* = "minecraft:keep_alive"
  PlayPing* = "minecraft:ping"
  PlayDisconnect* = "minecraft:disconnect"
  PlaySetTime* = "minecraft:set_time"
  PlaySetDefaultSpawnPosition* = "minecraft:set_default_spawn_position"
  PlayGameEvent* = "minecraft:game_event"
  PlaySetChunkCacheCenter* = "minecraft:set_chunk_cache_center"
  PlaySetChunkCacheRadius* = "minecraft:set_chunk_cache_radius"
  PlaySetSimulationDistance* = "minecraft:set_simulation_distance"
  PlayLevelChunkWithLight* = "minecraft:level_chunk_with_light"
  PlayForgetLevelChunk* = "minecraft:forget_level_chunk"
  PlayChunkBatchStart* = "minecraft:chunk_batch_start"
  PlayChunkBatchFinished* = "minecraft:chunk_batch_finished"
  PlayChunksBiomes* = "minecraft:chunks_biomes"
  PlayStartConfiguration* = "minecraft:start_configuration"

  # Clientbound, blocks
  PlayBlockUpdate* = "minecraft:block_update"
  PlaySectionBlocksUpdate* = "minecraft:section_blocks_update"
  PlayBlockEntityData* = "minecraft:block_entity_data"
  PlayBlockChangedAck* = "minecraft:block_changed_ack"
  PlayBlockDestruction* = "minecraft:block_destruction"
  PlayBlockEvent* = "minecraft:block_event"
  PlaySound* = "minecraft:sound"
  PlaySoundEntity* = "minecraft:sound_entity"
  PlayLevelEvent* = "minecraft:level_event"

  # Clientbound, survival
  PlaySetHealth* = "minecraft:set_health"
  PlaySetExperience* = "minecraft:set_experience"
  PlayDamageEvent* = "minecraft:damage_event"
  PlayHurtAnimation* = "minecraft:hurt_animation"
  PlayPlayerCombatKill* = "minecraft:player_combat_kill"
  PlaySetHeldSlot* = "minecraft:set_held_slot"
  PlayPlayerAbilities* = "minecraft:player_abilities"

  # Clientbound, entities
  PlayAddEntity* = "minecraft:add_entity"
  PlayRemoveEntities* = "minecraft:remove_entities"
  PlayMoveEntityPos* = "minecraft:move_entity_pos"
  PlayMoveEntityPosRot* = "minecraft:move_entity_pos_rot"
  PlayMoveEntityRot* = "minecraft:move_entity_rot"
  PlayTeleportEntity* = "minecraft:teleport_entity"
  PlayEntityPositionSync* = "minecraft:entity_position_sync"
  PlaySetEntityMotion* = "minecraft:set_entity_motion"
  PlaySetEntityData* = "minecraft:set_entity_data"
  PlaySetEquipment* = "minecraft:set_equipment"
  PlayAnimate* = "minecraft:animate"
  PlayEntityEvent* = "minecraft:entity_event"
  PlaySetEntityLink* = "minecraft:set_entity_link"
  PlaySetPassengers* = "minecraft:set_passengers"
  PlayRotateHead* = "minecraft:rotate_head"
  PlayTakeItemEntity* = "minecraft:take_item_entity"

  # Clientbound, containers
  PlayContainerSetSlot* = "minecraft:container_set_slot"
  PlayContainerSetContent* = "minecraft:container_set_content"
  PlayContainerSetData* = "minecraft:container_set_data"
  PlayOpenScreen* = "minecraft:open_screen"
  PlayContainerClose* = "minecraft:container_close"
  PlaySetCursorItem* = "minecraft:set_cursor_item"
  PlaySetPlayerInventory* = "minecraft:set_player_inventory"

  # Clientbound, chat
  PlaySystemChat* = "minecraft:system_chat"
  PlayPlayerChat* = "minecraft:player_chat"
  PlayDisguisedChat* = "minecraft:disguised_chat"

  # Serverbound
  PlayAcceptTeleportation* = "minecraft:accept_teleportation"
  PlayKeepAliveOut* = "minecraft:keep_alive"
  PlayPongOut* = "minecraft:pong"
  PlayMovePlayerPos* = "minecraft:move_player_pos"
  PlayMovePlayerPosRot* = "minecraft:move_player_pos_rot"
  PlayMovePlayerRot* = "minecraft:move_player_rot"
  PlayMovePlayerStatusOnly* = "minecraft:move_player_status_only"
  PlayChunkBatchReceived* = "minecraft:chunk_batch_received"
  PlayPlayerLoaded* = "minecraft:player_loaded"
  PlayClientTickEnd* = "minecraft:client_tick_end"
  PlayClientCommand* = "minecraft:client_command"
  PlayPlayerAction* = "minecraft:player_action"
  PlayUseItemOn* = "minecraft:use_item_on"
  PlayUseItem* = "minecraft:use_item"
  PlaySwing* = "minecraft:swing"
  PlaySetCarriedItem* = "minecraft:set_carried_item"
  PlayPlayerCommand* = "minecraft:player_command"
  PlayPlayerInput* = "minecraft:player_input"
  PlayInteract* = "minecraft:interact"
  PlayContainerClickOut* = "minecraft:container_click"
  PlayContainerCloseOut* = "minecraft:container_close"
  PlaySetCreativeModeSlot* = "minecraft:set_creative_mode_slot"
  PlayChatOut* = "minecraft:chat"
  PlayChatCommandOut* = "minecraft:chat_command"
  PlayChatAckOut* = "minecraft:chat_ack"

const
  # The bits of `player_position`'s relative-flags word, in the order the 774
  # definition lists them. A set bit means the field is a *delta* on what the
  # client already had; a clear bit means it is absolute. Getting this backwards
  # puts the player at the origin on every teleport, which looks like a server
  # problem and is not.
  RelX* = 0
  RelY* = 1
  RelZ* = 2
  RelYaw* = 3
  RelPitch* = 4
  RelDeltaX* = 5
  RelDeltaY* = 6
  RelDeltaZ* = 7
  RelYawDelta* = 8

  # `move_player_*`'s flags byte.
  MoveOnGround* = 1
  MoveHorizontalCollision* = 2

  # `player_action`, which is dig start, dig cancel, dig finish and five more.
  DigStart* = 0
  DigCancel* = 1
  DigFinish* = 2
  DropStack* = 3
  DropOne* = 4
  ShootOrEat* = 5
  SwapHands* = 6

  # `client_command`.
  CommandRespawn* = 0
  CommandRequestStats* = 1

  # `game_event`, the reasons that matter to a client that is standing up.
  EventNoRespawnBlock* = 0
  EventStartRaining* = 1
  EventStopRaining* = 2
  EventChangeGameMode* = 3
  EventWinGame* = 4
  EventRainLevel* = 7
  EventThunderLevel* = 8
  EventLevelChunksLoaded* = 13
    ## The one a joining client waits for: it means the server considers the
    ## initial terrain sent, and it is when the loading screen comes down.

proc declarePlayFrom*(t: var Table; dir, id: int; name: string) =
  ## One Play row, from a profile. Thin on purpose: the point is that there is
  ## no other way to get a Play id into this mod, so grepping for this call
  ## finds every place a version profile is trusted.
  declare(t, StatePlay, dir, id, name)

proc playName*(t: Table; dir, id: int): string =
  nameOf(t, StatePlay, dir, id)

proc playId*(t: Table; dir: int; name: string): int =
  idOf(t, StatePlay, dir, name)

# ---------------------------------------------------------------------------
# The records
#
# One object per packet, with the fields the 774 definition lists and in that
# order. Where a field is an id into a registry it stays an id: resolving
# `dimension` to a name needs the servers own registry data, which arrives in
# Configuration, and inventing a mapping here would be exactly the hardcoding
# rule 1 forbids.

type
  GlobalPos* = object
    dimension*: string
    at*: BlockPos

  SpawnInfo* = object
    ## The worldState of `login` and the whole of `respawn`. Shared, which is
    ## why a dimension change and a first join run the same code.
    dimension*: int            ## index into the dimension_type registry
    worldName*: string
    hashedSeed*: int
    gamemode*: int
    previousGamemode*: int     ## 255 for "none", as an unsigned byte
    isDebug*, isFlat*: bool
    hasDeath*: bool
    death*: GlobalPos
    portalCooldown*: int
    seaLevel*: int

  LoginPacket* = object
    entityId*: int
    hardcore*: bool
    worldNames*: seq[string]
    maxPlayers*: int
    viewDistance*: int
    simulationDistance*: int
    reducedDebugInfo*: bool
    respawnScreen*: bool
    limitedCrafting*: bool
    world*: SpawnInfo
    enforcesSecureChat*: bool

  RespawnPacket* = object
    world*: SpawnInfo
    copyMetadata*: int

  PositionPacket* = object
    ## `player_position`, which is a teleport and not a hint. It must be
    ## answered with `accept_teleportation` carrying the same id, and until it
    ## is, the server ignores everything the client says about where it is.
    teleportId*: int
    x*, y*, z*: float
    dx*, dy*, dz*: float
    yaw*, pitch*: float
    flags*: int

  RotationPacket* = object
    yaw*: float
    relativeYaw*: bool
    pitch*: float
    relativePitch*: bool

  TimePacket* = object
    age*: int                  ## world age in ticks, never decreases
    time*: int                 ## time of day, 0..23999
    tickDayTime*: bool         ## whether the daylight cycle is running

  SpawnPositionPacket* = object
    ## `set_default_spawn_position`, which is `RespawnData`: a dimension-scoped
    ## block position plus the angle to face. The compass points here.
    at*: GlobalPos
    yaw*, pitch*: float

  GameEventPacket* = object
    reason*: int
    value*: float

  ChunkCenterPacket* = object
    chunkX*, chunkZ*: int

  ForgetChunkPacket* = object
    chunkX*, chunkZ*: int

  ChunkHeader* = object
    ## Everything in `level_chunk_with_light` up to the section array, plus
    ## where that array is. `sectionsAt` and `sectionsLen` are an offset into
    ## the readers own buffer, so a caller can hand the span to `netchunk`
    ## offline or, on the live path, let the host decode it without the bytes
    ## ever crossing.
    chunkX*, chunkZ*: int
    heightmapKinds*: seq[int]
    heightmapLongs*: seq[int]  ## every heightmap concatenated
    heightmapFirst*: seq[int]  ## where each one starts in `heightmapLongs`
    heightmapCount*: seq[int]
    sectionsAt*, sectionsLen*: int

  BlockEntityEntry* = object
    x*, y*, z*: int            ## world coordinates, unpacked from the chunk
    kind*: int
    data*: Nbt

  BlockUpdatePacket* = object
    at*: BlockPos
    state*: int

  SectionBlocksPacket* = object
    ## `section_blocks_update`. The section is named by a packed long and every
    ## record packs a block state and a position *inside* that section into one
    ## VarLong: `state shl 12` with the low twelve bits split 4-4-4 as x, z, y.
    sectionX*, sectionY*, sectionZ*: int
    positions*: seq[BlockPos]  ## already resolved to world coordinates
    states*: seq[int]

  BlockEntityPacket* = object
    at*: BlockPos
    kind*: int
    data*: Nbt

  BlockDestructionPacket* = object
    entityId*: int
    at*: BlockPos
    stage*: int                ## 0..9, and anything else means "stop"

  BlockEventPacket* = object
    at*: BlockPos
    actionId*, actionParam*: int
    blockType*: int

  SoundPacket* = object
    ## The sound is a *registry entry holder*: a VarInt that is either
    ## `id + 1`, naming an entry of the sound registry, or zero followed by an
    ## inline definition. Reading only the id is the mistake that desynchronises
    ## on the first sound a datapack adds.
    inlineSound*: bool
    soundId*: int
    soundName*: string
    hasFixedRange*: bool
    fixedRange*: float
    category*: int
    x*, y*, z*: float          ## already divided by eight, as the wire packs it
    volume*, pitch*: float
    seed*: int

  EntitySoundPacket* = object
    inlineSound*: bool
    soundId*: int
    soundName*: string
    hasFixedRange*: bool
    fixedRange*: float
    category*: int
    entityId*: int
    volume*, pitch*: float
    seed*: int

  LevelEventPacket* = object
    effectId*: int
    at*: BlockPos
    data*: int
    global*: bool

  HealthPacket* = object
    health*: float
    food*: int
    saturation*: float

  ExperiencePacket* = object
    progress*: float           ## 0..1 across the current level
    level*: int
    total*: int

  DamageEventPacket* = object
    entityId*: int
    sourceType*: int
    sourceCause*: int          ## 0 means none; ids are one-based on the wire
    sourceDirect*: int
    hasPosition*: bool
    x*, y*, z*: float

  CombatKillPacket* = object
    playerId*: int
    message*: Nbt

# ---------------------------------------------------------------------------
# Decoding
#
# Every one of these leaves the reader positioned exactly at the end of the
# packet, and `remaining` being non-zero afterwards is how a caller finds out
# that a shape is wrong. That check is worth more than it looks: a decoder one
# field short still produces a completely plausible packet.

proc readGlobalPos*(r: var Reader): GlobalPos =
  result = GlobalPos(dimension: "", at: BlockPos(x: 0, y: 0, z: 0))
  result.dimension = readString(r)
  result.at = readPosition(r)

proc readSpawnInfo*(r: var Reader): SpawnInfo =
  result = SpawnInfo(dimension: 0, worldName: "", hashedSeed: 0, gamemode: 0,
                     previousGamemode: 0, isDebug: false, isFlat: false,
                     hasDeath: false,
                     death: GlobalPos(dimension: "",
                                      at: BlockPos(x: 0, y: 0, z: 0)),
                     portalCooldown: 0, seaLevel: 0)
  result.dimension = readVarInt(r)
  result.worldName = readString(r)
  result.hashedSeed = readLong(r)
  result.gamemode = readSByte(r)
  result.previousGamemode = readByte(r)
  result.isDebug = readBool(r)
  result.isFlat = readBool(r)
  result.hasDeath = readBool(r)
  if result.hasDeath and ok(r):
    result.death = readGlobalPos(r)
  result.portalCooldown = readVarInt(r)
  result.seaLevel = readVarInt(r)

proc readLoginPacket*(r: var Reader): LoginPacket =
  result = LoginPacket(entityId: 0, hardcore: false, worldNames: @[],
                       maxPlayers: 0, viewDistance: 0, simulationDistance: 0,
                       reducedDebugInfo: false, respawnScreen: false,
                       limitedCrafting: false, world: SpawnInfo(),
                       enforcesSecureChat: false)
  result.entityId = readInt(r)
  result.hardcore = readBool(r)
  let worlds = readVarInt(r)
  if not ok(r): return
  if worlds < 0 or worlds > 4096:
    fail(r, "the world list length is out of range")
    return
  var i = 0
  while i < worlds:
    result.worldNames.add readString(r)
    if not ok(r): return
    inc i
  result.maxPlayers = readVarInt(r)
  result.viewDistance = readVarInt(r)
  result.simulationDistance = readVarInt(r)
  result.reducedDebugInfo = readBool(r)
  result.respawnScreen = readBool(r)
  result.limitedCrafting = readBool(r)
  result.world = readSpawnInfo(r)
  result.enforcesSecureChat = readBool(r)

proc readRespawnPacket*(r: var Reader): RespawnPacket =
  result = RespawnPacket(world: SpawnInfo(), copyMetadata: 0)
  result.world = readSpawnInfo(r)
  result.copyMetadata = readByte(r)

proc readPositionPacket*(r: var Reader): PositionPacket =
  result = PositionPacket(teleportId: 0, x: 0.0, y: 0.0, z: 0.0, dx: 0.0,
                          dy: 0.0, dz: 0.0, yaw: 0.0, pitch: 0.0, flags: 0)
  result.teleportId = readVarInt(r)
  result.x = readDouble(r)
  result.y = readDouble(r)
  result.z = readDouble(r)
  result.dx = readDouble(r)
  result.dy = readDouble(r)
  result.dz = readDouble(r)
  result.yaw = readFloat(r)
  result.pitch = readFloat(r)
  # The flags are a 32-bit word here, not the single byte they were before
  # 1.21.2. Reading one byte leaves three behind and the next packet is read
  # from the middle of this one.
  result.flags = readUInt(r)

proc relative*(p: PositionPacket; bit: int): bool =
  (p.flags shr bit and 1) != 0

proc readRotationPacket*(r: var Reader): RotationPacket =
  result = RotationPacket(yaw: 0.0, relativeYaw: false, pitch: 0.0,
                          relativePitch: false)
  result.yaw = readFloat(r)
  result.relativeYaw = readBool(r)
  result.pitch = readFloat(r)
  result.relativePitch = readBool(r)

proc readTimePacket*(r: var Reader): TimePacket =
  result = TimePacket(age: 0, time: 0, tickDayTime: false)
  result.age = readLong(r)
  result.time = readLong(r)
  result.tickDayTime = readBool(r)

proc readSpawnPositionPacket*(r: var Reader): SpawnPositionPacket =
  result = SpawnPositionPacket(
    at: GlobalPos(dimension: "", at: BlockPos(x: 0, y: 0, z: 0)),
    yaw: 0.0, pitch: 0.0)
  result.at = readGlobalPos(r)
  result.yaw = readFloat(r)
  result.pitch = readFloat(r)

proc readGameEventPacket*(r: var Reader): GameEventPacket =
  result = GameEventPacket(reason: 0, value: 0.0)
  result.reason = readByte(r)
  result.value = readFloat(r)

proc readChunkCenterPacket*(r: var Reader): ChunkCenterPacket =
  result = ChunkCenterPacket(chunkX: 0, chunkZ: 0)
  result.chunkX = readVarInt(r)
  result.chunkZ = readVarInt(r)

proc readForgetChunkPacket*(r: var Reader): ForgetChunkPacket =
  ## **Z comes first.** `forget_level_chunk` is the one packet in the family
  ## whose two coordinates are in the other order, and a decoder that reads x
  ## first unloads a chunk reflected about the diagonal - which looks like
  ## terrain flickering hundreds of blocks away rather than like a field-order
  ## bug.
  result = ForgetChunkPacket(chunkX: 0, chunkZ: 0)
  result.chunkZ = readInt(r)
  result.chunkX = readInt(r)

proc readChunkHeader*(r: var Reader): ChunkHeader =
  ## Reads up to the section array and stops there. See the file prose: the
  ## section bytes are the one thing in Play that must not cross into the
  ## interpreter.
  result = ChunkHeader(chunkX: 0, chunkZ: 0, heightmapKinds: @[],
                       heightmapLongs: @[], heightmapFirst: @[],
                       heightmapCount: @[], sectionsAt: 0, sectionsLen: 0)
  result.chunkX = readInt(r)
  result.chunkZ = readInt(r)
  let maps = readVarInt(r)
  if not ok(r): return
  if maps < 0 or maps > 64:
    fail(r, "the heightmap count is out of range")
    return
  var m = 0
  while m < maps:
    let kind = readVarInt(r)
    let longs = readVarInt(r)
    if not ok(r): return
    if longs < 0 or longs > 4096:
      fail(r, "a heightmap length is out of range")
      return
    result.heightmapKinds.add kind
    result.heightmapFirst.add result.heightmapLongs.len
    result.heightmapCount.add longs
    var i = 0
    while i < longs:
      result.heightmapLongs.add readLong(r)
      inc i
    if not ok(r): return
    inc m
  let size = readVarInt(r)
  if not ok(r): return
  if size < 0 or size > remaining(r):
    fail(r, "the chunk section array length is out of range")
    return
  result.sectionsAt = r.at
  result.sectionsLen = size
  r.at = r.at + size

proc readBlockEntities*(r: var Reader; header: ChunkHeader;
                        out0: var seq[BlockEntityEntry]) =
  ## The block entities that follow the section array. Their position is packed
  ## into one byte as `(x shl 4) or z` *relative to the chunk*, then a short y,
  ## so the world coordinate needs the chunk position from the header - which is
  ## why this takes it rather than being folded into `readChunkHeader`.
  ##
  ## This shape has no machine-readable definition in the 774 profile - it is
  ## one of the handful the schema implements in code rather than declaring - so
  ## `Tests/mcplay_test.nim` marks it rather than pretending to derive it.
  out0 = @[]
  let count = readVarInt(r)
  if not ok(r): return
  if count < 0 or count > 4096:
    fail(r, "the block entity count is out of range")
    return
  var i = 0
  while i < count:
    let packed = readByte(r)
    let y = readShort(r)
    let kind = readVarInt(r)
    if not ok(r): return
    let data = readNbt(r)
    if data.problem.len > 0:
      fail(r, data.problem)
      return
    out0.add BlockEntityEntry(x: header.chunkX * 16 + (packed shr 4 and 0xF),
                              y: y,
                              z: header.chunkZ * 16 + (packed and 0xF),
                              kind: kind, data: data)
    inc i

type
  LightData* = object
    ## The light that follows a chunk column, and the shape is unusual enough to
    ## be worth naming. Four bitmasks say *which* of the 26 light sections - the
    ## 24 real ones plus one above and one below - are present and which are
    ## known to be entirely dark or entirely lit. Then one 2048-byte array per
    ## bit set in the corresponding present-mask, and **not** one per section.
    ## A reader that assumed a fixed count would be right on a chunk in the open
    ## and wrong underground.
    skyMask*, blockMask*: seq[int]
    emptySkyMask*, emptyBlockMask*: seq[int]
    skyArrays*, blockArrays*: int      ## how many arrays of each arrived
    skyBytes*, blockBytes*: int        ## and how many bytes they were

proc readLongArray(r: var Reader; out0: var seq[int]) =
  out0 = @[]
  let n = readVarInt(r)
  if not ok(r): return
  if n < 0 or n > 64:
    fail(r, "a light mask is longer than any world is tall")
    return
  var i = 0
  while i < n:
    out0.add readLong(r)
    inc i

proc readLightArrays(r: var Reader; count, bytes: var int) =
  count = 0
  bytes = 0
  let n = readVarInt(r)
  if not ok(r): return
  if n < 0 or n > 64:
    fail(r, "more light arrays than a column can have")
    return
  var i = 0
  while i < n:
    let size = readVarInt(r)
    if not ok(r): return
    if size < 0 or size > remaining(r):
      fail(r, "a light array runs past the end")
      return
    # Half a byte per block over a 16x16x16 section is 2048 bytes, and vanilla
    # sends exactly that. The bytes are skipped rather than kept: a client that
    # lights its own world does not need the servers answer, and copying them
    # would be 52KB a chunk of nothing.
    r.at = r.at + size
    bytes = bytes + size
    inc count
    inc i

proc readLightData*(r: var Reader): LightData =
  result = LightData(skyMask: @[], blockMask: @[], emptySkyMask: @[],
                     emptyBlockMask: @[], skyArrays: 0, blockArrays: 0,
                     skyBytes: 0, blockBytes: 0)
  readLongArray(r, result.skyMask)
  readLongArray(r, result.blockMask)
  readLongArray(r, result.emptySkyMask)
  readLongArray(r, result.emptyBlockMask)
  readLightArrays(r, result.skyArrays, result.skyBytes)
  readLightArrays(r, result.blockArrays, result.blockBytes)

proc readBlockUpdatePacket*(r: var Reader): BlockUpdatePacket =
  result = BlockUpdatePacket(at: BlockPos(x: 0, y: 0, z: 0), state: 0)
  result.at = readPosition(r)
  result.state = readVarInt(r)

proc readSectionBlocksPacket*(r: var Reader): SectionBlocksPacket =
  ## The section coordinate is a single long packed 22-22-20 as x, z, y - a
  ## *different* packing from `BlockPos`, which is 26-26-12 as x, z, y. Two
  ## packings that both put z in the middle and differ only in their widths is
  ## exactly the pair a decoder gets wrong once and never notices, because the
  ## low bits of a small coordinate come out the same either way.
  result = SectionBlocksPacket(sectionX: 0, sectionY: 0, sectionZ: 0,
                               positions: @[], states: @[])
  let packed = readLong(r)
  if not ok(r): return
  result.sectionX = signExtend(packed shr 42, 22)
  result.sectionZ = signExtend(packed shr 20, 22)
  result.sectionY = signExtend(packed, 20)
  let count = readVarInt(r)
  if not ok(r): return
  if count < 0 or count > 4096:
    fail(r, "the block record count is out of range")
    return
  var i = 0
  while i < count:
    let record = readVarLong(r)
    if not ok(r): return
    let local = record and 0xFFF
    result.states.add (record shr 12) and 0x7FFFFFFFFFFFF
    result.positions.add BlockPos(
      x: result.sectionX * 16 + ((local shr 8) and 0xF),
      y: result.sectionY * 16 + (local and 0xF),
      z: result.sectionZ * 16 + ((local shr 4) and 0xF))
    inc i

proc readBlockEntityPacket*(r: var Reader): BlockEntityPacket =
  result = BlockEntityPacket(at: BlockPos(x: 0, y: 0, z: 0), kind: 0,
                             data: emptyNbt())
  result.at = readPosition(r)
  result.kind = readVarInt(r)
  result.data = readNbt(r)
  if result.data.problem.len > 0: fail(r, result.data.problem)

proc readBlockDestructionPacket*(r: var Reader): BlockDestructionPacket =
  result = BlockDestructionPacket(entityId: 0, at: BlockPos(x: 0, y: 0, z: 0),
                                  stage: 0)
  result.entityId = readVarInt(r)
  result.at = readPosition(r)
  result.stage = readSByte(r)

proc readBlockEventPacket*(r: var Reader): BlockEventPacket =
  result = BlockEventPacket(at: BlockPos(x: 0, y: 0, z: 0), actionId: 0,
                            actionParam: 0, blockType: 0)
  result.at = readPosition(r)
  result.actionId = readByte(r)
  result.actionParam = readByte(r)
  result.blockType = readVarInt(r)

proc readSoundHolder(r: var Reader; inlineSound: var bool; soundId: var int;
                     soundName: var string; hasRange: var bool;
                     fixedRange: var float) =
  inlineSound = false
  soundId = 0
  soundName = ""
  hasRange = false
  fixedRange = 0.0
  let tag = readVarInt(r)
  if not ok(r): return
  if tag == 0:
    inlineSound = true
    soundName = readString(r)
    hasRange = readBool(r)
    if hasRange and ok(r): fixedRange = readFloat(r)
  else:
    soundId = tag - 1

proc readSoundPacket*(r: var Reader): SoundPacket =
  result = SoundPacket(inlineSound: false, soundId: 0, soundName: "",
                       hasFixedRange: false, fixedRange: 0.0, category: 0,
                       x: 0.0, y: 0.0, z: 0.0, volume: 0.0, pitch: 0.0, seed: 0)
  readSoundHolder(r, result.inlineSound, result.soundId, result.soundName,
                  result.hasFixedRange, result.fixedRange)
  result.category = readVarInt(r)
  # The position is a fixed-point int of eighths of a block, which is what lets
  # a sound be placed to within 12.5cm in four bytes each.
  result.x = float(readInt(r)) / 8.0
  result.y = float(readInt(r)) / 8.0
  result.z = float(readInt(r)) / 8.0
  result.volume = readFloat(r)
  result.pitch = readFloat(r)
  result.seed = readLong(r)

proc readEntitySoundPacket*(r: var Reader): EntitySoundPacket =
  result = EntitySoundPacket(inlineSound: false, soundId: 0, soundName: "",
                             hasFixedRange: false, fixedRange: 0.0,
                             category: 0, entityId: 0, volume: 0.0,
                             pitch: 0.0, seed: 0)
  readSoundHolder(r, result.inlineSound, result.soundId, result.soundName,
                  result.hasFixedRange, result.fixedRange)
  result.category = readVarInt(r)
  result.entityId = readVarInt(r)
  result.volume = readFloat(r)
  result.pitch = readFloat(r)
  result.seed = readLong(r)

proc readLevelEventPacket*(r: var Reader): LevelEventPacket =
  result = LevelEventPacket(effectId: 0, at: BlockPos(x: 0, y: 0, z: 0),
                            data: 0, global: false)
  result.effectId = readInt(r)
  result.at = readPosition(r)
  result.data = readInt(r)
  result.global = readBool(r)

proc readHealthPacket*(r: var Reader): HealthPacket =
  result = HealthPacket(health: 0.0, food: 0, saturation: 0.0)
  result.health = readFloat(r)
  result.food = readVarInt(r)
  result.saturation = readFloat(r)

proc readExperiencePacket*(r: var Reader): ExperiencePacket =
  result = ExperiencePacket(progress: 0.0, level: 0, total: 0)
  result.progress = readFloat(r)
  result.level = readVarInt(r)
  result.total = readVarInt(r)

proc readDamageEventPacket*(r: var Reader): DamageEventPacket =
  result = DamageEventPacket(entityId: 0, sourceType: 0, sourceCause: 0,
                             sourceDirect: 0, hasPosition: false, x: 0.0,
                             y: 0.0, z: 0.0)
  result.entityId = readVarInt(r)
  result.sourceType = readVarInt(r)
  # Both cause and direct entity ids are sent one higher than they are, so that
  # zero can mean "none". A decoder that skipped the subtraction blames the
  # wrong entity for every hit, and by exactly one.
  result.sourceCause = readVarInt(r) - 1
  result.sourceDirect = readVarInt(r) - 1
  result.hasPosition = readBool(r)
  if result.hasPosition and ok(r):
    result.x = readDouble(r)
    result.y = readDouble(r)
    result.z = readDouble(r)

proc readCombatKillPacket*(r: var Reader): CombatKillPacket =
  result = CombatKillPacket(playerId: 0, message: emptyNbt())
  result.playerId = readVarInt(r)
  result.message = readNbt(r)
  if result.message.problem.len > 0: fail(r, result.message.problem)

# ---------------------------------------------------------------------------
# Encoding, the serverbound side
#
# Each of these writes a packet *body* - no id and no length. The transport puts
# the id on, because the transport is the only thing that has the table.

proc bodyAcceptTeleportation*(teleportId: int): seq[int] =
  var w = writer()
  putVarInt(w, teleportId)
  w.data

proc bodyKeepAlive*(id: int): seq[int] =
  var w = writer()
  putLong(w, id)
  w.data

proc bodyPong*(id: int): seq[int] =
  var w = writer()
  putInt(w, id)
  w.data

proc moveFlags*(onGround, horizontalCollision: bool): int =
  result = 0
  if onGround: result = result or MoveOnGround
  if horizontalCollision: result = result or MoveHorizontalCollision

proc bodyMovePlayerPos*(x, y, z: float; onGround, collided: bool): seq[int] =
  var w = writer()
  putDouble(w, x)
  putDouble(w, y)
  putDouble(w, z)
  putByte(w, moveFlags(onGround, collided))
  w.data

proc bodyMovePlayerPosRot*(x, y, z, yaw, pitch: float;
                           onGround, collided: bool): seq[int] =
  var w = writer()
  putDouble(w, x)
  putDouble(w, y)
  putDouble(w, z)
  putFloat(w, yaw)
  putFloat(w, pitch)
  putByte(w, moveFlags(onGround, collided))
  w.data

proc bodyMovePlayerRot*(yaw, pitch: float; onGround, collided: bool): seq[int] =
  var w = writer()
  putFloat(w, yaw)
  putFloat(w, pitch)
  putByte(w, moveFlags(onGround, collided))
  w.data

proc bodyMovePlayerStatusOnly*(onGround, collided: bool): seq[int] =
  var w = writer()
  putByte(w, moveFlags(onGround, collided))
  w.data

proc bodyChunkBatchReceived*(chunksPerTick: float): seq[int] =
  ## The pacing reply. The server sizes its next batch from this number, so a
  ## client that cannot decode fast enough lowers it rather than falling behind
  ## - which is the only lever there is, and it is here rather than in the host
  ## because how much of a frame chunk decoding may have is a game decision.
  var w = writer()
  putFloat(w, chunksPerTick)
  w.data

proc bodyPlayerLoaded*(): seq[int] =
  ## Empty, and sent once, after the first terrain has been taken. Omitting it
  ## leaves the server holding the player in a joining state.
  var w = writer()
  w.data

proc bodyClientTickEnd*(): seq[int] =
  var w = writer()
  w.data

proc bodyClientCommand*(action: int): seq[int] =
  var w = writer()
  putVarInt(w, action)
  w.data

proc bodyPlayerAction*(status: int; at: BlockPos; face, sequence: int): seq[int] =
  ## Dig start, dig cancel and dig finish are three values of `status` on one
  ## packet, not three packets. `sequence` is the clients own counter, echoed
  ## back in `block_changed_ack`, and it is how the client knows whether to keep
  ## its optimistic guess about the block or roll it back.
  var w = writer()
  putVarInt(w, status)
  putPosition(w, at)
  putByte(w, face)
  putVarInt(w, sequence)
  w.data

proc bodyUseItemOn*(hand: int; at: BlockPos; face: int;
                    cursorX, cursorY, cursorZ: float;
                    insideBlock, worldBorderHit: bool;
                    sequence: int): seq[int] =
  ## Placing a block. `worldBorderHit` is new and easy to miss: leaving it out
  ## makes the packet one byte short and the servers `sequence` read garbage, so
  ## every placement is acknowledged against a sequence the client never sent.
  var w = writer()
  putVarInt(w, hand)
  putPosition(w, at)
  putVarInt(w, face)
  putFloat(w, cursorX)
  putFloat(w, cursorY)
  putFloat(w, cursorZ)
  putBool(w, insideBlock)
  putBool(w, worldBorderHit)
  putVarInt(w, sequence)
  w.data

proc bodyUseItem*(hand, sequence: int; yaw, pitch: float): seq[int] =
  var w = writer()
  putVarInt(w, hand)
  putVarInt(w, sequence)
  putFloat(w, yaw)
  putFloat(w, pitch)
  w.data

proc bodySwing*(hand: int): seq[int] =
  var w = writer()
  putVarInt(w, hand)
  w.data

proc bodySetCarriedItem*(slot: int): seq[int] =
  var w = writer()
  putShort(w, slot)
  w.data

proc bodyPlayerCommand*(entityId, action, jumpBoost: int): seq[int] =
  var w = writer()
  putVarInt(w, entityId)
  putVarInt(w, action)
  putVarInt(w, jumpBoost)
  w.data

proc bodyPlayerInput*(flags: int): seq[int] =
  var w = writer()
  putByte(w, flags)
  w.data

# ---------------------------------------------------------------------------
# The session
#
# What a client has to *do* rather than what it has to parse, and it is a short
# list that is nonetheless the whole difference between a decoder and a client:
# answer every teleport, answer every keep-alive, answer every ping, answer
# every chunk batch, and say `player_loaded` once. Miss any of them and the
# connection either drops after twenty seconds or silently stops sending
# terrain, and neither failure names itself.

type
  Outbound* = object
    name*: string
    body*: seq[int]

  Play* = object
    live*: bool                ## Play was entered and has not been left
    entityId*: int
    hardcore*: bool
    gamemode*: int
    dimension*: int
    worldName*: string
    seaLevel*: int
    viewDistance*: int
    simulationDistance*: int

    x*, y*, z*: float
    yaw*, pitch*: float
    dx*, dy*, dz*: float
    onGround*: bool
    positioned*: bool          ## a teleport has been received and answered
    lastTeleportId*: int
    pendingTeleports*: int     ## unanswered, which should never exceed zero
                               ## for longer than one call to `onPlayPacket`

    chunkCenterX*, chunkCenterZ*: int
    batchOpen*: bool
    batchesSeen*: int
    chunksInBatch*: int
    chunksPerTick*: float

    loadedAnnounced*: bool     ## `player_loaded` has been sent
    terrainReady*: bool        ## the level-chunks-loaded game event arrived

    health*: float
    food*: int
    saturation*: float
    experienceLevel*: int
    dead*: bool
    deaths*: int
      ## How many times the server has killed this player, and therefore how
      ## many respawns this client asked for. A count rather than a flag so a
      ## play script can tell "never died" from "died and came back".
    respawnAsked: bool

    worldAge*: int
    timeOfDay*: int
    spawn*: BlockPos

    keepAlivesAnswered*: int
    out0*: seq[Outbound]
    problem*: string

const
  DefaultChunksPerTick* = 16.0
    ## What vanilla asks for on a fast connection. The number is a *request*,
    ## and `pace` below is how a client that cannot keep up lowers it.
  MinChunksPerTick* = 0.01
  MaxChunksPerTick* = 64.0

proc playSession*(): Play =
  Play(live: false, entityId: 0, hardcore: false, gamemode: 0, dimension: 0,
       worldName: "", seaLevel: 0, viewDistance: 0, simulationDistance: 0,
       x: 0.0, y: 0.0, z: 0.0, yaw: 0.0, pitch: 0.0, dx: 0.0, dy: 0.0, dz: 0.0,
       onGround: false, positioned: false, lastTeleportId: -1,
       pendingTeleports: 0, chunkCenterX: 0, chunkCenterZ: 0, batchOpen: false,
       batchesSeen: 0, chunksInBatch: 0, chunksPerTick: DefaultChunksPerTick,
       loadedAnnounced: false, terrainReady: false, health: 20.0, food: 20,
       saturation: 5.0, experienceLevel: 0, dead: false, deaths: 0,
       respawnAsked: false, worldAge: 0,
       timeOfDay: 0, spawn: BlockPos(x: 0, y: 0, z: 0), keepAlivesAnswered: 0,
       out0: @[], problem: "")

proc send(s: var Play; name: string; body: seq[int]) =
  s.out0.add Outbound(name: name, body: body)

proc noteProblem(s: var Play; why: string) =
  if s.problem.len == 0: s.problem = why

proc takeOutbound*(s: var Play): seq[Outbound] =
  ## Drain the queue. A caller sends what comes back and nothing else, which is
  ## what makes "what would this client say here" a question a test can ask
  ## without a socket.
  result = s.out0
  s.out0 = @[]

proc pace*(s: var Play; chunksPerTick: float) =
  ## Change the pacing the *next* `chunk_batch_finished` will ask for. Clamped,
  ## because zero stops terrain arriving altogether and the server takes a large
  ## number at its word.
  var v = chunksPerTick
  if v < MinChunksPerTick: v = MinChunksPerTick
  if v > MaxChunksPerTick: v = MaxChunksPerTick
  s.chunksPerTick = v

proc applyTeleport(s: var Play; p: PositionPacket) =
  ## The relative-flag rules, spelled out because they are per axis and because
  ## the delta fields have their own three bits. A set bit means "add to what
  ## you have"; a clear bit means "this is where you are".
  if relative(p, RelX): s.x = s.x + p.x else: s.x = p.x
  if relative(p, RelY): s.y = s.y + p.y else: s.y = p.y
  if relative(p, RelZ): s.z = s.z + p.z else: s.z = p.z
  if relative(p, RelYaw): s.yaw = s.yaw + p.yaw else: s.yaw = p.yaw
  if relative(p, RelPitch): s.pitch = s.pitch + p.pitch else: s.pitch = p.pitch
  if relative(p, RelDeltaX): s.dx = s.dx + p.dx else: s.dx = p.dx
  if relative(p, RelDeltaY): s.dy = s.dy + p.dy else: s.dy = p.dy
  if relative(p, RelDeltaZ): s.dz = s.dz + p.dz else: s.dz = p.dz

proc enterPlay*(s: var Play) =
  ## Called when Configuration finishes. Separate from `playSession` so that a
  ## dimension change, which re-runs much of this, does not have to pretend to
  ## be a fresh connection.
  s.live = true

proc onPlayPacket*(s: var Play; name: string; r: var Reader) =
  ## One clientbound packet, by name. Unknown names are ignored on purpose: the
  ## frame carries its own length, so skipping a packet this client does not
  ## handle costs a cursor advance and nothing else, and there are 139 of them.
  if not s.live: return
  if name == PlayLogin:
    let p = readLoginPacket(r)
    if not ok(r):
      noteProblem(s, "a truncated login packet")
      return
    s.entityId = p.entityId
    s.hardcore = p.hardcore
    s.viewDistance = p.viewDistance
    s.simulationDistance = p.simulationDistance
    s.gamemode = p.world.gamemode
    s.dimension = p.world.dimension
    s.worldName = p.world.worldName
    s.seaLevel = p.world.seaLevel
    # A join is not a position. The server always follows `login` with a
    # `player_position`, and until that arrives the client does not know where
    # it is - which is why `positioned` starts false and is not set here.
    s.positioned = false
    s.dead = false
    return

  if name == PlayRespawn:
    let p = readRespawnPacket(r)
    if not ok(r):
      noteProblem(s, "a truncated respawn packet")
      return
    s.gamemode = p.world.gamemode
    s.dimension = p.world.dimension
    s.worldName = p.world.worldName
    s.seaLevel = p.world.seaLevel
    s.positioned = false
    s.dead = false
    s.terrainReady = false
    # Every chunk the client held belonged to the old dimension. Saying so here
    # is what stops a respawn showing the world it left behind.
    return

  if name == PlayPlayerPosition:
    let p = readPositionPacket(r)
    if not ok(r):
      noteProblem(s, "a truncated player position")
      return
    applyTeleport(s, p)
    s.lastTeleportId = p.teleportId
    s.positioned = true
    # The dance, and the order matters: confirm first, then say where you are.
    # A client that sends its position before confirming is telling the server
    # about a teleport the server does not yet believe it accepted, and the
    # server answers with another teleport.
    send(s, PlayAcceptTeleportation, bodyAcceptTeleportation(p.teleportId))
    send(s, PlayMovePlayerPosRot,
         bodyMovePlayerPosRot(s.x, s.y, s.z, s.yaw, s.pitch, s.onGround, false))
    return

  if name == PlayPlayerRotation:
    let p = readRotationPacket(r)
    if not ok(r):
      noteProblem(s, "a truncated player rotation")
      return
    if p.relativeYaw: s.yaw = s.yaw + p.yaw else: s.yaw = p.yaw
    if p.relativePitch: s.pitch = s.pitch + p.pitch else: s.pitch = p.pitch
    return

  if name == PlayDisconnect:
    # The server's own words for why it is about to close the socket, which is
    # the one thing a client can never work out for itself.
    #
    # Without this, a kick and a cable being pulled are the same event here: the
    # socket ends, the host says "the server closed the connection", and the
    # only way to find out which is to read somebody else's log - which said
    # "Disconnected" and nothing else. A day went into that.
    #
    # The reason is a text component, and in this protocol that is NBT rather
    # than JSON. Nothing here decodes NBT for a message nobody renders, so this
    # takes the printable runs out of the body and keeps the longest, which for
    # every kick vanilla sends is the sentence itself. A partial answer in the
    # log beats a correct answer nobody can get at.
    var best = ""
    var run = ""
    while true:
      let b = readByte(r)
      if not ok(r): break
      if b >= 32 and b < 127:
        run.add char(b)
      else:
        if run.len > best.len: best = run
        run = ""
    if run.len > best.len: best = run
    noteProblem(s, if best.len > 2: "the server disconnected us: " & best
                   else: "the server disconnected us, with no readable reason")
    return

  if name == PlayKeepAlive:
    let id = readLong(r)
    if not ok(r):
      noteProblem(s, "a truncated keep alive")
      return
    # The id is echoed exactly. A client that answers with its own number is
    # disconnected, and one that does not answer at all is disconnected after
    # twenty seconds with no message that says why.
    send(s, PlayKeepAliveOut, bodyKeepAlive(id))
    inc s.keepAlivesAnswered
    return

  if name == PlayPing:
    let id = readInt(r)
    if not ok(r):
      noteProblem(s, "a truncated ping")
      return
    send(s, PlayPongOut, bodyPong(id))
    return

  if name == PlaySetTime:
    let p = readTimePacket(r)
    if not ok(r):
      noteProblem(s, "a truncated set time")
      return
    s.worldAge = p.age
    # A negative time of day is how the server says the daylight cycle is
    # frozen; the magnitude is still the time. Taking it as written puts the sun
    # below the horizon at noon.
    s.timeOfDay = p.time
    if s.timeOfDay < 0: s.timeOfDay = -s.timeOfDay
    return

  if name == PlaySetDefaultSpawnPosition:
    let p = readSpawnPositionPacket(r)
    if not ok(r):
      noteProblem(s, "a truncated spawn position")
      return
    s.spawn = p.at.at
    return

  if name == PlaySetChunkCacheCenter:
    let p = readChunkCenterPacket(r)
    if not ok(r):
      noteProblem(s, "a truncated chunk cache centre")
      return
    s.chunkCenterX = p.chunkX
    s.chunkCenterZ = p.chunkZ
    return

  if name == PlaySetChunkCacheRadius:
    let v = readVarInt(r)
    if not ok(r):
      noteProblem(s, "a truncated chunk cache radius")
      return
    s.viewDistance = v
    return

  if name == PlaySetSimulationDistance:
    let v = readVarInt(r)
    if not ok(r):
      noteProblem(s, "a truncated simulation distance")
      return
    s.simulationDistance = v
    return

  if name == PlayChunkBatchStart:
    # No fields at all. Its whole content is that it arrived.
    s.batchOpen = true
    s.chunksInBatch = 0
    return

  if name == PlayChunkBatchFinished:
    let size = readVarInt(r)
    if not ok(r):
      noteProblem(s, "a truncated chunk batch end")
      return
    if not s.batchOpen:
      # A batch that ends without starting means a packet was missed, which
      # means the stream is out of step. Better to say so than to answer.
      noteProblem(s, "a chunk batch finished that never started")
      return
    s.batchOpen = false
    inc s.batchesSeen
    if size != s.chunksInBatch:
      # Not fatal - the server counts what it sent and the client counts what it
      # decoded, and a client is allowed to drop one - but it is exactly the
      # signal that a chunk was refused, so it is recorded rather than ignored.
      discard
    send(s, PlayChunkBatchReceived, bodyChunkBatchReceived(s.chunksPerTick))
    return

  if name == PlayGameEvent:
    let p = readGameEventPacket(r)
    if not ok(r):
      noteProblem(s, "a truncated game event")
      return
    if p.reason == EventChangeGameMode:
      s.gamemode = int(p.value)
    elif p.reason == EventLevelChunksLoaded:
      s.terrainReady = true
      if not s.loadedAnnounced:
        # Said once, and only after the server says the terrain is there. A
        # client that says it earlier is claiming to have loaded a world it has
        # not been sent.
        send(s, PlayPlayerLoaded, bodyPlayerLoaded())
        s.loadedAnnounced = true
    return

  if name == PlaySetHealth:
    let p = readHealthPacket(r)
    if not ok(r):
      noteProblem(s, "a truncated set health")
      return
    let wasDead = s.dead
    s.health = p.health
    s.food = p.food
    s.saturation = p.saturation
    if s.health <= 0.0:
      s.dead = true
      # Asking to come back from HERE as well, and not only from
      # `player_combat_kill`, because a player who logs in already dead is
      # never sent that packet - the server just says nought health and waits
      # for a death screen that does not exist in this client. That is the
      # state a session gets STUCK in: dead in the player file, dead again
      # every login, and nothing in the game able to undo it.
      if not wasDead and not s.respawnAsked:
        s.deaths = s.deaths + 1
        send(s, PlayClientCommand, bodyClientCommand(CommandRespawn))
        s.respawnAsked = true
    else:
      s.dead = false
      s.respawnAsked = false
    return

  if name == PlaySetExperience:
    let p = readExperiencePacket(r)
    if not ok(r):
      noteProblem(s, "a truncated set experience")
      return
    s.experienceLevel = p.level
    return

  if name == PlayPlayerCombatKill:
    let p = readCombatKillPacket(r)
    if not ok(r):
      noteProblem(s, "a truncated combat kill")
      return
    if p.playerId == s.entityId and not s.dead:
      s.dead = true
      # And ask to come back, at once.
      #
      # A vanilla client shows a death screen and waits for a person to press
      # Respawn; this one has no death screen and nobody to press it, so
      # without this the session simply stops - the body stays dead, movement
      # stops being believed, and the server writes "dead" into the player file
      # so that EVERY later login starts dead as well. One play script killed
      # the player with an rcon `damage` and every run after it was stuck at
      # nought health with no way out but hand-editing somebody's world.
      #
      # `client_command 0` is exactly what the button sends. A client that
      # declines to have a death screen is a client that respawns itself.
      s.deaths = s.deaths + 1
      send(s, PlayClientCommand, bodyClientCommand(CommandRespawn))
    return

  if name == PlayStartConfiguration:
    # The server is taking the connection back to Configuration - a datapack
    # reload, or a resource pack change. Play is over until it finishes again.
    s.live = false
    return

  # Everything else is a packet this session does not act on. The caller may
  # still decode it; the session simply has no state that depends on it.
  discard

proc respawnNow*(s: var Play) =
  ## What the death screen button does. Nothing else clears `dead`, so a client
  ## that never calls this stays dead, which is the correct behaviour rather
  ## than a stuck one.
  if not s.dead or s.respawnAsked: return
  send(s, PlayClientCommand, bodyClientCommand(CommandRespawn))
  s.respawnAsked = true

proc noteChunk*(s: var Play) =
  ## Called once per `level_chunk_with_light` taken, so that the count a batch
  ## ends with can be compared with the count that arrived.
  if s.batchOpen: inc s.chunksInBatch

proc stepMovement*(s: var Play; x, y, z, yaw, pitch: float;
                   onGround: bool) =
  ## Where the game tells the connection the player went. Sends the smallest
  ## packet that says it, which is what vanilla does and what keeps a moving
  ## player from costing forty bytes a tick: position and look only when both
  ## changed, and the one-byte status packet when neither did.
  if not s.positioned: return
  let movedPos = x != s.x or y != s.y or z != s.z
  let movedLook = yaw != s.yaw or pitch != s.pitch
  let movedGround = onGround != s.onGround
  s.x = x
  s.y = y
  s.z = z
  s.yaw = yaw
  s.pitch = pitch
  s.onGround = onGround
  if movedPos and movedLook:
    send(s, PlayMovePlayerPosRot,
         bodyMovePlayerPosRot(x, y, z, yaw, pitch, onGround, false))
  elif movedPos:
    send(s, PlayMovePlayerPos, bodyMovePlayerPos(x, y, z, onGround, false))
  elif movedLook:
    send(s, PlayMovePlayerRot, bodyMovePlayerRot(yaw, pitch, onGround, false))
  elif movedGround:
    send(s, PlayMovePlayerStatusOnly, bodyMovePlayerStatusOnly(onGround, false))

proc digStart*(s: var Play; at: BlockPos; face, sequence: int) =
  send(s, PlayPlayerAction, bodyPlayerAction(DigStart, at, face, sequence))

proc digCancel*(s: var Play; at: BlockPos; face, sequence: int) =
  send(s, PlayPlayerAction, bodyPlayerAction(DigCancel, at, face, sequence))

proc digFinish*(s: var Play; at: BlockPos; face, sequence: int) =
  send(s, PlayPlayerAction, bodyPlayerAction(DigFinish, at, face, sequence))

proc placeBlock*(s: var Play; hand: int; at: BlockPos; face: int;
                 cursorX, cursorY, cursorZ: float; insideBlock: bool;
                 sequence: int) =
  send(s, PlayUseItemOn,
       bodyUseItemOn(hand, at, face, cursorX, cursorY, cursorZ, insideBlock,
                     false, sequence))

proc swing*(s: var Play; hand: int) =
  send(s, PlaySwing, bodySwing(hand))
