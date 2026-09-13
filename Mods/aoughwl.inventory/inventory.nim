## What an inventory is, before anybody decides what one looks like.
##
## Two halves. The first is a set of catalog kinds - what an item is, what a
## container is - so a mod can add a bandage or a backpack without knowing that
## anything will ever draw them. The second is the arithmetic: containers that
## hold stacks, and the handful of operations that move stacks between them,
## each answering with an `Outcome` rather than throwing, because a raise in a
## mod is a dead interpreter slot and a dead session.
##
## Nothing here knows about grids, cells, rotation, screens, pointers or any
## particular game. An item's shape is an opaque token this library never reads;
## room is counted as `bulk`, which a presentation layer may interpret as area,
## volume, or one-per-slot. Whoever draws the inventory decides what a shape is;
## whoever plays it decides what fits.
##
## The two halves meet at the catalogs. A content mod fills them:
##
##   let kit = itemCatalog("survival.items", "Things to carry")
##   kit.defineItem("bandage", "Bandage", stack = 4, bulk = 1.0, weight = 0.1,
##                  shape = "1x1", tags = "medical small")
##
##   let bags = containerCatalog("survival.containers", "Things to carry in")
##   bags.defineContainer("pouch", "Belt pouch", slots = 2, capacity = 4.0,
##                        accepts = "medical")
##
## and a mod that runs an inventory opens one and works it:
##
##   let pouch = openContainer("survival.containers", "pouch", "belt")
##   if not put(pouch, "bandage", 4).went: ...
##
## This is a module rather than the mod's `main.nim` because it is the file that
## wants to be `ModSdk/inventory.nim` the day one mod can import another. Until
## then a consumer mod reaches this layer through the catalogs, which carry
## data, and not through these procs, which it cannot name. See docs/INVENTORY.md.

import jester
import catalogs

# ---------------------------------------------------------------------------
# The kinds, and the facets that make one definition out of several catalogs
# ---------------------------------------------------------------------------

## A catalog holds one kind of value, so a definition with a name, a number and
## a tag list is not one catalog - it is a base catalog of names plus a facet
## catalog per field, all keyed by the same item id. The facet's catalog id is
## the base's plus a suffix, which is a spelling rule and not a guess: a mod
## that never calls `defineItem` still puts its numbers where a reader looks.
const
  ItemKind* = "aoughwl.item"
    ## Base: an item id and what to call it. Text.
  ItemStackKind* = "aoughwl.item.stack"
    ## How many units one stack of it may hold. Integer, 1 means never stacks.
  ItemBulkKind* = "aoughwl.item.bulk"
    ## How much room one unit takes, in whatever unit a container counts in.
  ItemWeightKind* = "aoughwl.item.weight"
    ## What one unit weighs.
  ItemShapeKind* = "aoughwl.item.shape"
    ## An opaque token for whoever draws it. Never read here.
  ItemTagKind* = "aoughwl.item.tags"
    ## Space separated tags, which is the only thing a container filters on.

  ContainerKind* = "aoughwl.container"
    ## Base: a container id and what to call it. Text.
  ContainerSlotKind* = "aoughwl.container.slots"
    ## Most stacks it may hold at once. Integer, below zero means no limit.
  ContainerCapacityKind* = "aoughwl.container.capacity"
    ## Most bulk it may hold. Below zero means no limit.
  ContainerLoadKind* = "aoughwl.container.load"
    ## Most weight it may hold. Below zero means no limit.
  ContainerAcceptKind* = "aoughwl.container.accepts"
    ## Tags it takes. Empty takes anything.
  ContainerRejectKind* = "aoughwl.container.rejects"
    ## Tags it refuses, checked after `accepts`.

  StackFacet* = ".stack"
  BulkFacet* = ".bulk"
  WeightFacet* = ".weight"
  ShapeFacet* = ".shape"
  TagFacet* = ".tags"
  SlotFacet* = ".slots"
  CapacityFacet* = ".capacity"
  LoadFacet* = ".load"
  AcceptFacet* = ".accepts"
  RejectFacet* = ".rejects"

const KindsDeclared* = "aoughwl.inventory.kinds"
  ## A catalog created alongside the kinds and never read, so that a second mod
  ## can find out that a first one already declared them. There is no host call
  ## that asks whether a *kind* exists, and `defineCatalogKind` on a kind
  ## another mod owns does not answer no - it raises inside the host, which
  ## takes the calling mod's interpreter slot with it. So the question is asked
  ## of a catalog, which can be asked, exactly the way `ensureCatalog` in the
  ## SDK asks it.

var kindsDeclared = false

## Say that these kinds of catalog can exist. The first mod to call this in a
## session owns them; every later caller is a no-op, so a content mod may call
## it defensively rather than depending on load order.
proc declareInventoryKinds*() =
  if kindsDeclared: return
  kindsDeclared = true
  if catalogSignature(KindsDeclared).len > 0: return
  defineCatalogKind(ItemKind, "text",
    "Something that can be held, carried or stored, and what to call it.")
  defineCatalogKind(ItemStackKind, "integer",
    "How many units of an item one stack may hold.")
  defineCatalogKind(ItemBulkKind, "number",
    "How much room one unit of an item takes.")
  defineCatalogKind(ItemWeightKind, "number",
    "What one unit of an item weighs.")
  defineCatalogKind(ItemShapeKind, "text",
    "An item's shape, as a token only a presentation layer reads.")
  defineCatalogKind(ItemTagKind, "text",
    "An item's tags, space separated.")
  defineCatalogKind(ContainerKind, "text",
    "Something that holds items, and what to call it.")
  defineCatalogKind(ContainerSlotKind, "integer",
    "Most stacks a container may hold. Below zero is no limit.")
  defineCatalogKind(ContainerCapacityKind, "number",
    "Most bulk a container may hold. Below zero is no limit.")
  defineCatalogKind(ContainerLoadKind, "number",
    "Most weight a container may hold. Below zero is no limit.")
  defineCatalogKind(ContainerAcceptKind, "text",
    "The tags a container takes. Empty takes anything.")
  defineCatalogKind(ContainerRejectKind, "text",
    "The tags a container refuses.")
  createCatalog(KindsDeclared, ItemKind,
    "That the inventory kinds are declared, and by whom.")

# ---------------------------------------------------------------------------
# What a definition reads as
# ---------------------------------------------------------------------------

type
  Item* = object
    ## One item definition, gathered from a base catalog and its facets.
    id*: string
    display*: string
    stack*: int
    bulk*: float64
    weight*: float64
    shape*: string
    tags*: string
    known*: bool
      ## False when no registered catalog names this id, which is the only way
      ## a caller finds out that a mod asked for something nobody defined.

  Holder* = object
    ## One container definition. Every limit below zero means no limit, so a
    ## container nobody bothered to describe holds anything, which is the right
    ## default for a sandbox and the wrong one for a game - so a game says so.
    id*: string
    display*: string
    slots*: int
    capacity*: float64
    load*: float64
    accepts*: string
    rejects*: string
    known*: bool

  Stack* = object
    ## One pile of one item inside a container.
    item*: string
    count*: int

  Container* = distinct int
    ## A live container this library holds. Zero is nothing, the way an Entity's
    ## zero is nothing, so a failed open reads as false without a second call.

  Trouble* = enum
    ## Why an operation did nothing. Every operation answers with one of these
    ## and never raises: the interpreter turns a raise into an abandoned mod
    ## slot that answers nothing for the rest of the session.
    NoTrouble
    NoSuchContainer
    NoSuchStack
    UnknownItem
    NotAccepted
    NoRoom
    TooHeavy
    NotEnough
    Nowhere
    BadCount

  Outcome* = object
    ## What an operation did. `moved` is units, and it is zero for everything
    ## that refused; there is no partial answer to a refusal.
    trouble*: Trouble
    moved*: int
    slot*: int
    note*: string

proc went*(o: Outcome): bool = o.trouble == NoTrouble
  ## Whether it happened. `if not put(bag, "bandage").went:` is the shape.

## The trouble in words. Spelled `name` and not `$` because a user-defined `$`
## on an enum is silently ignored by this interpreter and the identifier is
## printed instead.
proc name*(t: Trouble): string =
  case t
  of NoTrouble: "fine"
  of NoSuchContainer: "no such container"
  of NoSuchStack: "no such stack"
  of UnknownItem: "no mod defines that item"
  of NotAccepted: "this container does not take that"
  of NoRoom: "no room"
  of TooHeavy: "too heavy"
  of NotEnough: "not that many there"
  of Nowhere: "nothing to do"
  of BadCount: "count must be one or more"

proc isNothing*(c: Container): bool = int(c) == 0
proc isSame*(a, b: Container): bool = int(a) == int(b)
proc nothingContainer*(): Container = Container(0)

proc fine(moved, slot: int): Outcome =
  Outcome(trouble: NoTrouble, moved: moved, slot: slot, note: "")

proc refused(t: Trouble; note = ""): Outcome =
  Outcome(trouble: t, moved: 0, slot: -1, note: (if note.len > 0: note else: name(t)))

# ---------------------------------------------------------------------------
# Tags: a space separated list, matched without cutting the string up
# ---------------------------------------------------------------------------

## Whether `tags` holds the word sitting at `at` for `length` characters in
## `word`. Written as an index walk because a mod cannot take a string apart -
## `charToString` is unreachable, so there is no substring to compare.
proc holdsWord(tags, word: string; at, length: int): bool =
  if length <= 0: return false
  if length > tags.len: return false
  var i = 0
  while i + length <= tags.len:
    var j = 0
    var same = true
    while j < length:
      if tags[i + j] != word[at + j]:
        same = false
        break
      inc j
    if same:
      var ends = i + length == tags.len
      if not ends: ends = tags[i + length] == ' '
      var begins = i == 0
      if not begins: begins = tags[i - 1] == ' '
      if ends and begins: return true
    inc i
  false

## Whether a space separated tag list holds this exact tag.
proc tagged*(tags, tag: string): bool = holdsWord(tags, tag, 0, tag.len)

## Whether a tag list holds any of the tags in a second list. An empty `wanted`
## is not "none of them", it is "no opinion", and the callers below read it so.
proc taggedAny*(tags, wanted: string): bool =
  var start = 0
  var i = 0
  while i <= wanted.len:
    var boundary = i == wanted.len
    if not boundary: boundary = wanted[i] == ' '
    if boundary:
      if i > start:
        if holdsWord(tags, wanted, start, i - start): return true
      start = i + 1
    inc i
  false

# ---------------------------------------------------------------------------
# Reading definitions out of catalogs
# ---------------------------------------------------------------------------

var
  itemCatalogs: seq[string]
  holderCatalogs: seq[string]

proc listed(list: seq[string]; id: string): bool =
  var i = 0
  while i < list.len:
    if list[i] == id: return true
    inc i
  false

## Read item definitions out of this catalog too. Later registrations win, so a
## modpack can put a catalog in front of one a dependency published without
## either of them knowing about the other.
proc useItems*(catalog: string) =
  if not listed(itemCatalogs, catalog): itemCatalogs.add catalog

## The same for container definitions.
proc useContainers*(catalog: string) =
  if not listed(holderCatalogs, catalog): holderCatalogs.add catalog

## Stop reading one. A mod unloading takes its catalogs with it, so this is for
## a mod that changes its mind, not for cleanup.
proc dropItems*(catalog: string) =
  var i = 0
  while i < itemCatalogs.len:
    if itemCatalogs[i] == catalog:
      var j = i
      while j + 1 < itemCatalogs.len:
        let next = itemCatalogs[j + 1]
        itemCatalogs[j] = next
        inc j
      itemCatalogs.setLen(itemCatalogs.len - 1)
      return
    inc i

proc dropContainers*(catalog: string) =
  var i = 0
  while i < holderCatalogs.len:
    if holderCatalogs[i] == catalog:
      var j = i
      while j + 1 < holderCatalogs.len:
        let next = holderCatalogs[j + 1]
        holderCatalogs[j] = next
        inc j
      holderCatalogs.setLen(holderCatalogs.len - 1)
      return
    inc i

## Whether a catalog is there at all. A read against one nobody created is a
## failed host call, and a failed host call hands back a nil that pretends to be
## a value - so every read below is gated on this rather than on its answer.
proc catalogPresent*(id: string): bool = catalogSignature(id).len > 0

proc facetText(base, facet, id, fallback: string): string =
  let cat = base & facet
  if not catalogPresent(cat): return fallback
  let row = named(cat).find(id)
  if not row.exists: return fallback
  row.text

proc facetNumber(base, facet, id: string; fallback: float64): float64 =
  let cat = base & facet
  if not catalogPresent(cat): return fallback
  let row = named(cat).find(id)
  if not row.exists: return fallback
  row.number

proc facetInteger(base, facet, id: string; fallback: int): int =
  let cat = base & facet
  if not catalogPresent(cat): return fallback
  let row = named(cat).find(id)
  if not row.exists: return fallback
  int(row.integer)

## The item this id names, from the last registered catalog that has it.
## `known` is false and every field is its default when nobody does.
proc itemOf*(id: string): Item =
  result = Item(id: id, display: id, stack: 1, bulk: 1.0, weight: 0.0,
    shape: "", tags: "", known: false)
  var i = itemCatalogs.len - 1
  while i >= 0:
    let base = itemCatalogs[i]
    if catalogPresent(base):
      let row = named(base).find(id)
      if row.exists:
        result.known = true
        result.display = row.text
        result.stack = facetInteger(base, StackFacet, id, 1)
        result.bulk = facetNumber(base, BulkFacet, id, 1.0)
        result.weight = facetNumber(base, WeightFacet, id, 0.0)
        result.shape = facetText(base, ShapeFacet, id, "")
        result.tags = facetText(base, TagFacet, id, "")
        if result.stack < 1: result.stack = 1
        if result.bulk < 0.0: result.bulk = 0.0
        return
    dec i

## The container definition this id names, looked for in one catalog.
proc holderIn*(catalog, id: string): Holder =
  result = Holder(id: id, display: id, slots: -1, capacity: -1.0, load: -1.0,
    accepts: "", rejects: "", known: false)
  if not catalogPresent(catalog): return
  let row = named(catalog).find(id)
  if not row.exists: return
  result.known = true
  result.display = row.text
  result.slots = facetInteger(catalog, SlotFacet, id, -1)
  result.capacity = facetNumber(catalog, CapacityFacet, id, -1.0)
  result.load = facetNumber(catalog, LoadFacet, id, -1.0)
  result.accepts = facetText(catalog, AcceptFacet, id, "")
  result.rejects = facetText(catalog, RejectFacet, id, "")

## The container definition this id names, from the last registered catalog that
## has it.
proc holderOf*(id: string): Holder =
  result = Holder(id: id, display: id, slots: -1, capacity: -1.0, load: -1.0,
    accepts: "", rejects: "", known: false)
  var i = holderCatalogs.len - 1
  while i >= 0:
    let found = holderIn(holderCatalogs[i], id)
    if found.known: return found
    dec i

# ---------------------------------------------------------------------------
# Writing definitions into catalogs
# ---------------------------------------------------------------------------

## A catalog of item definitions, and the facet catalogs that go with it, all
## created here so a definer never has to spell the suffixes out. Registers it
## for reading as well, because a mod that publishes items almost always wants
## to see them.
proc itemCatalog*(id: string; description = ""): Catalog =
  declareInventoryKinds()
  createCatalog(id, ItemKind, description)
  createCatalog(id & StackFacet, ItemStackKind, "Stack sizes for " & id)
  createCatalog(id & BulkFacet, ItemBulkKind, "Bulk for " & id)
  createCatalog(id & WeightFacet, ItemWeightKind, "Weights for " & id)
  createCatalog(id & ShapeFacet, ItemShapeKind, "Shapes for " & id)
  createCatalog(id & TagFacet, ItemTagKind, "Tags for " & id)
  useItems(id)
  Catalog(id)

## The same for container definitions.
proc containerCatalog*(id: string; description = ""): Catalog =
  declareInventoryKinds()
  createCatalog(id, ContainerKind, description)
  createCatalog(id & SlotFacet, ContainerSlotKind, "Slot counts for " & id)
  createCatalog(id & CapacityFacet, ContainerCapacityKind, "Capacity for " & id)
  createCatalog(id & LoadFacet, ContainerLoadKind, "Load limits for " & id)
  createCatalog(id & AcceptFacet, ContainerAcceptKind, "Accepted tags for " & id)
  createCatalog(id & RejectFacet, ContainerRejectKind, "Refused tags for " & id)
  useContainers(id)
  Catalog(id)

## One item, written across the base catalog and its facets in one call.
proc defineItem*(c: Catalog; id, display: string; stack = 1; bulk = 1.0;
    weight = 0.0; shape = ""; tags = "") =
  let base = name(c)
  addToCatalog(base, id, display)
  addToCatalog(base & StackFacet, id, int64(if stack < 1: 1 else: stack))
  addToCatalog(base & BulkFacet, id, bulk)
  addToCatalog(base & WeightFacet, id, weight)
  addToCatalog(base & ShapeFacet, id, shape)
  addToCatalog(base & TagFacet, id, tags)

## One container definition, the same way.
proc defineContainer*(c: Catalog; id, display: string; slots = -1;
    capacity = -1.0; load = -1.0; accepts = ""; rejects = "") =
  let base = name(c)
  addToCatalog(base, id, display)
  addToCatalog(base & SlotFacet, id, int64(slots))
  addToCatalog(base & CapacityFacet, id, capacity)
  addToCatalog(base & LoadFacet, id, load)
  addToCatalog(base & AcceptFacet, id, accepts)
  addToCatalog(base & RejectFacet, id, rejects)

# ---------------------------------------------------------------------------
# Live containers
# ---------------------------------------------------------------------------

type Bin = object
  definition: Holder
  label: string
  live: bool
  slots: seq[Stack]

var bins: seq[Bin]

proc indexOf(c: Container): int =
  let at = int(c) - 1
  if at < 0 or at >= bins.len: return -1
  if not bins[at].live: return -1
  at

proc least(a, b: int): int = (if a < b: a else: b)

proc perStack(it: Item): int = (if it.stack < 1: 1 else: it.stack)

proc usedBulk(b: Bin): float64 =
  result = 0.0
  var i = 0
  while i < b.slots.len:
    result = result + itemOf(b.slots[i].item).bulk * float64(b.slots[i].count)
    inc i

proc usedLoad(b: Bin): float64 =
  result = 0.0
  var i = 0
  while i < b.slots.len:
    result = result + itemOf(b.slots[i].item).weight * float64(b.slots[i].count)
    inc i

## Whether the definition's tags let this item in at all. Empty `accepts` is no
## opinion rather than nothing allowed; `rejects` is checked second so a mod can
## say "everything medical except the big one" in two lines.
proc lets(d: Holder; it: Item): bool =
  if d.accepts.len > 0:
    if not taggedAny(it.tags, d.accepts): return false
  if d.rejects.len > 0:
    if taggedAny(it.tags, d.rejects): return false
  true

## What stops `count` of this item going in, or `NoTrouble`. Answers without
## touching anything, which is what makes a cross-container move all-or-nothing:
## the target is asked before the source is emptied.
proc trouble(b: Bin; it: Item; count: int): Trouble =
  if count < 1: return BadCount
  if not it.known: return UnknownItem
  let d = b.definition
  if not lets(d, it): return NotAccepted
  if d.capacity >= 0.0:
    if usedBulk(b) + it.bulk * float64(count) > d.capacity: return NoRoom
  if d.load >= 0.0:
    if usedLoad(b) + it.weight * float64(count) > d.load: return TooHeavy
  if d.slots >= 0:
    let per = perStack(it)
    var remaining = count
    var i = 0
    while i < b.slots.len and remaining > 0:
      if b.slots[i].item == it.id:
        let room = per - b.slots[i].count
        if room > 0: remaining = remaining - least(room, remaining)
      inc i
    if remaining > 0:
      let need = (remaining + per - 1) div per
      if b.slots.len + need > d.slots: return NoRoom
  NoTrouble

## Put units in without asking. Every caller has already asked `trouble`.
proc place(b: var Bin; it: Item; count: int): int =
  var remaining = count
  let per = perStack(it)
  var i = 0
  var landed = -1
  while i < b.slots.len and remaining > 0:
    if b.slots[i].item == it.id and b.slots[i].count < per:
      let take = least(per - b.slots[i].count, remaining)
      var s = b.slots[i]
      s.count = s.count + take
      b.slots[i] = s
      remaining = remaining - take
      landed = i
    inc i
  while remaining > 0:
    let take = least(per, remaining)
    b.slots.add Stack(item: it.id, count: take)
    landed = b.slots.len - 1
    remaining = remaining - take
  landed

proc dropSlot(b: var Bin; slot: int) =
  var i = slot
  while i + 1 < b.slots.len:
    let next = b.slots[i + 1]
    b.slots[i] = next
    inc i
  b.slots.setLen(b.slots.len - 1)

proc drawOff(b: var Bin; slot, count: int) =
  var s = b.slots[slot]
  s.count = s.count - count
  if s.count < 1: dropSlot(b, slot)
  else: b.slots[slot] = s

# ---------------------------------------------------------------------------
# The operations
# ---------------------------------------------------------------------------

## Open a container from a definition in a named catalog. `Container(0)` when
## the catalog does not hold that id, which `isNothing` reads.
proc openContainer*(catalog, definition: string; label = ""): Container =
  let d = holderIn(catalog, definition)
  if not d.known: return Container(0)
  bins.add Bin(definition: d, label: (if label.len > 0: label else: d.display),
    live: true, slots: @[])
  Container(bins.len)

## The same from a definition in any registered container catalog.
proc openContainerOf*(definition: string; label = ""): Container =
  let d = holderOf(definition)
  if not d.known: return Container(0)
  bins.add Bin(definition: d, label: (if label.len > 0: label else: d.display),
    live: true, slots: @[])
  Container(bins.len)

## A container from a definition a mod built itself, for one that never wanted a
## catalog - a corpse, a ground pile, a vendor's stall for one trade.
proc openHolder*(d: Holder; label = ""): Container =
  bins.add Bin(definition: d, label: (if label.len > 0: label else: d.display),
    live: true, slots: @[])
  Container(bins.len)

## Close one. Its handle never comes back, so a stale handle reads as
## `NoSuchContainer` rather than as somebody else's container.
proc closeContainer*(c: Container): Outcome =
  let at = indexOf(c)
  if at < 0: return refused(NoSuchContainer)
  var b = bins[at]
  let held = b.slots.len
  b.live = false
  b.slots = @[]
  bins[at] = b
  fine(held, -1)

## Whether the handle still names something.
proc open*(c: Container): bool = indexOf(c) >= 0

proc containerLabel*(c: Container): string =
  let at = indexOf(c)
  if at < 0: return ""
  bins[at].label

proc containerDefinition*(c: Container): Holder =
  let at = indexOf(c)
  if at < 0: return Holder(id: "", display: "", slots: -1, capacity: -1.0,
    load: -1.0, accepts: "", rejects: "", known: false)
  bins[at].definition

## Put units of an item in. All of them or none: a `put` that would half fit
## answers `NoRoom` and changes nothing, because a half-fitting put is a rule
## the caller has to unpick and nobody ever does.
proc put*(c: Container; item: string; count = 1): Outcome =
  let at = indexOf(c)
  if at < 0: return refused(NoSuchContainer)
  let it = itemOf(item)
  let why = trouble(bins[at], it, count)
  if why != NoTrouble: return refused(why)
  var b = bins[at]
  let slot = place(b, it, count)
  bins[at] = b
  fine(count, slot)

## Take units of an item out, from wherever they are, newest stack first.
proc take*(c: Container; item: string; count = 1): Outcome =
  let at = indexOf(c)
  if count < 1: return refused(BadCount)
  if at < 0: return refused(NoSuchContainer)
  var b = bins[at]
  var have = 0
  var i = 0
  while i < b.slots.len:
    if b.slots[i].item == item: have = have + b.slots[i].count
    inc i
  if have < count: return refused(NotEnough)
  var remaining = count
  i = b.slots.len - 1
  while i >= 0 and remaining > 0:
    if b.slots[i].item == item:
      let gone = least(b.slots[i].count, remaining)
      drawOff(b, i, gone)
      remaining = remaining - gone
    dec i
  bins[at] = b
  fine(count, -1)

## Take units out of one stack by its slot. `count` of zero means all of it.
proc takeFrom*(c: Container; slot: int; count = 0): Outcome =
  let at = indexOf(c)
  if at < 0: return refused(NoSuchContainer)
  var b = bins[at]
  if slot < 0 or slot >= b.slots.len: return refused(NoSuchStack)
  let want = (if count < 1: b.slots[slot].count else: count)
  if want > b.slots[slot].count: return refused(NotEnough)
  drawOff(b, slot, want)
  bins[at] = b
  fine(want, -1)

## Move units of one stack from one container into another. Either the target
## takes all of them and the source loses all of them, or neither is touched:
## the target is asked before the source is drawn down, and nothing in between
## can fail. `count` of zero means the whole stack.
proc moveStack*(source, target: Container; slot: int; count = 0): Outcome =
  let from0 = indexOf(source)
  let to0 = indexOf(target)
  if from0 < 0 or to0 < 0: return refused(NoSuchContainer)
  if from0 == to0:
    return refused(Nowhere, "a move within one container is a split or a merge")
  if slot < 0 or slot >= bins[from0].slots.len: return refused(NoSuchStack)
  let held = bins[from0].slots[slot]
  let want = (if count < 1: held.count else: count)
  if want > held.count: return refused(NotEnough)
  let it = itemOf(held.item)
  let why = trouble(bins[to0], it, want)
  if why != NoTrouble: return refused(why)
  var src = bins[from0]
  drawOff(src, slot, want)
  bins[from0] = src
  var dst = bins[to0]
  let landed = place(dst, it, want)
  bins[to0] = dst
  fine(want, landed)

## Cut `count` units off a stack into a stack of their own, in the same
## container. Refuses when there is no slot for the new one.
proc splitStack*(c: Container; slot, count: int): Outcome =
  let at = indexOf(c)
  if at < 0: return refused(NoSuchContainer)
  if count < 1: return refused(BadCount)
  var b = bins[at]
  if slot < 0 or slot >= b.slots.len: return refused(NoSuchStack)
  if count >= b.slots[slot].count:
    return refused(NotEnough, "a split has to leave something behind")
  let d = b.definition
  if d.slots >= 0 and b.slots.len + 1 > d.slots: return refused(NoRoom)
  let item = b.slots[slot].item
  var s = b.slots[slot]
  s.count = s.count - count
  b.slots[slot] = s
  b.slots.add Stack(item: item, count: count)
  bins[at] = b
  fine(count, b.slots.len - 1)

## Pour one stack into another in the same container, as far as the item's stack
## size allows. Moves what fits and says how much; the source is dropped when it
## empties, which is why `merge` answers with a count and not a yes.
proc mergeStacks*(c: Container; source, target: int): Outcome =
  let at = indexOf(c)
  if at < 0: return refused(NoSuchContainer)
  var b = bins[at]
  if source < 0 or source >= b.slots.len: return refused(NoSuchStack)
  if target < 0 or target >= b.slots.len: return refused(NoSuchStack)
  if source == target: return refused(Nowhere)
  if b.slots[source].item != b.slots[target].item:
    return refused(NotAccepted, "those are not the same item")
  let it = itemOf(b.slots[source].item)
  let room = perStack(it) - b.slots[target].count
  if room < 1: return refused(NoRoom)
  let moved = least(room, b.slots[source].count)
  var t = b.slots[target]
  t.count = t.count + moved
  b.slots[target] = t
  drawOff(b, source, moved)
  bins[at] = b
  fine(moved, (if source < target: target - 1 else: target))

## Empty one out. What it held is gone, not moved; a mod that wants it moved
## walks `contents` and calls `moveStack` per stack.
proc emptyContainer*(c: Container): Outcome =
  let at = indexOf(c)
  if at < 0: return refused(NoSuchContainer)
  var b = bins[at]
  let held = b.slots.len
  b.slots = @[]
  bins[at] = b
  fine(held, -1)

# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------

proc stackCount*(c: Container): int =
  let at = indexOf(c)
  if at < 0: return 0
  bins[at].slots.len

proc stackAt*(c: Container; slot: int): Stack =
  let at = indexOf(c)
  if at < 0: return Stack(item: "", count: 0)
  if slot < 0 or slot >= bins[at].slots.len: return Stack(item: "", count: 0)
  bins[at].slots[slot]

## Every stack in it, in slot order. Spelled `contents` and not `items` for the
## reason `catalogs` spells its walk `entries`: the interpreter answers a magic
## name itself when it can.
iterator contents*(c: Container): Stack {.sideEffect.} =
  let at = indexOf(c)
  if at >= 0:
    var i = 0
    while i < bins[at].slots.len:
      yield bins[at].slots[i]
      inc i

## How many units of an item are in there, across every stack.
proc countOf*(c: Container; item: string): int =
  let at = indexOf(c)
  result = 0
  if at < 0: return
  var i = 0
  while i < bins[at].slots.len:
    if bins[at].slots[i].item == item: result = result + bins[at].slots[i].count
    inc i

proc holds*(c: Container; item: string): bool = countOf(c, item) > 0

proc bulkUsed*(c: Container): float64 =
  let at = indexOf(c)
  if at < 0: return 0.0
  usedBulk(bins[at])

proc loadUsed*(c: Container): float64 =
  let at = indexOf(c)
  if at < 0: return 0.0
  usedLoad(bins[at])

## Why this many of this item would not go in, or `NoTrouble` if they would.
## The question every UI asks before it lets go of a drag.
proc troubleWith*(c: Container; item: string; count = 1): Trouble =
  let at = indexOf(c)
  if at < 0: return NoSuchContainer
  trouble(bins[at], itemOf(item), count)

proc roomFor*(c: Container; item: string; count = 1): bool =
  troubleWith(c, item, count) == NoTrouble

## Whether the container's tags let this item in, ignoring how full it is.
proc accepts*(c: Container; item: string): bool =
  let at = indexOf(c)
  if at < 0: return false
  lets(bins[at].definition, itemOf(item))
