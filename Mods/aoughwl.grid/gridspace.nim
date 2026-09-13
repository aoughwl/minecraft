## Where a thing is, when a bag is a grid of cells.
##
## `aoughwl.inventory` answers *whether* - the tags a container takes, what
## it weighs, how big a stack may be, and what to call the refusal. It has no
## opinion about where anything sits, and it should not have one: a weight-only
## game has no cells at all. This module is the other half, and it is the half
## that makes an inventory feel like Tarkov: an item has a footprint in cells, a
## footprint can be turned on its side, a thing only goes where there is a hole
## the shape of it, and a container can be put inside another container and
## carried away with everything in it.
##
## The split is worth stating exactly, because it is the whole design:
##
## - the **library** owns whether. Tags, bulk, weight, stack size, and the
##   `Trouble` vocabulary a refusal is spelled in. A `Bag` keeps a real
##   `Container` behind it and asks it before it commits to anything.
## - this module owns **where**. Cells, footprints, rotation, overlap, and the
##   parent chain that makes one bag live inside another bag's cell.
##
## Nothing here draws. `gridview` does that, and a mod that wants a different
## looking inventory writes its own and keeps this.
##
## Three catalog facets are added to the ones `docs/INVENTORY.md` lists, spelled
## by the same rule - the base catalog's id plus a suffix - so a content mod
## that never calls a builder still puts its numbers where a reader looks:
##
## | facet catalog | kind | value | default |
## | --- | --- | --- | --- |
## | `<base>.shape` | `aoughwl.item.shape` | text `"5x1"` | `"1x1"` |
## | `<base>.holds` | `aoughwl.item.holds` | text: a container id | `""` |
## | `<base>.grid` | `aoughwl.container.grid` | text `"4x6"` | `"1x1"` |
##
## `shape` is the library's own facet, which it carries and never reads; this is
## the mod that reads it, and it reads it as *wide* by *tall* in cells. `holds`
## is what makes an item a container: a rig whose `holds` names a container
## definition opens a `Bag` of its own the moment it is stowed. `grid` is how
## many cells that space has.

import jester
import catalogs
import aoughwl_inventory/inventory
export inventory

# ---------------------------------------------------------------------------
# The facets this layer adds
# ---------------------------------------------------------------------------

const
  ItemHoldsKind* = "aoughwl.item.holds"
    ## The container definition an item opens when it is stowed. Text, empty
    ## when the item is not a container.
  ContainerGridKind* = "aoughwl.container.grid"
    ## How many cells a container has, as `"<wide>x<tall>"`.
  SourceKind* = "aoughwl.inventory.source"
    ## One row per catalog of definitions that anybody published, so a mod can
    ## find items another mod defined without being told the catalog's name.

  HoldsFacet* = ".holds"
  GridFacet* = ".grid"
  SourceCatalog* = "aoughwl.inventory.sources"
    ## The registry itself. Rows are catalog ids; the text is `items` or
    ## `containers`.

var extrasDeclared = false

## Say that these three kinds can exist, and that the registry catalog does.
## The first mod to call it in a session owns them and every later call is a
## no-op, so a content mod may call it defensively.
proc declareGridKinds*() =
  if extrasDeclared: return
  extrasDeclared = true
  declareInventoryKinds()
  if catalogSignature(SourceCatalog).len > 0: return
  defineCatalogKind(ItemHoldsKind, "text",
    "The container definition an item opens when it is stowed.")
  defineCatalogKind(ContainerGridKind, "text",
    "How many cells a container has, as wide by tall.")
  defineCatalogKind(SourceKind, "text",
    "A catalog of inventory definitions, and which half it holds.")
  createCatalog(SourceCatalog, SourceKind,
    "Every catalog of item or container definitions anybody published.")

# ---------------------------------------------------------------------------
# Publishing, and finding what somebody else published
# ---------------------------------------------------------------------------
#
# `useItems` is a module-level `var` inside the library, and a module-level var
# has one instance per mod that imports it - so a content mod calling
# `itemCatalog` registers its catalog with *its own* copy and the mod that draws
# the inventory never hears about it. Anything two mods must genuinely agree
# about goes through the host, so the agreement is a catalog.

proc publishItems*(catalog: string) =
  ## Tell every other mod that this catalog holds item definitions. Call it
  ## right after `itemCatalog`.
  declareGridKinds()
  useItems(catalog)
  addToCatalog(SourceCatalog, catalog, "items")

proc publishContainers*(catalog: string) =
  declareGridKinds()
  useContainers(catalog)
  addToCatalog(SourceCatalog, catalog, "containers")

## Read every catalog anybody published. A mod that draws an inventory calls
## this in `start()` and then knows about items it has never heard of.
## Answers how many catalogs it took up.
proc adoptPublished*(): int =
  declareGridKinds()
  result = 0
  if catalogSignature(SourceCatalog).len == 0: return
  for row in entries(named(SourceCatalog)):
    if row.text == "items": useItems(row.id)
    else: useContainers(row.id)
    result = result + 1

## Every item id anybody published, in the order the catalogs were published.
## This is how a mod fills a bag with things it does not have a list of.
proc publishedItems*(): seq[string] =
  result = @[]
  if catalogSignature(SourceCatalog).len == 0: return result
  for row in entries(named(SourceCatalog)):
    if row.text != "items": continue
    if catalogSignature(row.id).len == 0: continue
    for one in entries(named(row.id)):
      var already = false
      var i = 0
      while i < result.len:
        if result[i] == one.id: already = true
        i = i + 1
      if not already: result.add one.id

# ---------------------------------------------------------------------------
# Footprints
# ---------------------------------------------------------------------------

type Footprint* = object
  ## How many cells a thing takes, before anybody turns it. One by one when
  ## nobody said, because a bandage that nobody described is still a bandage.
  wide*, tall*: int

proc footprint*(wide, tall: int): Footprint =
  Footprint(wide: (if wide < 1: 1 else: wide),
    tall: (if tall < 1: 1 else: tall))

## Read `"<wide>x<tall>"`. Anything that is not that reads as one by one, which
## is what an item with no shape facet at all reads as too - a shape token is
## opaque to the library on purpose, and a token this mod cannot read is a token
## somebody else's presentation understands.
proc readFootprint*(token: string): Footprint =
  var wide = 0
  var tall = 0
  var seenX = false
  var digits = 0
  var i = 0
  while i < token.len:
    let c = token[i]
    if c >= '0' and c <= '9':
      let d = ord(c) - 48
      if seenX: tall = tall * 10 + d
      else: wide = wide * 10 + d
      digits = digits + 1
    elif (c == 'x' or c == 'X') and not seenX and digits > 0:
      seenX = true
      digits = 0
    else:
      return footprint(1, 1)
    i = i + 1
  if not seenX or digits == 0: return footprint(1, 1)
  footprint(wide, tall)

## The footprint of an item, from its `shape` facet.
proc footprintOf*(item: string): Footprint =
  readFootprint(itemOf(item).shape)

## The same footprint on its side.
proc turned*(f: Footprint): Footprint = footprint(f.tall, f.wide)

## Whether turning it changes anything. A square thing has one orientation, and
## offering to rotate it is a lie.
proc turnable*(f: Footprint): bool = f.wide != f.tall

proc cells*(f: Footprint): int = f.wide * f.tall

# ---------------------------------------------------------------------------
# What a grid container is, and what is in one
# ---------------------------------------------------------------------------

type
  Bag* = distinct int
    ## A live grid container. Zero is nothing, the way `Container`'s zero is,
    ## so a failed open reads as false without a second call.

  Entry* = object
    ## One thing sitting in a bag: a stack of one item, at a cell, possibly on
    ## its side, possibly a container in its own right.
    key*: int
      ## Its identity, unique across every space and never reused. This is what
      ## a drag carries, because the library's slot indices shift under a
      ## caller the moment anything is taken out of the middle of a container.
    item*: string
    count*: int
    column*, row*: int
    rotated*: bool
    inner*: Bag
      ## The space this thing is, when it is a container. `Bag(0)` otherwise.

const NoEntry* = Entry(key: 0, item: "", count: 0, column: -1, row: -1,
  rotated: false, inner: Bag(0))

type Held = object
  live: bool
  label: string
  definition: string
  wide, tall: int
  entries: seq[Entry]
  mirror: Container
  parent: Bag
  parentKey: int

var
  bags: seq[Held]
  nextKey = 0

proc isNothing*(s: Bag): bool = int(s) == 0
proc isSame*(a, b: Bag): bool = int(a) == int(b)
proc nowhereBag*(): Bag = Bag(0)

proc at(s: Bag): int =
  let i = int(s) - 1
  if i < 0 or i >= bags.len: return -1
  if not bags[i].live: return -1
  i

proc ok(moved, key: int): Outcome =
  Outcome(trouble: NoTrouble, moved: moved, slot: key, note: "")

## A refusal, in the library's own vocabulary plus a sentence of our own.
##
## `Trouble` has no case for "that would put a bag inside itself" and none for
## "that is off the edge of the grid", and it should not grow one for every
## presentation anybody writes - so the nearest case carries the refusal and the
## note carries the reason. A UI shows the note.
proc no(t: Trouble; note: string): Outcome =
  Outcome(trouble: t, moved: 0, slot: 0,
    note: (if note.len > 0: note else: name(t)))

# ---------------------------------------------------------------------------
# Reading the grid facet
# ---------------------------------------------------------------------------

proc facetOf(base, facet, id: string): string =
  let cat = base & facet
  if catalogSignature(cat).len == 0: return ""
  let row = named(cat).find(id)
  if not row.exists: return ""
  row.text

## How many cells this container definition has, looked for in one catalog.
proc gridIn*(catalog, definition: string): Footprint =
  let token = facetOf(catalog, GridFacet, definition)
  if token.len == 0: return footprint(1, 1)
  readFootprint(token)

var gridCatalogs: seq[string]

proc rememberGrid(catalog: string) =
  var i = 0
  while i < gridCatalogs.len:
    if gridCatalogs[i] == catalog: return
    i = i + 1
  gridCatalogs.add catalog

## How many cells this container definition has, from whichever published
## catalog names it - the last one wins, the same rule the library reads
## definitions by.
proc gridOf*(definition: string): Footprint =
  result = footprint(1, 1)
  var i = gridCatalogs.len - 1
  while i >= 0:
    let token = facetOf(gridCatalogs[i], GridFacet, definition)
    if token.len > 0: return readFootprint(token)
    i = i - 1
  if catalogSignature(SourceCatalog).len == 0: return result
  for row in entries(named(SourceCatalog)):
    if row.text != "containers": continue
    let token = facetOf(row.id, GridFacet, definition)
    if token.len > 0: return readFootprint(token)

## The container definition this item opens when it is stowed, or empty.
proc holdsOf*(item: string): string =
  result = ""
  if catalogSignature(SourceCatalog).len == 0: return result
  for row in entries(named(SourceCatalog)):
    if row.text != "items": continue
    let token = facetOf(row.id, HoldsFacet, item)
    if token.len > 0: result = token

# ---------------------------------------------------------------------------
# Defining
# ---------------------------------------------------------------------------

## An item catalog, published so other mods can find it, with the two extra
## facet catalogs this layer reads.
proc gridItemCatalog*(id: string; description = ""): Catalog =
  declareGridKinds()
  let c = itemCatalog(id, description)
  createCatalog(id & HoldsFacet, ItemHoldsKind, "What " & id & " opens")
  publishItems(id)
  c

proc gridContainerCatalog*(id: string; description = ""): Catalog =
  declareGridKinds()
  let c = containerCatalog(id, description)
  createCatalog(id & GridFacet, ContainerGridKind, "Cells for " & id)
  rememberGrid(id)
  publishContainers(id)
  c

## One item, with a footprint and - when it is a container - the definition it
## opens. Everything else is the library's own `defineItem`.
proc defineThing*(c: Catalog; id, display: string; shape = "1x1"; stack = 1;
    weight = 0.0; bulk = 1.0; tags = ""; holds = "") =
  defineItem(c, id, display, stack = stack, bulk = bulk, weight = weight,
    shape = shape, tags = tags)
  addToCatalog(name(c) & HoldsFacet, id, holds)

## One container definition, with its cells.
proc defineBag*(c: Catalog; id, display: string; grid = "1x1";
    load = -1.0; capacity = -1.0; accepts = ""; rejects = "") =
  defineContainer(c, id, display, slots = -1, capacity = capacity, load = load,
    accepts = accepts, rejects = rejects)
  addToCatalog(name(c) & GridFacet, id, grid)
  rememberGrid(name(c))

# ---------------------------------------------------------------------------
# Opening and closing
# ---------------------------------------------------------------------------

proc openIn(d: Holder; wide, tall: int; label: string; parent: Bag;
    parentKey: int): Bag =
  let mirror = openHolder(d, label)
  bags.add Held(live: true, label: (if label.len > 0: label else: d.display),
    definition: d.id, wide: wide, tall: tall, entries: @[], mirror: mirror,
    parent: parent, parentKey: parentKey)
  Bag(bags.len)

## Open a grid container from a definition in any published catalog.
proc openBag*(definition: string; label = ""): Bag =
  declareGridKinds()
  let d = holderOf(definition)
  if not d.known: return Bag(0)
  let f = gridOf(definition)
  openIn(d, f.wide, f.tall, label, Bag(0), 0)

## Open one from a definition a mod built itself and a size it chose - a ground
## pile, a corpse, a vendor's stall. Nothing has to be in a catalog to be a bag.
proc openGrid*(d: Holder; wide, tall: int; label = ""): Bag =
  declareGridKinds()
  openIn(d, wide, tall, label, Bag(0), 0)

proc bagLive*(s: Bag): bool = at(s) >= 0

proc bagWide*(s: Bag): int =
  let i = at(s)
  if i < 0: return 0
  bags[i].wide

proc bagTall*(s: Bag): int =
  let i = at(s)
  if i < 0: return 0
  bags[i].tall

proc bagLabel*(s: Bag): string =
  let i = at(s)
  if i < 0: return ""
  bags[i].label

proc bagDefinition*(s: Bag): string =
  let i = at(s)
  if i < 0: return ""
  bags[i].definition

## The container underneath, for anything the library answers and this does not.
proc bagContainer*(s: Bag): Container =
  let i = at(s)
  if i < 0: return nothingContainer()
  bags[i].mirror

proc bagParent*(s: Bag): Bag =
  let i = at(s)
  if i < 0: return Bag(0)
  bags[i].parent

proc entryCount*(s: Bag): int =
  let i = at(s)
  if i < 0: return 0
  bags[i].entries.len

proc entryAt*(s: Bag; index: int): Entry =
  let i = at(s)
  if i < 0: return NoEntry
  if index < 0 or index >= bags[i].entries.len: return NoEntry
  bags[i].entries[index]

proc indexOfKey(i: int; key: int): int =
  result = -1
  var j = 0
  while j < bags[i].entries.len:
    if bags[i].entries[j].key == key: result = j
    j = j + 1

## The entry with this key, in this space. `key` of zero when there is none.
proc entryOf*(s: Bag; key: int): Entry =
  let i = at(s)
  if i < 0: return NoEntry
  let j = indexOfKey(i, key)
  if j < 0: return NoEntry
  bags[i].entries[j]

## How the entry sits right now, its rotation taken into account.
proc footprintOn*(e: Entry): Footprint =
  let f = footprintOf(e.item)
  if e.rotated: turned(f) else: f

# ---------------------------------------------------------------------------
# Nesting
# ---------------------------------------------------------------------------

## Whether `inner` is `outer`, or sits somewhere inside it. Walking up is the
## cheap direction, and it is the direction the question is always asked in: may
## this thing go in there.
proc within*(inner, outer: Bag): bool =
  if isNothing(inner) or isNothing(outer): return false
  var walk = inner
  var guard = 0
  while not isNothing(walk) and guard < 64:
    if isSame(walk, outer): return true
    walk = bagParent(walk)
    guard = guard + 1
  false

## Everything in a space weighs, its containers' contents included. The library
## counts a container's weight as the weight of the container, because it has no
## idea one container can be inside another; this is the arithmetic that makes a
## full rig heavier than an empty one.
proc weightIn*(s: Bag): float64 =
  let i = at(s)
  result = 0.0
  if i < 0: return result
  var j = 0
  while j < bags[i].entries.len:
    let e = bags[i].entries[j]
    result = result + itemOf(e.item).weight * float64(e.count)
    if not isNothing(e.inner): result = result + weightIn(e.inner)
    j = j + 1

proc cellsTotal*(s: Bag): int =
  let i = at(s)
  if i < 0: return 0
  bags[i].wide * bags[i].tall

proc bulkIn*(s: Bag): float64 =
  let i = at(s)
  result = 0.0
  if i < 0: return result
  var j = 0
  while j < bags[i].entries.len:
    let e = bags[i].entries[j]
    result = result + itemOf(e.item).bulk * float64(e.count)
    if not isNothing(e.inner): result = result + bulkIn(e.inner)
    j = j + 1

## How many cells are covered, out of how many there are.
proc cellsUsed*(s: Bag): int =
  let i = at(s)
  result = 0
  if i < 0: return result
  var j = 0
  while j < bags[i].entries.len:
    result = result + cells(footprintOn(bags[i].entries[j]))
    j = j + 1

# ---------------------------------------------------------------------------
# Packing
# ---------------------------------------------------------------------------

proc onGrid(i: int; column, row, wide, tall: int): bool =
  column >= 0 and row >= 0 and column + wide <= bags[i].wide and
    row + tall <= bags[i].tall

proc overlapping(i: int; column, row, wide, tall, ignore: int): bool =
  result = false
  var j = 0
  while j < bags[i].entries.len:
    let e = bags[i].entries[j]
    if e.key != ignore:
      let f = footprintOn(e)
      let apart = column + wide <= e.column or e.column + f.wide <= column or
        row + tall <= e.row or e.row + f.tall <= row
      if not apart: result = true
    j = j + 1

## Whether a block of that size would sit at that cell with nothing in the way.
## `ignore` is an entry key that does not count as being in the way, which is
## what makes turning a thing where it stands, or nudging it one cell, a
## question this can answer.
proc roomAt*(s: Bag; column, row, wide, tall: int; ignore = 0): bool =
  let i = at(s)
  if i < 0: return false
  if not onGrid(i, column, row, wide, tall): return false
  not overlapping(i, column, row, wide, tall, ignore)

type Spot* = object
  ## Where something would go, and which way round. `found` is false when it
  ## would not go anywhere at all.
  column*, row*: int
  rotated*: bool
  found*: bool

const NoSpot* = Spot(column: -1, row: -1, rotated: false, found: false)

## The first cell a footprint of that size fits, reading the grid the way a
## page is read. Tries it the way up it was given first and on its side second,
## because a player who laid a rifle down flat expects it to stay flat.
proc spotFor*(s: Bag; f: Footprint; ignore = 0): Spot =
  let i = at(s)
  result = NoSpot
  if i < 0: return result
  var turn = 0
  while turn < 2:
    var shape = f
    if turn == 1: shape = turned(f)
    if turn == 0 or turnable(f):
      var r = 0
      while r + shape.tall <= bags[i].tall:
        var c = 0
        while c + shape.wide <= bags[i].wide:
          if not overlapping(i, c, r, shape.wide, shape.tall, ignore):
            return Spot(column: c, row: r, rotated: turn == 1, found: true)
          c = c + 1
        r = r + 1
    turn = turn + 1

## Which entry covers this cell, or zero. What a click on a cell reads.
proc keyAtCell*(s: Bag; column, row: int): int =
  let i = at(s)
  result = 0
  if i < 0: return result
  var j = 0
  while j < bags[i].entries.len:
    let e = bags[i].entries[j]
    let f = footprintOn(e)
    if column >= e.column and column < e.column + f.wide and
       row >= e.row and row < e.row + f.tall: result = e.key
    j = j + 1

# ---------------------------------------------------------------------------
# Asking before doing
# ---------------------------------------------------------------------------

## What stops this many of this item going into this space at all - tags,
## weight, bulk, and whether anybody defined it. Cells are a separate question,
## because a bag can have room in it and no hole the right shape.
##
## `extraWeight` and `extraBulk` are what the thing brings with it: a rig that
## is already full weighs what it weighs plus what is in it, and the library
## cannot know that because it does not know a container can hold a container.
proc troubleTaking*(s: Bag; item: string; count: int;
    extraWeight = 0.0; extraBulk = 0.0): Trouble =
  let i = at(s)
  if i < 0: return NoSuchContainer
  let flat = troubleWith(bags[i].mirror, item, count)
  if flat != NoTrouble: return flat
  let d = containerDefinition(bags[i].mirror)
  let it = itemOf(item)
  if d.load >= 0.0:
    if weightIn(s) + it.weight * float64(count) + extraWeight > d.load:
      return TooHeavy
  if d.capacity >= 0.0:
    if bulkIn(s) + it.bulk * float64(count) + extraBulk > d.capacity:
      return NoRoom
  NoTrouble

proc roomFor*(s: Bag; item: string; count = 1): bool =
  troubleTaking(s, item, count) == NoTrouble

# ---------------------------------------------------------------------------
# Doing
# ---------------------------------------------------------------------------

proc openInner(item: string; parent: Bag; key: int): Bag =
  ## A container item gets a space of its own the moment it is stowed. An item
  ## that names a definition nobody defined gets none, and is a plain thing.
  let definition = holdsOf(item)
  if definition.len == 0: return Bag(0)
  let d = holderOf(definition)
  if not d.known: return Bag(0)
  let f = gridOf(definition)
  openIn(d, f.wide, f.tall, d.display, parent, key)

proc reparent(s: Bag; parent: Bag; key: int) =
  let i = at(s)
  if i < 0: return
  var b = bags[i]
  b.parent = parent
  b.parentKey = key
  bags[i] = b

## Put a stack at a named cell, the way up you say. Nothing happens unless all
## of it happens: the space is asked about the tags, the weight and the bulk,
## and the cells are asked about the hole, before anything is written down.
proc stowAt*(s: Bag; item: string; count: int; column, row: int;
    rotated = false): Outcome =
  let i = at(s)
  if i < 0: return no(NoSuchContainer, "")
  if count < 1: return no(BadCount, "")
  let why = troubleTaking(s, item, count)
  if why != NoTrouble: return no(why, "")
  var f = footprintOf(item)
  if rotated: f = turned(f)
  if not onGrid(i, column, row, f.wide, f.tall):
    return no(NoRoom, "a " & $f.wide & " by " & $f.tall &
      " thing does not fit on a " & $bags[i].wide & " by " & $bags[i].tall &
      " grid at " & $column & "," & $row)
  if overlapping(i, column, row, f.wide, f.tall, 0):
    return no(NoRoom, "something is already there")
  let put0 = put(bags[i].mirror, item, count)
  if not went(put0): return no(put0.trouble, put0.note)
  nextKey = nextKey + 1
  let key = nextKey
  var b = bags[i]
  b.entries.add Entry(key: key, item: item, count: count, column: column,
    row: row, rotated: rotated, inner: Bag(0))
  bags[i] = b
  let inner = openInner(item, s, key)
  if not isNothing(inner):
    let j = indexOfKey(i, key)
    var b2 = bags[i]
    var e = b2.entries[j]
    e.inner = inner
    b2.entries[j] = e
    bags[i] = b2
  ok(count, key)

## Put a stack wherever it will go, turning it if that is what it takes.
proc stow*(s: Bag; item: string; count = 1): Outcome =
  let i = at(s)
  if i < 0: return no(NoSuchContainer, "")
  if count < 1: return no(BadCount, "")
  let why = troubleTaking(s, item, count)
  if why != NoTrouble: return no(why, "")
  let spot = spotFor(s, footprintOf(item))
  if not spot.found:
    return no(NoRoom, "no hole the shape of " & itemOf(item).display &
      " anywhere in " & bags[i].label)
  stowAt(s, item, count, spot.column, spot.row, spot.rotated)

proc dropEntry(i, j: int) =
  var b = bags[i]
  var k = j
  while k + 1 < b.entries.len:
    let next = b.entries[k + 1]
    b.entries[k] = next
    k = k + 1
  b.entries.setLen(b.entries.len - 1)
  bags[i] = b

## Close a space, and every space inside it. Handles never come back, so a stale
## one reads as `NoSuchContainer` rather than as somebody else's bag.
proc closeBag*(s: Bag): Outcome =
  let i = at(s)
  if i < 0: return no(NoSuchContainer, "")
  let held = bags[i].entries.len
  var j = 0
  while j < bags[i].entries.len:
    let inner = bags[i].entries[j].inner
    if not isNothing(inner): discard closeBag(inner)
    j = j + 1
  var b = bags[i]
  b.live = false
  b.entries = @[]
  bags[i] = b
  discard closeContainer(b.mirror)
  ok(held, 0)

## Take a thing out and let it go. A container taken out takes its contents with
## it, which here means they stop existing along with it - a caller that wants
## them kept moves the entry somewhere instead.
proc lift*(s: Bag; key: int): Outcome =
  let i = at(s)
  if i < 0: return no(NoSuchContainer, "")
  let j = indexOfKey(i, key)
  if j < 0: return no(NoSuchStack, "nothing here has that key")
  let e = bags[i].entries[j]
  discard take(bags[i].mirror, e.item, e.count)
  if not isNothing(e.inner): discard closeBag(e.inner)
  dropEntry(i, j)
  ok(e.count, key)

## Turn a thing where it stands. Refused when the space it would then take is
## not free, which is the rule that makes rotation feel like a real constraint
## rather than a cosmetic flag.
proc turn*(s: Bag; key: int): Outcome =
  let i = at(s)
  if i < 0: return no(NoSuchContainer, "")
  let j = indexOfKey(i, key)
  if j < 0: return no(NoSuchStack, "nothing here has that key")
  var e = bags[i].entries[j]
  let f = footprintOf(e.item)
  if not turnable(f): return no(Nowhere, "a square thing has one way up")
  var next = f
  if not e.rotated: next = turned(f)
  if not onGrid(i, e.column, e.row, next.wide, next.tall):
    return no(NoRoom, "turning it would put it off the grid")
  if overlapping(i, e.column, e.row, next.wide, next.tall, key):
    return no(NoRoom, "something is in the way of turning it")
  e.rotated = not e.rotated
  var b = bags[i]
  b.entries[j] = e
  bags[i] = b
  ok(e.count, key)

## Move a thing to a cell, in this space or another one. Either it lands and
## leaves, or neither: the target is asked about the tags, the weight, the
## nesting and the hole before the source is touched at all.
##
## Moving a container moves what is in it. The contents live in the container's
## own space and that space travels with the entry, so this is not a special
## case in the arithmetic - it is a special case only in what it must refuse,
## which is putting a bag inside itself.
proc moveTo*(source: Bag; key: int; target: Bag; column, row: int;
    rotated = false): Outcome =
  let from0 = at(source)
  let to0 = at(target)
  if from0 < 0 or to0 < 0: return no(NoSuchContainer, "")
  let j = indexOfKey(from0, key)
  if j < 0: return no(NoSuchStack, "nothing here has that key")
  let e = bags[from0].entries[j]
  if not isNothing(e.inner):
    if within(target, e.inner):
      return no(Nowhere, itemOf(e.item).display &
        " cannot be put inside itself")
  var f = footprintOf(e.item)
  if rotated: f = turned(f)
  let sameSpace = from0 == to0
  if not sameSpace:
    let carriedWeight = (if isNothing(e.inner): 0.0 else: weightIn(e.inner))
    let carriedBulk = (if isNothing(e.inner): 0.0 else: bulkIn(e.inner))
    let why = troubleTaking(target, e.item, e.count, carriedWeight, carriedBulk)
    if why != NoTrouble: return no(why, "")
  if not onGrid(to0, column, row, f.wide, f.tall):
    return no(NoRoom, "a " & $f.wide & " by " & $f.tall &
      " thing does not fit on a " & $bags[to0].wide & " by " &
      $bags[to0].tall & " grid at " & $column & "," & $row)
  if overlapping(to0, column, row, f.wide, f.tall, key):
    return no(NoRoom, "something is already there")
  if sameSpace:
    var b = bags[from0]
    var moved = b.entries[j]
    moved.column = column
    moved.row = row
    moved.rotated = rotated
    b.entries[j] = moved
    bags[from0] = b
    return ok(e.count, key)
  discard take(bags[from0].mirror, e.item, e.count)
  dropEntry(from0, j)
  let landed = put(bags[to0].mirror, e.item, e.count)
  if not went(landed):
    # The target was asked and said yes; if it says no now the two answers
    # disagree, and putting the thing back where it came from is the only
    # honest thing left to do.
    discard put(bags[from0].mirror, e.item, e.count)
    var back = bags[from0]
    back.entries.add e
    bags[from0] = back
    return no(landed.trouble, landed.note)
  var moved = e
  moved.column = column
  moved.row = row
  moved.rotated = rotated
  var b = bags[to0]
  b.entries.add moved
  bags[to0] = b
  if not isNothing(moved.inner): reparent(moved.inner, target, key)
  ok(e.count, key)

## Move it wherever it will go in the target, turning it if that is what it
## takes. What a "send this over there" button does.
proc sendTo*(source: Bag; key: int; target: Bag): Outcome =
  let from0 = at(source)
  if from0 < 0: return no(NoSuchContainer, "")
  let j = indexOfKey(from0, key)
  if j < 0: return no(NoSuchStack, "nothing here has that key")
  let e = bags[from0].entries[j]
  let ignore = (if isSame(source, target): key else: 0)
  let spot = spotFor(target, footprintOf(e.item), ignore)
  if not spot.found:
    return no(NoRoom, "no hole the shape of " & itemOf(e.item).display &
      " in " & bagLabel(target))
  moveTo(source, key, target, spot.column, spot.row, spot.rotated)

## Cut a stack in two, the new half placed wherever it will go. Refused when
## there is nowhere for it, and refused when it would leave nothing behind,
## because a split that takes all of it is a move.
proc splitOff*(s: Bag; key, count: int): Outcome =
  let i = at(s)
  if i < 0: return no(NoSuchContainer, "")
  if count < 1: return no(BadCount, "")
  let j = indexOfKey(i, key)
  if j < 0: return no(NoSuchStack, "nothing here has that key")
  var e = bags[i].entries[j]
  if not isNothing(e.inner):
    return no(Nowhere, "a container is one thing and does not split")
  if count >= e.count: return no(NotEnough, "a split has to leave something behind")
  let spot = spotFor(s, footprintOf(e.item), 0)
  if not spot.found: return no(NoRoom, "nowhere to put the other half")
  e.count = e.count - count
  var b = bags[i]
  b.entries[j] = e
  bags[i] = b
  nextKey = nextKey + 1
  let fresh = nextKey
  var b2 = bags[i]
  b2.entries.add Entry(key: fresh, item: e.item, count: count,
    column: spot.column, row: spot.row, rotated: spot.rotated,
    inner: Bag(0))
  bags[i] = b2
  ok(count, fresh)

## Pour one stack onto another of the same item, as far as the item's own stack
## size allows. The source goes when it empties, which is why this answers with
## a count and not a yes.
proc mergeInto*(s: Bag; key, onto: int): Outcome =
  let i = at(s)
  if i < 0: return no(NoSuchContainer, "")
  if key == onto: return no(Nowhere, "")
  let a = indexOfKey(i, key)
  let b0 = indexOfKey(i, onto)
  if a < 0 or b0 < 0: return no(NoSuchStack, "nothing here has that key")
  var source = bags[i].entries[a]
  var target = bags[i].entries[b0]
  if source.item != target.item:
    return no(NotAccepted, "those are not the same thing")
  if not isNothing(source.inner) or not isNothing(target.inner):
    return no(Nowhere, "two containers do not pour into one another")
  let it = itemOf(source.item)
  let per = (if it.stack < 1: 1 else: it.stack)
  let room = per - target.count
  if room < 1: return no(NoRoom, "that stack is already full")
  var moved = room
  if source.count < moved: moved = source.count
  target.count = target.count + moved
  source.count = source.count - moved
  var bag = bags[i]
  bag.entries[b0] = target
  if source.count < 1:
    bag.entries[a] = source
    bags[i] = bag
    dropEntry(i, a)
  else:
    bag.entries[a] = source
    bags[i] = bag
  ok(moved, onto)

## Pour one stack onto another of the same item, wherever the two of them are.
## Within one space that is `mergeInto`; across two it is a move of as much as
## the target stack has room for, asked of the target before the source is drawn
## down, exactly like any other move.
proc pourOnto*(source: Bag; key: int; target: Bag; onto: int): Outcome =
  if isSame(source, target): return mergeInto(source, key, onto)
  let from0 = at(source)
  let to0 = at(target)
  if from0 < 0 or to0 < 0: return no(NoSuchContainer, "")
  let a = indexOfKey(from0, key)
  let b0 = indexOfKey(to0, onto)
  if a < 0 or b0 < 0: return no(NoSuchStack, "nothing here has that key")
  var give = bags[from0].entries[a]
  var takeOn = bags[to0].entries[b0]
  if give.item != takeOn.item:
    return no(NotAccepted, "those are not the same thing")
  if not isNothing(give.inner) or not isNothing(takeOn.inner):
    return no(Nowhere, "two containers do not pour into one another")
  let it = itemOf(give.item)
  let per = (if it.stack < 1: 1 else: it.stack)
  let room = per - takeOn.count
  if room < 1: return no(NoRoom, "that stack is already full")
  var moved = room
  if give.count < moved: moved = give.count
  let why = troubleTaking(target, give.item, moved)
  if why != NoTrouble: return no(why, "")
  discard take(bags[from0].mirror, give.item, moved)
  let landed = put(bags[to0].mirror, give.item, moved)
  if not went(landed):
    discard put(bags[from0].mirror, give.item, moved)
    return no(landed.trouble, landed.note)
  takeOn.count = takeOn.count + moved
  give.count = give.count - moved
  var bagTo = bags[to0]
  bagTo.entries[b0] = takeOn
  bags[to0] = bagTo
  var bagFrom = bags[from0]
  bagFrom.entries[a] = give
  bags[from0] = bagFrom
  if give.count < 1: dropEntry(from0, a)
  ok(moved, onto)

## Everything in a space, in the order it was put there.
iterator contentsOf*(s: Bag): Entry {.sideEffect.} =
  let i = at(s)
  if i >= 0:
    var j = 0
    while j < bags[i].entries.len:
      yield bags[i].entries[j]
      j = j + 1

## Where everything is, in one line, so a headless run reads an arrangement back
## instead of a picture of it. Nested spaces are written in brackets.
proc arrangementOf*(s: Bag): string =
  let i = at(s)
  result = ""
  if i < 0: return result
  var j = 0
  while j < bags[i].entries.len:
    if j > 0: result = result & " "
    let e = bags[i].entries[j]
    result = result & e.item & "@" & $e.column & "," & $e.row
    let f = footprintOn(e)
    result = result & "/" & $f.wide & "x" & $f.tall
    if e.count > 1: result = result & "*" & $e.count
    if not isNothing(e.inner):
      result = result & "[" & arrangementOf(e.inner) & "]"
    j = j + 1
