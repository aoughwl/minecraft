## Minecraft's scrolling list, as arithmetic - the one foundation under the
## world list, the resource-pack columns and the server list.
##
## Every list screen in Minecraft is the same widget with different rows in it.
## `GuiSlot` (`AbstractSelectionList` in the modern names) is a band between a
## header and a footer, a fixed row stride, a scroll offset in interface pixels,
## and a scrollbar on the right that only exists when there is something to
## scroll. Three screens in this mod want that widget, so it is written once,
## here, and none of it touches a host.
##
## The numbers are the game's and they are not arbitrary:
##
##     k = floor(mouseY - top) - headerPadding + amountScrolled - 4
##     slot = k / slotHeight
##     hit when mouseX in [left, left + listWidth] and k >= 0 and slot < size
##
## and the row itself is drawn at
##
##     top + 4 - amountScrolled + slot * slotHeight
##
## Those two are one statement said twice, which is exactly the sort of thing
## that drifts. So `rowSlot` below is the *only* place the row's position is
## computed, `rowUnder` is defined as "the slot whose `rowSlot` holds the
## point", and the drawn rectangle is that slot short by the four-pixel gap the
## game leaves between entries. A test can then assert the game's arithmetic
## against this without either side being copied from the other.
##
## The scrollbar is the other piece worth writing down, because it is not a
## proportion:
##
##     thumb = (bottom - top)^2 / contentHeight, clamped to [32, band - 8]
##     y     = scrolled * (band - thumb) / maxScroll + top
##
## The clamp is why a list of four hundred worlds still has a thumb you can
## grab, and the square is why the thumb shrinks as the square of the content
## rather than linearly.

import mcuicore

const
  ListTop* = 32
    ## Every list screen in the game starts its band 32 pixels down, under the
    ## title.
  TopPad* = 4
    ## The gap above the first row, and the `- 4` in the game's hit test. One
    ## number, used by both, which is the point of naming it.
  RowGap* = 4
    ## A row occupies `rowHeight` of the scroll and is *drawn* four pixels
    ## shorter, which is the gutter between entries.
  ScrollbarWidth* = 6
  ScrollbarGap* = 4
    ## Between the right edge of the rows and the left edge of the bar.
  MinThumb* = 32
  ThumbInset* = 8
    ## The thumb is never taller than the band less this, so there is always
    ## somewhere for it to go.
  WorldRowHeight* = 36
    ## `GuiListWorldSelection` and `ServerSelectionList` both use 36.
  PackRowHeight* = 36
    ## `GuiResourcePackList` uses 36 as well; its band is narrower, not shorter.
  ListWidth* = 220
    ## `getListWidth()`'s default, which the world and server lists both take.
  PackColumnWidth* = 200
    ## The two resource-pack columns are 200 wide and sit either side of the
    ## centre with an eight-pixel channel between them.

type
  ListBox* = object
    ## A band with rows in it. Interface pixels throughout.
    top*, bottom*: int
    left*, width*: int    ## where the rows are drawn, not where the band is
    rowHeight*: int
    rows*: int

proc listBox*(top, bottom, left, width, rowHeight, rows: int): ListBox =
  ListBox(top: top, bottom: bottom, left: left, width: width,
          rowHeight: rowHeight, rows: rows)

## The band's height. Named because four things divide by it.
proc band*(b: ListBox): int =
  if b.bottom > b.top: b.bottom - b.top else: 0

proc contentHeight*(b: ListBox): int = b.rows * b.rowHeight

## How far down the list can be pushed. Zero when everything already fits,
## which is also the answer that makes the scrollbar disappear.
proc maxScroll*(b: ListBox): int =
  let over = contentHeight(b) - band(b)
  if over > 0: over else: 0

proc clampScroll*(b: ListBox; scroll: int): int =
  let top = maxScroll(b)
  if scroll < 0: 0
  elif scroll > top: top
  else: scroll

proc scrollable*(b: ListBox): bool = maxScroll(b) > 0

## Where the slot `i` sits, at this scroll, counting the gutter as part of it.
## Everything else here is defined against this one rectangle.
proc rowSlot*(b: ListBox; i, scroll: int): MRect =
  mrect(float(b.left), float(b.top + TopPad - scroll + i * b.rowHeight),
        float(b.width), float(b.rowHeight))

## What is actually drawn: the slot, short by the gutter.
proc rowRect*(b: ListBox; i, scroll: int): MRect =
  let s = rowSlot(b, i, scroll)
  mrect(s.x, s.y, s.w, s.h - float(RowGap))

## Which row that point is over, or -1. A point above the band or below it is
## over nothing even when a row's rectangle would reach it, because the band
## clips: that is the difference between the list and the buttons under it.
proc rowUnder*(b: ListBox; scroll: int; x, y: float): int =
  if y < float(b.top) or y >= float(b.bottom): return -1
  var i = 0
  while i < b.rows:
    if rowSlot(b, i, scroll).holds(x, y): return i
    inc i
  -1

## The first and last row with any part of itself inside the band, so a caller
## draws a screenful and not a listful. `last` is one past the end, and both are
## zero when the list is empty.
proc visible*(b: ListBox; scroll: int): seq[int] =
  var first = b.rows
  var last = 0
  var i = 0
  while i < b.rows:
    let s = rowSlot(b, i, scroll)
    if s.bottom > float(b.top) and s.y < float(b.bottom):
      if i < first: first = i
      last = i + 1
    inc i
  if first > last: first = last
  @[first, last]

# ---------------------------------------------------------------------------
# The scrollbar

## Where the bar runs, whether or not there is a thumb in it.
proc scrollbar*(b: ListBox): MRect =
  mrect(float(b.left + b.width + ScrollbarGap), float(b.top),
        float(ScrollbarWidth), float(band(b)))

## How tall the thumb is - the square law, clamped at both ends.
proc thumbHeight*(b: ListBox): int =
  let h = band(b)
  let content = contentHeight(b)
  if content <= 0: return h
  var t = h * h div content
  let ceiling = h - ThumbInset
  if t < MinThumb: t = MinThumb
  if t > ceiling: t = ceiling
  if t < 0: t = 0
  t

## Where the thumb is at this scroll. An empty rectangle when nothing scrolls,
## which is how the caller knows not to draw one.
proc thumb*(b: ListBox; scroll: int): MRect =
  let range = maxScroll(b)
  if range <= 0: return mrect(0.0, 0.0, 0.0, 0.0)
  let t = thumbHeight(b)
  var y = clampScroll(b, scroll) * (band(b) - t) div range + b.top
  if y < b.top: y = b.top
  let bar = scrollbar(b)
  mrect(bar.x, float(y), bar.w, float(t))

## Dragging the thumb: the scroll that puts the thumb's *top* at `y`. The
## inverse of `thumb`, and the test asserts the round trip rather than the
## formula.
proc scrollForThumb*(b: ListBox; y: float): int =
  let range = maxScroll(b)
  if range <= 0: return 0
  let travel = band(b) - thumbHeight(b)
  if travel <= 0: return 0
  clampScroll(b, int((y - float(b.top)) * float(range) / float(travel) + 0.5))

## The wheel. Minecraft moves a slot and a half per notch - `i * 16` against a
## 36-high row is not far off - and this says it in rows so a list of any row
## height feels the same.
proc scrollByNotches*(b: ListBox; scroll, notches: int): int =
  clampScroll(b, scroll - notches * b.rowHeight)

## Keeping a selected row on screen, which is what an arrow key needs. Answers
## the scroll that shows row `i` with as little movement as possible.
proc scrollToShow*(b: ListBox; scroll, i: int): int =
  if i < 0 or i >= b.rows: return clampScroll(b, scroll)
  let above = i * b.rowHeight
  let below = above + b.rowHeight
  var s = clampScroll(b, scroll)
  if above < s: s = above
  elif below > s + band(b) - TopPad: s = below - band(b) + TopPad
  clampScroll(b, s)

# ---------------------------------------------------------------------------
# The bands above and below
#
# Every list screen in the game has the same three parts: a title over a list
# over a row of buttons. The list's own top and bottom are what differ, and
# they differ per screen, so they are the screen's business - but the *shape*
# is here so that three screens cannot disagree about it.

const
  TitleBaseline* = 8
    ## `drawCenteredString(title, width / 2, 8, 0xFFFFFF)` on every list screen
    ## with a footer of two rows, and 16 on the resource-pack screen, which
    ## has two titles side by side instead of one.
  TwoRowFooterTop* = 52
    ## `height - 52` is the upper of the two button rows.
  FooterRowStep* = 24
  ListBottomTwoRows* = 64
    ## `height - 64` is where the list stops when there are two rows under it.

proc footerRow*(guiH, row: int): int =
  guiH - TwoRowFooterTop + row * FooterRowStep
