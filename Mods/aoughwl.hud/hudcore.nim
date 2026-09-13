## Everything a survival HUD gets wrong, kept where it can be proved.
##
## Pure: nothing in this file calls the host, so it compiles both inside
## `aoughwl.hud` and inside `Tests/hud_test.nim`. That is the whole point.
## Stack merging, slot arithmetic, hunger, regeneration, fall damage and the
## experience curve are the five places a Minecraft HUD is quietly wrong, and
## none of them can be settled by looking at a screenshot of some hearts.
##
## Three things live here:
##
##   * **the item registry** - a flat list of definitions, filled from catalogs
##     by `huditems.nim` and read by everything else. It is a value rather than
##     a global so a test can build one out of literals.
##   * **the slots** - one flat array of stacks with a layout on top of it, and
##     the six operations a mouse performs on a slot: take, put, swap, merge,
##     halve, place-one.
##   * **the survival simulation** - health, hunger, saturation, exhaustion,
##     armour, experience and death, stepped by seconds and metres.
##
## Nothing here knows about drawing, input, catalogs, or Minecraft.

# ---------------------------------------------------------------------------
# Small text tools
#
# `std/strutils` is not imported anywhere in a mod in this project and this
# file has to compile inside the interpreter, so the three string operations a
# recipe or an icon needs are written out here and proved with everything else.
# ---------------------------------------------------------------------------

## The pieces of `text` between each `sep`. A trailing separator yields a final
## empty piece, which is what makes "a|b|" three fields and not two.
proc splitOn*(text: string; sep: char): seq[string] =
  result = @[]
  var current = ""
  var i = 0
  while i < text.len:
    if text[i] == sep:
      result.add current
      current = ""
    else:
      current.add text[i]
    i = i + 1
  result.add current

proc isSpace(c: char): bool = c == ' ' or c == '\t' or c == '\r' or c == '\n'

## `text` without leading or trailing blanks.
proc trimmed*(text: string): string =
  var a = 0
  var b = text.len
  while a < b and isSpace(text[a]): a = a + 1
  while b > a and isSpace(text[b - 1]): b = b - 1
  result = ""
  var i = a
  while i < b:
    result.add text[i]
    i = i + 1

## The whole number `text` spells, or `fallback` when it does not spell one. A
## partial number is not half read: "12x" is the fallback, not 12.
proc wholeOf*(text: string; fallback = 0): int =
  let body = trimmed(text)
  if body.len == 0: return fallback
  var i = 0
  var sign = 1
  if body[0] == '-':
    sign = -1
    i = 1
  elif body[0] == '+':
    i = 1
  if i >= body.len: return fallback
  var value = 0
  while i < body.len:
    let c = body[i]
    if c < '0' or c > '9': return fallback
    value = value * 10 + (ord(c) - ord('0'))
    i = i + 1
  sign * value

# ---------------------------------------------------------------------------
# Names, looked up without walking
# ---------------------------------------------------------------------------
#
# THE DEFECT THIS EXISTS FOR. Everything below that answers "which row is
# called that" used to walk every row, and nothing that asked walked once. A
# modpack with 1,505 items asked about each of them thirteen times - six
# catalog walks inside `itemOf`, one to find which catalog it came from, six
# more for this mod's facets - and every walk was a host call per row. One
# `update()` of `aoughwl.hud` took 372,693 milliseconds, six minutes, with
# nothing repainting, the first time an asset import actually delivered items
# (`artifacts/playtest/unity-1.log`, "Mod 'aoughwl.hud' spent"). The mod
# had always been quadratic; a modpack that delivered nothing had hidden it.
#
# So a list of names is indexed once and asked many times. Open addressing over
# a power-of-two table, the name's own hash, linear probing - the same shape
# `aoughwl.spawner`'s title index uses, and for the same reason: `Table`
# is not reached for because a mod's standard library is not the place to find
# out what nimony has.
#
# The rule kept is the one every catalog walk in this project follows: a later
# row of a name wins over an earlier one. That is not a detail - it is why
# `Catalog.find` never stopped early, and it is what makes a modpack able to
# override a dependency's item.

type NameIndex* = object
  ## Which row each name is at, without asking every row.
  ids*: seq[string]
  slots*: seq[int]
    ## Into `ids`, or -1 for an empty slot. Always a power of two long and
    ## never less than twice `ids.len`, so a probe always ends.

proc hashOf*(text: string): int =
  ## FNV-1a, masked to stay positive in 32 bits however wide an int is here.
  var h = 2166136261
  var i = 0
  while i < text.len:
    h = h xor int(text[i])
    h = (h * 16777619) and 0x3FFFFFFF
    i = i + 1
  h

proc noNames*(): NameIndex = NameIndex(ids: @[], slots: @[])

proc reslot(n: var NameIndex) =
  ## Build the table over whatever `ids` holds now. A name that appears twice
  ## keeps the later row, which is the answer a walk that never stopped early
  ## always gave.
  var size = 16
  while size < n.ids.len * 2: size = size * 2
  n.slots = @[]
  var i = 0
  while i < size:
    n.slots.add(-1)
    i = i + 1
  i = 0
  while i < n.ids.len:
    var at = hashOf(n.ids[i]) and (size - 1)
    while n.slots[at] >= 0 and n.ids[n.slots[at]] != n.ids[i]:
      at = (at + 1) and (size - 1)
    n.slots[at] = i
    i = i + 1

proc rowOf*(n: NameIndex; id: string): int =
  ## Which row is called that, or -1. A hash and a string compare, whatever the
  ## number of rows is.
  if n.slots.len == 0: return -1
  let mask = n.slots.len - 1
  var at = hashOf(id) and mask
  var steps = 0
  while steps <= n.slots.len:
    let row = n.slots[at]
    if row < 0: return -1
    if n.ids[row] == id: return row
    at = (at + 1) and mask
    steps = steps + 1
  -1

proc addName*(n: var NameIndex; id: string): int =
  ## Index one more name and say which row it is. A name already here keeps the
  ## row it had, so a caller can use the answer to decide between replacing a
  ## row and adding one.
  let had = rowOf(n, id)
  if had >= 0: return had
  n.ids.add id
  if n.slots.len < n.ids.len * 2:
    reslot(n)
  else:
    let mask = n.slots.len - 1
    var at = hashOf(id) and mask
    while n.slots[at] >= 0: at = (at + 1) and mask
    n.slots[at] = n.ids.len - 1
  n.ids.len - 1

proc namesFrom*(ids: seq[string]): NameIndex =
  ## Index a whole list at once, later rows winning.
  result = NameIndex(ids: ids, slots: @[])
  reslot(result)

proc nameCount*(n: NameIndex): int = n.ids.len

proc probesFor*(n: NameIndex; id: string): int =
  ## How many slots `rowOf` touches to answer about this name - the work, in
  ## the only unit that means the same thing on every machine.
  ##
  ## This is here so `Tests/hud_test.nim` can assert the SHAPE of the cost
  ## rather than a number of milliseconds: four times the names must cost about
  ## four times the probes, and a walk of every row dressed up as a lookup
  ## cannot hide inside that. A wall clock would be a claim about one machine
  ## and would have to be loosened until it could not fail.
  if n.slots.len == 0: return 0
  let mask = n.slots.len - 1
  var at = hashOf(id) and mask
  var steps = 0
  while steps <= n.slots.len:
    steps = steps + 1
    let row = n.slots[at]
    if row < 0: return steps
    if n.ids[row] == id: return steps
    at = (at + 1) and mask
  steps

# ---------------------------------------------------------------------------
# What an item is
# ---------------------------------------------------------------------------

type
  ArmourPart* = enum
    ## Which armour slot a piece belongs in. `NotArmour` is everything else,
    ## which is almost everything.
    NotArmour, Head, Chest, Legs, Feet

  ItemDef* = object
    ## One item definition. `stack` is what one slot holds; `icon` is either a
    ## cell of the HUD's own sprite sheet ("3") or a colour ("#8b6b3f"), and an
    ## item that says neither gets a colour derived from its id, so a block a
    ## mod registered five minutes ago still looks like something.
    id*, display*: string
    stack*: int
    icon*: string
    food*: int
      ## Half-haunches restored. Zero is not food.
    saturation*: float64
    armour*: int
      ## Armour points this piece is worth, out of twenty.
    part*: ArmourPart
    known*: bool
      ## False for an id nobody defined, which is the only way a caller learns
      ## that a mod asked for something that does not exist.

  Registry* = object
    ## Every definition this session knows about. A later definition of the
    ## same id replaces the earlier one, which is the rule every catalog walk
    ## in this project follows.
    defs*: seq[ItemDef]
    names*: NameIndex
      ## Where each id sits in `defs`. Kept beside it by `define` rather than
      ## recomputed, because `definitionOf` is asked once per slot per frame
      ## and `define` once per item of a modpack - both of which walked all
      ## 1,505 definitions before this was here.

proc unknownItem*(id: string): ItemDef =
  ItemDef(id: id, display: id, stack: 64, icon: "", food: 0, saturation: 0.0,
    armour: 0, part: NotArmour, known: false)

proc newRegistry*(): Registry = Registry(defs: @[], names: noNames())

proc indexOf*(r: Registry; id: string): int =
  ## Which definition is called that, or -1.
  ##
  ## A registry somebody built by hand - `Registry(defs: @[...])`, without the
  ## index - is still answered, by the walk this used to be. That is not dead
  ## code kept for politeness: it is what makes the index an optimisation
  ## rather than a new rule about how a Registry may be made, and the two
  ## answers are checked against each other in `Tests/hud_test.nim`.
  if r.names.ids.len != r.defs.len:
    result = -1
    var i = 0
    while i < r.defs.len:
      if r.defs[i].id == id: result = i
      i = i + 1
    return result
  rowOf(r.names, id)

proc lookupCost*(r: Registry; id: string): int =
  ## What `indexOf` touches to answer about this id: probes through the index,
  ## or every definition there is when there is no index to go through.
  ##
  ## It takes the same branch `indexOf` takes, which is the point - a registry
  ## that has lost its index answers `defs.len` here and fails the check in
  ## `Tests/hud_test.nim` that says four times the definitions cost about four
  ## times the work, rather than quietly costing a frame.
  if r.names.ids.len != r.defs.len: return r.defs.len
  probesFor(r.names, id)

proc reindex(r: var Registry) =
  ## Put the index back over a registry that was made without one, dropping an
  ## earlier definition of an id a later row repeats - which is exactly what
  ## `indexOf` answering with the last match always meant.
  var had = r.defs
  r.defs = @[]
  r.names = noNames()
  var i = 0
  while i < had.len:
    let at = addName(r.names, had[i].id)
    if at < r.defs.len: r.defs[at] = had[i]
    else: r.defs.add had[i]
    i = i + 1

## Put one in, replacing a definition of the same id rather than shadowing it,
## so `count` is the number of distinct things and not the number of calls.
proc define*(r: var Registry; d: ItemDef) =
  var fixed = d
  fixed.known = true
  if fixed.stack < 1: fixed.stack = 1
  if fixed.display.len == 0: fixed.display = fixed.id
  if r.names.ids.len != r.defs.len: reindex(r)
  let at = addName(r.names, fixed.id)
  if at < r.defs.len: r.defs[at] = fixed
  else: r.defs.add fixed

proc define*(r: var Registry; id, display: string; stack = 64; icon = "";
    food = 0; saturation = 0.0; armour = 0; part = NotArmour) =
  define(r, ItemDef(id: id, display: display, stack: stack, icon: icon,
    food: food, saturation: saturation, armour: armour, part: part,
    known: true))

proc definitionOf*(r: Registry; id: string): ItemDef =
  let at = indexOf(r, id)
  if at < 0: return unknownItem(id)
  r.defs[at]

proc count*(r: Registry): int = r.defs.len

## What one slot holds of this. An item nobody defined stacks to 64 rather than
## to one: a HUD that has not heard of a block yet should still let a player
## carry a pile of it, and refusing to would make an unregistered item look
## like a bug in the inventory rather than a gap in a catalog.
proc stackLimit*(r: Registry; id: string): int =
  if id.len == 0: return 0
  let d = definitionOf(r, id)
  if d.stack < 1: 1 else: d.stack

# ---------------------------------------------------------------------------
# A stack, and a slot full of one
# ---------------------------------------------------------------------------

type ItemStack* = object
  ## One pile of one thing. An empty slot is an empty id, never a count of
  ## zero with an id still in it - so `isEmpty` is one comparison and a slot
  ## can never be half cleared.
  item*: string
  count*: int

proc nothingStack*(): ItemStack = ItemStack(item: "", count: 0)
proc stack*(item: string; count = 1): ItemStack =
  if item.len == 0 or count <= 0: nothingStack()
  else: ItemStack(item: item, count: count)

proc isEmpty*(s: ItemStack): bool = s.item.len == 0 or s.count <= 0
proc sameItem*(a, b: ItemStack): bool =
  (not isEmpty(a)) and (not isEmpty(b)) and a.item == b.item

## Pour as much of `from0` into `onto` as the stack limit allows, and answer
## what is left of `from0`. Nothing is created and nothing is lost: the two
## counts before and after always add up.
proc pourInto*(r: Registry; onto: var ItemStack; from0: ItemStack): ItemStack =
  if isEmpty(from0): return nothingStack()
  if isEmpty(onto):
    let room = stackLimit(r, from0.item)
    if from0.count <= room:
      onto = from0
      return nothingStack()
    onto = stack(from0.item, room)
    return stack(from0.item, from0.count - room)
  if onto.item != from0.item: return from0
  let room = stackLimit(r, onto.item) - onto.count
  if room <= 0: return from0
  if from0.count <= room:
    onto.count = onto.count + from0.count
    return nothingStack()
  onto.count = onto.count + room
  stack(from0.item, from0.count - room)

## Half of a stack, rounded up, taken out of it - the right mouse button on a
## slot with an empty hand. Nine becomes five in the hand and four in the slot.
proc halve*(s: var ItemStack): ItemStack =
  if isEmpty(s): return nothingStack()
  let taken = (s.count + 1) div 2
  let left = s.count - taken
  let item = s.item
  if left <= 0: s = nothingStack()
  else: s.count = left
  stack(item, taken)

## Take `count` out of a stack; a count of zero means all of it.
proc takeFrom*(s: var ItemStack; count: int): ItemStack =
  if isEmpty(s): return nothingStack()
  var want = count
  if want <= 0 or want > s.count: want = s.count
  let item = s.item
  let left = s.count - want
  if left <= 0: s = nothingStack()
  else: s.count = left
  stack(item, want)

# ---------------------------------------------------------------------------
# The layout
# ---------------------------------------------------------------------------

const
  HotbarSlots* = 9
  MainColumns* = 9
  MainRows* = 3
  MainSlots* = 27
  ArmourSlots* = 4
  PlayerSlots* = 40
    ## 0..8 hotbar, 9..35 main, 36..39 armour: head, chest, legs, feet.
  FirstMain* = 9
  FirstArmour* = 36

type SlotKind* = enum
  SlotNowhere, SlotHotbar, SlotMain, SlotArmour

proc kindOfSlot*(slot: int): SlotKind =
  if slot < 0 or slot >= PlayerSlots: SlotNowhere
  elif slot < HotbarSlots: SlotHotbar
  elif slot < FirstArmour: SlotMain
  else: SlotArmour

## Which piece of armour belongs in this slot. `NotArmour` for every slot that
## is not one of the four.
proc armourPartOf*(slot: int): ArmourPart =
  case slot - FirstArmour
  of 0: Head
  of 1: Chest
  of 2: Legs
  of 3: Feet
  else: NotArmour

type Inventory* = object
  slots*: seq[ItemStack]

proc newInventory*(): Inventory =
  result = Inventory(slots: @[])
  var i = 0
  while i < PlayerSlots:
    result.slots.add nothingStack()
    i = i + 1

proc at*(inv: Inventory; slot: int): ItemStack =
  if slot < 0 or slot >= inv.slots.len: nothingStack()
  else: inv.slots[slot]

proc put*(inv: var Inventory; slot: int; s: ItemStack) =
  if slot < 0 or slot >= inv.slots.len: return
  inv.slots[slot] = s

## Whether this slot will hold this at all. Only armour slots refuse anything,
## and they refuse everything that is not the piece they are for - so a HUD
## never has to ask any other question before letting go of a drag.
proc slotAccepts*(r: Registry; slot: int; s: ItemStack): bool =
  if slot < 0 or slot >= PlayerSlots: return false
  if isEmpty(s): return true
  if kindOfSlot(slot) != SlotArmour: return true
  definitionOf(r, s.item).part == armourPartOf(slot)

# ---------------------------------------------------------------------------
# Picking things up
# ---------------------------------------------------------------------------

## Put `count` of `item` into the inventory the way a pickup does: top up
## stacks that already hold it, hotbar first, then fill empty slots, hotbar
## first again. Answers how many would not go in - zero when all of it did.
proc give*(inv: var Inventory; r: Registry; item: string; count: int): int =
  if item.len == 0 or count <= 0: return 0
  var left = count
  var pass = 0
  while pass < 2 and left > 0:
    var slot = 0
    while slot < FirstArmour and left > 0:
      let existing = inv.slots[slot]
      let usable = (pass == 0 and (not isEmpty(existing)) and
        existing.item == item) or (pass == 1 and isEmpty(existing))
      if usable:
        var target = existing
        let over = pourInto(r, target, stack(item, left))
        inv.slots[slot] = target
        left = if isEmpty(over): 0 else: over.count
      slot = slot + 1
    pass = pass + 1
  left

## How many of one thing are in here, across every stack of it.
proc countOf*(inv: Inventory; item: string): int =
  result = 0
  var i = 0
  while i < inv.slots.len:
    if (not isEmpty(inv.slots[i])) and inv.slots[i].item == item:
      result = result + inv.slots[i].count
    i = i + 1

## Take `count` of one thing out, newest slot first, and answer how many were
## actually taken.
proc takeOut*(inv: var Inventory; item: string; count: int): int =
  var left = count
  var i = inv.slots.len - 1
  while i >= 0 and left > 0:
    if (not isEmpty(inv.slots[i])) and inv.slots[i].item == item:
      let got = takeFrom(inv.slots[i], left)
      left = left - got.count
    i = i - 1
  count - left

# ---------------------------------------------------------------------------
# What a mouse does to a slot
#
# Every one of these takes what is in the hand and answers what is in the hand
# afterwards, so a screen never has to work out which of the two it should have
# written back.
# ---------------------------------------------------------------------------

## The left button: an empty hand takes the stack, a full hand puts it down, a
## hand holding the same thing merges into it, and anything else swaps.
proc clickSlot*(inv: var Inventory; r: Registry; slot: int;
    carried: ItemStack): ItemStack =
  if kindOfSlot(slot) == SlotNowhere: return carried
  var here = inv.slots[slot]
  if isEmpty(carried):
    inv.slots[slot] = nothingStack()
    return here
  if not slotAccepts(r, slot, carried): return carried
  if sameItem(here, carried):
    let left = pourInto(r, here, carried)
    inv.slots[slot] = here
    return left
  if not slotAccepts(r, slot, carried): return carried
  inv.slots[slot] = carried
  here

## The right button: an empty hand halves the stack, a full hand puts one down.
proc rightClickSlot*(inv: var Inventory; r: Registry; slot: int;
    carried: ItemStack): ItemStack =
  if kindOfSlot(slot) == SlotNowhere: return carried
  var here = inv.slots[slot]
  if isEmpty(carried):
    let taken = halve(here)
    inv.slots[slot] = here
    return taken
  if not slotAccepts(r, slot, carried): return carried
  if isEmpty(here):
    inv.slots[slot] = stack(carried.item, 1)
    var hand = carried
    hand.count = hand.count - 1
    if hand.count <= 0: hand = nothingStack()
    return hand
  if here.item != carried.item: return carried
  if here.count >= stackLimit(r, here.item): return carried
  here.count = here.count + 1
  inv.slots[slot] = here
  var hand = carried
  hand.count = hand.count - 1
  if hand.count <= 0: hand = nothingStack()
  hand

## Move a whole stack from one slot to another, merging when they are the same
## thing and swapping when they are not. What will not fit stays where it was.
proc moveSlot*(inv: var Inventory; r: Registry; source, target: int): bool =
  if kindOfSlot(source) == SlotNowhere: return false
  if kindOfSlot(target) == SlotNowhere: return false
  if source == target: return false
  let moving = inv.slots[source]
  if isEmpty(moving): return false
  if not slotAccepts(r, target, moving): return false
  var here = inv.slots[target]
  if sameItem(here, moving):
    let left = pourInto(r, here, moving)
    inv.slots[target] = here
    inv.slots[source] = left
    return not isEmpty(moving)
  if not slotAccepts(r, source, here): return false
  inv.slots[target] = moving
  inv.slots[source] = here
  true

## Shift-click: hotbar to the main grid and back again, into the first place it
## will go. Armour goes to its own slot from anywhere. Answers whether anything
## moved.
proc quickMove*(inv: var Inventory; r: Registry; slot: int): bool =
  let moving = inv.at(slot)
  if isEmpty(moving): return false
  let kind = kindOfSlot(slot)
  if kind == SlotNowhere: return false
  # A piece of armour goes to the slot it is for, if that one is free.
  let part = definitionOf(r, moving.item).part
  if part != NotArmour and kind != SlotArmour:
    var armourSlot = FirstArmour
    while armourSlot < PlayerSlots:
      if armourPartOf(armourSlot) == part and isEmpty(inv.slots[armourSlot]):
        return moveSlot(inv, r, slot, armourSlot)
      armourSlot = armourSlot + 1
  var first = 0
  var last = 0
  if kind == SlotHotbar:
    first = FirstMain
    last = FirstArmour
  else:
    first = 0
    last = HotbarSlots
  # Top up a matching stack before opening a new one, exactly as a pickup does.
  var pass = 0
  var moved = false
  while pass < 2:
    var i = first
    while i < last:
      let here = inv.slots[i]
      let usable = (pass == 0 and sameItem(here, inv.slots[slot])) or
        (pass == 1 and isEmpty(here))
      if usable and (not isEmpty(inv.slots[slot])):
        if moveSlot(inv, r, slot, i): moved = true
        if isEmpty(inv.slots[slot]): return true
      i = i + 1
    pass = pass + 1
  moved

## Which hotbar slot the wheel leaves you on. Positive is away from you, which
## Minecraft reads as one slot to the left, and it wraps in both directions
## however many notches arrive at once.
proc scrolledSlot*(selected: int; notches: float64; slots = HotbarSlots): int =
  if slots <= 0: return 0
  var steps = int(notches)
  if notches > 0.0 and steps == 0: steps = 1
  if notches < 0.0 and steps == 0: steps = -1
  var s = (selected - steps) mod slots
  if s < 0: s = s + slots
  s

# ---------------------------------------------------------------------------
# Armour
# ---------------------------------------------------------------------------

## The armour bar, out of twenty points, from what is actually worn.
proc armourWorn*(inv: Inventory; r: Registry): int =
  result = 0
  var slot = FirstArmour
  while slot < PlayerSlots:
    let s = inv.at(slot)
    if not isEmpty(s):
      let d = definitionOf(r, s.item)
      if d.part == armourPartOf(slot): result = result + d.armour
    slot = slot + 1
  if result > 20: result = 20

# ---------------------------------------------------------------------------
# Staying alive
# ---------------------------------------------------------------------------

const
  MaxHealth* = 20
    ## In half-hearts: ten hearts.
  MaxHunger* = 20
    ## In half-haunches: ten haunches.
  ExhaustionPerDrain* = 4.0
    ## How much exhaustion costs one point of saturation, or of hunger when
    ## there is no saturation left.
  RegenPeriod* = 4.0
  StarvePeriod* = 4.0
  RegenExhaustion* = 6.0
  RegenHunger* = 18
    ## Nine haunches: below this, nothing heals.
  SprintHunger* = 7
    ## Below this you cannot sprint, which is what stops a starving player
    ## outrunning the hunger that is killing them.
  SafeFall* = 3.0
    ## Metres you may fall for nothing.

type Survival* = object
  health*: int
  hunger*: int
  saturation*: float64
  exhaustion*: float64
  armour*: int
  experience*: int
    ## Total points ever gathered, minus what has been spent. Levels are
    ## derived from it rather than kept beside it, so the two cannot disagree.
  regenTimer*: float64
  starveTimer*: float64
  falling*: bool
  fellFrom*: float64
  dead*: bool
  lastHurt*: float64
    ## Seconds since the last damage, for a HUD that flashes.

proc newSurvival*(): Survival =
  Survival(health: MaxHealth, hunger: MaxHunger, saturation: 5.0,
    exhaustion: 0.0, armour: 0, experience: 0, regenTimer: 0.0,
    starveTimer: 0.0, falling: false, fellFrom: 0.0, dead: false,
    lastHurt: 1000.0)

proc alive*(s: Survival): bool = s.health > 0 and not s.dead

## Spend exhaustion, which comes out of saturation first and out of hunger
## after that. This is the only path by which hunger ever goes down.
proc exhaust*(s: var Survival; amount: float64) =
  if amount <= 0.0 or s.dead: return
  s.exhaustion = s.exhaustion + amount
  while s.exhaustion >= ExhaustionPerDrain:
    s.exhaustion = s.exhaustion - ExhaustionPerDrain
    if s.saturation > 0.0:
      s.saturation = s.saturation - 1.0
      if s.saturation < 0.0: s.saturation = 0.0
    elif s.hunger > 0:
      s.hunger = s.hunger - 1

## Exhaustion for having walked. Sprinting costs ten times what walking does,
## which is the whole reason a player thinks about food at all.
proc walked*(s: var Survival; metres: float64; sprinting = false) =
  if metres <= 0.0: return
  if sprinting: exhaust(s, metres * 0.1)
  else: exhaust(s, metres * 0.01)

proc jumped*(s: var Survival; sprinting = false) =
  if sprinting: exhaust(s, 0.2) else: exhaust(s, 0.05)

proc canSprint*(s: Survival): bool = s.hunger > SprintHunger

## How much damage `points` actually does through this much armour. Twenty
## points of armour take four fifths of it, and never all of it.
proc afterArmour*(points: int; armour: int): int =
  if points <= 0: return 0
  var worn = armour
  if worn < 0: worn = 0
  if worn > 20: worn = 20
  let left = float64(points) * (1.0 - float64(worn) / 25.0)
  result = int(left)
  if float64(result) < left: result = result + 1
  if result < 1: result = 1

proc heal*(s: var Survival; points: int) =
  if s.dead or points <= 0: return
  s.health = s.health + points
  if s.health > MaxHealth: s.health = MaxHealth

## Take damage, in half-hearts. `throughArmour` is false for the kinds of harm
## armour does nothing about - starving, drowning, falling out of the world.
proc hurt*(s: var Survival; points: int; throughArmour = true) =
  if s.dead or points <= 0: return
  var taken = points
  if throughArmour: taken = afterArmour(points, s.armour)
  s.health = s.health - taken
  s.lastHurt = 0.0
  s.regenTimer = 0.0
  if s.health <= 0:
    s.health = 0
    s.dead = true

## Eat something. Saturation can never exceed hunger, which is the rule that
## stops a steak eaten on a full stomach being stored for later.
proc eat*(s: var Survival; food: int; saturation: float64) =
  if s.dead or food <= 0: return
  s.hunger = s.hunger + food
  if s.hunger > MaxHunger: s.hunger = MaxHunger
  s.saturation = s.saturation + saturation
  if s.saturation > float64(s.hunger): s.saturation = float64(s.hunger)

## Whether eating this would do anything at all - what greys out the mouse.
proc wouldEat*(s: Survival; food: int): bool =
  food > 0 and s.hunger < MaxHunger and not s.dead

## How much a fall of this many metres hurts, in half-hearts, before armour.
proc fallDamage*(metres: float64): int =
  if metres <= SafeFall: return 0
  let over = metres - SafeFall
  result = int(over)
  if float64(result) > over: result = result - 1
  if result < 0: result = 0

## Follow a body through the air. Call it every frame with the height it is at
## and whether the host says it is standing on something; it answers the damage
## the landing did, in half-hearts, and zero on every other frame.
proc fell*(s: var Survival; height: float64; onGround: bool): int =
  if onGround:
    if not s.falling: return 0
    s.falling = false
    let drop = s.fellFrom - height
    return fallDamage(drop)
  if not s.falling:
    s.falling = true
    s.fellFrom = height
  elif height > s.fellFrom:
    s.fellFrom = height
  0

## Put the fall counter back where a teleport or a respawn leaves it, so
## arriving somewhere lower than you left is not a fall.
proc groundAt*(s: var Survival; height: float64) =
  s.falling = false
  s.fellFrom = height

## One frame of simply existing: regeneration when there is food for it, and
## starvation when there is not.
proc step*(s: var Survival; seconds: float64) =
  if s.dead or seconds <= 0.0: return
  s.lastHurt = s.lastHurt + seconds
  if s.hunger >= RegenHunger and s.health < MaxHealth:
    s.regenTimer = s.regenTimer + seconds
    if s.regenTimer >= RegenPeriod:
      s.regenTimer = s.regenTimer - RegenPeriod
      heal(s, 1)
      exhaust(s, RegenExhaustion)
  else:
    s.regenTimer = 0.0
  if s.hunger <= 0:
    s.starveTimer = s.starveTimer + seconds
    if s.starveTimer >= StarvePeriod:
      s.starveTimer = s.starveTimer - StarvePeriod
      hurt(s, 1, false)
  else:
    s.starveTimer = 0.0

## Start again. Experience is kept, which is this game's choice and not
## Minecraft's; nothing else survives.
proc respawn*(s: var Survival) =
  let xp = s.experience
  s = newSurvival()
  s.experience = xp

# ---------------------------------------------------------------------------
# Experience
# ---------------------------------------------------------------------------

## How many points the step from `level` to `level + 1` costs. The three
## straight lines Minecraft uses, and the reason a level is worth more later.
proc pointsForLevel*(level: int): int =
  if level < 0: 0
  elif level < 16: 2 * level + 7
  elif level < 31: 5 * level - 38
  else: 9 * level - 158

## Points from nothing up to the start of `level`.
proc pointsToLevel*(level: int): int =
  result = 0
  var i = 0
  while i < level:
    result = result + pointsForLevel(i)
    i = i + 1

## The level this many points is worth.
proc levelOf*(points: int): int =
  if points <= 0: return 0
  result = 0
  var spent = 0
  while true:
    let next = spent + pointsForLevel(result)
    if next > points: return result
    spent = next
    result = result + 1

## How far along the bar is, 0.0 at the start of a level and just under 1.0 at
## the end of it.
proc levelProgress*(points: int): float64 =
  if points <= 0: return 0.0
  let level = levelOf(points)
  let start = pointsToLevel(level)
  let span = pointsForLevel(level)
  if span <= 0: return 0.0
  float64(points - start) / float64(span)

proc addExperience*(s: var Survival; points: int) =
  if points <= 0: return
  s.experience = s.experience + points

# ---------------------------------------------------------------------------
# Icons
#
# `drawImage` can only name a file inside the calling mod's own folder, so an
# item another mod registered cannot hand this one a picture. An icon is
# therefore a cell of the HUD's own sheet or a colour, and an item that says
# neither gets a colour derived from its id - which is not pretty, but it is
# stable, distinct per item, and needs nobody's permission.
# ---------------------------------------------------------------------------

const IconSheetCells* = 4
  ## The sheet is this many cells across and the same down.

type
  IconWindow* = object
    ## The part of the sheet one icon is, in 0..1 with zero at its top - the
    ## u/v window `drawImage` takes.
    u0*, v0*, u1*, v1*: float64
  Rgb* = object
    r*, g*, b*: float64

## Which cell of the sheet this icon names, or -1 when it names none.
proc iconCell*(icon: string): int =
  let body = trimmed(icon)
  if body.len == 0: return -1
  if body[0] == '#': return -1
  let n = wholeOf(body, -1)
  if n < 0 or n >= IconSheetCells * IconSheetCells: return -1
  n

## Where in the sheet that cell is, as the u/v window `drawImage` takes.
proc iconWindow*(cell: int): IconWindow =
  let span = 1.0 / float64(IconSheetCells)
  let column = cell mod IconSheetCells
  let row = cell div IconSheetCells
  IconWindow(u0: float64(column) * span, v0: float64(row) * span,
    u1: float64(column + 1) * span, v1: float64(row + 1) * span)

proc nibbleOf(c: char): int =
  if c >= '0' and c <= '9': ord(c) - ord('0')
  elif c >= 'a' and c <= 'f': 10 + ord(c) - ord('a')
  elif c >= 'A' and c <= 'F': 10 + ord(c) - ord('A')
  else: -1

## A stable colour for an item, from its icon when it names one and from its id
## when it does not. Three channels, each 0..1.
proc channelAt(body: string; index: int): float64 =
  let hi = nibbleOf(body[1 + index * 2])
  let lo = nibbleOf(body[2 + index * 2])
  if hi < 0 or lo < 0: 0.0
  else: float64(hi * 16 + lo) / 255.0

proc iconColour*(id, icon: string): Rgb =
  let body = trimmed(icon)
  if body.len >= 7 and body[0] == '#':
    return Rgb(r: channelAt(body, 0), g: channelAt(body, 1),
      b: channelAt(body, 2))
  # FNV-1a over the id, then three bytes of it, floored away from black so
  # nothing lands on the panel colour and disappears.
  var h = 2166136261
  var i = 0
  while i < id.len:
    h = (h xor ord(id[i])) * 16777619
    h = h and 0x7fffffff
    i = i + 1
  Rgb(r: 0.35 + float64(h mod 160) / 255.0,
    g: 0.35 + float64((h div 251) mod 160) / 255.0,
    b: 0.35 + float64((h div 65029) mod 160) / 255.0)
