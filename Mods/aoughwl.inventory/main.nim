## The mod that says what an item is and what a container is, and nothing else.
##
## It spawns nothing and takes no input, and the only thing it draws is one
## line saying that it loaded and that its arithmetic holds. All it does at start()
## is declare the catalog kinds in `inventory.nim` so that other mods have
## somewhere to put items, and then run the arithmetic once against a catalog of
## its own so a headless build proves the library rather than the compiler.
##
## Everything Tarkov-shaped - a grid, a cell, a rotation, a rig - belongs to the
## mod above this one. Everything screen-shaped belongs to the one above that.

import jester
import aoughwl_inventory/inventory
import invpanel

const
  ## The self-check's own catalogs. They are this mod's, owned by it and gone
  ## when it unloads, and they are named after the check rather than after any
  ## game so nobody mistakes them for content.
  CheckItems = "aoughwl.inventory.selfcheck.items"
  CheckContainers = "aoughwl.inventory.selfcheck.containers"

var
  checks = 0
  passed = 0
  ask = AskNothing
  loadedAt = 0.0

proc expect(what: string; ok: bool) =
  checks = checks + 1
  if ok: passed = passed + 1
  else: log("inventory self-check failed: " & what)

proc expectTrouble(what: string; o: Outcome; want: Trouble) =
  expect(what & " (was " & name(o.trouble) & ")", o.trouble == want)

## The library, exercised end to end: definitions written into catalogs, read
## back out as definitions, and then moved around as stacks. Every refusal below
## is a rule the library holds, and every one of them is a returned Outcome - if
## any of this raised, the mod slot would answer nothing for the rest of the
## session and this proc would end without a word.
proc selfCheck() =
  let kit = itemCatalog(CheckItems, "Items the inventory library checks itself with")
  kit.defineItem("bandage", "Bandage", stack = 4, bulk = 1.0, weight = 0.1,
    shape = "1x1", tags = "medical small")
  kit.defineItem("rifle", "Rifle", stack = 1, bulk = 4.0, weight = 3.5,
    shape = "4x1", tags = "weapon large")

  let bags = containerCatalog(CheckContainers,
    "Containers the inventory library checks itself with")
  bags.defineContainer("pouch", "Belt pouch", slots = 2, capacity = 4.0,
    load = 2.0, accepts = "medical")
  bags.defineContainer("crate", "Crate", slots = 8, capacity = 40.0, load = 100.0)

  let bandage = itemOf("bandage")
  expect("a defined item reads back", bandage.known and bandage.stack == 4)
  expect("an undefined item is not known", not itemOf("nothing").known)
  expect("a shape is carried but never read here", bandage.shape == "1x1")
  expect("tags match whole words", tagged(bandage.tags, "medical") and
    not tagged(bandage.tags, "medic"))

  let pouch = openContainer(CheckContainers, "pouch", "belt")
  let crate = openContainer(CheckContainers, "crate")
  expect("a container opens", pouch.open() and crate.open())
  expect("an undefined container does not", openContainer(CheckContainers,
    "nothing").isNothing())

  expectTrouble("a pouch refuses a rifle by tag", pouch.put("rifle", 1), NotAccepted)
  expectTrouble("an unknown item is refused", pouch.put("nothing", 1), UnknownItem)
  expect("four bandages are one stack", pouch.put("bandage", 4).went and
    pouch.stackCount() == 1)
  expectTrouble("a fifth bandage does not fit the bulk", pouch.put("bandage", 1),
    NoRoom)
  expect("a refusal changes nothing", pouch.countOf("bandage") == 4)

  expect("a crate takes two rifles as two stacks", crate.put("rifle", 2).went and
    crate.stackCount() == 2)
  expectTrouble("a move the target refuses is refused",
    moveStack(crate, pouch, 0), NotAccepted)
  expect("and leaves the source alone", crate.countOf("rifle") == 2)

  expect("a stack splits", pouch.splitStack(0, 2).went and pouch.stackCount() == 2)
  expect("and merges back", pouch.mergeStacks(1, 0).went and
    pouch.stackCount() == 1)

  let moved = moveStack(pouch, crate, 0, 2)
  expect("a move that fits moves exactly what it said", moved.went and
    moved.moved == 2 and pouch.countOf("bandage") == 2 and
    crate.countOf("bandage") == 2)
  expectTrouble("a move within one container is neither", moveStack(pouch, pouch, 0),
    Nowhere)
  expectTrouble("a move of more than is there is refused",
    moveStack(pouch, crate, 0, 99), NotEnough)

  expect("taking works across stacks", pouch.take("bandage", 2).went and
    pouch.stackCount() == 0)
  expectTrouble("taking what is not there is refused", pouch.take("bandage", 1),
    NotEnough)

  expect("a closed container is gone", crate.closeContainer().went and
    not crate.open())
  expectTrouble("and stays gone", crate.put("rifle", 1), NoSuchContainer)
  discard pouch.closeContainer()

proc start() =
  declareInventoryKinds()
  selfCheck()
  loadedAt = gameTime()
  log("inventory: kinds declared, self-check " & $passed & "/" & $checks &
    " (L shows this on the screen)")

## Whether the panel is worth drawing this frame - `invpanel.wanted` is the
## rule, and this is the clock it takes.
proc showing(): bool =
  wanted(passed, checks, gameTime() - loadedAt, ask)

proc update() =
  if pressed("L"): ask = toggled(showing())

## The one screen this mod has, and the reason it has one. A modpack of nothing
## but libraries came up as an unbroken black rectangle in a shipped player -
## the kinds were declared, the self-check passed, and a person looking at it
## had no way to tell that from a mod that had failed to load. This says which
## it was, in the only place a person can read. It draws no inventory: a grid,
## a cell and a bag are the mods above this one, and this line is about the
## library itself.
##
## It is not permanent any more, and that is the other half of the same
## argument. This mod is a library under `minecraft` as well as the
## whole of `aoughwl.inventory`, and there the same three lines sat over
## the world for the length of the session. `invpanel.wanted` keeps them up
## while a session is young - which is when the black-rectangle question is
## asked - and for ever when a check FAILED, which is the case worth drawing.
## L brings it back.
proc drawGui() =
  if not showing(): return
  beginMenu("Inventory Library")
  label("kinds declared: item, container")
  label("self-check " & $passed & " of " & $checks &
    (if passed == checks: " - all pass" else: " - SEE THE LOG"))
  label("a mod that fills a catalog of these kinds draws the screen")
  label("L hides this")
  endMenu()
