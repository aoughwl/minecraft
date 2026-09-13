## The seam between somebody else's block numbers and this world's.
##
## `aoughwl.mcnet` speaks the protocol and the host decodes a chunk column
## into **runs** of equal block state. What arrives is a Minecraft *block state
## id* - 27,000-odd numbers, one per block per combination of its properties -
## and what this world stores is its own small block id, which is a row of the
## `voxel.blocks` catalog. Nothing else in this mod knows either of those
## numbers, and the translation between them is all here.
##
## Nothing in this file calls the host, so `Tests/voxel_test.exe` settles every
## rule below in a second, with no server, no socket and no Unity.
##
## ## The one piece of arithmetic worth stating out loud
##
## A section's blocks come back in Minecraft's own **y-then-z-then-x** order,
## and this world's `vxworld.localIndex` is `(y * 16 + z) * 16 + x`. Those are
## the same order. So a run of equal state is a **contiguous span** of this
## world's own block array, and adopting a section is a fill per run rather
## than a coordinate worked out per block.
##
## That is not a coincidence to lean on quietly - it is the whole reason this
## seam is cheap - so `Tests/voxel_test.exe` asserts the two orders agree
## against `localIndex` itself rather than against a copy of it here. If this
## world ever renumbers its own storage, that check fails and this file is
## where the transposition goes.
##
## ## Why there is an index file at all
##
## A chunk carries state ids and no names. The map from a state id to a block
## name is Mojang's, it is six megabytes of it, and it is version specific -
## so it is neither written down here nor parsed here. `tools/mcindex.ps1`
## reduces their `blocks.json` to one line per block:
##
##     minecraft:stone<TAB>1<TAB>1
##     minecraft:grass_block<TAB>10<TAB>2
##
## - a name, the first state id it owns and how many it owns - which is about
## a thousand lines and thirty kilobytes. **It is generated, it is theirs, and
## it is not in this repository**; the mod folder's `.gitignore` keeps it out
## and a missing file is reported rather than worked around.
##
## The ids a block owns are contiguous and the blocks are in id order, so the
## lookup is a binary search over the first column. A linear walk would be a
## thousand interpreted steps per run.
##
## ## What a name becomes
##
## A name, not a state. `minecraft:grass_block[snowy=true]` and
## `[snowy=false]` are the same block here, because this world has one grass.
## The name is looked up in **this session's own registry** - the catalog
## `aoughwl.minecraft` fills when the player has granted their copy of the
## game, and the eleven blocks this mod ships when they have not - so there is
## exactly one table of what a block looks like and this file does not hold a
## second one.
##
## A name no row answers to becomes **air**, and is counted.
##
## It used to become the fallback - stone - on the argument that a hole looks
## like a broken decoder. That argument was wrong, and wrong in the one way
## that matters: a player adopting a real server's chunks with eleven blocks in
## their catalog was sealed inside a cube of stone, unable to walk sixteen
## blocks, and could not tell that stone from the server's own. Air is the
## safer of the two - you can walk through what is missing - and the honest
## one: nothing is drawn where nothing is known.
##
## Honest, though, only if it is *countable*. So `BlockMap.known` and
## `BlockMap.unknown` say how many of the index's blocks this session can name
## at all, and `hole` marks the rows that became air for this reason so the
## caller can count the blocks it dropped rather than guess at how much of a
## world is real. A world that arrives as mostly nothing must say so in a
## number, not in the silence it looks like.

const
  McAir* = 0
    ## Minecraft's state 0 is `minecraft:air`, in every version, and it is by
    ## far the most common run in a column. Named so that the fast path out of
    ## a sky section is a comparison rather than a lookup.
  SectionSide* = 16
  SectionBlocks* = SectionSide * SectionSide * SectionSide

type
  StateIndex* = object
    ## One row per block: its name, and the half-open range of state ids it
    ## owns. `first` is ascending, which is what the search below needs.
    names*: seq[string]
    first*: seq[int]
    count*: seq[int]
    problem*: string

  PlayRows* = object
    ## The Play packet table out of the player's own `packets.json`. Names
    ## rather than numbers, because 165 of the 251 shared ids moved between
    ## protocol 774 and 776 - see `netproto.knownTable`.
    dirs*: seq[int]
    ids*: seq[int]
    names*: seq[string]
    problem*: string

proc emptyStateIndex*(): StateIndex =
  StateIndex(names: @[], first: @[], count: @[], problem: "")

proc emptyPlayRows*(): PlayRows =
  PlayRows(dirs: @[], ids: @[], names: @[], problem: "")

# ---------------------------------------------------------------------------
# Reading the generated files
#
# Both are tab separated text with `#` comments, because the thing that writes
# them is a PowerShell script and the thing that reads them is an interpreter
# with no standard library. A parser that is four lines long cannot be the
# reason a session fails.

proc wholeOf(text: string; from0, to0: int; ok: var bool): int =
  ## The decimal number in `text[from0 ..< to0]`, or 0 with `ok` false. There is
  ## no `parseInt` here: the pure modules import nothing, so that the mod
  ## builder and nimony compile exactly the same file.
  ok = false
  var i = from0
  var sign = 1
  if i < to0 and text[i] == '-':
    sign = -1
    inc i
  var value = 0
  var digits = 0
  while i < to0:
    let d = int(text[i]) - int('0')
    if d < 0 or d > 9: return 0
    value = value * 10 + d
    inc digits
    inc i
  if digits == 0: return 0
  ok = true
  sign * value

proc fields(line: string; starts, ends: var seq[int]) =
  ## Split on tabs, in place. Trailing carriage returns go with the field, so
  ## they are trimmed here rather than by every caller: a file written on this
  ## machine and read on this machine still arrives with them.
  starts = @[]
  ends = @[]
  var at = 0
  var i = 0
  while i <= line.len:
    if i == line.len or line[i] == '\t':
      var stop = i
      while stop > at and (line[stop - 1] == '\r' or line[stop - 1] == ' '):
        dec stop
      starts.add at
      ends.add stop
      at = i + 1
    inc i

proc eachLine(text: string; at: var int; line: var string): bool =
  ## The next line, without allocating the whole file as a sequence of them.
  if at >= text.len: return false
  var stop = at
  while stop < text.len and text[stop] != '\n': inc stop
  line = text.substr(at, stop - 1)
  at = stop + 1
  true

## The state index, as `tools/mcindex.ps1` writes it. A malformed row is
## skipped and named in `problem` rather than thrown: this is generated from
## somebody else's data, and one bad row must cost one block and never the
## session.
proc parseStateIndex*(text: string): StateIndex =
  result = emptyStateIndex()
  var at = 0
  var line = ""
  var bad = 0
  while eachLine(text, at, line):
    if line.len == 0 or line[0] == '#': continue
    var starts: seq[int] = @[]
    var ends: seq[int] = @[]
    fields(line, starts, ends)
    if starts.len < 3:
      inc bad
      continue
    var okFirst = false
    var okCount = false
    let first = wholeOf(line, starts[1], ends[1], okFirst)
    let count = wholeOf(line, starts[2], ends[2], okCount)
    if not okFirst or not okCount or count <= 0:
      inc bad
      continue
    let name = line.substr(starts[0], ends[0] - 1)
    if name.len == 0:
      inc bad
      continue
    # Ascending order is what the search relies on, and it is a property of the
    # file rather than of this reader - so it is checked rather than assumed.
    if result.first.len > 0 and first < result.first[result.first.len - 1]:
      result.problem = "the state index is not in ascending id order at '" &
        name & "'"
      return
    result.names.add name
    result.first.add first
    result.count.add count
  if result.names.len == 0 and result.problem.len == 0:
    result.problem = "the state index has no rows in it"
  elif bad > 0 and result.problem.len == 0:
    result.problem = $bad & " unreadable rows in the state index"

## The Play packet rows: `<0 to server|1 to client><TAB><id><TAB><name>`.
proc parsePlayPackets*(text: string): PlayRows =
  result = emptyPlayRows()
  var at = 0
  var line = ""
  while eachLine(text, at, line):
    if line.len == 0 or line[0] == '#': continue
    var starts: seq[int] = @[]
    var ends: seq[int] = @[]
    fields(line, starts, ends)
    if starts.len < 3: continue
    var okDir = false
    var okId = false
    let dir = wholeOf(line, starts[0], ends[0], okDir)
    let id = wholeOf(line, starts[1], ends[1], okId)
    if not okDir or not okId: continue
    let name = line.substr(starts[2], ends[2] - 1)
    if name.len == 0: continue
    result.dirs.add dir
    result.ids.add id
    result.names.add name
  if result.names.len == 0:
    result.problem = "the play packet table has no rows in it"


## An `id<TAB>name` table, as `tools/mcindex.ps1` writes `items.txt` and
## `components.txt`. Answered as a seq indexed by the id itself, because both
## of these are looked up by a number that arrived on the wire and a seq index
## is the one lookup this interpreter does not charge a proc call for.
##
## A row whose id is past the end grows the seq with blanks rather than being
## dropped: a gap in a registry is a name this build does not know, and naming
## it "" is honest, where shifting everything after it down by one is a table
## that answers confidently and wrongly.
proc parseIdNames*(text: string): seq[string] =
  result = @[]
  var at = 0
  var line = ""
  while eachLine(text, at, line):
    if line.len == 0 or line[0] == '#': continue
    var starts: seq[int] = @[]
    var ends: seq[int] = @[]
    fields(line, starts, ends)
    if starts.len < 2: continue
    var okId = false
    let id = wholeOf(line, starts[0], ends[0], okId)
    if not okId or id < 0 or id > 65535: continue
    let name = line.substr(starts[1], ends[1] - 1)
    if name.len == 0: continue
    while result.len <= id: result.add ""
    result[id] = name

## One row of such a table, or "" - so that a caller never indexes past the end
## of a table that a different version of the game wrote.
proc nameAt*(names: seq[string]; id: int): string =
  if id < 0 or id >= names.len: return ""
  names[id]

## The short form, without the namespace: `minecraft:oak_log` is `oak_log`.
## Which is what this world's own block registry calls things.
proc plainName*(name: string): string =
  var i = 0
  while i < name.len:
    if name[i] == ':': return name.substr(i + 1, name.len - 1)
    inc i
  name
# ---------------------------------------------------------------------------
# State id to block

## Which row of the index owns that state id, or -1. A binary search, because
## this is asked once per run and a run is the unit the whole seam is built on:
## a thousand-step linear walk here would cost more than the decode it is
## reading.
proc rowOfState*(ix: StateIndex; state: int): int =
  if ix.names.len == 0 or state < 0: return -1
  var low = 0
  var high = ix.names.len - 1
  while low <= high:
    let mid = (low + high) div 2
    if state < ix.first[mid]:
      high = mid - 1
    elif state >= ix.first[mid] + ix.count[mid]:
      low = mid + 1
    else:
      return mid
  -1

## The block's own name, with `minecraft:` taken off - because that is the
## spelling `voxel.blocks` carries, and the namespace would otherwise have to be
## stripped at every call site instead of at the one place that knows it came
## off the wire.
proc nameOfState*(ix: StateIndex; state: int): string =
  let row = rowOfState(ix, state)
  if row < 0: return ""
  let whole = ix.names[row]
  var i = 0
  while i < whole.len:
    if whole[i] == ':': return whole.substr(i + 1)
    inc i
  whole

# ---------------------------------------------------------------------------
# The table this world actually uses
#
# One entry per row of the index rather than one per state: a thousand numbers
# instead of twenty-seven thousand, worked out once when the world is made, and
# re-worked whenever the block catalog grows - because a mod that registers its
# blocks after this one started is a mod this engine is built to allow.

type
  BlockMap* = object
    ## `voxelOf[row]` is this session's block id for the block on that row of
    ## the index, or 0 - air - for one no catalog row answers to.
    ##
    ## `hole[row]` tells the two kinds of 0 apart: a row that is air because
    ## Minecraft says it is air, and a row that is air because this session has
    ## never heard of it. Only the second is a hole, and only the second is
    ## worth counting.
    voxelOf*: seq[int]
    hole*: seq[bool]
    air*: int
    known*: int        ## how many rows found a real block of their own
    unknown*: int      ## and how many did not, and became air
    ready*: bool

proc emptyBlockMap*(): BlockMap =
  BlockMap(voxelOf: @[], hole: @[], air: 0, known: 0, unknown: 0, ready: false)

## Everything that names nothing in this world. Air is not a block here - it is
## the absence of one - and the three flavours of it Minecraft distinguishes
## are all the same absence. `cave_air` and `void_air` are not decoration: a
## chunk below the world and a chunk inside a cave are full of them, and a
## world that drew them as its fallback would be solid rock.
proc isAirName*(name: string): bool =
  name == "air" or name == "cave_air" or name == "void_air"

## Every row's block name, with `minecraft:` taken off. The caller asks its own
## registry about each of these and hands the answers back to `blockMapFrom`.
##
## Two procs rather than one taking the registry's lookup, deliberately: the
## rules about what an unanswered name becomes are the part worth testing, and
## a test that has to build a registry to reach them is a test nobody writes.
proc plainNames*(ix: StateIndex): seq[string] =
  result = @[]
  var i = 0
  while i < ix.names.len:
    let whole = ix.names[i]
    var name = whole
    var j = 0
    while j < whole.len:
      if whole[j] == ':':
        name = whole.substr(j + 1)
        break
      inc j
    result.add name
    inc i

## Build the table from what the registry answered: `resolved[i]` is this
## session's block id for `plainNames(ix)[i]`, or 0 or less for a name it does
## not carry.
##
## There is no fallback block to pass in any more, deliberately. The registry
## answers -1 for a name it does not carry, and a map built before the catalog
## was filled asks it about every name; the old code turned that into
## `idOf("stone")` on an empty registry - which is -1 as well - and wrote it
## into the world as a block number nothing could answer for. The version after
## that wrote real stone, which is worse to play: a wall you cannot tell from
## the ground. Air has neither failure and one number says how much of it there
## is.
proc blockMapFrom*(ix: StateIndex; resolved: seq[int]): BlockMap =
  result = emptyBlockMap()
  result.air = 0
  let names = plainNames(ix)
  var i = 0
  while i < names.len:
    if isAirName(names[i]):
      result.voxelOf.add 0
      result.hole.add false
    elif i < resolved.len and resolved[i] > 0:
      result.voxelOf.add resolved[i]
      result.hole.add false
      inc result.known
    else:
      result.voxelOf.add 0
      result.hole.add true
      inc result.unknown
    inc i
  result.ready = true

## One state id, as a block of this world. Unknown states become air, for the
## reason at the top of this file.
proc blockOfState*(ix: StateIndex; m: BlockMap; state: int): int =
  if state == McAir: return 0
  let row = rowOfState(ix, state)
  if row < 0: return 0
  if row >= m.voxelOf.len: return 0
  m.voxelOf[row]

## Whether a state became air because nothing here knows what it is, as opposed
## to because Minecraft says it is air. The caller counts the blocks it dropped
## with this, run by run, while it fills a section - which is the only place the
## *quantity* of a missing palette is visible at all.
proc stateIsHole*(ix: StateIndex; m: BlockMap; state: int): bool =
  if state == McAir: return false
  let row = rowOfState(ix, state)
  if row < 0: return true
  if row >= m.hole.len: return true
  m.hole[row]

# ---------------------------------------------------------------------------
# A section, from its runs

## Fill `[at, at + n)` of a section with one block. This is the whole bulk
## path: a run of equal state in Minecraft's y-z-x order is a contiguous span
## of this world's own storage - see the note at the top - so an air section or
## a solid-stone one is one call and one loop.
##
## Out-of-range spans are clipped rather than refused, because the length a run
## claims comes off the wire and a decoder that wrote past the end of a chunk
## would corrupt the one beside it.
proc fillRun*(blocks: var seq[int]; at, n, id: int): int =
  ## How many blocks it actually wrote.
  if n <= 0 or at >= blocks.len: return 0
  var i = at
  if i < 0: i = 0
  var stop = at + n
  if stop > blocks.len: stop = blocks.len
  var wrote = 0
  while i < stop:
    blocks[i] = id
    inc i
    inc wrote
  wrote

proc airSection*(): seq[int] =
  ## A section of nothing, which is what a column is mostly made of.
  newSeq[int](SectionBlocks)

## How many of a section are not air, counted while it is filled rather than
## walked again afterwards. `Chunk.filled` is what decides whether a chunk gets
## a mesh at all, so it has to be right and it is cheaper to keep than to find.
proc countFilled*(blocks: seq[int]): int =
  var n = 0
  var i = 0
  while i < blocks.len:
    if blocks[i] != 0: inc n
    inc i
  n

# ---------------------------------------------------------------------------
# Where a Minecraft column lands in this world
#
# This world is a window a few chunks across whose blocks run from its own
# origin, and Minecraft's run from y = -64 to y = 319. X and Z need no
# translation at all - the window follows the player and the player is where
# the server says they are - and Y needs exactly one number.

## The y of the world's own floor, in Minecraft's coordinates, for a player
## standing at `feetY` in a world `blocksHigh` tall. Rounded down to a section
## boundary, which is what makes one Minecraft section land on exactly one
## chunk of this world instead of straddling two.
##
## A third of the window below the player rather than half: what is under your
## feet is rock you will never see, and what is over your head is the sky the
## horizon does not draw.
proc floorFor*(feetY, blocksHigh: int): int =
  var base = feetY - blocksHigh div 3
  # Floor division, spelled out, because `div` truncates towards zero and the
  # y this is given is routinely negative - which put the floor a section too
  # high for everything below y = 0 and nowhere else.
  var sections = base div SectionSide
  if base < 0 and base mod SectionSide != 0: dec sections
  sections * SectionSide

## Whether a Minecraft section is inside the window at all, given the floor.
proc sectionInWorld*(sectionY, floorY, blocksHigh: int): bool =
  let low = sectionY * SectionSide - floorY
  low >= 0 and low + SectionSide <= blocksHigh

## A Minecraft y as this world's y.
proc worldYof*(mcY, floorY: int): int = mcY - floorY

# ---------------------------------------------------------------------------
# Base64, both ways
#
# The host's stream surface carries a blob as base64 - `readBytes` gives one
# and `putBytes` takes one - because the ABI carries a `cstring` and a cstring
# stops at the first NUL. So a mod that hands a packet body to a decoder that
# works in bytes has to turn one into the other, and there is no standard
# library here to do it.
#
# **This is not how a packet body is read.** `docs/STREAM.md` is explicit that
# the cursor beats this path at every size, and the client uses the cursor for
# everything it reads itself. What this is for is the small packets whose
# decoders already exist in `aoughwl.mcnet`, written against a byte
# reader and proved against hand-built vectors: a teleport, a keep-alive, a
# block update. Writing those a second time against the cursor would be a
# second decoder to get subtly wrong, which is the thing the mcnet prose warns
# about. The bodies are tens of bytes and the chunk packet - the one this would
# be fatal for - never comes through here at all.

const B64Alphabet =
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

proc b64Value(c: char): int =
  if c >= 'A' and c <= 'Z': return int(c) - int('A')
  if c >= 'a' and c <= 'z': return 26 + int(c) - int('a')
  if c >= '0' and c <= '9': return 52 + int(c) - int('0')
  if c == '+': return 62
  if c == '/': return 63
  -1

## Bytes out of base64. Padding and anything that is not an alphabet character
## are skipped rather than refused, because what comes back from the host is
## the host's own spelling and a reader that argued with it would be arguing
## about whitespace.
proc fromBase64*(text: string): seq[int] =
  result = @[]
  var acc = 0
  var bits = 0
  var i = 0
  while i < text.len:
    let v = b64Value(text[i])
    if v >= 0:
      acc = (acc shl 6) or v
      bits = bits + 6
      if bits >= 8:
        bits = bits - 8
        result.add (acc shr bits) and 0xFF
    inc i

## And back, which is what a packet body a mod built has to become before it
## can go out. Bytes above 255 are masked rather than refused for the reason
## `vxblocks` gives about a resource pack: this is data, and one wrong byte
## must cost one packet.
proc toBase64*(data: seq[int]): string =
  result = ""
  var i = 0
  while i + 2 < data.len:
    let n = ((data[i] and 0xFF) shl 16) or ((data[i + 1] and 0xFF) shl 8) or
      (data[i + 2] and 0xFF)
    result.add B64Alphabet[(n shr 18) and 63]
    result.add B64Alphabet[(n shr 12) and 63]
    result.add B64Alphabet[(n shr 6) and 63]
    result.add B64Alphabet[n and 63]
    i = i + 3
  let left = data.len - i
  if left == 1:
    let n = (data[i] and 0xFF) shl 16
    result.add B64Alphabet[(n shr 18) and 63]
    result.add B64Alphabet[(n shr 12) and 63]
    result.add '='
    result.add '='
  elif left == 2:
    let n = ((data[i] and 0xFF) shl 16) or ((data[i + 1] and 0xFF) shl 8)
    result.add B64Alphabet[(n shr 18) and 63]
    result.add B64Alphabet[(n shr 12) and 63]
    result.add B64Alphabet[(n shr 6) and 63]
    result.add '='

# ---------------------------------------------------------------------------
# Where to connect

## `host:port`, or a bare host with `fallback` for the port. Its own proc with
## its own checks because the two failures it has - a port that is not a number
## and a port outside the range - both look like a connection that silently
## never happens, and a mod that split this inline would report neither.
proc splitHostPort*(text: string; fallback: int;
                    host: var string; port: var int): bool =
  host = ""
  port = fallback
  var cut = -1
  var i = 0
  while i < text.len:
    if text[i] == ':': cut = i
    inc i
  if cut < 0:
    host = text
    return host.len > 0
  host = text.substr(0, cut - 1)
  if host.len == 0: return false
  var ok = false
  port = wholeOf(text, cut + 1, text.len, ok)
  if not ok or port <= 0 or port > 65535:
    port = fallback
    return false
  true
