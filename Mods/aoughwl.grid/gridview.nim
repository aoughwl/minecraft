## A grid container, on the screen, with things you can pick up out of it.
##
## `gridspace` is where a thing is; this is how a person moves it. It is a thin
## layer on purpose - the whole of the input is `aoughwl.ui`'s drag and
## drop machine, and the whole of the arithmetic is `gridspace` - and what it
## adds is the two things a Tarkov inventory has that a grid of buttons does
## not:
##
## - **the preview.** While a thing is over a bag, the cells it would land on
##   are painted, green when it would go there and red when it would not, and
##   the reason it would not is a sentence somebody can read before they let go.
##   A drop that is refused after the fact feels broken; a drop that says no
##   while you are still holding it feels like a rule.
## - **one drop target per bag, not one per cell.** A cell is 44 pixels with a
##   2 pixel gap, and `cellUnder` answers "no cell" in the gap - so a per-cell
##   target throws away one drop in twenty for landing on a seam. The bag is the
##   target, the cell is arithmetic, and where the thing lands is worked out
##   from the corner of what is being carried rather than from the pointer, so a
##   rifle taken hold of by its stock does not jump forward four cells.

import jester
import vec
import color
import aoughwl_ui/ui
import gridspace
export gridspace

const ItemKindTag* = "item"
  ## The kind every carry in a grid inventory has, so a drop target that takes
  ## items and one that takes something else can be told apart.

var
  fromBag = nowhereBag()
  fromKey = 0
  turnedInHand = false
  refusalNote = ""
  refusalFor = 0

## Which entry, in which space, is under the pointer right now.
proc carriedKey*(): int = fromKey
proc carriedFrom*(): Bag = fromBag

## Whether the thing in hand has been turned since it was picked up.
proc carriedTurned*(): bool = turnedInHand

## Turn the thing in hand. What a mod wires the rotate key to. Answers false
## when nothing is being carried, or when it is square and has one way up.
proc turnCarried*(): bool =
  if not carrying(ItemKindTag): return false
  if fromKey == 0: return false
  if not turnable(footprintOf(carried().id)): return false
  turnedInHand = not turnedInHand
  true

## Why the last drop that was refused was refused, in words, or empty. A screen
## shows this under the bags; it is set while the thing is still in the air.
proc refusal*(): string = refusalNote

proc forgetRefusal*() =
  refusalNote = ""
  refusalFor = 0

## What to write on the ghost under the pointer.
proc carriedCaption*(): string =
  if not carrying(ItemKindTag): return ""
  let it = itemOf(carried().id)
  var said = it.display
  if carried().count > 1: said = said & " x" & $carried().count
  said

type Board* = object
  ## One bag on the screen: a space, where it is, and how big its cells are.
  bag*: Bag
  at*: Vec2
  cell*, gap*: float64
  name*: string

proc board*(s: Bag; at: Vec2; name: string; cell = 44.0; gap = 2.0): Board =
  Board(bag: s, at: at, cell: cell, gap: gap, name: name)

## The `ui` grid this board is drawn on. Every rectangle below is one of its
## cells or a block of them.
proc cellsOf*(b: Board): Grid =
  grid(b.at, bagWide(b.bag), bagTall(b.bag), b.cell, b.gap)

proc boardArea*(b: Board): Rect = bounds(cellsOf(b))

type BoardEvent* = object
  ## What a person did to this board this frame.
  dropped*: bool
    ## Something was let go over it - whether or not it was allowed.
  moved*: Outcome
    ## What came of that. Read `.note` for the refusal.
  chose*: int
    ## The entry clicked this frame - a click, never a drag. Zero for none.
  picked*: int
    ## The entry a drag started from this frame. Zero for none.

const NoBoardEvent = BoardEvent(dropped: false,
  moved: Outcome(trouble: NoTrouble, moved: 0, slot: 0, note: ""),
  chose: 0, picked: 0)

## Which cell the top left corner of the carried thing is over, clamped so the
## whole footprint stays on the grid when it can. Clamping rather than refusing
## is what makes a drop near an edge land where a person meant it; a footprint
## too big for the bag at all is left at the corner, and refused with a sentence
## about its size rather than about the pointer.
proc cellForCorner*(g: Grid; corner: Vec2; wide, tall: int): Cell =
  let step = g.cell + g.gap
  var c = int((corner.x - g.at.x + g.cell * 0.5) / step)
  var r = int((corner.y - g.at.y + g.cell * 0.5) / step)
  if corner.x < g.at.x: c = 0
  if corner.y < g.at.y: r = 0
  if c > g.columns - wide: c = g.columns - wide
  if r > g.rows - tall: r = g.rows - tall
  if c < 0: c = 0
  if r < 0: r = 0
  Cell(column: c, row: r, inside: true)

proc footprintInHand(): Footprint =
  var f = footprintOf(carried().id)
  if turnedInHand: f = turned(f)
  f

## Draw one bag, and let a person take things out of it and put things into it.
##
## Everything is between `beginFrame()` and `endFrame()`, and the ghost is drawn
## by the caller after every board, because the ghost has to be on top of all of
## them and only the caller knows which one is last.
proc drawBoard*(b: Board): BoardEvent =
  result = NoBoardEvent
  pushId(b.name)
  let g = cellsOf(b)
  let area = bounds(g)

  paint(area.inset(-6.0), style().panel)
  border(area.inset(-6.0), 1.0, style().edge)

  var r = 0
  while r < g.rows:
    var c = 0
    while c < g.columns:
      let one = cellAt(g, c, r)
      paint(one, style().slot)
      border(one, 1.0, style().edge)
      c = c + 1
    r = r + 1

  # One target for the whole bag. The cell is arithmetic, not a widget.
  let zone = dropZone("cells", area, ItemKindTag)

  if carrying(ItemKindTag) and zone.over:
    let f = footprintInHand()
    let corner = vec2(pointerAt().x - carried().grip.x,
      pointerAt().y - carried().grip.y)
    let cell = cellForCorner(g, corner, f.wide, f.tall)
    let over = span(g, cell.column, cell.row, f.wide, f.tall)
    let ignore = (if isSame(fromBag, b.bag): fromKey else: 0)
    var why = troubleTaking(b.bag, carried().id, int(carried().count))
    if why == NoTrouble:
      if not roomAt(b.bag, cell.column, cell.row, f.wide, f.tall, ignore):
        why = NoRoom
    if why == NoTrouble:
      paint(over, style().welcome.withAlpha(0.30))
      border(over, 2.0, style().welcome)
      if refusalFor == fromKey: forgetRefusal()
    else:
      paint(over, style().refuse.withAlpha(0.30))
      border(over, 2.0, style().refuse)
      refusalNote = itemOf(carried().id).display & " does not go in " &
        bagLabel(b.bag) & ": " & name(why)
      refusalFor = fromKey
    if zone.dropped:
      result.dropped = true
      # Let go on top of a stack of the same thing and they pour together;
      # anywhere else and it is a move. The cell under the pointer decides,
      # not the corner, because that is the cell a person is looking at.
      let under = cellUnder(g, pointerAt())
      var onto = 0
      if under.inside: onto = keyAtCell(b.bag, under.column, under.row)
      if onto != 0 and onto != fromKey and
         entryOf(b.bag, onto).item == carried().id:
        result.moved = pourOnto(fromBag, fromKey, b.bag, onto)
      else:
        result.moved = moveTo(fromBag, fromKey, b.bag, cell.column,
          cell.row, turnedInHand)
      if not went(result.moved):
        refusalNote = itemOf(carried().id).display & ": " & result.moved.note
        refusalFor = fromKey
      else:
        forgetRefusal()
  elif zone.dropped:
    result.dropped = true
    result.moved = moveTo(fromBag, fromKey, b.bag, 0, 0, turnedInHand)

  var i = 0
  while i < entryCount(b.bag):
    let e = entryAt(b.bag, i)
    let f = footprintOn(e)
    let box = span(g, e.column, e.row, f.wide, f.tall)
    var said = itemOf(e.item).display
    if e.count > 1: said = said & " x" & $e.count
    let held = tile($e.key, box, said, carry(ItemKindTag, e.item, int64(e.count)))
    if held.dragging and fromKey != e.key:
      fromKey = e.key
      fromBag = b.bag
      turnedInHand = e.rotated
    if held.clicked: result.chose = e.key
    if held.dragging and result.picked == 0: result.picked = e.key
    if not isNothing(e.inner):
      # A thing you can put things in wears a mark, because from the outside a
      # full rig and a heavy rock look the same.
      let mark = rect(box.x + box.width - 12.0, box.y + 2.0, 10.0, 10.0)
      paint(mark, style().accent)
    i = i + 1

  popId()

## Forget what was being carried once the drag is over. Call it once a frame,
## after every board - a drag that landed on nothing is a landing too, and this
## is where a mod hears about it.
proc settleDrag*(): Landing =
  result = landing()
  if result.happened:
    fromKey = 0
    fromBag = nowhereBag()
    turnedInHand = false
