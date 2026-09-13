## The mod that carries the grid inventory layer, and proves it at start().
##
## It draws nothing, spawns nothing and reads no input. All it does is build a
## few bags out of catalogs of its own and run the arithmetic that makes a grid
## inventory a grid inventory: a thing only goes where there is a hole the shape
## of it, turning it changes the shape of the hole, a bag can go inside a bag
## but never inside itself, a bag that moves takes what is in it, and a refusal
## leaves both sides exactly as they were.
##
## Every check below is a rule somebody could get wrong, and every one runs with
## no screen, no camera and no host call but `log` and the catalog calls - which
## is why this and `Tests/grid_test.exe` are the evidence, and a screenshot is
## only the thing that shows it is on the screen at all.

import jester
import gridspace

const
  Items = "aoughwl.grid.selfcheck.items"
  Bags = "aoughwl.grid.selfcheck.bags"

var
  checks = 0
  failures = 0

proc expect(what: string; okay: bool) =
  checks = checks + 1
  if not okay:
    failures = failures + 1
    log("grid self-check failed: " & what)

proc defineEverything() =
  let kit = gridItemCatalog(Items, "Things to carry, for the self-check")
  defineThing(kit, "bandage", "Bandage", shape = "1x1", stack = 4,
    weight = 0.1, tags = "medical small")
  defineThing(kit, "rifle", "Rifle", shape = "5x1", weight = 3.5,
    tags = "gun big")
  defineThing(kit, "mag", "Magazine", shape = "1x2", stack = 60, weight = 0.4,
    tags = "ammo")
  defineThing(kit, "rig", "Chest rig", shape = "2x2", weight = 1.0,
    tags = "gear", holds = "rigbag")
  defineThing(kit, "lump", "Lump", shape = "pistol", tags = "junk")

  let bags = gridContainerCatalog(Bags, "Things to carry in, for the self-check")
  defineBag(bags, "stash", "Stash", grid = "4x6")
  defineBag(bags, "pouch", "Medical pouch", grid = "3x3", accepts = "medical")
  defineBag(bags, "rigbag", "Rig pockets", grid = "2x3")
  defineBag(bags, "light", "Light satchel", grid = "6x6", load = 1.2)

proc anywhere(): Holder =
  ## A definition built in code rather than read from a catalog - a ground pile.
  Holder(id: "ground", display: "Ground", slots: -1, capacity: -1.0,
    load: -1.0, accepts: "", rejects: "", known: true)

# ------------------------------------------------------------- footprints --

proc checkFootprints() =
  expect("a shape token reads as wide by tall",
    readFootprint("5x1").wide == 5 and readFootprint("5x1").tall == 1)
  expect("two digits either side read",
    readFootprint("12x10").wide == 12 and readFootprint("12x10").tall == 10)
  expect("a token this layer cannot read is one cell",
    readFootprint("pistol").wide == 1 and readFootprint("pistol").tall == 1)
  expect("no token at all is one cell", readFootprint("").wide == 1)
  expect("turning swaps the sides",
    turned(footprint(5, 1)).wide == 1 and turned(footprint(5, 1)).tall == 5)
  expect("a square thing has one way up", not turnable(footprint(2, 2)))
  expect("an oblong has two", turnable(footprint(5, 1)))
  expect("an item with a shape nobody can read is still one cell",
    footprintOf("lump").wide == 1)

# ------------------------------------------------------------- the packing --

proc checkPacking() =
  let stash = openBag("stash", "stash")
  expect("a container opened from a catalog is live", bagLive(stash))
  expect("its cells come from the grid facet",
    bagWide(stash) == 4 and bagTall(stash) == 6)

  let flat = stowAt(stash, "rifle", 1, 0, 0, false)
  expect("a five-wide rifle is refused by a four-wide bag", not went(flat))
  expect("and the refusal says why, in cells",
    flat.trouble == NoRoom and flat.note.len > 10)
  expect("a refused stow leaves the bag empty", entryCount(stash) == 0)

  let turnedIn = stowAt(stash, "rifle", 1, 0, 0, true)
  expect("the same rifle on its side fits", went(turnedIn))
  expect("and it is one cell wide and five tall",
    footprintOn(entryOf(stash, turnedIn.slot)).wide == 1 and
    footprintOn(entryOf(stash, turnedIn.slot)).tall == 5)
  expect("it covers the cells under it",
    keyAtCell(stash, 0, 4) == turnedIn.slot and keyAtCell(stash, 0, 5) == 0)

  let onTop = stowAt(stash, "bandage", 1, 0, 2, false)
  expect("nothing goes where something already is", not went(onTop))
  expect("and that is a refusal about room", onTop.trouble == NoRoom)

  let beside = stowAt(stash, "bandage", 1, 1, 0, false)
  expect("beside it is fine", went(beside))

  let auto = stow(stash, "mag", 30)
  expect("a stack put in with no cell named finds one", went(auto))
  expect("and it landed on the grid",
    entryOf(stash, auto.slot).column >= 0)

  expect("cells used is the sum of the footprints",
    cellsUsed(stash) == 5 + 1 + 2)
  expect("cells there are is the whole grid", cellsTotal(stash) == 24)

  # A bag with only room the wrong way round takes it the right way round.
  let narrow = openGrid(anywhere(), 1, 6, "chimney")
  let squeezed = stow(narrow, "rifle", 1)
  expect("a rifle goes into a one-wide bag by turning", went(squeezed))
  expect("and it went in on its side",
    entryOf(narrow, squeezed.slot).rotated)

  let turnBack = turn(narrow, squeezed.slot)
  expect("turning it back would put it off the grid", not went(turnBack))
  expect("and it did not move", entryOf(narrow, squeezed.slot).rotated)

  discard closeBag(narrow)
  discard closeBag(stash)

# ------------------------------------------------------------------- tags --

proc checkTags() =
  let pouch = openBag("pouch", "pouch")
  let ground = openGrid(anywhere(), 6, 6, "ground")
  discard stow(ground, "rifle", 1)
  let rifleKey = entryAt(ground, 0).key

  let before = arrangementOf(ground)
  let refused = moveTo(ground, rifleKey, pouch, 0, 0, false)
  expect("a medical pouch refuses a rifle", not went(refused))
  expect("and says it was the tags", refused.trouble == NotAccepted)
  expect("the source is untouched by a refused move",
    arrangementOf(ground) == before)
  expect("and so is the target", entryCount(pouch) == 0)

  let welcome = stow(pouch, "bandage", 1)
  expect("the pouch takes what it is for", went(welcome))
  discard closeBag(pouch)
  discard closeBag(ground)

# ---------------------------------------------------------------- nesting --

proc checkNesting() =
  let ground = openGrid(anywhere(), 6, 6, "ground")
  let put0 = stow(ground, "rig", 1)
  expect("a rig goes on the ground", went(put0))
  let rigKey = put0.slot
  let inside = entryOf(ground, rigKey).inner
  expect("an item that names a container opens one", bagLive(inside))
  expect("its cells come from that definition",
    bagWide(inside) == 2 and bagTall(inside) == 3)
  expect("and its parent is the bag the rig is in",
    isSame(bagParent(inside), ground))

  expect("filling it works like any bag", went(stow(inside, "bandage", 4)))
  expect("which is one stack of four", entryCount(inside) == 1)

  let itself = moveTo(ground, rigKey, inside, 0, 0, false)
  expect("a container cannot be put inside itself", not went(itself))
  expect("and the refusal says so", itself.note.len > 10)
  expect("the rig is still on the ground", entryCount(ground) == 1)
  expect("and still holds what it held", entryCount(inside) == 1)

  # One level deeper: a rig inside a rig, then the outer one into the inner.
  let second = stow(ground, "rig", 1)
  let secondInner = entryOf(ground, second.slot).inner
  expect("a second rig opens a second space", bagLive(secondInner))
  expect("a rig goes inside another rig",
    went(moveTo(ground, second.slot, inside, 0, 1, false)))
  expect("and the ground is down to one thing", entryCount(ground) == 1)
  let nowhereToGo = moveTo(inside, rigKey, secondInner, 0, 0, false)
  expect("moving the outer rig into its grandchild is refused",
    not went(nowhereToGo))
  expect("because that rig is not even there",
    nowhereToGo.trouble == NoSuchStack)
  let deeper = moveTo(ground, rigKey, secondInner, 0, 0, false)
  expect("nor from where it really is", not went(deeper))
  expect("and that one is refused as self-containment",
    deeper.trouble == Nowhere)

  discard closeBag(ground)

proc checkMovingFull() =
  let ground = openGrid(anywhere(), 6, 6, "ground")
  let stash = openGrid(anywhere(), 6, 6, "stash")
  let rig = stow(ground, "rig", 1)
  let inside = entryOf(ground, rig.slot).inner
  discard stow(inside, "bandage", 4)
  discard stow(inside, "mag", 60)
  let held = arrangementOf(inside)
  expect("the rig has two things in it", entryCount(inside) == 2)

  let moved = moveTo(ground, rig.slot, stash, 2, 2, false)
  expect("a full rig moves", went(moved))
  expect("the ground is empty", entryCount(ground) == 0)
  expect("the stash has it", entryCount(stash) == 1)
  expect("at the cell it was put at",
    entryAt(stash, 0).column == 2 and entryAt(stash, 0).row == 2)
  expect("its contents came with it", entryCount(inside) == 2)
  expect("unmoved, cell for cell", arrangementOf(inside) == held)
  expect("and it is the same space, not a copy",
    isSame(entryAt(stash, 0).inner, inside))
  expect("whose parent is now the stash",
    isSame(bagParent(inside), stash))
  expect("and the arrangement says what is inside what",
    arrangementOf(stash).len > held.len)

  discard closeBag(ground)
  discard closeBag(stash)

proc checkRecursiveWeight() =
  let ground = openGrid(anywhere(), 6, 6, "ground")
  let rig = stow(ground, "rig", 1)
  let inside = entryOf(ground, rig.slot).inner
  expect("an empty rig weighs what a rig weighs", weightIn(ground) == 1.0)
  discard stow(inside, "bandage", 4)
  expect("a full one weighs more", weightIn(ground) > 1.39)
  expect("and it is the contents that made the difference",
    weightIn(inside) > 0.39 and weightIn(inside) < 0.41)

  let light = openBag("light", "satchel")
  expect("the satchel would take the rig on its own",
    troubleTaking(light, "rig", 1) == NoTrouble)
  let heavy = moveTo(ground, rig.slot, light, 0, 0, false)
  expect("but not the rig with four bandages in it", not went(heavy))
  expect("and the reason is the weight", heavy.trouble == TooHeavy)
  expect("nothing moved", entryCount(light) == 0 and entryCount(ground) == 1)

  discard lift(inside, entryAt(inside, 0).key)
  expect("emptied, it goes in",
    went(moveTo(ground, rig.slot, light, 0, 0, false)))

  discard closeBag(light)
  discard closeBag(ground)

proc checkLifting() =
  let ground = openGrid(anywhere(), 6, 6, "ground")
  let rig = stow(ground, "rig", 1)
  let inside = entryOf(ground, rig.slot).inner
  discard stow(inside, "bandage", 4)
  expect("a rig on the ground is live", bagLive(inside))
  discard lift(ground, rig.slot)
  expect("lifting it away takes it off the grid", entryCount(ground) == 0)
  expect("and its space goes with it", not bagLive(inside))
  expect("a stale handle is a refusal, not somebody else's bag",
    stow(inside, "bandage", 1).trouble == NoSuchContainer)
  discard closeBag(ground)

# -------------------------------------------------------- stacks and stalls --

proc checkStacks() =
  let ground = openGrid(anywhere(), 6, 6, "ground")
  let first = stow(ground, "mag", 40)
  expect("forty rounds go in as one stack", entryCount(ground) == 1)
  let cut = splitOff(ground, first.slot, 15)
  expect("a stack splits", went(cut))
  expect("into two", entryCount(ground) == 2)
  expect("and the halves add up",
    entryOf(ground, first.slot).count == 25 and
    entryOf(ground, cut.slot).count == 15)
  expect("a split that leaves nothing behind is a move, and is refused",
    not went(splitOff(ground, cut.slot, 15)))

  let poured = mergeInto(ground, cut.slot, first.slot)
  expect("they pour back together", went(poured))
  expect("into one stack again", entryCount(ground) == 1)
  expect("of forty", entryOf(ground, first.slot).count == 40)

  discard stow(ground, "bandage", 1)
  let mixed = mergeInto(ground, entryAt(ground, 1).key, first.slot)
  expect("two different things do not pour together", not went(mixed))
  expect("a container does not split",
    not went(splitOff(ground, stow(ground, "rig", 1).slot, 1)))

  # And across two bags, which is the same rule with a move in the middle.
  let other = openGrid(anywhere(), 4, 4, "other")
  let spare = stow(other, "mag", 10)
  let poured2 = pourOnto(other, spare.slot, ground, first.slot)
  expect("a stack pours into one in another bag", went(poured2))
  expect("as much of it as the stack size allows", poured2.moved == 10)
  expect("the emptied stack is gone from where it was",
    entryCount(other) == 0)
  expect("and the one it went into has both",
    entryOf(ground, first.slot).count == 50)
  discard closeBag(other)
  discard closeBag(ground)

# --------------------------------------------------------- other mods' items --

proc checkPublished() =
  let mine = publishedItems()
  var sawRifle = false
  var i = 0
  while i < mine.len:
    if mine[i] == "rifle": sawRifle = true
    i = i + 1
  expect("a published catalog can be walked by a mod that did not write it",
    sawRifle)
  expect("and it found every item this mod defined", mine.len >= 5)
  expect("adopting what is published takes up at least the two here",
    adoptPublished() >= 2)

# ------------------------------------------------------------------ start --

## The checks, run on demand rather than at `start()`.
##
## `aoughwl.ui` runs its own self-check from `start()` and is right to:
## every rule it holds is arithmetic on rectangles, and proving it costs one
## `log`. This one cannot. Its rules are about catalogs, and catalogs are the
## host's and are shared by every mod in the session - so a self-check that ran
## at `start()` would leave five made-up items and four made-up bags in every
## game that loaded the grid library, and the inventory a person is playing with
## would be full of a Lump. So the checks are a callback, `Tests/grid_test.exe`
## calls it, and a live session gets a library and nothing else.
proc selfCheck() =
  defineEverything()
  checkFootprints()
  checkPacking()
  checkTags()
  checkNesting()
  checkMovingFull()
  checkRecursiveWeight()
  checkLifting()
  checkStacks()
  checkPublished()
  if failures == 0:
    log("grid self-check passed " & $checks & " checks")
  else:
    log("grid self-check FAILED " & $failures & " of " & $checks & " checks")

proc start() =
  declareGridKinds()

proc stop() = discard
