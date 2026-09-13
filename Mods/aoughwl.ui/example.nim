## A Tarkov-shaped inventory, written the way a mod would write one.
##
## This is the worked example, and it is also the argument: nothing below
## reaches past `ui` into `ui_floor`, nothing below touches the host, and the
## whole screen - two grids of slots, things of different sizes in them, pick
## one up and put it down in the other - is a hundred lines of rectangles and
## names. A mod that owns real items writes exactly this and keeps its items
## where it already keeps them.
##
## It lives inside the library's own mod folder rather than in a mod of its
## own because a mod cannot yet `import` a module out of another mod; when
## declared dependencies reach the module path this file moves out unchanged
## and the consuming mod declares `aoughwl.ui` in its `mod.json`.

import jester
import vec
import ui
import ui_dsl
import textfield

const
  Stash* = 0
  Pouch* = 1

type Thing* = object
  ## One thing in a bag. A mod with real items keeps its own type and reads the
  ## carry's `id` back into it; nothing here is a rule of the library.
  id*, caption*: string
  wide*, tall*: int
  bag*, column*, row*: int

var things: seq[Thing] = @[]

## Where each bag is on the screen and how big its cells are. Two grids, the
## same call twice.
proc bagOf*(which: int): Grid =
  if which == Stash: grid(vec2(60.0, 130.0), 8, 6, 44.0, 2.0)
  else: grid(vec2(500.0, 130.0), 3, 3, 44.0, 2.0)

proc bagName(which: int): string =
  if which == Stash: "stash" else: "pouch"

## The starting arrangement. Called again by the checks, so it is a proc and
## not an initialiser.
proc setUpBags*() =
  things = @[]
  things.add Thing(id: "bandage", caption: "Bandage", wide: 1, tall: 1,
    bag: Stash, column: 0, row: 0)
  things.add Thing(id: "rifle", caption: "Rifle", wide: 4, tall: 1,
    bag: Stash, column: 0, row: 2)
  things.add Thing(id: "mag", caption: "Mag", wide: 1, tall: 2,
    bag: Pouch, column: 2, row: 0)

proc indexOf*(id: string): int =
  result = -1
  var i = 0
  while i < things.len:
    if things[i].id == id: result = i
    i = i + 1

proc thingAt*(id: string): Thing =
  let i = indexOf(id)
  if i < 0: Thing(id: "", caption: "", wide: 0, tall: 0, bag: -1,
    column: -1, row: -1)
  else: things[i]

proc blocked(which, column, row, wide, tall: int; ignore: int): bool =
  ## Whether any other thing already covers those cells. Rectangle against
  ## rectangle, in cells, which is the whole of what an inventory grid is.
  result = false
  var i = 0
  while i < things.len:
    if i != ignore and things[i].bag == which:
      let apart = column + wide <= things[i].column or
        things[i].column + things[i].wide <= column or
        row + tall <= things[i].row or
        things[i].row + things[i].tall <= row
      if not apart: result = true
    i = i + 1

## Put a thing in a bag at a cell, if it will go there. Answers whether it
## went, so a refused move can say so instead of silently doing nothing.
proc place*(id: string; which, column, row: int): bool =
  let i = indexOf(id)
  if i < 0: return false
  let g = bagOf(which)
  if not fits(g, column, row, things[i].wide, things[i].tall): return false
  if blocked(which, column, row, things[i].wide, things[i].tall, i): return false
  things[i].bag = which
  things[i].column = column
  things[i].row = row
  result = true

## The caption of whatever is being carried, for the ghost under the pointer.
proc carriedCaption(): string =
  if not carrying(): return ""
  thingAt(carried().id).caption

proc drawBag(which: int) =
  let g = bagOf(which)
  inside bagName(which):
    heading(rect(g.at.x, g.at.y - 30.0, 200.0, 24.0), bagName(which))
    var r = 0
    while r < g.rows:
      var c = 0
      while c < g.columns:
        inside $(r * g.columns + c):
          let landed = slot("cell", cellAt(g, c, r), "item")
          if landed.dropped:
            discard place(landed.load.id, which, c, r)
        c = c + 1
      r = r + 1
    var i = 0
    while i < things.len:
      if things[i].bag == which:
        let box = span(g, things[i].column, things[i].row,
          things[i].wide, things[i].tall)
        discard tile(things[i].id, box, things[i].caption,
          carry("item", things[i].id, 1))
      i = i + 1

# ---------------------------------------------------- the scissor and the wheel --
#
# The strip along the bottom is the two things the drawing floor could not do
# until the host grew a scissor and a wheel, and it is here rather than in a
# test because both of them are things you have to look at once.
#
# The field's caption is longer than the field. Put the caret at its end and the
# text slides left and stops dead at the border, cut mid-letter - which is the
# scissor; before it, the string ran out over whatever was beside it and the
# field could not scroll sideways at all, because sliding the text only moved
# the spill. The list beside it has forty rows in a box that holds three, so its
# top and bottom rows are always half-rows - which is the same scissor - and the
# wheel moves it without touching the bar.

var caption*: Edit
var lines: seq[string] = @[]

proc setUpNotes*() =
  caption = editable("A caption long enough to run out of the end of this field")
  lines = @[]
  var i = 0
  while i < 40:
    lines.add "line " & $(i + 1) & " - a row of a list that scrolls"
    i = i + 1

## How far the list has been scrolled, said out loud, so a headless run reads
## the wheel back rather than looking at a picture of it.
proc listScroll*(): float64 = scrollOf("notes/lines")
## And how far the field's text has slid inside its own border.
proc captionScroll*(): float64 = scrollOf("notes/caption/x")

proc notesStrip*() =
  if lines.len == 0: setUpNotes()
  let strip = rect(30.0, 492.0, 700.0, 96.0)
  panel(strip)
  inside "notes":
    hint(rect(46.0, 498.0, 320.0, 18.0), "A field that scrolls sideways")
    discard textField("caption", rect(46.0, 520.0, 200.0, 30.0), caption)
    hint(rect(386.0, 498.0, 320.0, 18.0), "A list the wheel moves, half-rows and all")
    let list = beginList("lines", rect(386.0, 520.0, 320.0, 58.0), lines.len, 24.0)
    var i = list.first
    while i < list.last:
      let row = rowAt(list, i)
      if i mod 2 == 0: paint(row, style().slot)
      paint(lines[i], row.inset(6.0), style().small, AlignLeft, style().ink)
      i = i + 1
    endList(list)

## The whole screen, between one `beginFrame` and one `endFrame`.
proc inventoryScreen*() =
  panel(rect(30.0, 60.0, 700.0, 420.0))
  heading(rect(50.0, 74.0, 400.0, 26.0), "INVENTORY")
  hint(rect(50.0, 100.0, 400.0, 20.0), "Drag a thing from one bag to the other")
  drawBag(Stash)
  drawBag(Pouch)
  notesStrip()
  ghost(carriedCaption())

## Where everything is, in one line, so a headless run can read the arrangement
## back rather than look at a picture of it.
proc arrangement*(): string =
  result = ""
  var i = 0
  while i < things.len:
    if i > 0: result = result & " "
    result = result & things[i].id & "@" & bagName(things[i].bag) & ":" &
      $things[i].column & "," & $things[i].row
    i = i + 1
