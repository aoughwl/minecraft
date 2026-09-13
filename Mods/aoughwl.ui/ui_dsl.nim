## Block forms for the things that open and close.
##
## Every one of these is exactly the pair of `ui` calls a mod would write by
## hand, with the closing one impossible to forget:
##
##   screen:
##     panel(box)
##     inside "bag":
##       cropped box:
##         label(row, "safe from spilling out")
##
##   scrolling view, "stash", box, 900.0:
##     var down = column(view.content)
##     label(down.take(24.0), "row one")
##
## These are templates, not macros. `catalogs_dsl` had to reach for
## `std/macros` and it costs every mod that imports it thirty-odd modules and a
## minute of semantic pass; nothing here needs to look at the shape of the code,
## so nothing here pays that. It is a separate module for the same reason
## regardless: `ui` never imports it, so a mod that wants the plain calls never
## sees it, and one that wants the blocks writes one more `import`.

import vec
import ui
export ui

## One frame of interface, closed however the body leaves.
template screen*(body: untyped) =
  beginFrame()
  body
  endFrame()

## The same, from pointer facts you supply rather than the host's - a test, a
## gamepad cursor, a pointer a peer is moving.
template screenAt*(at: Vec2; down: bool; area: Rect; body: untyped) =
  beginFrame(at, down, area)
  body
  endFrame()

## Everything in the body is cropped to this rectangle, and cannot be clicked
## outside it.
template cropped*(area: Rect; body: untyped) =
  pushClip(area)
  body
  popClip()

## Everything in the body is named inside this, so two copies of one panel on
## one screen are two panels.
template inside*(name: string; body: untyped) =
  pushId(name)
  body
  popId()

## A scrolling region, with the region itself bound to the name you give first.
template scrolling*(view, name, area, contentHeight, body: untyped) =
  var view = beginScroll(name, area, contentHeight)
  body
  endScroll(view)

## A scrolling list of `count` rows, with the list bound to the name you give
## first. Walk `rows.first ..< rows.last` inside it; those are the rows on the
## screen, and the rest cost nothing.
template listing*(rows, name, area, count, height, body: untyped) =
  var rows = beginList(name, area, count, height)
  body
  endList(rows)
