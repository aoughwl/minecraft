## Everything that is in the world and is not made of blocks: who they are,
## where they are, and how what a server said turns into something that moves.
##
## ## The seam, and why it is shaped like this
##
## This mod draws entities. It does not know what a server is, it does not
## parse a packet, and it must not: the Play state of Minecraft's protocol is
## `aoughwl.mcnet`'s, and there is exactly one thing this file needs from
## it - *what is out there and where*. So the two meet at a **service**
## (`services.nim`): the mod that knows answers a named question, the mod that
## draws asks it, and the answer is text. `docs/ENTITIES.md` is the contract
## and this file is the reference reader of it.
##
## A service call is **one host crossing for the whole world**, which is the
## property that makes it usable at all. A catalog row per entity would be one
## crossing each to read plus one to write; a part per entity per frame is
## seven. The cost that is left is the parsing, in the interpreter, and that is
## what the grammar is designed around:
##
## **The feed is a delta and not a census.** The asker says which tick it last
## heard about and is told only what has changed since - which is what the wire
## already is (Minecraft sends relative moves), so the producer is passing on
## the shape it received rather than inventing one. A world of a hundred
## entities standing still is an empty answer. A world of a hundred entities
## all walking is a hundred short lines, and that is the honest worst case: see
## `docs/ENTITIES.md` for what it costs and what to do about it.
##
## ## The grammar
##
##     t 4117                          up to date as of this tick
##     + 42 zombie Steve               there is a 42, it is a zombie, called Steve
##     @ 42 12.5 64 -8.25 90 85 0      it is here, pointed this way
##     ! 42 hurt 1                     something happened to it
##     - 42                            it is gone
##
## One line per fact, first token the verb, whitespace between. A verb this
## reader does not know is skipped rather than refused, and so is a field: a
## producer that learns to say something new does not break a client that has
## not, which is the only property that lets the two mods be written by two
## people at once.
##
## ## What is arithmetic here and what is not
##
## Nothing in this file calls the host. The interpolation, the easing of the
## shoulders, how far a thing has walked and how fast it is going are all
## arithmetic over what the feed said, and `Tests/entity_test.exe` runs the
## whole of it - including a feed of a thousand lines - in a millisecond.

import vxview
import vxmodel
import vxblocks

const
  SnapDistance* = 4.0
    ## How far a thing may be moved in one message before it is put there
    ## rather than walked there. A teleport, a respawn and a chunk arriving
    ## late all look like this, and easing into them draws a zombie sliding
    ## across the landscape at forty miles an hour.
  CatchUp* = 12.0
    ## How fast a drawn position closes on the last one the server said, per
    ## second, as a fraction of the gap. Minecraft's client does this over
    ## three ticks; this is the same idea said as a rate, so it is right at any
    ## frame rate rather than at one.
  TurnRate* = 14.0
    ## The same for the head and the body's own yaw.
  WalkTop* = 4.3
    ## What counts as walking flat out, in metres a second. A zombie's speed is
    ## about 0.23 blocks a tick; this is the fast end, and everything is scaled
    ## against it so that a sprinting player's legs and a wandering cow's are
    ## the same animation at different amounts.
  Forgotten* = 12.0
    ## How long a thing the feed has stopped mentioning is kept before it is
    ## dropped, in seconds. Not zero: a feed that misses a tick should not make
    ## the world blink.

type
  Being* = object
    id*: int
    kind*: string
      ## Which model it wears, by name. Whatever the feed called it; nothing
      ## in this mod compares it against a list of mobs it knows.
    label*: string
      ## What its nameplate says, or "" for no nameplate.
    ## Where it is drawn, which is not where the server last said it is.
    x*, y*, z*: float
    ## And where the server last said it is.
    toX*, toY*, toZ*: float
    ## Where it is pointed. `yaw` is the body the server sent, `headYaw` the
    ## head, `pitch` the head's up and down. `bodyYaw` is the drawn body, which
    ## eases towards `yaw` and is dragged by the head exactly the way the
    ## player's own shoulders are (`vxview.bodyYawFor`).
    yaw*, headYaw*, pitch*: float
    bodyYaw*, drawnHeadYaw*, drawnPitch*: float
    ## What the animation reads.
    walked*: float
    pace*: float
    deadFor*: float
      ## Seconds since it died, or below zero for something that is alive.
    hurtFor*: float
      ## Seconds since it was last hit, or below zero.
    fuse*: float
      ## Seconds a creeper has been primed for, or zero for anything that is
      ## not about to go off.
    offset*: float
      ## Its own place in the idle cycle, so that two of a kind standing beside
      ## each other do not sway in step. Taken off the id, which is the only
      ## number that is certainly different between two of them.
    falling*: bool
    quiet*: float
      ## How long since the feed last said anything about it.
    fresh*: bool
      ## True until the caller has had a frame to build its parts, and cleared
      ## by `stepBeings`.
    placed*: bool
      ## Whether it has ever been told where it is. The FIRST position is put
      ## there rather than walked to, and every one after it is walked to
      ## unless it is a teleport - which is a different question from `fresh`
      ## and was the same field once, for one afternoon, during which two
      ## messages in one frame made every entity snap.
    model*: int
      ## Which model of the set it wears, resolved once. -1 until it has been
      ## looked up, and -1 for ever if the set has no such model - which is a
      ## thing the world draws nothing for and says once.

  Beings* = object
    ## Flat, and swept linearly. There are tens of these and every sweep is
    ## over all of them anyway - drawing is a sweep, stepping is a sweep - so
    ## an index would buy nothing and would be a second thing to keep true.
    list*: seq[Being]
    tick*: int
      ## The last tick the feed said it was up to date as of. Handed back on
      ## the next ask, which is what makes the feed a delta.
    unknown*: seq[string]
      ## Every kind the feed mentioned that the model set has no model for,
      ## once each. Logged rather than thrown: a server with a mob this mod has
      ## never heard of is normal and is not an error, and the list is what
      ## tells somebody which rows to add.

proc noBeings*(): Beings = Beings(list: @[], tick: 0, unknown: @[])

proc beingCount*(b: Beings): int = b.list.len

## Which slot that id is in, or -1.
proc indexOf*(b: Beings; id: int): int =
  var i = 0
  while i < b.list.len:
    if b.list[i].id == id: return i
    inc i
  -1

## A new one, with everything a feed has not said yet at the value that means
## "nothing has happened".
proc newBeing*(id: int; kind: string): Being =
  # The idle offset is the id folded into a fraction. Any scramble does; what
  # matters is that consecutive ids do not land near each other, which is why
  # it is a prime times the id rather than the id.
  let scatter = float((id * 7919) mod 1000) * 0.001
  Being(id: id, kind: kind, label: "",
    x: 0.0, y: 0.0, z: 0.0, toX: 0.0, toY: 0.0, toZ: 0.0,
    yaw: 0.0, headYaw: 0.0, pitch: 0.0,
    bodyYaw: 0.0, drawnHeadYaw: 0.0, drawnPitch: 0.0,
    walked: 0.0, pace: 0.0, deadFor: -1.0, hurtFor: -1.0, fuse: 0.0,
    offset: scatter, falling: false, quiet: 0.0, fresh: true, placed: false,
    model: -1)

# ---------------------------------------------------------------------------
# Reading the feed

## The next whitespace-separated word of `text` from `at`, and where the word
## after it starts. Written out rather than split into a sequence because this
## runs over every line of every feed of every frame, and a sequence a line is
## a sequence a line too many.
proc wordAt(text: string; at: int; word: var string): int =
  word = ""
  var i = at
  while i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\r'):
    inc i
  while i < text.len and text[i] != ' ' and text[i] != '\t' and text[i] != '\r':
    word.add text[i]
    inc i
  i

## Everything left, with the whitespace off the front. What a label is: the
## rest of the line, because a name may have spaces in it and a grammar that
## said otherwise would be a grammar that cannot carry "Notch the Second".
proc restAt(text: string; at: int): string =
  result = ""
  var i = at
  while i < text.len and (text[i] == ' ' or text[i] == '\t'): inc i
  while i < text.len:
    if text[i] != '\r': result.add text[i]
    inc i

proc wholeOf(word: string): int =
  var ok = false
  let value = readNumber(word, ok)
  if not ok: return 0
  int(value)

proc numberOf(word: string): float =
  var ok = false
  let value = readNumber(word, ok)
  if not ok: return 0.0
  value

## Make sure there is a slot for that id, and answer which. A `@` or a `!`
## about an id nobody announced makes one anyway, with no kind - which is a
## thing that draws nothing and starts drawing the moment a `+` arrives. A feed
## whose first message was lost is then a feed that catches up rather than a
## feed that is wrong for ever.
proc slotFor(b: var Beings; id: int; kind: string): int =
  result = indexOf(b, id)
  if result < 0:
    b.list.add newBeing(id, kind)
    return b.list.len - 1
  if kind.len > 0 and b.list[result].kind != kind:
    b.list[result].kind = kind
    b.list[result].model = -1
    b.list[result].fresh = true

## One line of the feed over the store. Answers false for a line it did not
## understand, which the caller may count and nothing else.
proc readLine*(b: var Beings; line: string): bool =
  var verb = ""
  var at = wordAt(line, 0, verb)
  if verb.len == 0: return true
  if verb == "#": return true
  if verb == "t":
    var word = ""
    at = wordAt(line, at, word)
    b.tick = wholeOf(word)
    return true
  var idWord = ""
  at = wordAt(line, at, idWord)
  if idWord.len == 0: return false
  let id = wholeOf(idWord)
  if verb == "-":
    let slot = indexOf(b, id)
    if slot >= 0:
      var j = slot
      while j + 1 < b.list.len:
        # Through a local, because a `seq` element assigned straight from
        # another element of the same `seq` is two references to one buffer and
        # the toolchain refuses it - the same shuffle `dropMeshes` does.
        let moved = b.list[j + 1]
        b.list[j] = moved
        inc j
      b.list.setLen(b.list.len - 1)
    return true
  if verb == "+":
    var kind = ""
    at = wordAt(line, at, kind)
    let slot = slotFor(b, id, kind)
    let label = restAt(line, at)
    b.list[slot].label = label
    b.list[slot].quiet = 0.0
    return true
  if verb == "@":
    let slot = slotFor(b, id, "")
    var word = ""
    at = wordAt(line, at, word)
    let x = numberOf(word)
    at = wordAt(line, at, word)
    let y = numberOf(word)
    at = wordAt(line, at, word)
    let z = numberOf(word)
    at = wordAt(line, at, word)
    let yaw = numberOf(word)
    at = wordAt(line, at, word)
    let head = numberOf(word)
    at = wordAt(line, at, word)
    let pitch = numberOf(word)
    b.list[slot].toX = x
    b.list[slot].toY = y
    b.list[slot].toZ = z
    b.list[slot].yaw = wrapAngle(yaw)
    b.list[slot].headYaw = wrapAngle(head)
    b.list[slot].pitch = pitch
    b.list[slot].quiet = 0.0
    # Far enough to be a teleport rather than a step: put it there, and put the
    # drawn angles there too, so a thing that respawns does not spin on the way.
    let dx = x - b.list[slot].x
    let dy = y - b.list[slot].y
    let dz = z - b.list[slot].z
    if not b.list[slot].placed or
       dx * dx + dy * dy + dz * dz > SnapDistance * SnapDistance:
      b.list[slot].x = x
      b.list[slot].y = y
      b.list[slot].z = z
      b.list[slot].bodyYaw = b.list[slot].yaw
      b.list[slot].drawnHeadYaw = b.list[slot].headYaw
      b.list[slot].drawnPitch = pitch
    b.list[slot].placed = true
    return true
  if verb == "!":
    let slot = slotFor(b, id, "")
    var what = ""
    at = wordAt(line, at, what)
    var word = ""
    at = wordAt(line, at, word)
    let value = numberOf(word)
    b.list[slot].quiet = 0.0
    if what == "hurt":
      b.list[slot].hurtFor = 0.0
      return true
    if what == "dead":
      if b.list[slot].deadFor < 0.0: b.list[slot].deadFor = 0.0
      return true
    if what == "alive":
      b.list[slot].deadFor = -1.0
      return true
    if what == "fuse":
      b.list[slot].fuse = value
      return true
    if what == "falling":
      b.list[slot].falling = value != 0.0
      return true
    if what == "name":
      b.list[slot].label = restAt(line, at)
      return true
    # A state this reader has not learned. Not a failure: see the header.
    return true
  # A verb this reader has not learned, which is the same thing said one level
  # up: a producer that grows a new kind of line does not break a client that
  # has not grown with it. A line whose VERB is one of these and whose fields
  # are missing is a different matter and is answered false above.
  true

## A whole answer. Returns how many lines were not understood, which is zero
## for a producer and this reader that agree and is the number to log when they
## do not.
proc applyFeed*(b: var Beings; body: string): int =
  result = 0
  var line = ""
  var i = 0
  while i <= body.len:
    if i == body.len or body[i] == '\n':
      if line.len > 0:
        if not readLine(b, line): inc result
      line = ""
    else:
      line.add body[i]
    inc i

## What to ask the feed for. The tick it was last up to date as of, so it can
## answer with what has changed since.
proc askFor*(b: Beings): string = "since " & $b.tick

# ---------------------------------------------------------------------------
# Writing the feed
#
# Here because the two halves of a grammar belong in one file: the test writes
# a feed with these, reads it with the above, and asserts it got back what it
# put in. A producer that writes its own lines by hand is free to - these are
# not privileged - but then nothing checks the two agree, which is how a
# grammar quietly grows two dialects.

proc sayTick*(tick: int): string = "t " & $tick

proc sayAppear*(id: int; kind, label: string): string =
  result = "+ " & $id & " " & kind
  if label.len > 0: result = result & " " & label

proc sayGone*(id: int): string = "- " & $id

## A number written for the wire: two decimal places, which is a centimetre and
## is finer than anything a box model shows. Written out rather than borrowed
## because the pure modules import nothing.
proc wireNumber*(value: float): string =
  var v = value
  var sign = ""
  if v < 0.0:
    sign = "-"
    v = -v
  let hundredths = int(v * 100.0 + 0.5)
  let whole = hundredths div 100
  let rest = hundredths mod 100
  var tail = $rest
  if rest < 10: tail = "0" & tail
  sign & $whole & "." & tail

proc sayAt*(id: int; x, y, z, yaw, head, pitch: float): string =
  "@ " & $id & " " & wireNumber(x) & " " & wireNumber(y) & " " &
    wireNumber(z) & " " & wireNumber(yaw) & " " & wireNumber(head) & " " &
    wireNumber(pitch)

proc sayState*(id: int; what: string; value: float): string =
  "! " & $id & " " & what & " " & wireNumber(value)

# ---------------------------------------------------------------------------
# Making it move
#
# Between two messages about an entity there are a dozen frames, and what
# happens in them is the difference between a world and a slideshow.

proc easeTowards(now, want, rate, seconds: float): float =
  var step = rate * seconds
  if step < 0.0: step = 0.0
  if step > 1.0: step = 1.0
  now + (want - now) * step

proc easeAngle(now, want, rate, seconds: float): float =
  var step = rate * seconds
  if step < 0.0: step = 0.0
  if step > 1.0: step = 1.0
  wrapAngle(now + angleBetween(wrapAngle(now), wrapAngle(want)) * step)

## Newton again, because a step is a length and there is no square root here.
proc rootOf(value: float): float =
  if value <= 0.0: return 0.0
  var guess = value
  if guess < 1.0: guess = 1.0
  var step = 0
  while step < 20:
    guess = 0.5 * (guess + value / guess)
    inc step
  guess

## One frame over every entity: close the gap, ease the angles, add up what has
## been walked, and run the clocks.
##
## **How far it walked is measured off the drawn position and not off the
## message.** A mob walking into a wall is a mob the server keeps sending the
## same position for, and a mob whose legs are driven by the message would
## march on the spot for ever. This is the same rule the player's own bob
## follows and it is the same two lines.
proc stepBeings*(b: var Beings; seconds: float) =
  var i = 0
  while i < b.list.len:
    let wasX = b.list[i].x
    let wasZ = b.list[i].z
    b.list[i].x = easeTowards(b.list[i].x, b.list[i].toX, CatchUp, seconds)
    b.list[i].y = easeTowards(b.list[i].y, b.list[i].toY, CatchUp, seconds)
    b.list[i].z = easeTowards(b.list[i].z, b.list[i].toZ, CatchUp, seconds)
    let stepX = b.list[i].x - wasX
    let stepZ = b.list[i].z - wasZ
    let went = rootOf(stepX * stepX + stepZ * stepZ)
    b.list[i].walked = b.list[i].walked + went
    var pace = 0.0
    if seconds > 0.0: pace = went / seconds / WalkTop
    if pace > 1.0: pace = 1.0
    # Eased rather than taken raw: a frame that happened to be short would
    # otherwise read as a standstill and the legs would stutter.
    b.list[i].pace = easeTowards(b.list[i].pace, pace, 10.0, seconds)
    b.list[i].drawnHeadYaw =
      easeAngle(b.list[i].drawnHeadYaw, b.list[i].headYaw, TurnRate, seconds)
    b.list[i].drawnPitch =
      easeTowards(b.list[i].drawnPitch, b.list[i].pitch, TurnRate, seconds)
    # The shoulders: towards where it is walking, then dragged by the head if
    # the head has got too far round. The player's own rule, not a second one.
    b.list[i].bodyYaw = bodyYawFor(b.list[i].bodyYaw, b.list[i].drawnHeadYaw,
      b.list[i].yaw, b.list[i].pace > 0.02, seconds * BodyTurnRate)
    if b.list[i].deadFor >= 0.0:
      b.list[i].deadFor = b.list[i].deadFor + seconds
    if b.list[i].hurtFor >= 0.0:
      b.list[i].hurtFor = b.list[i].hurtFor + seconds
      if b.list[i].hurtFor > 1.0: b.list[i].hurtFor = -1.0
    if b.list[i].fuse > 0.0:
      b.list[i].fuse = b.list[i].fuse + seconds
    b.list[i].quiet = b.list[i].quiet + seconds
    b.list[i].fresh = false
    inc i

## Take away everything the feed has stopped mentioning. Answers how many went.
##
## Separate from `stepBeings` because forgetting destroys parts and stepping
## does not, and a caller that wants to know what to destroy wants to be told
## once rather than to diff two lists.
proc forgetQuiet*(b: var Beings; after = Forgotten): seq[int] =
  result = @[]
  var i = 0
  while i < b.list.len:
    if b.list[i].quiet > after:
      result.add b.list[i].id
      var j = i
      while j + 1 < b.list.len:
        # Through a local, because a `seq` element assigned straight from
        # another element of the same `seq` is two references to one buffer and
        # the toolchain refuses it - the same shuffle `dropMeshes` does.
        let moved = b.list[j + 1]
        b.list[j] = moved
        inc j
      b.list.setLen(b.list.len - 1)
    else:
      inc i

## Resolve every kind that has not been looked up yet, and remember the ones
## that are not there. Called once a frame; it does nothing at all for an
## entity that has already been resolved, which is all of them after the frame
## they arrived on.
proc resolveModels*(b: var Beings; set0: ModelSet) =
  var i = 0
  while i < b.list.len:
    if b.list[i].model < 0 and b.list[i].kind.len > 0:
      let at = modelIndex(set0, b.list[i].kind)
      if at >= 0:
        b.list[i].model = at
      else:
        var known = false
        var k = 0
        while k < b.unknown.len:
          if b.unknown[k] == b.list[i].kind: known = true
          inc k
        if not known: b.unknown.add b.list[i].kind
    inc i
