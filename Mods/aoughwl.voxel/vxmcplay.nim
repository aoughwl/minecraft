## The client: a socket at one end, this world's blocks at the other.
##
## Everything either side of this file already existed and neither half could
## reach the other. `aoughwl.mcnet` is the whole protocol as arithmetic -
## it has never touched a socket and, by its own design, never will.
## `vxworld` is a world that generates, meshes and streams its own terrain and
## has never heard of a server. This is the seam, and it is deliberately the
## only file in either mod that knows about both.
##
## ## What crosses and what does not
##
## Three rules, and all three come out of `docs/STREAM.md` rather than being
## invented here:
##
## **A chunk's bytes never enter the interpreter.** `level_chunk_with_light` is
## tens of kilobytes and materialising one costs more than a frame before a
## single block is looked at. So its header is read field by field off the
## host's own cursor, and the section array is handed to `chunkDecode`, which
## unpacks the paletted containers host-side and answers with **runs**.
##
## **Runs are the bulk path.** A section is 4096 blocks and a host call is
## about a microsecond, so reading a section block by block is eight
## milliseconds - worse than the problem being solved. A section of air, or of
## solid stone, is one run and one fill. `vxmcmap.fillRun` is where a run lands,
## and it lands as a contiguous span because Minecraft's y-z-x order and this
## world's own `localIndex` are the same order.
##
## **Every other packet keeps its existing decoder.** `netplay` answers a
## packet by name from a byte reader, and those decoders were written against
## Mojang's own 774 type definitions and are proved against them in
## `Tests/mcplay_test.exe`. Writing them a second time against the cursor would
## be a second decoder to get subtly wrong. So a small packet's body is taken
## whole and handed to the one that already exists - and *only* a small one:
## anything past `BodyLimit` is stepped over unread, which is what keeps the
## megabyte of registry data in Configuration off the frame.
##
## `block_update` and `section_blocks_update` are exactly that path, which is
## why one changed block never costs a section decode: they are ordinary small
## packets with ordinary small decoders, and nothing here holds a copy of a
## section that would need refreshing.
##
## ## What this does not do
##
## Online mode. The three login calls the host provides - the sealed secret,
## the sealed token, the signed hash - are not used, and an `Encryption
## Request` is reported as "this server is in online mode" rather than
## half-answered. A LAN world, a server on this machine and an offline-mode
## server all work; a Mojang-authenticated one is a session-server `httpPost`
## this file does not make yet, and saying so out loud is better than a
## connection that hangs.

import stream
import aoughwl_mcnet/netwire
import aoughwl_mcnet/netproto
import aoughwl_mcnet/netplay
import aoughwl_mcnet/netslot
import aoughwl_mcnet/netinv
import aoughwl_mcnet/netentity
import aoughwl_mcnet/netherd
import vxbeing
import vxblocks
import vxworld
import vxmcmap

const
  BodyLimit* = 4096
    ## The largest packet body this will take whole. Everything `netplay` acts
    ## on is far below it - a teleport is 34 bytes, a keep-alive is 8 - and
    ## everything above it is either a chunk, which is intercepted before this
    ## is asked, or something no decoder here reads. The base64 hatch costs per
    ## byte, so this is the line between "reuse the decoder that exists" and
    ## "spend a frame on a packet nobody reads".

  DefaultSections* = 24
    ## How many sections an overworld column has at protocol 774: y from -64 to
    ## 320. It is the dimension's height divided by sixteen, and the height is
    ## in the `registry_data` NBT this client does not read - so it is a default
    ## rather than a fact, and it is **checked rather than trusted**:
    ## `chunkDecode` is told the byte count the packet stated and refuses if the
    ## sections it was asked for did not consume exactly that. A wrong section
    ## count therefore fails loudly on the first column rather than quietly
    ## producing a plausible wrong world.
  DefaultMinSection* = -4
    ## And where they start: y = -64 is section -4.

  ColumnCost* = 1200
    ## What adopting one column is charged against the caller's frame budget,
    ## in the same units `main.nim` charges chunk generation and band meshing
    ## in. A column is a few sections of real blocks and each is a 4096-entry
    ## fill, so it is the dearest single thing a frame can do here - which is
    ## exactly why it is a budget and not a count. See `workChunks`.

  TicksPerSecond* = 20.0
  MinPace* = 0.05
    ## One column a second, which is the floor a client that is barely running
    ## should be allowed to ask for. It was 1.0 - twenty a second - and a floor
    ## of twenty is not a floor at all for a client that can take one: it is the
    ## same unbounded backlog the constant above used to build, arrived at by a
    ## clamp instead of by arithmetic.
  MaxPace* = 40.0
    ## The bounds this client will ask the server to send chunks at. The number
    ## goes out in `chunk_batch_received` and the server takes it at its word,
    ## so a client that asks for more than it can adopt gets a backlog it never
    ## clears and one that asks for nothing gets no world.

  MoveTick* = 0.05
    ## How often a moving player tells the server so, in seconds. Twenty a
    ## second, which is one a server tick and exactly what vanilla sends: the
    ## server integrates nothing between two of these, so a slower rate is a
    ## player who teleports in front of everyone else, and a faster one is
    ## packets the server throws away while counting them against a rate limit.
    ##
    ## It is counted off the *frame's own* `deltaTime`, by the caller, and not
    ## off a clock read here - a mod cannot time its own work, because the
    ## clock it can read was sampled at the top of the frame.

  FaceDown* = 0
  FaceUp* = 1
  FaceNorth* = 2
  FaceSouth* = 3
  FaceWest* = 4
  FaceEast* = 5
    ## Minecraft's face numbering, which is the order of `Direction.values()`
    ## and not an ordering anything else here uses. A dig or a placement sent
    ## with the wrong one is not refused - it is applied to the wrong side of
    ## the block, which looks like an off-by-one in the ray walk.

  MainHand* = 0

  HotbarSlots* = 9
    ## And where window zero keeps them: `netinv.SlotHotbarFirst` .. +9.

type
  McClient* = object
    handle*: int               ## the host's stream, or -1
    conn*: Connection
    table*: Table
    play*: Play
    ix*: StateIndex
    map*: BlockMap
    sections*: int
    minSection*: int

    greeted*: bool             ## the handshake has gone out
    floorY*: int               ## this world's y = 0, in Minecraft's y
    anchored*: bool            ## and whether it has been decided yet

    columns*: int              ## columns adopted into the world
    refused*: int              ## columns the host would not decode
    outside*: int              ## sections that fell outside the window
    serverBlocks*: int         ## blocks written from the server's own chunks
    holes*: int
      ## And blocks NOT written, because the name on them answers to nothing in
      ## this session's catalog. They go in as air - see `vxmcmap` - and this
      ## is the only number that says how many, which is to say how much of
      ## this world is the server's and how much of it is an unfinished
      ## palette. A world with a big number here is a world you can walk
      ## through the walls of.
    edits*: int                ## single blocks changed by block updates
    packets*: int

    groundState*: int          ## the state id of the block under the spawn
    groundX*, groundY*, groundZ*: int
    groundKnown*: bool
      ## What the server says is directly under the player where it put them,
      ## by its own block state id, taken with one `chunkBlock` out of the
      ## column that holds it.
      ##
      ## It is the assertion with no counting in it. A total says blocks
      ## arrived; it does not say they arrived in the right order, through the
      ## right palette slot, or at the right height - a decoder that read every
      ## run one entry out has exactly the right total. A named block at a
      ## named place does say that, and it is the one thing here that is
      ## **the server's answer** rather than this client's arithmetic about it.
      ##
      ## `chunkBlock` is documented as a spot check and not the bulk path, and
      ## this is the spot check: one call, once, for the whole join.

    # -----------------------------------------------------------------------
    # Saying things back
    #
    # Everything below this line is the half of a client that a decoder does
    # not have: what it *does*. All of it is counted, and every count has a
    # `sent` twin and an `agreed` twin, because the only interesting question
    # about an action is whether the server did it - and a client that counts
    # only what it said proves nothing at all.

    moved*: int                ## movement packets actually put on the wire
    sinceMove*: float          ## seconds since the last one, off the frame

    centreSeen*: bool
    centre0X*, centre0Z*: int
    driftTeleport*: int
    driftWait*: int
    driftMax*: int
      ## How far the server's *own* chunk cache centre has ever got from where
      ## it was when this world was first filled, in chunks.
      ##
      ## This is the movement check with nothing of ours in it. Every other
      ## number a moving client can report - where it thinks it is, how many
      ## packets it sent - is this client agreeing with itself, and would say
      ## exactly the same thing against a server that hung up ten seconds ago.
      ## `set_chunk_cache_center` is sent by the server, when the server decides
      ## the player it is keeping has crossed a chunk boundary. It cannot move
      ## unless the movement arrived and was believed.
      ##
      ## The baseline is taken once a column has been adopted rather than at the
      ## first teleport, because the centre and the teleport arrive in either
      ## order and a baseline of 0,0 taken before the real one would read as an
      ## enormous drift on the next packet.

    sequence*: int             ## the action counter every dig and place carries
    acked*: int                ## `block_changed_ack` packets seen
    lastAck*: int              ## and the sequence the last one carried

    digOpen*: bool             ## a dig start has gone out and not been ended
    digX*, digY*, digZ*: int   ## where, in Minecraft's own coordinates
    digFace*: int
    digsStarted*: int
    digsFinished*: int

    wantBreak*: bool           ## a dig finish is waiting for the server
    breakX*, breakY*, breakZ*: int
    breaksAgreed*: int
      ## Blocks the server itself turned to air at the place this client asked
      ## it to. Not "blocks this client removed": this client removes nothing
      ## in server mode, precisely so that this number can only go up when the
      ## server says so.

    placesSent*: int
    wantPlace*: bool
    placeAtX*, placeAtY*, placeAtZ*: int
    placesAgreed*: int
      ## And the same for a placement: the server's own `block_update` at the
      ## cell this client aimed at, carrying something that is not air.

    brokeAtX*, brokeAtY*, brokeAtZ*: int
    putAtX*, putAtY*, putAtZ*: int
    putState*: int
      ## And *where*, in Minecraft's own coordinates, so that the same question
      ## can be put to the server afterwards by a person with an rcon console.
      ## This is the whole point of writing them down: a count is this client
      ## agreeing with itself, and a coordinate is something a second witness
      ## can be asked about.

    # -----------------------------------------------------------------------
    # What is in the bag

    items*: seq[string]        ## item id -> name, from the player's own jar
    parts*: ComponentTable     ## data component type id -> name, likewise
    kinds*: seq[string]        ## entity type id -> name, likewise
    inv*: Containers
    slotIds*: seq[int]         ## window zero, 46 of them, -1 for empty
    slotCounts*: seq[int]
    heldSlot*: int             ## 0..8, the hotbar cell the server thinks is up
    slotWrites*: int           ## `set_slot` packets applied
    contentWrites*: int        ## `container_set_content` packets applied
    heldWrites*: int           ## `set_held_slot` packets applied
    invProblem*: string

    # -----------------------------------------------------------------------
    # What else is out there
    #
    # `netherd` holds it - the table of everything the server has told this
    # client about that is not a block. Kept here rather than in `Play` because
    # it is a hundred kilobytes of a long session and `Play` is copied about.

    herd*: Herd
    feeds*: int                ## how many times the renderer has taken a delta
    fedLines*: int             ## and how many lines went out on the last one
    unnamed*: int
      ## Entities whose type id this build's registry has no name for. Not an
      ## error - a newer server owns types this jar does not - but a hole, and
      ## counted as one.
    kindProblem*: string

    problem*: string
    phase*: string
    host*: string
    port*: int

proc newClient*(): McClient =
  McClient(handle: -1, conn: Connection(state: StateHandshake, threshold: -1,
             loginSucceeded: false, finished: false, problem: ""),
           table: emptyTable(), play: playSession(),
           ix: emptyStateIndex(), map: emptyBlockMap(),
           sections: DefaultSections, minSection: DefaultMinSection,
           greeted: false, floorY: 0, anchored: false,
           columns: 0, refused: 0, outside: 0, serverBlocks: 0, holes: 0,
           edits: 0,
           packets: 0, groundState: -1, groundX: 0, groundY: 0, groundZ: 0,
           groundKnown: false,
           moved: 0, sinceMove: 0.0,
           centreSeen: false, centre0X: 0, centre0Z: 0, driftTeleport: -2, driftWait: 0,
           driftMax: 0,
           sequence: 0, acked: 0, lastAck: -1,
           digOpen: false, digX: 0, digY: 0, digZ: 0, digFace: 0,
           digsStarted: 0, digsFinished: 0,
           wantBreak: false, breakX: 0, breakY: 0, breakZ: 0, breaksAgreed: 0,
           placesSent: 0, wantPlace: false,
           placeAtX: 0, placeAtY: 0, placeAtZ: 0, placesAgreed: 0,
           brokeAtX: 0, brokeAtY: 0, brokeAtZ: 0,
           putAtX: 0, putAtY: 0, putAtZ: 0, putState: -1,
           items: @[], parts: emptyComponents(), kinds: @[], inv: containers(),
           slotIds: @[], slotCounts: @[], heldSlot: 0,
           slotWrites: 0, contentWrites: 0, heldWrites: 0, invProblem: "",
           herd: emptyHerd(), feeds: 0, fedLines: 0, unnamed: 0,
           kindProblem: "",
           problem: "", phase: "idle", host: "", port: 0)

proc floorInt(v: float): int =
  ## Towards minus infinity, which is what a block coordinate needs and what
  ## `int()` does not do: a player at x = -0.4 stands in block -1, and
  ## truncation puts them in block 0 - one chunk out, but only west and north
  ## of the origin, which is why it looks like it works.
  let whole = int(v)
  if v < 0.0 and float(whole) != v: return whole - 1
  whole

proc fault(c: var McClient; why: string) =
  if c.problem.len == 0: c.problem = why
  c.phase = "failed"

# ---------------------------------------------------------------------------
# Opening one

## Load the two generated tables. Both are the player's own data out of their
## own jar - see `tools/mcindex.ps1` - and a missing one is named rather than
## worked around, because a client that guessed a packet id would send the
## wrong packet to a real server.
proc loadTables*(c: var McClient; indexText, packetsText: string) =
  c.ix = parseStateIndex(indexText)
  if c.ix.problem.len > 0:
    fault(c, "the block state index: " & c.ix.problem)
    return
  let rows = parsePlayPackets(packetsText)
  if rows.problem.len > 0:
    fault(c, "the play packet table: " & rows.problem)
    return
  c.table = knownTable()
  var i = 0
  while i < rows.names.len:
    declarePlayFrom(c.table, rows.dirs[i], rows.ids[i], rows.names[i])
    inc i

## And the two the *inventory* needs, which are a separate call because they
## are a separate failure: a client with no item table still plays the world
## perfectly and only cannot name what is in its hand, where a client with no
## packet table cannot join at all. Missing is therefore reported in
## `invProblem` and not in `problem` - it must not fail a join.
##
## The component table is the load-bearing one of the pair. A stack on the wire
## carries its components as `(type id, value)` and the value's *shape* is
## looked up by the type's name, so a reader without this table cannot skip a
## component it does not want - and a component it cannot skip makes every byte
## after it in the packet unreadable, not just that field.
proc loadItemTables*(c: var McClient; itemsText, componentsText: string) =
  c.items = parseIdNames(itemsText)
  let parts = parseIdNames(componentsText)
  c.parts = emptyComponents()
  var i = 0
  while i < parts.len:
    if parts[i].len > 0: declareComponent(c.parts, i, parts[i])
    inc i
  if c.items.len == 0:
    c.invProblem = "no item table - run tools/mcindex.ps1"
  elif parts.len == 0:
    c.invProblem = "no data component table - run tools/mcindex.ps1"

## And the one the *entities* need, which is a third separate failure for the
## third time for the same reason: a client with no entity type table plays the
## world exactly as before and simply draws nobody in it.
##
## `add_entity` carries a number into `minecraft:entity_type`, and that
## numbering is the jar's - `minecraft:zombie` is 150 at 1.21.11 and was
## something else at 1.21.4. Nothing here hardcodes one. The names are full
## namespaced names and are passed on as such; it is `herdFeed` that shortens
## them, where the reason to is written down.
proc loadEntityTable*(c: var McClient; kindsText: string) =
  c.kinds = parseIdNames(kindsText)
  if c.kinds.len == 0:
    c.kindProblem = "no entity type table - run tools/mcindex.ps1"

## Which block names the index carries, so the caller can ask its own registry
## about each of them. Kept out here rather than done inside, because the
## registry is `main.nim`'s and this file has deliberately never seen one.
proc wantedNames*(c: McClient): seq[string] = plainNames(c.ix)

## What the registry answered. Everything a name does not answer to becomes
## air and is counted in `c.map.unknown`; see `vxmcmap`.
proc useBlocks*(c: var McClient; resolved: seq[int]) =
  c.map = blockMapFrom(c.ix, resolved)

## Open the socket. Returns at once - connecting happens off the frame - so
## `step` is what finds out whether it worked.
proc connect*(c: var McClient; host: string; port: int) =
  c.host = host
  c.port = port
  if not streamAvailable():
    fault(c, "this build has no stream host calls in it")
    return
  if not streamAllowed(host):
    fault(c, "the player has not allowed " & host & " - see stream-allow.txt")
    return
  c.handle = openStream(host, port)
  if c.handle < 0:
    fault(c, streamProblem(-1))
    return
  c.phase = "connecting"

proc close*(c: var McClient) =
  if c.handle >= 0: discard closeStream(c.handle)
  c.handle = -1
  c.phase = "closed"

# ---------------------------------------------------------------------------
# Saying things

proc sendBody(c: var McClient; dir, state: int; name: string; body: seq[int]) =
  ## One packet by name. The id comes out of the table the jar filled, so a
  ## name this profile does not carry is a packet that is **not sent** rather
  ## than packet zero sent to a real server.
  let id = idOf(c.table, state, dir, name)
  if id < 0:
    fault(c, "this protocol profile has no id for " & name)
    return
  beginPacket(c.handle, id)
  if body.len > 0: putBytes(c.handle, toBase64(body))
  discard sendPacket(c.handle)

proc greet(c: var McClient) =
  ## Handshake with intent 2, then Login Start. Two packets and no waiting in
  ## between: the server reads them back to back and answers both.
  beginPacket(c.handle, IdIntention)
  putVarInt(c.handle, ProtocolVersion)
  putString(c.handle, c.host)
  putShort(c.handle, c.port)
  putVarInt(c.handle, IntentLogin)
  discard sendPacket(c.handle)
  c.conn.state = StateLogin

  var w = writer()
  putString(w, "Jester")
  # The offline-mode UUID. A server in offline mode derives its own from the
  # name and does not care what this is; one in online mode never gets here.
  var i = 0
  while i < 16:
    putByte(w, 0)
    inc i
  beginPacket(c.handle, IdHello)
  putBytes(c.handle, toBase64(w.data))
  discard sendPacket(c.handle)
  c.greeted = true
  c.phase = "login"

proc tellClientInformation(c: var McClient) =
  ## What the server asks every client for in Configuration. It is answered
  ## because a server that never gets it does not finish configuring, not
  ## because anything here reads it back.
  var w = writer()
  putString(w, "en_gb")
  # Two, and not the eight this asked for until a client stayed logged in long
  # enough for it to matter.
  #
  # The window this world keeps is three chunks across. A view distance of eight
  # is a 17x17 square - 289 columns - of which nine can ever land in it, and the
  # other 280 are decoded far enough to be counted in `outside` and thrown away.
  # That is not merely waste. A column costs `ColumnCost` of the frame budget
  # and `step` reads packets in arrival order, so 280 useless columns are 280
  # columns' worth of frames that the server's `keep_alive` is queued BEHIND -
  # and a keep alive answered late is a client the server disconnects with
  # "Timed out" about forty-five seconds in. Which is exactly what it did, every
  # time, just as a play script got to the part where it breaks a block.
  #
  # Two is a 5x5 square: twenty-five columns, nine of them useful, and the rest
  # is one frame's slack rather than four minutes of it.
  putByte(w, 2)          # view distance, in chunks
  putVarInt(w, 0)        # chat mode: enabled
  putBool(w, true)       # chat colours
  putByte(w, 0x7F)       # every skin part on
  putVarInt(w, 1)        # main hand: right
  putBool(w, false)      # text filtering
  putBool(w, true)       # listed in the server list
  putVarInt(w, 0)        # particle status: all
  beginPacket(c.handle, IdClientInformation)
  putBytes(c.handle, toBase64(w.data))
  discard sendPacket(c.handle)

proc drainOutbound(c: var McClient) =
  ## Everything the session decided to say. `netplay` queues rather than sends
  ## precisely so that what a client would say here is a question a test can
  ## ask without a socket - so this is the only place the queue becomes bytes.
  let queued = takeOutbound(c.play)
  var i = 0
  while i < queued.len:
    sendBody(c, ToServer, StatePlay, queued[i].name, queued[i].body)
    inc i

# ---------------------------------------------------------------------------
# Doing things
#
# The half of a client that a decoder is not. Everything here is the caller's
# own game saying what the player did; `netplay` turns each into a body and
# this turns the body into bytes. Two rules run through all of it.
#
# **Nothing is applied locally.** A break does not remove a block here and a
# placement does not add one. The server owns this world - it is the whole
# premise of the mode - and a client that changed its own copy first would be
# predicting, which needs the rollback half of prediction to be correct and
# would make every count below unfalsifiable: "blocks broken" would go up
# whether or not the server ever agreed. What arrives instead is
# `block_update`, through the path that already existed, and the counters that
# matter are incremented *there*.
#
# **Every action carries a sequence number.** The server echoes the highest it
# has applied in `block_changed_ack`, which is how a real client knows which of
# its predictions survived. Nothing here predicts, so the number is not needed
# to undo anything - but it is needed for the server to accept the action at
# all, and it is a second, independent witness that the packets went somewhere.

proc talking(c: McClient): bool =
  c.handle >= 0 and c.problem.len == 0 and c.conn.state == StatePlay and
    c.play.positioned

## Minecraft's y for one of this world's. The inverse of `vxmcmap.worldYof`,
## and the only place the two coordinate systems meet on the way *out*.
proc mcYof*(c: McClient; worldY: int): int = worldY + c.floorY

## Where the game says the player is, at most twenty times a second.
##
## `stepMovement` decides which of the four movement packets says it - it sends
## nothing at all when nothing changed - so this is called on every tick the
## caller can afford and costs nothing while the player stands still.
##
## `client_tick_end` goes after it, which is the order vanilla sends them in
## and what it means: everything since the last one was one client tick.
proc sendMovement*(c: var McClient; x, worldY, z, yaw, pitch: float;
                   onGround: bool) =
  if not talking(c): return
  let before = c.play.out0.len
  stepMovement(c.play, x, worldY + float(c.floorY), z, yaw, pitch, onGround)
  if c.play.out0.len > before: inc c.moved
  drainOutbound(c)
  sendBody(c, ToServer, StatePlay, PlayClientTickEnd, bodyClientTickEnd())

## Pace it off the frame that has just happened. Returns whether this frame is
## a movement tick, so the caller spends one `player.position()` and not two.
proc movementDue*(c: var McClient; seconds: float): bool =
  c.sinceMove = c.sinceMove + seconds
  if c.sinceMove < MoveTick: return false
  c.sinceMove = 0.0
  true

## The button went down on a block. In survival the server runs its own break
## timer from here, so this is not a formality: a `dig finish` with no `dig
## start` before it is refused, and the block stays where it is.
proc digStartAt*(c: var McClient; x, worldY, z, face: int) =
  if not talking(c): return
  let mcY = mcYof(c, worldY)
  if c.digOpen and c.digX == x and c.digY == mcY and c.digZ == z: return
  inc c.sequence
  c.digOpen = true
  c.digX = x
  c.digY = mcY
  c.digZ = z
  c.digFace = face
  inc c.digsStarted
  digStart(c.play, BlockPos(x: x, y: mcY, z: z), face, c.sequence)
  swing(c.play, MainHand)
  drainOutbound(c)

## The button came up before the block did.
proc digCancelAt*(c: var McClient) =
  if not c.digOpen: return
  c.digOpen = false
  if not talking(c): return
  inc c.sequence
  digCancel(c.play, BlockPos(x: c.digX, y: c.digY, z: c.digZ), c.digFace,
            c.sequence)
  drainOutbound(c)

## The block is through. What happens next is the server's: it checks its own
## progress, and either destroys the block and tells everyone - which is the
## `block_update` `applyOne` is waiting for - or does not.
proc digFinishAt*(c: var McClient; x, worldY, z, face: int) =
  if not talking(c):
    c.digOpen = false
    return
  let mcY = mcYof(c, worldY)
  if not c.digOpen: digStartAt(c, x, worldY, z, face)
  inc c.sequence
  c.digOpen = false
  inc c.digsFinished
  c.wantBreak = true
  c.breakX = x
  c.breakY = mcY
  c.breakZ = z
  digFinish(c.play, BlockPos(x: x, y: mcY, z: z), face, c.sequence)
  drainOutbound(c)

## Against the face of a block, with what is in the hand. `at` is the block
## that was *clicked*, not the empty cell beside it - the server works the
## second out of the first and the face, and a client that sends the empty one
## places a block one further out than the player aimed.
proc placeAt*(c: var McClient; x, worldY, z, face: int) =
  if not talking(c): return
  inc c.sequence
  inc c.placesSent
  let mcY = mcYof(c, worldY)
  # The point on the face, in the block's own 0..1 space. The middle of the
  # face it was hit on, which is what a crosshair in the centre of a block
  # means and all the server uses it for is the half-slab question.
  var cx = 0.5
  var cy = 0.5
  var cz = 0.5
  if face == FaceDown: cy = 0.0
  elif face == FaceUp: cy = 1.0
  elif face == FaceNorth: cz = 0.0
  elif face == FaceSouth: cz = 1.0
  elif face == FaceWest: cx = 0.0
  elif face == FaceEast: cx = 1.0
  # Where the block should end up if the server agrees, so that the answer can
  # be recognised when it arrives. Remembered here rather than re-derived at
  # reporting time, for the same reason the ground spot check is.
  c.wantPlace = true
  c.placeAtX = x
  c.placeAtY = mcY
  c.placeAtZ = z
  if face == FaceDown: c.placeAtY = mcY - 1
  elif face == FaceUp: c.placeAtY = mcY + 1
  elif face == FaceNorth: c.placeAtZ = z - 1
  elif face == FaceSouth: c.placeAtZ = z + 1
  elif face == FaceWest: c.placeAtX = x - 1
  elif face == FaceEast: c.placeAtX = x + 1
  placeBlock(c.play, MainHand, BlockPos(x: x, y: mcY, z: z), face,
             cx, cy, cz, false, c.sequence)
  swing(c.play, MainHand)
  drainOutbound(c)

## Which hotbar cell is up. The server keeps its own idea of this and every
## placement and every dig is resolved against *its* copy, so a client that
## changes the slot on screen without saying so places the wrong block.
proc holdSlot*(c: var McClient; slot: int) =
  if slot < 0 or slot >= HotbarSlots: return
  if not talking(c): return
  c.heldSlot = slot
  sendBody(c, ToServer, StatePlay, PlaySetCarriedItem, bodySetCarriedItem(slot))

## One click in a container, in the one mode that matters: pick the stack up,
## put the stack down. No prediction is sent, which is legal - the server then
## answers with the whole window rather than trusting the click - and it is the
## honest thing for a client that has no cursor stack of its own yet.
proc clickSlot*(c: var McClient; window, slot, button, mode: int) =
  if not talking(c): return
  var none: seq[int] = @[]
  sendBody(c, ToServer, StatePlay, PlayContainerClickOut,
           bodyContainerClick(window, stateOf(c.inv, window), slot, button,
                              mode, none, none, none, false, 0, 0))

# ---------------------------------------------------------------------------
# A chunk column
#
# The one packet that is not read by the rules above, and the whole reason this
# seam exists.

proc adoptColumn(c: var McClient; w: var World; r: Registry) =
  ## `level_chunk_with_light`, read off the cursor as far as the section array
  ## and then handed to the host.
  ##
  ## The header walk is `netplay.readChunkHeader` said against the cursor
  ## rather than against a byte reader, field for field, and it stops in the
  ## same place for the same reason. The heightmaps are stepped over rather
  ## than read: this world has its own.
  let chunkX = readInt(c.handle)
  let chunkZ = readInt(c.handle)
  let maps = readVarInt(c.handle)
  if not packetOk(c.handle) or maps < 0 or maps > 64:
    fault(c, "a chunk header that does not parse")
    return
  var m = 0
  while m < maps:
    discard readVarInt(c.handle)          # which heightmap
    let longs = readVarInt(c.handle)
    if not packetOk(c.handle) or longs < 0 or longs > 4096:
      fault(c, "a heightmap length out of range")
      return
    discard skipBytes(c.handle, longs * 8)
    inc m
  let size = readVarInt(c.handle)
  if not packetOk(c.handle) or size < 0:
    fault(c, "a chunk section array length out of range")
    return

  # And here the bytes stop. What comes back is a handle to a decoded column
  # sitting host-side, and everything below reads it as runs.
  # Whether the block under the player is in this column, worked out before
  # the decode so that the spot check below is one call and not a search.
  var spotSection = -1
  var spotAt = 0
  if c.anchored and not c.groundKnown:
    let px = floorInt(c.play.x)
    let pz = floorInt(c.play.z)
    let py = floorInt(c.play.y) - 1
    if floorDiv(px, SectionSide) == chunkX and
       floorDiv(pz, SectionSide) == chunkZ:
      let s0 = floorDiv(py, SectionSide) - c.minSection
      if s0 >= 0 and s0 < c.sections:
        # Remembered as it was *here*, not read back off the session later: the
        # server moves the player again while the world is still filling, and a
        # coordinate re-derived at reporting time names a block this never
        # looked at. That cost an hour of thinking the decoder was wrong when
        # the only wrong thing was the label on the answer.
        c.groundX = px
        c.groundY = py
        c.groundZ = pz
        spotSection = s0
        spotAt = (floorMod(py, SectionSide) * SectionSide +
                  floorMod(pz, SectionSide)) * SectionSide +
                 floorMod(px, SectionSide)

  let column = chunkDecode(c.handle, c.sections, false, size)
  if column < 0:
    inc c.refused
    if c.refused == 1: c.problem = "chunkDecode: " & chunkProblem(-1)
    return

  if spotSection >= 0:
    c.groundState = chunkBlock(column, spotSection, spotAt)
    c.groundKnown = true

  var s = 0
  while s < c.sections:
    let sectionY = c.minSection + s
    if not sectionInWorld(sectionY, c.floorY, w.blocksHigh()):
      inc c.outside
      inc s
      continue
    let cy = (sectionY * SectionSide - c.floorY) div SectionSide
    let index = w.chunkIndex(chunkX, cy, chunkZ)
    if index < 0:
      inc c.outside
      inc s
      continue
    # A section of nothing is one question and no blocks at all. Most of a
    # column is sky, so this is the common case and not the corner one.
    if chunkNonAir(column, s) == 0:
      var nothing: seq[int] = @[]
      discard w.adoptChunk(index, nothing, 0, -1, 0)
      inc s
      continue

    var blocks = airSection()
    var filled = 0
    var opaque = 0
    var top = -1
    let runs = chunkRuns(column, s)
    var at = 0
    var run = 0
    while run < runs:
      let state = chunkRunId(column, s, run)
      let n = chunkRunLength(column, s, run)
      if state != McAir:
        let id = blockOfState(c.ix, c.map, state)
        if id == AirId:
          # Not air on the wire and air here: a block this session cannot name.
          # Counted per block rather than per run, because the question it
          # answers is how much of the world went missing and not how often.
          if stateIsHole(c.ix, c.map, state): c.holes = c.holes + n
        else:
          let wrote = fillRun(blocks, at, n, id)
          filled = filled + wrote
          if r.isOpaque(id): opaque = opaque + wrote
          # The last row this run touched, which is the air line this section
          # contributes. Worked out from the run rather than by walking the
          # blocks afterwards: a run knows where it ends.
          let lastY = (at + wrote - 1) div (SectionSide * SectionSide)
          if lastY > top: top = lastY
      at = at + n
      inc run
    discard w.adoptChunk(index, blocks, filled, top, opaque)
    c.serverBlocks = c.serverBlocks + filled
    inc s

  discard chunkClose(column)
  inc c.columns
  noteChunk(c.play)

# ---------------------------------------------------------------------------
# One changed block
#
# Applied straight into the world. Nothing here re-decodes a section, because
# nothing here holds one.

proc applyOne(c: var McClient; w: var World; at: BlockPos; state: int) =
  let id = blockOfState(c.ix, c.map, state)
  if w.setBlockAt(at.x, worldYof(at.y, c.floorY), at.z, id): inc c.edits
  # And the two questions this client asked the server. Both are answered here
  # and nowhere else: this is the server's own packet, about the server's own
  # world, at the cell this client named before it sent anything. A counter
  # incremented where the button was pressed would say the same thing whether
  # the server had ever heard of it.
  if c.wantBreak and at.x == c.breakX and at.y == c.breakY and
     at.z == c.breakZ and state == McAir:
    c.wantBreak = false
    inc c.breaksAgreed
    c.brokeAtX = at.x
    c.brokeAtY = at.y
    c.brokeAtZ = at.z
  if c.wantPlace and at.x == c.placeAtX and at.y == c.placeAtY and
     at.z == c.placeAtZ and state != McAir:
    c.wantPlace = false
    inc c.placesAgreed
    c.putAtX = at.x
    c.putAtY = at.y
    c.putAtZ = at.z
    c.putState = state

# ---------------------------------------------------------------------------
# The bag
#
# Window zero, kept as two flat seqs rather than as `SlotItem`s: what this
# world needs off a stack is its item id and how many, and a `SlotItem` carries
# spans into a reader whose buffer is gone by the next frame. Keeping one would
# be keeping a pointer into a packet.

proc putSlot(c: var McClient; slot: int; item: SlotItem) =
  if slot < 0 or slot >= PlayerSlotCount: return
  while c.slotIds.len < PlayerSlotCount:
    c.slotIds.add(-1)
    c.slotCounts.add 0
  if item.empty or item.count <= 0:
    c.slotIds[slot] = -1
    c.slotCounts[slot] = 0
  else:
    c.slotIds[slot] = item.itemId
    c.slotCounts[slot] = item.count

## What is in one hotbar cell, 0..8, as the game's own name and a count.
proc hotbarName*(c: McClient; cell: int): string =
  if cell < 0 or cell >= HotbarSlots: return ""
  let slot = SlotHotbarFirst + cell
  if slot >= c.slotIds.len or c.slotIds[slot] < 0: return ""
  plainName(nameAt(c.items, c.slotIds[slot]))

proc hotbarCount*(c: McClient; cell: int): int =
  if cell < 0 or cell >= HotbarSlots: return 0
  let slot = SlotHotbarFirst + cell
  if slot >= c.slotCounts.len: return 0
  c.slotCounts[slot]

## And what is in the hand right now, which is the one the server resolves a
## placement against.
proc heldName*(c: McClient): string = hotbarName(c, c.heldSlot)
proc heldCount0*(c: McClient): int = hotbarCount(c, c.heldSlot)

## How many stacks the bag holds at all - the cheap "did anything arrive"
## question, which is separate from "did the right thing arrive".
proc stacksHeld*(c: McClient): int =
  result = 0
  var i = 0
  while i < c.slotIds.len:
    if c.slotIds[i] >= 0: result = result + 1
    inc i

proc takeBody(c: var McClient): seq[int] =
  ## The rest of the packet in hand, as bytes. Only ever called for a body that
  ## has already been measured against `BodyLimit`.
  fromBase64(readBytes(c.handle, -1))

# ---------------------------------------------------------------------------
# The pump

proc stepLogin(c: var McClient; id: int) =
  if id == IdSetCompression:
    let threshold = readVarInt(c.handle)
    # Framing, not state: this arrives *before* Login Success, and the success
    # packet is therefore the first thing the server deflates.
    streamCompression(c.handle, threshold)
    c.conn.threshold = threshold
    return
  if id == IdLoginSuccess:
    c.conn.loginSucceeded = true
    beginPacket(c.handle, IdLoginAcknowledged)
    discard sendPacket(c.handle)
    # The client's acknowledgement moves the connection, not the server's
    # success - see `netproto`. A client that switched on Login Success would
    # read the next packet out of the wrong table.
    c.conn.state = StateConfiguration
    c.phase = "configuring"
    tellClientInformation(c)
    return
  if id == IdEncryptionRequest:
    fault(c, "this server is in online mode, which this client does not do yet")
    return
  if id == IdLoginDisconnect:
    fault(c, "the server refused the login: " & readString(c.handle))
    return

proc stepConfiguration(c: var McClient; id: int) =
  if id == IdConfigKeepAliveOut:
    let alive = readLong(c.handle)
    beginPacket(c.handle, IdConfigKeepAlive)
    putLong(c.handle, alive)
    discard sendPacket(c.handle)
    return
  if id == IdPing:
    let token = readInt(c.handle)
    beginPacket(c.handle, IdPong)
    putInt(c.handle, token)
    discard sendPacket(c.handle)
    return
  if id == IdKnownPacksOut:
    # Echo the server's list back. A client that answers with nothing is told
    # every registry in full instead of the vanilla ones by reference, which is
    # megabytes of NBT this client would then have to skip.
    let count = readVarInt(c.handle)
    var w = writer()
    if count < 0 or count > 1024:
      putVarInt(w, 0)
    else:
      putVarInt(w, count)
      var i = 0
      while i < count:
        let space = readString(c.handle)
        let name = readString(c.handle)
        let version = readString(c.handle)
        putString(w, space)
        putString(w, name)
        putString(w, version)
        inc i
      if not packetOk(c.handle):
        w = writer()
        putVarInt(w, 0)
    beginPacket(c.handle, IdKnownPacks)
    putBytes(c.handle, toBase64(w.data))
    discard sendPacket(c.handle)
    return
  if id == IdFinishConfigurationOut:
    beginPacket(c.handle, IdFinishConfiguration)
    discard sendPacket(c.handle)
    c.conn.state = StatePlay
    c.conn.finished = true
    enterPlay(c.play)
    c.phase = "playing"
    return
  if id == IdConfigDisconnect:
    fault(c, "the server disconnected during configuration")
    return

proc stepPlay(c: var McClient; w: var World; r: Registry; id: int) =
  let name = nameOf(c.table, StatePlay, ToClient, id)
  if name == "unknown": return

  if name == PlayLevelChunkWithLight:
    # Not until the world knows where it is. A column adopted before the first
    # teleport would be written against a floor that is about to move, which is
    # a world made of two worlds.
    if not c.anchored: return
    adoptColumn(c, w, r)
    return

  if name == PlayBlockUpdate:
    if packetLeft(c.handle) > BodyLimit: return
    var body = takeBody(c)
    var reader0 = reader(body)
    let p = readBlockUpdatePacket(reader0)
    if not ok(reader0): return
    if c.anchored: applyOne(c, w, p.at, p.state)
    return

  if name == PlaySectionBlocksUpdate:
    if packetLeft(c.handle) > BodyLimit: return
    var body = takeBody(c)
    var reader0 = reader(body)
    let p = readSectionBlocksPacket(reader0)
    if not ok(reader0): return
    if not c.anchored: return
    var i = 0
    while i < p.positions.len:
      applyOne(c, w, p.positions[i], p.states[i])
      inc i
    return

  if name == PlayBlockChangedAck:
    if packetLeft(c.handle) > BodyLimit: return
    var body = takeBody(c)
    var reader0 = reader(body)
    let n = readVarInt(reader0)
    if not ok(reader0): return
    inc c.acked
    c.lastAck = n
    return

  # The bag. These are the packets that need the item and component tables, so
  # a build without them reads none of them rather than reading them wrongly -
  # `invProblem` already says why, once, at join.
  if name == PlayContainerSetSlot or name == PlayContainerSetContent or
     name == PlaySetPlayerInventory or name == PlaySetHeldSlot:
    if not loaded(c.parts): return
    if packetLeft(c.handle) > BodyLimit: return
    var body = takeBody(c)
    var reader0 = reader(body)
    if name == PlaySetHeldSlot:
      let p = readHeldSlotPacket(reader0)
      if not ok(reader0): return
      if p.slot >= 0 and p.slot < HotbarSlots:
        c.heldSlot = p.slot
        inc c.heldWrites
      return
    if name == PlaySetPlayerInventory:
      let p = readPlayerInventorySlotPacket(reader0, c.parts)
      if not ok(reader0):
        if c.invProblem.len == 0: c.invProblem = reader0.problem
        return
      putSlot(c, p.slot, p.item)
      inc c.slotWrites
      return
    if name == PlayContainerSetSlot:
      let p = readSetSlotPacket(reader0, c.parts)
      if not ok(reader0):
        if c.invProblem.len == 0: c.invProblem = reader0.problem
        return
      noteState(c.inv, p.window, p.stateId)
      # Only window zero lands in the bag. A chest's own slots are the chest's,
      # and writing them over the inventory is the classic way a client ends up
      # showing furnace fuel in its hotbar.
      if p.window == WindowPlayer:
        putSlot(c, p.slot, p.item)
        inc c.slotWrites
      return
    let p = readSetContentPacket(reader0, c.parts)
    if not ok(reader0):
      if c.invProblem.len == 0: c.invProblem = reader0.problem
      return
    noteState(c.inv, p.window, p.stateId)
    if p.window == WindowPlayer:
      var i = 0
      while i < p.items.len:
        putSlot(c, i, p.items[i])
        inc i
      inc c.contentWrites
    return

  # Everything that is out there and is not a block. Sixteen packet names into
  # one table, and the table is `netherd`'s - nothing about where a zombie is
  # gets decided in this file.
  #
  # Every one of these is small: the largest is `set_entity_data`, and a spawn
  # is forty bytes. They go through the ordinary take-the-body path for the
  # reason the block updates do - the decoders exist, were written against
  # Mojang's own 774 definitions, and writing a second set against the cursor
  # would be a second set to get subtly wrong.
  if name == PlayAddEntity or name == PlayRemoveEntities or
     name == PlayMoveEntityPos or name == PlayMoveEntityPosRot or
     name == PlayMoveEntityRot or name == PlayTeleportEntity or
     name == PlayEntityPositionSync or name == PlayRotateHead or
     name == PlayEntityEvent or name == PlayDamageEvent:
    if packetLeft(c.handle) > BodyLimit: return
    var body = takeBody(c)
    var reader0 = reader(body)
    if name == PlayAddEntity:
      let p = readSpawnEntityPacket(reader0)
      if ok(reader0): onAdd(c.herd, p)
      return
    if name == PlayRemoveEntities:
      let p = readRemoveEntitiesPacket(reader0)
      if ok(reader0): onRemove(c.herd, p)
      return
    if name == PlayMoveEntityPos or name == PlayMoveEntityPosRot:
      let p = readMovePacket(reader0, name == PlayMoveEntityPosRot)
      if ok(reader0): onMove(c.herd, p)
      return
    if name == PlayMoveEntityRot:
      let p = readRotatePacket(reader0)
      if ok(reader0): onRotate(c.herd, p)
      return
    if name == PlayTeleportEntity:
      let p = readTeleportPacket(reader0)
      if ok(reader0): onTeleport(c.herd, p)
      return
    if name == PlayEntityPositionSync:
      let p = readSyncPositionPacket(reader0)
      if ok(reader0): onSync(c.herd, p)
      return
    if name == PlayRotateHead:
      let p = readHeadRotationPacket(reader0)
      if ok(reader0): onHeadRotation(c.herd, p)
      return
    if name == PlayEntityEvent:
      let p = readEntityEventPacket(reader0)
      if ok(reader0): onEvent(c.herd, p)
      return
    # `damage_event`, which is where a hit lives at this protocol - entity
    # status 2 has not meant "hurt" since 1.19.4. The packet also names the
    # attacker and the direct cause, and this takes neither: a flinch is about
    # the thing that was hit.
    let p = readDamageEventPacket(reader0)
    if ok(reader0): onHurt(c.herd, p.entityId)
    return

  # Everything else keeps the decoder it already has. A body past the limit is
  # left unread - the frame carries its own length, so skipping it costs a
  # cursor advance and nothing else.
  if packetLeft(c.handle) > BodyLimit: return
  var body = takeBody(c)
  var reader0 = reader(body)
  onPlayPacket(c.play, name, reader0)
  # A join and a respawn both arrive as a world this client has not seen, and
  # the server does NOT remove the old world's entities first - it simply stops
  # talking about them. Everything is told to go, which is what keeps a death in
  # the Nether from leaving a herd of ghosts standing in the overworld.
  if name == PlayLogin or name == PlayRespawn: forgetAll(c.herd)
  if c.play.entityId != c.herd.mine: ownEntity(c.herd, c.play.entityId)

## One frame's worth. Reads packets until the socket has none or the budget is
## spent, and answers how much of the budget it used - in the same units
## `main.nim` charges generation and meshing in, so that a frame that adopted a
## column does not also generate one.
##
## `floorAt` is where this world's y = 0 should sit in Minecraft's coordinates
## once the server says where the player is. It is decided **once**, on the
## first teleport, because moving it afterwards would mean every block already
## in the world is at the wrong height.
proc step*(c: var McClient; w: var World; r: Registry; budget: int): int =
  result = 0
  if c.handle < 0 or c.problem.len > 0: return

  let state = streamState(c.handle)
  if state == StreamClosed:
    # The Play session's own problem FIRST, and the host's second. The host can
    # only ever say that the socket ended; the session may have read the
    # server's `disconnect` packet a moment before it did, and that carries the
    # reason. Reported the other way round, a kick reads as a dropped cable.
    fault(c, if c.play.problem.len > 0: c.play.problem
             elif streamProblem(c.handle).len > 0: streamProblem(c.handle)
             else: "the server closed the connection")
    return
  if state != StreamOpen:
    c.phase = "connecting"
    return
  if not c.greeted: greet(c)

  var spent = 0
  while spent < budget:
    let id = nextPacket(c.handle)
    if id < 0: break
    inc c.packets
    let before = c.columns
    if c.conn.state == StateLogin: stepLogin(c, id)
    elif c.conn.state == StateConfiguration: stepConfiguration(c, id)
    elif c.conn.state == StatePlay: stepPlay(c, w, r, id)
    if c.problem.len > 0: break
    if c.columns != before: spent = spent + ColumnCost
    # Where the world is. The first teleport is the first time anything knows,
    # and it is the moment the floor is fixed.
    if not c.anchored and c.play.positioned:
      c.floorY = floorFor(floorInt(c.play.y), w.blocksHigh())
      c.anchored = true
      drainOutbound(c)
      # And stop, one packet into the frame. The teleport that just landed is
      # the first thing that says where this world is, and the window is still
      # wherever it was made - so the very next packets, which are the chunks
      # *nearest the player* and therefore the ones that matter most, would be
      # adopted against an origin that is about to move and thrown away by the
      # recentre. The caller puts the window over the server's position and
      # this carries on next frame, one frame poorer and a world richer.
      #
      # This was not a guess: with it missing, eighty-five columns arrived and
      # eight and a half thousand blocks stuck, because the only columns that
      # landed inside the window were the late, distant ones.
      return spent
    drainOutbound(c)
  # What the server thinks of where we are, measured off the server's own
  # packet. See `driftMax`.
  if c.anchored and c.columns > 0:
    # A teleport is not this player walking. The server moves a client it does
    # not believe, and an operator moves one over rcon, and either would carry
    # the chunk cache centre with it - so the baseline is taken again after
    # each, and what is measured is only ever distance the player travelled
    # themselves since the last time they were put somewhere.
    if c.play.lastTeleportId != c.driftTeleport:
      c.driftTeleport = c.play.lastTeleportId
      c.centreSeen = false
      # Not on the very next packet. The teleport and the chunk cache centre
      # that goes with it are two packets and they do not have to arrive
      # together, so a baseline taken the instant the teleport lands can be the
      # centre from *before* it - and the real one arriving a frame later then
      # reads as an enormous drift nobody walked.
      #
      # TWO frames, and it was thirty, with "half a second at sixty" written
      # beside it. Sixty is a thing a game on somebody's desk does; a headless
      # editor adopting a world and meshing it runs a frame every three seconds,
      # so thirty frames is a minute and a half before the baseline is even
      # taken. A play script walked thirty blocks across two chunk boundaries
      # inside that window and `drift` was still nought when it asked - which
      # reads as a server that never believed the movement rather than as a
      # counter that had not started counting.
      #
      # Two is enough at any rate, because a frame here is not an instant: every
      # frame drains every packet the socket has, so the centre cannot still be
      # two frames behind the teleport that carried it.
      c.driftWait = 2
    if c.driftWait > 0:
      dec c.driftWait
    elif not c.centreSeen:
      c.centreSeen = true
      c.centre0X = c.play.chunkCenterX
      c.centre0Z = c.play.chunkCenterZ
    else:
      var dx = c.play.chunkCenterX - c.centre0X
      if dx < 0: dx = -dx
      var dz = c.play.chunkCenterZ - c.centre0Z
      if dz < 0: dz = -dz
      if dx + dz > c.driftMax: c.driftMax = dx + dz
  result = spent

## What to ask for in the next `chunk_batch_received`, out of how many columns
## the frame budget actually paid for. The server takes the number at its word,
## so it is measured rather than chosen: a client that asks for more than it
## can adopt builds a backlog it never clears.
##
## THE FRAME RATE IS MEASURED AND NOT ASSUMED, and that is the whole of this
## proc's history. It used to be `perFrame * 3.0`, on the reasoning that the
## number is per *tick* and a tick is three frames at sixty. Sixty is a thing a
## game running on somebody's desk does. A headless editor adopting a world and
## meshing it takes seconds a frame - and at three seconds a frame that constant
## asks a server for six columns a tick, a hundred and twenty a second, against
## a client that can take two every three. The backlog is unbounded by
## construction and the session ends about twenty seconds in, every time, which
## is why no play script had ever reached the part where it breaks a block.
##
## So: columns this frame paid for, divided by how long the frame took, divided
## by the twenty ticks a second the server runs at. `seconds` is the same delta
## the caller is stepping everything else with.
proc paceFor*(c: var McClient; budget: int; seconds: float) =
  let perFrame = float(budget) / float(ColumnCost)
  # A frame time of zero is the first frame, and a very long one is a hitch
  # rather than the rate. Both are clamped to something a division survives.
  var frame = seconds
  if frame < 0.001: frame = 0.001
  if frame > 4.0: frame = 4.0
  var want = perFrame / frame / TicksPerSecond
  if want < MinPace: want = MinPace
  if want > MaxPace: want = MaxPace
  pace(c.play, want)

# ---------------------------------------------------------------------------
# The feed
#
# `docs/ENTITIES.md` §2 is the contract and `vxbeing` is its reference reader.
# This is the other half of it, written against a real server rather than
# against twelve things walking a square.

## A whole number for the wire, rounded towards zero the way a coordinate in an
## `execute if entity` selector wants it.
proc wholeFor(v: float): int =
  if v < 0.0: return -int(-v + 0.5)
  int(v + 0.5)

## The three conversions, in one place, and they are the same three this client
## already makes for its own body in the other direction:
##
##   * **the height** is this world's, which sits `floorY` below Minecraft's;
##   * **the yaw is negated**, because this engine turns clockwise from +Z
##     through +X and Minecraft turns clockwise from +Z through -X, so the same
##     heading is the same number with the sign flipped. Getting this wrong
##     draws every mob facing its mirror image and looks almost right;
##   * **the pitch is not** - both call looking down positive.
##
## Nothing in `netherd` knows about any of them: it holds Minecraft's numbers
## and this is the seam.
proc feedLineFor(c: McClient; slot: int): string =
  let b = c.herd.list[slot]
  sayAt(b.id, b.x, b.y - float(c.floorY), b.z, -b.yaw, -b.headYaw, b.pitch)

## What the model is called. `minecraft:zombie` from the jar's own registry, cut
## down to `zombie`, which is what `vxbeasts` calls the rows and what this
## world's own block registry does with block names for the same reason.
##
## An id this build has no name for answers "" and the entity is announced with
## no kind at all - which is a row the consumer keeps and draws nothing for, and
## which starts drawing the moment somebody adds a model. That is the grammar's
## own rule and not a special case here.
proc kindNameOf(c: var McClient; kind: int): string =
  if kind < 0: return ""
  let full = nameAt(c.kinds, kind)
  if full.len == 0:
    inc c.unnamed
    return ""
  plainName(full)

## Everything that has changed since the tick the asker last heard about.
##
## An asker that is up to date gets the delta; one that is behind - a first
## frame, a missed answer, a world thrown away underneath it - gets the lot.
## Both are the same loop with one bit different, because two loops would be two
## chances for a census and a delta to disagree about what a line looks like.
proc herdFeed*(c: var McClient; since: int): string =
  # Not until the floor is fixed. A position converted against a `floorY` that
  # is about to be decided is a mob buried in the ground, and the first teleport
  # is the moment anything knows where the world is.
  if not c.anchored: return ""
  let full = behind(c.herd, since)
  var body = ""
  var lines = 0
  var i = 0
  while i < c.herd.gone.len:
    body = body & sayGone(c.herd.gone[i]) & "\n"
    inc lines
    inc i
  i = 0
  while i < c.herd.list.len:
    if not (full or dirty(c.herd, i)):
      inc i
      continue
    let b = c.herd.list[i]
    if full or not b.announced:
      body = body & sayAppear(b.id, kindNameOf(c, b.kind), b.label) & "\n"
      inc lines
    if full or b.changed or not b.announced:
      body = body & feedLineFor(c, i) & "\n"
      inc lines
    if full or b.stateChanged or not b.announced:
      # `falling` is the `onGround` byte every move, rotate, teleport and sync
      # packet carries, passed straight on. It is NOT derived from the velocity
      # packets, which arrive more often than anything else and are deliberately
      # dropped - see the foot of `netherd.nim` and `docs/ENTITIES.md`.
      body = body & sayState(b.id, "falling",
        (if b.onGround: 0.0 else: 1.0)) & "\n"
      body = body & sayState(b.id, (if b.dead: "dead" else: "alive"), 1.0) & "\n"
      lines = lines + 2
    if b.hurts > 0:
      body = body & sayState(b.id, "hurt", 1.0) & "\n"
      inc lines
    inc i
  taken(c.herd)
  inc c.feeds
  c.fedLines = lines
  sayTick(c.herd.tick) & "\n" & body

proc herdCount0*(c: McClient): int = beastCount(c.herd)
proc herdSpawns*(c: McClient): int = c.herd.spawns
proc herdRemoves*(c: McClient): int = c.herd.removes
proc herdMoves*(c: McClient): int = c.herd.moves
proc herdOrphans*(c: McClient): int = c.herd.orphans
proc herdHurts*(c: McClient): int = c.herd.hurtsSeen
proc herdDeaths*(c: McClient): int = c.herd.deathsSeen

## The nearest thing the server has told this client about that this build can
## name, and where it is *in Minecraft's own coordinates*.
##
## This is the assertion that is not ours. A count of entities is this client
## agreeing with itself and says the same number against a server that hung up
## ten seconds ago; a point this client worked out by adding up relative moves
## off the wire, handed back to the server as "is there a zombie within three
## blocks of here", is a fact about somebody else's world with none of ours in
## it. `herdWhere` writes it as the tail of an `execute if entity` selector
## because that is the form the question has to be asked in.
##
## The player's own body is not in the table at all, so "nearest" can never be
## the thing holding the camera.
proc nearestSlot(c: McClient): int =
  result = -1
  var bestAway = 0.0
  var i = 0
  while i < c.herd.list.len:
    let b = c.herd.list[i]
    if b.kind >= 0 and nameAt(c.kinds, b.kind).len > 0:
      let dx = b.x - c.play.x
      let dy = b.y - c.play.y
      let dz = b.z - c.play.z
      let away = dx * dx + dy * dy + dz * dz
      if result < 0 or away < bestAway:
        result = i
        bestAway = away
    inc i

proc herdNearestKind*(c: McClient): string =
  let at = nearestSlot(c)
  if at < 0: return ""
  plainName(nameAt(c.kinds, c.herd.list[at].kind))

proc selectorAt(c: McClient; at, near: int): string =
  "x=" & $wholeFor(c.herd.list[at].x) & ",y=" &
    $wholeFor(c.herd.list[at].y) & ",z=" &
    $wholeFor(c.herd.list[at].z) & ",distance=.." & $near

proc herdWhere*(c: McClient; near: int): string =
  let at = nearestSlot(c)
  if at < 0: return ""
  selectorAt(c, at, near)

## The same about the thing the server most recently announced, which is the
## handle a play script can actually predict: it summons something and that
## something is the newest. "The nearest" is not predictable - another player
## standing two metres away takes the title, and the question then asked of the
## server is about a cow at a player's feet and is correctly answered with
## silence. That is how this pair came to exist.
proc herdNewKind*(c: McClient): string =
  let at = slotOf(c.herd, c.herd.newest)
  if at < 0 or c.herd.list[at].kind < 0: return ""
  plainName(nameAt(c.kinds, c.herd.list[at].kind))

proc herdNewWhere*(c: McClient; near: int): string =
  let at = slotOf(c.herd, c.herd.newest)
  if at < 0: return ""
  selectorAt(c, at, near)

## The same question about a named kind rather than about whatever is closest.
## `player` is the one that matters: another player and a mob arrive down the
## same `add_entity` path and differ only in a number, so a script that can ask
## the server about the nearest *player* this client says it can see is the only
## way to prove the difference is genuinely only a number.
proc herdWhereKind*(c: McClient; kind: string; near: int): string =
  var best = -1
  var bestAway = 0.0
  var i = 0
  while i < c.herd.list.len:
    let b = c.herd.list[i]
    if b.kind >= 0 and plainName(nameAt(c.kinds, b.kind)) == kind:
      let dx = b.x - c.play.x
      let dy = b.y - c.play.y
      let dz = b.z - c.play.z
      let away = dx * dx + dy * dy + dz * dz
      if best < 0 or away < bestAway:
        best = i
        bestAway = away
    inc i
  if best < 0: return ""
  selectorAt(c, best, near)

## How many of a kind are out there, by the model's own name.
## How many DIFFERENT kinds are out there, and what the index-th of them is
## called. Between them these let a caller publish "where is the nearest cow"
## without anything in this file or the one above it ever spelling "cow".
##
## That is what a play script actually needs. The two handles that came before
## it - the nearest thing, and the newest thing - are both moving targets in a
## live world: another player walking past takes "nearest", and a chicken
## spawning and despawning in a chunk nobody is looking at takes "newest" and
## then leaves it pointing at nothing. A script that summons a cow wants to ask
## about a cow.
proc herdKindCount*(c: McClient): int =
  var seen: seq[string] = @[]
  var i = 0
  while i < c.herd.list.len:
    if c.herd.list[i].kind >= 0:
      let name = plainName(nameAt(c.kinds, c.herd.list[i].kind))
      if name.len > 0:
        var known = false
        var k = 0
        while k < seen.len:
          if seen[k] == name: known = true
          inc k
        if not known: seen.add name
    inc i
  seen.len

proc herdKindAt*(c: McClient; index: int): string =
  var seen: seq[string] = @[]
  var i = 0
  while i < c.herd.list.len:
    if c.herd.list[i].kind >= 0:
      let name = plainName(nameAt(c.kinds, c.herd.list[i].kind))
      if name.len > 0:
        var known = false
        var k = 0
        while k < seen.len:
          if seen[k] == name: known = true
          inc k
        if not known:
          seen.add name
          if seen.len - 1 == index: return name
    inc i
  ""

proc herdKinds*(c: McClient; kind: string): int =
  var n = 0
  var i = 0
  while i < c.herd.list.len:
    if c.herd.list[i].kind >= 0 and
       plainName(nameAt(c.kinds, c.herd.list[i].kind)) == kind: inc n
    inc i
  n

## Where the server says the player is, for a caller that has to put them
## there. Empty until the first teleport.
proc placedYet*(c: McClient): bool = c.anchored and c.play.positioned
proc placeX*(c: McClient): float = c.play.x
proc placeY*(c: McClient): float = c.play.y - float(c.floorY)
  ## Not `worldYof(int(c.play.y), ...)`, which was here and truncated: the
  ## height the server sent is fractional, the player is put at the whole part
  ## of it, and the very next movement packet then tells the server it has
  ## moved down by that fraction. Two of those in a row and the server corrects
  ## a player who never moved.
proc placeZ*(c: McClient): float = c.play.z

## What the server says is under the player's feet, by its own name. Empty
## until the column that holds it has arrived.
proc groundState0*(c: McClient): int = c.groundState
proc groundWhere*(c: McClient): string =
  ## Which block the spot check actually looked at, so that a disagreement with
  ## the server can be settled without guessing which end is wrong.
  $c.groundX & " " & $c.groundY & " " & $c.groundZ

## What the server says about the body it is keeping for this player. All four
## are the server's numbers, not this world's arithmetic about them: nothing
## here simulates hunger or awards experience, and every one of these moves
## only when a `set_health`, a `set_experience` or a `game_event` says so.
## Where the server agreed, in its own coordinates, as one line a log can carry
## and an rcon console can be handed straight back.
proc brokeWhere*(c: McClient): string =
  $c.brokeAtX & " " & $c.brokeAtY & " " & $c.brokeAtZ
proc putWhere*(c: McClient): string =
  $c.putAtX & " " & $c.putAtY & " " & $c.putAtZ
## And what the server says is now there, by its own name.
proc putName*(c: McClient): string =
  if c.putState < 0: return ""
  let name = nameOfState(c.ix, c.putState)
  if name.len == 0: return "state " & $c.putState
  name

proc serverHealth*(c: McClient): float = c.play.health
## How many times the server has killed this player and this client has asked
## to come back. Published so a play script can say "it died and it recovered"
## rather than having to infer it from a health reading that went to nought and
## back on a frame nobody was looking.
proc serverDeaths*(c: McClient): int = c.play.deaths
proc serverFood*(c: McClient): int = c.play.food
proc serverExperience*(c: McClient): int = c.play.experienceLevel
proc serverGamemode*(c: McClient): int = c.play.gamemode
proc serverDead*(c: McClient): bool = c.play.dead

## Ask to be put back. Nothing else clears the death, which is correct: a
## client that respawns itself is a client that cannot show a death screen.
proc askRespawn*(c: var McClient) =
  if not c.play.dead: return
  respawnNow(c.play)
  drainOutbound(c)

proc groundName*(c: McClient): string =
  if not c.groundKnown: return ""
  let name = nameOfState(c.ix, c.groundState)
  if name.len == 0: return "state " & $c.groundState
  name
