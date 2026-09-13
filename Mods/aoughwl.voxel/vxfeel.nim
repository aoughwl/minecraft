## What breaking a block *feels* like: the crack that grows on it, the chips
## that come off it, the noise it makes, and the beat before you may swing
## again.
##
## Pure: nothing here calls the host. Every rule below is arithmetic over
## numbers the caller already has, which is why it can be settled in
## `Tests/feel_test.exe` in a millisecond rather than in a play session by eye.
##
## The mechanics of breaking a block already worked - a hardness timer, a drop,
## a pickup, a placement. None of the *feel* did, and feel is what the whole of
## it is judged on. Three things were missing and this file is the arithmetic
## for all three.
##
## ## The crack
##
## A block being mined wears one of ten pictures, and which one is a division:
## how far the timer has got, times ten, floored. It is off - stage `-1` -
## until the timer has actually started, because a block you have merely looked
## at is not a cracked block.
##
## The pictures are not this mod's. They arrive in a catalog row as `|`
## separated picture uris - the same shape and the same separator
## `vxatlas.splitPictures` already reads for a block's six faces, so a provider
## learns one convention rather than two - and a row with fewer than ten of them
## still works: `crackPicture` maps a stage onto however many were given.
##
## ## The chips
##
## A burst of small textured quads wearing the block's own picture, thrown out
## of the block, pulled down and reaped. The whole design question is what they
## cost at the seam, and this file answers it in numbers rather than in taste -
## see `meshFrameCost` and `partBurstCost` below, and the cap they decide.
##
## ## The noise
##
## The lookup from a block to its sound group to the event name is here and is
## pure; whether the file that event names can be *played* is not this file's
## business, and the answer is now yes. `audible` is the gate: the host reads
## RIFF/WAV **and Ogg Vorbis** (`docs/AUDIO.md`), the latter over vendored
## NVorbis, and Minecraft ships every sound it has as Vorbis - so until that
## decoder landed, this lookup was written, proved and wired to a set of files
## the host could not read a single one of. It stays a gate rather than becoming
## `true`, because MP3 and Opus are still outside it, and a mod that fires one
## of those into `loadSound` still loses `start()` to a throw it cannot catch.

const
  Stages* = 10
    ## `block/destroy_stage_0` .. `destroy_stage_9`. Ten because that is how
    ## many pictures the game has, and the division below is by this rather than
    ## by ten spelled twice.

  BreakAgain* = 0.25
    ## How long after a block gives way before the next one may start. Without
    ## it a held button walks a tunnel through the world at one block a frame
    ## the instant a soft block is in front of a soft block, which is what the
    ## timer is supposed to prevent and does not, because the timer restarts at
    ## zero on a *new* block and zero is immediately enough for dirt.

  SwingFor* = 0.3
    ## How long one swing of the arm lasts. Nothing here draws an arm - the
    ## held-item view is somebody else's - and this is the phase that view
    ## reads, so the two agree about when a swing is over without either owning
    ## the other.

  ChipEvery* = 0.2
    ## How often a chip comes off a block that is being mined. The burst when it
    ## finally breaks is a different thing and is `BurstMotes` of them at once.

# ---------------------------------------------------------------------------
# What the seam costs
#
# These four numbers are the reason this file exists in the shape it does, and
# they are stated here rather than in a comment so that the cap below is
# *derived* from them and the test can fail when the derivation stops holding.
#
# `docs/MOD-API.md` and `ModSdk/aoughwl.nim` measure a host crossing at
# 0.68us plus 0.30us for every argument it carries, and an interpreted proc
# call at 2.1us. `vxatlas.nim` already spends both numbers deciding whether a
# block may be merged; this spends them deciding how a particle is drawn.

const
  CrossingFixed* = 0.68
  CrossingArg* = 0.30
  InterpCall* = 2.1

  MoteBudget* = 400.0
    ## What a frame of chips may spend at the seam, in microseconds. A voxel
    ## frame at sixty is 16,600us and `FaceBudget` already claims most of it, so
    ## this is about two and a half per cent of a frame - visible in a profile,
    ## invisible in play, and small enough that a burst cannot be what makes the
    ## world stutter on the frame a block breaks.

## One crossing carrying `args` arguments.
proc crossing*(args: int): float = CrossingFixed + CrossingArg * float(args)

## What one frame of the chip mesh costs at the seam.
##
## The design that won: **one mesh, rebuilt every frame the chips are moving.**
## The old mesh is destroyed, a part is spawned, the resolver is called back
## once, and every live chip is four vertices and a quad inside it.
proc meshFrameCost*(motes: int): float =
  crossing(0) +                       # destroy the last frame's mesh
  crossing(5) +                       # spawnPart
  InterpCall +                        # the resolvePart callback
  crossing(0) +                       # beginMesh
  float(motes) * (4.0 * crossing(8) + crossing(4)) +
  crossing(0) +                       # finishMesh
  crossing(1)                         # useTexture

## What the same chips cost as one spawned part each - the obvious design, and
## the one this file rejected.
##
## It is paid once, on the frame the block breaks, rather than every frame; but
## it is paid *all at once*, and it is the frame a player is already watching
## for a stutter. Each chip is its own spawn, its own resolver call, its own
## one-quad mesh, its own texture, scale, colour, rigid body and shove.
proc partBurstCost*(motes: int): float =
  float(motes) * (
    crossing(5) +                     # spawnPart
    InterpCall + crossing(0) +        # the callback, beginMesh
    4.0 * crossing(8) + crossing(4) + # the quad
    crossing(0) + crossing(1) +       # finishMesh, useTexture
    crossing(1) +                     # scale
    crossing(2) +                     # physics
    crossing(4))                      # push

## And what it costs to move them afterwards, which is the part that makes the
## comparison honest: a spawned part with a rigid body on it is moved by the
## host for nothing, and a mesh chip is moved by this mod for `meshFrameCost`.
proc partFrameCost*(motes: int): float = 0.0

## The most chips a frame may carry and stay inside `MoteBudget`.
##
## Written as a search rather than as a division so that changing the shape of
## `meshFrameCost` - a cheaper vertex, a second texture - moves the cap with it
## instead of leaving a number behind that used to be right.
proc moteBudgetFor*(micros: float): int =
  result = 0
  var n = 1
  while n <= 4096:
    if meshFrameCost(n) > micros: return result
    result = n
    inc n

const
  MoteCap* = 27
    ## The number `moteBudgetFor(MoteBudget)` comes out at, written down so the
    ## mod does not run a search every frame - and asserted against the search
    ## in `Tests/feel_test.exe`, which is what stops it from rotting.

  BurstMotes* = 16
    ## How many a broken block throws. Minecraft throws sixty-four - a four by
    ## four by four lattice - and sixty-four does not fit in `MoteCap`, which is
    ## the whole reason this number is here and is not sixty-four. Sixteen of
    ## them at this size reads as a burst; the arithmetic above says what the
    ## other forty-eight would have cost.

  PuffMotes* = 6
    ## And what a placement puffs out. Fewer, because a placement is a smaller
    ## event than a break and because two placements in a row must still fit.

# ---------------------------------------------------------------------------
# The crack

## Which of the ten pictures a block being mined wears, or -1 for none.
##
## `-1` rather than `0` for "not started". `destroy_stage_0` is a real picture
## with real cracks in it, so a block that shows stage 0 the instant the
## crosshair crosses it looks damaged by being looked at.
proc crackStage*(progress, needed: float): int =
  if needed <= 0.0: return -1
  if progress <= 0.0: return -1
  var stage = int(progress / needed * float(Stages))
  if stage < 0: stage = 0
  if stage >= Stages: stage = Stages - 1
  stage

## The stage pictures out of the catalog row: `|` separated, in order, first
## crack to last. The same separator `vxatlas.splitPictures` uses, and for the
## same reason - a `data:` uri carries commas of its own and base64 never
## carries a bar.
proc splitStages*(row: string): seq[string] =
  result = @[]
  var field = ""
  var i = 0
  while i <= row.len:
    if i == row.len or row[i] == '|':
      if field.len > 0: result.add field
      field = ""
    else:
      field.add row[i]
    inc i

## Which picture stage `stage` wears, out of however many were given. A pack
## that ships four stage pictures instead of ten is spread over the ten stages
## rather than refused.
proc crackPicture*(stages: seq[string]; stage: int): string =
  if stages.len == 0: return ""
  if stage < 0: return ""
  var at = stage * stages.len div Stages
  if at < 0: at = 0
  if at >= stages.len: at = stages.len - 1
  stages[at]

# ---------------------------------------------------------------------------
# The chips
#
# A chip is a position, a velocity, an age and a picture. There is no world
# query in here and deliberately so: the moment this asks which block is under
# a chip it stops being pure, and what it would buy is a bounce nobody watching
# a burst that lasts two thirds of a second can see.

const
  MoteGravity* = -14.0
    ## Metres a second a second. Heavier than the world's own gravity, which is
    ## what makes a chip read as a chip rather than as a thrown pebble.
  MoteDrag* = 1.6
    ## Linear damping, per second, applied as `v - v * MoteDrag * seconds`.
    ## Linear rather than exponential because there is no `pow` to reach for
    ## here and because at these speeds and this life the two are the same
    ## curve; `stepMotes` clamps so a long frame cannot push a chip backwards.
  MoteLife* = 0.7
  MoteSize* = 0.09
    ## A chip is about a sixth of a block face across, which is the size the
    ## game's own are at the distance you are standing when you break one.
  MoteSpeed* = 2.4

type
  Motes* = object
    ## Every chip in the air, kept as parallel seqs rather than as a seq of
    ## objects: the mesher walks all of one field at a time and the interpreter
    ## is markedly happier reading a flat seq than a field of an element of one.
    x*, y*, z*: seq[float]
    vx*, vy*, vz*: seq[float]
    age*: seq[float]
    life*: seq[float]
    size*: seq[float]
    kind*: seq[int]
      ## Which block it came off, so the mesher knows which picture it wears.
    face*: seq[int]
      ## And which of that block's six faces, in the world's own face order.
    made*: int
      ## How many have ever been made. It is the seed the scatter is drawn from,
      ## so two bursts in the same place are different bursts and the same burst
      ## is the same burst twice - which is what lets a test say anything about
      ## one at all.

proc newMotes*(): Motes =
  Motes(x: @[], y: @[], z: @[], vx: @[], vy: @[], vz: @[],
    age: @[], life: @[], size: @[], kind: @[], face: @[], made: 0)

proc moteCount*(m: Motes): int = m.x.len

## -1.0 to 1.0, from a number. A burst has to be the same burst twice or
## nothing about it can be asserted, so this is a hash and never a clock.
proc moteNoise*(seed: int): float =
  var h = seed * 1103515245 + 12345
  h = h mod 2147483647
  if h < 0: h = h + 2147483647
  float(h mod 2000) / 1000.0 - 1.0

proc addMote*(m: var Motes; x, y, z, vx, vy, vz, life, size: float;
    kind, face: int) =
  m.x.add x
  m.y.add y
  m.z.add z
  m.vx.add vx
  m.vy.add vy
  m.vz.add vz
  m.age.add 0.0
  m.life.add life
  m.size.add size
  m.kind.add kind
  m.face.add face
  m.made = m.made + 1

## Take one out. The last one is moved into the hole rather than the tail being
## shuffled down: nothing looks at the order of these, and the shuffle is what
## makes reaping a burst quadratic.
proc takeMote*(m: var Motes; at: int) =
  let last = m.x.len - 1
  if at < 0 or at > last: return
  if at != last:
    let lx = m.x[last]
    let ly = m.y[last]
    let lz = m.z[last]
    let lvx = m.vx[last]
    let lvy = m.vy[last]
    let lvz = m.vz[last]
    let lage = m.age[last]
    let llife = m.life[last]
    let lsize = m.size[last]
    let lkind = m.kind[last]
    let lface = m.face[last]
    m.x[at] = lx
    m.y[at] = ly
    m.z[at] = lz
    m.vx[at] = lvx
    m.vy[at] = lvy
    m.vz[at] = lvz
    m.age[at] = lage
    m.life[at] = llife
    m.size[at] = lsize
    m.kind[at] = lkind
    m.face[at] = lface
  m.x.setLen last
  m.y.setLen last
  m.z.setLen last
  m.vx.setLen last
  m.vy.setLen last
  m.vz.setLen last
  m.age.setLen last
  m.life.setLen last
  m.size.setLen last
  m.kind.setLen last
  m.face.setLen last

## One frame of it: pulled down, slowed, moved, aged, and reaped when its life
## is up.
proc stepMotes*(m: var Motes; seconds: float) =
  if seconds <= 0.0: return
  var damp = MoteDrag * seconds
  if damp > 1.0: damp = 1.0
  var i = 0
  while i < m.x.len:
    let newAge = m.age[i] + seconds
    if newAge >= m.life[i]:
      takeMote(m, i)
      continue
    m.age[i] = newAge
    let nvx = m.vx[i] - m.vx[i] * damp
    let nvy = m.vy[i] - m.vy[i] * damp + MoteGravity * seconds
    let nvz = m.vz[i] - m.vz[i] * damp
    m.vx[i] = nvx
    m.vy[i] = nvy
    m.vz[i] = nvz
    let nx = m.x[i] + nvx * seconds
    let ny = m.y[i] + nvy * seconds
    let nz = m.z[i] + nvz * seconds
    m.x[i] = nx
    m.y[i] = ny
    m.z[i] = nz
    inc i

## How many more chips this burst may have, given what is already in the air.
## The cap is a cap on the *frame*, so a burst thrown while the last one is
## still falling is the one that gets shortened.
proc moteRoom*(m: Motes; wanted: int): int =
  result = MoteCap - m.x.len
  if result < 0: result = 0
  if result > wanted: result = wanted

## Which of the six faces an offset from the middle of a block points at, in the
## world's own face order: +X, -X, +Y, -Y, +Z, -Z. A chip wears the picture of
## the face it came off, so a chip off the top of a grass block is green and one
## off its side is not - which is the whole reason a chip carries a face at all.
proc faceOfOffset*(dx, dy, dz: float): int =
  let ax = if dx < 0.0: -dx else: dx
  let ay = if dy < 0.0: -dy else: dy
  let az = if dz < 0.0: -dz else: dz
  if ax >= ay and ax >= az:
    if dx >= 0.0: return 0
    return 1
  if ay >= az:
    if dy >= 0.0: return 2
    return 3
  if dz >= 0.0: return 4
  5

## A broken block: chips out of every part of the cube it was, thrown outward
## and up. `count` is what was asked for; what is made is what fits.
proc burstMotes*(m: var Motes; x, y, z: float; kind, count: int) =
  let room = moteRoom(m, count)
  var i = 0
  while i < room:
    let seed = m.made
    let ox = moteNoise(seed * 3 + 1) * 0.34
    let oy = moteNoise(seed * 3 + 2) * 0.34
    let oz = moteNoise(seed * 3 + 3) * 0.34
    # Thrown out of where it was rather than in a random direction: a chip from
    # the left of the block goes left, which is what makes a burst look like a
    # block coming apart instead of a firework.
    addMote(m, x + ox, y + oy, z + oz,
      ox * MoteSpeed * 2.0,
      MoteSpeed * (0.6 + moteNoise(seed * 3 + 4) * 0.3),
      oz * MoteSpeed * 2.0,
      MoteLife, MoteSize, kind, faceOfOffset(ox, oy, oz))
    inc i

## One chip off the face being mined, which is the trickle while the button is
## held. It comes off the face rather than out of the middle, so it reads as
## coming off the surface the pick is on.
proc chipMote*(m: var Motes; x, y, z, nx, ny, nz: float; kind, face: int) =
  if moteRoom(m, 1) == 0: return
  let seed = m.made
  let sx = moteNoise(seed * 5 + 1) * 0.4
  let sy = moteNoise(seed * 5 + 2) * 0.4
  let sz = moteNoise(seed * 5 + 3) * 0.4
  addMote(m,
    x + nx * 0.52 + sx * (1.0 - nx * nx),
    y + ny * 0.52 + sy * (1.0 - ny * ny),
    z + nz * 0.52 + sz * (1.0 - nz * nz),
    nx * MoteSpeed * 0.5, ny * MoteSpeed * 0.5 + 0.8, nz * MoteSpeed * 0.5,
    MoteLife * 0.7, MoteSize * 0.8, kind, face)

## And what a placement puffs out: slow, short-lived, off the top of the block
## that just appeared.
proc puffMotes*(m: var Motes; x, y, z: float; kind, count: int) =
  let room = moteRoom(m, count)
  var i = 0
  while i < room:
    let seed = m.made
    let ox = moteNoise(seed * 7 + 1) * 0.5
    let oz = moteNoise(seed * 7 + 2) * 0.5
    addMote(m, x + ox, y - 0.4, z + oz,
      ox * 0.6, 0.5, oz * 0.6,
      MoteLife * 0.6, MoteSize * 0.7, kind, 2)
    inc i

## Whether another chip is due, given how long since the last one.
proc chipDue*(sinceChip: float): bool = sinceChip >= ChipEvery

# ---------------------------------------------------------------------------
# The beat

## Whether a block may start being broken again yet.
proc mayBreakAgain*(sinceBreak: float): bool = sinceBreak >= BreakAgain

## How far through a swing the arm is, 0 at the start and 1 when it is over.
## Nothing here draws it; this is the number a held-item view reads.
proc swingPhase*(sinceSwing: float): float =
  if sinceSwing <= 0.0: return 0.0
  if sinceSwing >= SwingFor: return 1.0
  sinceSwing / SwingFor

proc swinging*(sinceSwing: float): bool = sinceSwing < SwingFor

# ---------------------------------------------------------------------------
# The noise
#
# **A block's sound group is not in the jar, and this says so rather than
# pretending otherwise.** `sounds.json` maps an *event* - `block.stone.break` -
# to the files that may answer it, and it is the only sound data an extraction
# reaches. Which group a block belongs to is a table in Java code, and no amount
# of reading `assets/` recovers it: nothing anywhere in the granted copy says
# that `oak_planks` sounds like `wood`.
#
# So the group is derived from the event list, which the jar *does* carry, and
# the derivation is stated in three steps of falling confidence rather than in
# one rule that would have to be wrong somewhere:
#
#   1. the block's own name, when the pack has events for it;
#   2. the name with its leading words dropped one at a time, **while what is
#      left is still more than one word**, so a pack that names
#      `deepslate_bricks` specifically is found before anything coarser. The
#      "more than one word" is load-bearing and not tidiness: without it
#      `stone_bricks` reaches a group called `bricks` before step 3 ever runs,
#      and a shape wins over a material;
#   3. each of the name's words, left to right, so `stone_bricks` finds `stone`
#      and `polished_deepslate_bricks` finds `deepslate` - left to right and not
#      right to left, because the head of one of these names is the material and
#      the tail is the shape, and it is the material that makes the noise.
#
# What none of the three reaches - `oak_planks`, whose group is a word that does
# not appear in its name - falls to the `fallback` the caller offers, and to
# silence when there is none. A block that makes no noise is a smaller lie than
# a block that makes the wrong one.

const
  VerbBreak* = "break"
  VerbStep* = "step"
  VerbPlace* = "place"
  VerbHit* = "hit"
  VerbFall* = "fall"

proc soundEvent*(group, verb: string): string =
  if group.len == 0: return ""
  "block." & group & "." & verb

proc knows(known: seq[string]; group: string): bool =
  var i = 0
  while i < known.len:
    if known[i] == group: return true
    inc i
  false

## The name with its first underscore-separated word dropped. `""` when there
## is nothing left to drop.
proc shorten*(name: string): string =
  result = ""
  var mark = -1
  var i = 0
  while i < name.len:
    if name[i] == '_':
      mark = i
      break
    inc i
  if mark < 0: return result
  i = mark + 1
  while i < name.len:
    result.add name[i]
    inc i

## The name's underscore-separated words, in order.
proc wordsOf*(name: string): seq[string] =
  result = @[]
  var field = ""
  var i = 0
  while i <= name.len:
    if i == name.len or name[i] == '_':
      if field.len > 0: result.add field
      field = ""
    else:
      field.add name[i]
    inc i

## Which sound group a block belongs to, out of the groups the pack's own
## `sounds.json` actually names - the three steps above, in order. `""` when
## none of them fit and no fallback was offered, which is a block that makes no
## noise rather than a block that makes the wrong one.
proc manyWords(name: string): bool =
  var i = 0
  while i < name.len:
    if name[i] == '_': return true
    inc i
  false

proc soundGroupOf*(name: string; known: seq[string]; fallback = ""): string =
  if knows(known, name): return name
  var trying = shorten(name)
  while manyWords(trying):
    if knows(known, trying): return trying
    let shorter = shorten(trying)
    trying = shorter
  let words = wordsOf(name)
  var i = 0
  while i < words.len:
    if knows(known, words[i]): return words[i]
    inc i
  if fallback.len > 0 and knows(known, fallback): return fallback
  ""

## Which of an event's several files answers this time. Deterministic, for the
## same reason `moteNoise` is.
proc soundVariant*(files: seq[string]; seed: int): string =
  if files.len == 0: return ""
  var at = seed mod files.len
  if at < 0: at = at + files.len
  files[at]

## Whether this host could decode that file at all.
##
## The host reads RIFF/WAV **and Ogg Vorbis** - `docs/AUDIO.md`. Vorbis is the
## one that matters, because Minecraft ships every sound it has as `.ogg`, and
## while this said `.wav` only, all ~4,900 of them were unreachable through a
## host that had everything else it needed. The decoder now lives in
## `AudioHostCalls.Vorbis`, over vendored NVorbis, and no host call was added
## for it: `loadSound` already took a file and gave back a clip.
##
## This stays a gate rather than becoming `true`, because the set is still not
## everything - an MP3, or an Ogg carrying Opus rather than Vorbis, is still a
## file this host cannot read, and a mod that fires one into `loadSound` still
## loses `start()` to a throw it cannot catch. It is checked by extension here
## because that is all a *name* can tell you; the host re-checks the bytes, and
## the bytes win.
proc audible*(file: string): bool =
  if file.len < 4: return false
  var i = file.len - 4
  var ext = ""
  while i < file.len:
    let c = file[i]
    if c >= 'A' and c <= 'Z':
      let lower = char(int(c) + 32)
      ext.add lower
    else:
      ext.add c
    inc i
  ext == ".wav" or ext == ".ogg"
