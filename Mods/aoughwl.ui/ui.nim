## Interfaces, built out of the floor and nothing else.
##
## This is the layer a mod writes against. Import it and you have `ui_floor`
## too, and the SDK's `draw`, `vec` and `color` with it - one import for a
## screen:
##
##   import ui
##
##   proc drawGui() =
##     beginFrame()
##     let box = rect(80.0, 80.0, 420.0, 300.0)
##     panel(box)
##     var side = column(box.inset(12.0))
##     heading(side.take(26.0), "STASH")
##     if button("close", side.take(30.0), "Close"): shut()
##     endFrame()
##
## Nothing here knows about items, guns or bags. A grid of slots you can drag
## things between is spelled here; what a thing IS belongs to the mod above.
##
## Layout is arithmetic on rectangles, not a call into the host's panel stack.
## That stack is one column, cannot nest and cannot be cropped, so a window with
## a scrolling list in it cannot be written on it - and every layout call here
## can therefore be run, and checked, with no host at all.

import jester
import vec
import color
import input
import ui_floor
export ui_floor

# ------------------------------------------------------------------ layout --

type Flow* = enum
  Downward, Rightward

type Layout* = object
  ## A rectangle being handed out a piece at a time. `take` claims the next
  ## piece and answers where it is; `rest` is everything not claimed yet.
  area*: Rect
  flow*: Flow
  gap*: float64
  used*: float64

## Stack down a rectangle.
proc column*(area: Rect; gap = 6.0): Layout =
  Layout(area: area, flow: Downward, gap: gap, used: 0.0)

## Lay out across one.
proc across*(area: Rect; gap = 6.0): Layout =
  Layout(area: area, flow: Rightward, gap: gap, used: 0.0)

## Claim the next `size` of it - a height going down, a width going across.
proc take*(l: var Layout; size: float64): Rect =
  if l.flow == Downward:
    result = rect(l.area.x, l.area.y + l.used, l.area.width, size)
  else:
    result = rect(l.area.x + l.used, l.area.y, size, l.area.height)
  l.used = l.used + size + l.gap

## Leave a gap without claiming anything to put in it.
proc skip*(l: var Layout; size: float64) =
  l.used = l.used + size

## Everything not handed out yet.
proc rest*(l: Layout): Rect =
  if l.flow == Downward:
    rect(l.area.x, l.area.y + l.used, l.area.width, l.area.height - l.used)
  else:
    rect(l.area.x + l.used, l.area.y, l.area.width - l.used, l.area.height)

## The rectangle everything handed out so far fits in - what a panel that sizes
## itself to its contents closes around.
proc taken*(l: Layout): Rect =
  var span = l.used - l.gap
  if span < 0.0: span = 0.0
  if l.flow == Downward: rect(l.area.x, l.area.y, l.area.width, span)
  else: rect(l.area.x, l.area.y, span, l.area.height)

## The rectangle split into `count` even pieces with the gap between them - a
## row of buttons, or the columns of a table. Pure arithmetic; nothing is drawn.
proc share*(area: Rect; count: int; gap = 6.0; flow = Rightward): seq[Rect] =
  result = @[]
  if count <= 0: return result
  var total = area.height
  if flow == Rightward: total = area.width
  let size = (total - gap * float64(count - 1)) / float64(count)
  var i = 0
  while i < count:
    let at = (size + gap) * float64(i)
    if flow == Rightward:
      result.add rect(area.x + at, area.y, size, area.height)
    else:
      result.add rect(area.x, area.y + at, area.width, size)
    i = i + 1

# -------------------------------------------------------------------- grid --

type Grid* = object
  ## Square cells in rows and columns, which is what an inventory is. The cell
  ## size is given rather than derived, because a bag's slots are the same size
  ## in every bag and the bag is as big as its slots make it.
  at*: Vec2
  columns*, rows*: int
  cell*, gap*: float64

proc grid*(at: Vec2; columns, rows: int; cell: float64; gap = 2.0): Grid =
  Grid(at: at, columns: columns, rows: rows, cell: cell, gap: gap)

## How big the whole grid is - what to size a panel around.
proc bounds*(g: Grid): Rect =
  rect(g.at.x, g.at.y,
    float64(g.columns) * g.cell + float64(g.columns - 1) * g.gap,
    float64(g.rows) * g.cell + float64(g.rows - 1) * g.gap)

## One cell, by column and row, both counted from zero.
proc cellAt*(g: Grid; column, row: int): Rect =
  rect(g.at.x + float64(column) * (g.cell + g.gap),
    g.at.y + float64(row) * (g.cell + g.gap), g.cell, g.cell)

## A block of cells - a rifle that is four wide and one tall sits in one of
## these, and drops into one of these.
proc span*(g: Grid; column, row, wide, tall: int): Rect =
  let one = cellAt(g, column, row)
  rect(one.x, one.y,
    float64(wide) * g.cell + float64(wide - 1) * g.gap,
    float64(tall) * g.cell + float64(tall - 1) * g.gap)

type Cell* = object
  ## Which cell a point is in. `inside` is false when it is in none of them -
  ## in a gap, or off the grid entirely.
  column*, row*: int
  inside*: bool

## Which cell holds this point. This is how a drop knows where it landed.
proc cellUnder*(g: Grid; point: Vec2): Cell =
  result = Cell(column: -1, row: -1, inside: false)
  var r = 0
  while r < g.rows:
    var c = 0
    while c < g.columns:
      if holds(cellAt(g, c, r), point):
        result = Cell(column: c, row: r, inside: true)
        return result
      c = c + 1
    r = r + 1

## Whether a block of that size starting at that cell is still on the grid.
proc fits*(g: Grid; column, row, wide, tall: int): bool =
  column >= 0 and row >= 0 and column + wide <= g.columns and
    row + tall <= g.rows

# --------------------------------------------------------------- the plain --

## A backdrop with an edge. Draw it before whatever goes in it.
proc panel*(r: Rect) =
  paint(r, style().panel)
  border(r, 1.0, style().edge)

## A line said normally, shortened rather than spilling out of its box.
proc label*(r: Rect; text: string; align = AlignLeft) =
  paint(fitted(text, r.width, style().text), r, style().text, align, style().ink)

## A line said louder.
proc heading*(r: Rect; text: string; align = AlignLeft) =
  paint(fitted(text, r.width, 19.0), r, 19.0, align, style().ink)

## A line said more quietly - the sentence under a control.
proc hint*(r: Rect; text: string; align = AlignLeft) =
  paint(fitted(text, r.width, style().small), r, style().small, align, style().faint)

## A button. True on the frame it is clicked, which is the frame the press
## comes up on it, and never on the frame it goes down.
proc button*(name: string; r: Rect; text: string): bool =
  let t = touch(name, r)
  if t.held: paint(r, style().pressed)
  elif t.hot: paint(r, style().hot)
  else: paint(r, style().slot)
  var edge = style().edge
  if t.hot: edge = style().accent
  border(r, 1.0, edge)
  paint(fitted(text, r.width - 12.0, style().text), r.inset(6.0), style().text,
    AlignCentre, style().ink)
  result = t.clicked

## A box that is either ticked or not. Hand it what it is now; keep what it
## hands back, the same shape as every other question a settings screen asks.
proc toggle*(name: string; r: Rect; text: string; value: bool): bool =
  let t = touch(name, r)
  if t.hot: paint(r, style().hot)
  else: paint(r, style().slot)
  let side = r.height - 10.0
  let box = rect(r.x + 5.0, r.y + 5.0, side, side)
  paint(box, style().panel)
  if value: paint(box.inset(4.0), style().welcome)
  else: border(box, 1.0, style().edge)
  let words = rect(r.x + side + 14.0, r.y, r.width - side - 20.0, r.height)
  paint(fitted(text, words.width, style().text), words, style().text, AlignLeft,
    style().ink)
  result = value
  if t.clicked: result = not value

# ------------------------------------------------------------------ scroll --

type Scroll* = object
  ## A cropped window onto something taller than it. `view` is what shows;
  ## `content` is the whole of it, already moved up by however far it has been
  ## scrolled, so laying things out inside `content` needs no arithmetic of its
  ## own.
  view*, content*: Rect
  id*: string
  offset*, span*: float64

const BarWidth = 9.0

## How far one notch of the wheel moves a region. About two rows of a list, and
## a mod that wants another number scrolls the region itself with `scrollBy`.
const WheelStep = 56.0

## Open a scrolling region. Everything drawn until `endScroll` is cropped to it
## and cannot be clicked outside it. `contentHeight` is how tall the thing being
## looked at really is.
proc beginScroll*(name: string; area: Rect; contentHeight: float64): Scroll =
  let full = here(name)
  pushId(name)
  var span = contentHeight - area.height
  if span < 0.0: span = 0.0
  var view = area
  if span > 0.0: view = rect(area.x, area.y, area.width - BarWidth - 2.0, area.height)
  var off = scrollOf(full)
  # The wheel, if it turned over this region and this region has anywhere to go.
  # Away from you is towards the top, which is a smaller offset. Asked before the
  # bar is drawn so a wheel and a drag on the same frame agree about where the
  # thumb belongs.
  if span > 0.0: off = off - wheelOver(area) * WheelStep
  if off > span: off = span
  if off < 0.0: off = 0.0
  if span > 0.0:
    let track = rect(area.x + area.width - BarWidth, area.y, BarWidth, area.height)
    paint(track, style().slot)
    var thumbTall = area.height * area.height / contentHeight
    if thumbTall < 20.0: thumbTall = 20.0
    let travel = track.height - thumbTall
    let t = touch("bar",
      rect(track.x, track.y + travel * (off / span), BarWidth, thumbTall))
    if t.held and travel > 0.0:
      off = off + pointerMoved().y * (span / travel)
      if off < 0.0: off = 0.0
      if off > span: off = span
    var grip = style().edge
    if t.hot or t.held: grip = style().accent
    paint(rect(track.x, track.y + travel * (off / span), BarWidth, thumbTall),
      grip)
  setScroll(full, off)
  pushClip(view)
  result = Scroll(view: view,
    content: rect(view.x, view.y - off, view.width, contentHeight),
    id: full, offset: off, span: span)

proc endScroll*(s: Scroll) =
  popClip()
  popId()

type Rows* = object
  ## A scrolling list that only draws the rows you can see, so a bag with two
  ## thousand things in it costs the twenty on the screen.
  scroll*: Scroll
  height*: float64
  first*, last*: int
    ## The half-open range worth drawing: `first` up to but not including `last`.

proc beginList*(name: string; area: Rect; count: int; height = 28.0): Rows =
  let s = beginScroll(name, area, float64(count) * height)
  var first = int(s.offset / height)
  if first < 0: first = 0
  var last = first + int(area.height / height) + 2
  if last > count: last = count
  result = Rows(scroll: s, height: height, first: first, last: last)

## Where row `index` is on the screen, scroll already taken off it.
proc rowAt*(r: Rows; index: int): Rect =
  rect(r.scroll.content.x, r.scroll.content.y + float64(index) * r.height,
    r.scroll.content.width, r.height)

proc endList*(r: Rows) = endScroll(r.scroll)

# ------------------------------------------------------------ drag and drop --

## A slot something can be dropped into, drawn as it goes. `accepts` is the kind
## of carry it takes, or empty for any. Read `.dropped` to move the thing.
proc slot*(name: string; r: Rect; accepts: string): Drop =
  result = dropZone(name, r, accepts)
  paint(r, style().slot)
  if result.over: border(r, 2.0, style().welcome)
  elif carrying() and accepts.len > 0 and not carrying(accepts):
    border(r, 1.0, style().refuse)
  else: border(r, 1.0, style().edge)

## A thing that can be picked up out of a slot, drawn as it goes. While it is
## being carried its own place is drawn hollow, because the thing itself is
## under the pointer.
proc tile*(name: string; r: Rect; text: string; load: Carry): Drag =
  result = drag(name, r, load)
  if result.dragging:
    paint(r, style().slot)
    border(r, 1.0, style().edge)
    return result
  if result.hot: paint(r, style().hot)
  else: paint(r, style().filled)
  var edge = style().edge
  if result.hot: edge = style().accent
  border(r, 1.0, edge)
  paint(fitted(text, r.width - 8.0, style().small), r.inset(4.0), style().small,
    AlignCentre, style().ink)

## Whatever is being carried, drawn under the pointer. Call it last in the
## frame, after every panel, so it is on top of all of them.
proc ghost*(text: string) =
  if not carrying(): return
  let box = ghostRect()
  paint(box, style().filled.withAlpha(0.85))
  border(box, 1.0, style().ghost)
  paint(fitted(text, box.width - 8.0, style().small), box.inset(4.0), style().small,
    AlignCentre, style().ink)
