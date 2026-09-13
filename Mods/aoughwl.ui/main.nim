## The mod that carries the UI library, and proves it at start().
##
## It draws nothing, spawns nothing and takes no input of its own. All it does
## is run the state machine in `ui_floor` against a pointer it makes up, and say
## whether the machine did what it says it does. Every check below is a rule the
## library holds - a click is a press that comes up where it went down, a drag
## is a press that moved, a drop lands on whichever target was topmost - and
## every one of them runs with no screen, no camera and no host call but `log`,
## which is why it is proof and not a screenshot.
##
## `beginFrame(at, down, area)` is the seam that makes that possible, and it is
## not a test hatch: it is how a mod drives its interface from anything that is
## not the mouse.

import jester
import vec
import ui
import example
import textfield

let area = rect(0.0, 0.0, 800.0, 600.0)

var
  checks = 0
  failures = 0

proc expect(what: string; ok: bool) =
  checks = checks + 1
  if not ok:
    failures = failures + 1
    log("ui self-check failed: " & what)

proc frameAt(x, y: float64; down: bool) =
  beginFrame(vec2(x, y), down, area)

proc frameAt(x, y: float64; down: bool; turn: float64) =
  beginFrame(vec2(x, y), down, area, turn)

## Two frames with the pointer up and far away from anything, which is enough
## to retire a press, a hover and a landing from whatever ran before.
proc settle() =
  frameAt(4.0, 4.0, false)
  endFrame()
  frameAt(4.0, 4.0, false)
  endFrame()

# ------------------------------------------------------------------ layout --

proc checkLayout() =
  var down = column(rect(10.0, 20.0, 200.0, 400.0), 5.0)
  let first = down.take(30.0)
  let second = down.take(40.0)
  expect("a column starts at the top",
    first.y == 20.0 and first.height == 30.0 and first.width == 200.0)
  expect("the next row is under the first and the gap",
    second.y == 55.0 and second.height == 40.0)
  expect("what is left starts under both", rest(down).y == 100.0)
  expect("what was taken is as tall as the rows and the gap between them",
    taken(down).height == 75.0)

  var right = across(rect(0.0, 0.0, 300.0, 40.0), 10.0)
  let left = right.take(100.0)
  let next = right.take(50.0)
  expect("a row starts at the left", left.x == 0.0 and left.width == 100.0)
  expect("the next column is beside the first", next.x == 110.0)

  let three = share(rect(0.0, 0.0, 320.0, 40.0), 3, 10.0, Rightward)
  expect("three shares of a rectangle are three", three.len == 3)
  expect("they divide what is left after the gaps",
    three[0].width == 100.0 and three[2].x == 220.0)

proc checkGrid() =
  let g = grid(vec2(100.0, 100.0), 5, 3, 40.0, 2.0)
  expect("a grid is as wide as its cells and its gaps",
    bounds(g).width == 208.0 and bounds(g).height == 124.0)
  expect("a cell is where the arithmetic says",
    cellAt(g, 2, 1) == rect(184.0, 142.0, 40.0, 40.0))
  expect("a block of cells spans the gaps inside it",
    span(g, 0, 0, 4, 1).width == 166.0)
  let inCell = cellUnder(g, vec2(190.0, 150.0))
  expect("a point finds its cell",
    inCell.inside and inCell.column == 2 and inCell.row == 1)
  expect("a point in a gap is in no cell",
    not cellUnder(g, vec2(141.0, 150.0)).inside)
  expect("a point off the grid is in no cell",
    not cellUnder(g, vec2(600.0, 150.0)).inside)
  expect("a block that fits along the row fits", fits(g, 1, 0, 4, 1))
  expect("a block that runs off the edge does not",
    not fits(g, 2, 0, 4, 1) and not fits(g, 0, 2, 1, 2))

# -------------------------------------------------------------- clip and id --

proc checkClipAndId() =
  settle()
  let far = rect(120.0, 120.0, 60.0, 60.0)
  frameAt(150.0, 150.0, false)
  expect("nothing is cropped to start with", over(far))
  pushClip(rect(0.0, 0.0, 100.0, 100.0))
  expect("a rectangle outside the clip cannot be touched", not over(far))
  expect("and is not visible either", not visible(far))
  pushClip(rect(0.0, 0.0, 400.0, 400.0))
  expect("a wider clip inside a narrower one does not widen it", not over(far))
  popClip()
  popClip()
  expect("the clip comes back off", over(far))

  expect("a plain name is itself", here("slot") == "slot")
  pushId("bag")
  expect("a nested name carries its scope", here("slot") == "bag/slot")
  pushId(2)
  expect("an index is a scope like any other", here("slot") == "bag/2/slot")
  popId()
  popId()
  expect("the scope comes back off", here("slot") == "slot")
  endFrame()

# ----------------------------------------------------------------- pressing --

proc checkButton() =
  settle()
  let box = rect(100.0, 100.0, 120.0, 40.0)

  frameAt(150.0, 120.0, false)
  var t = touch("go", box)
  endFrame()
  expect("hovering is not clicking", t.hot and not t.held and not t.clicked)

  frameAt(150.0, 120.0, true)
  t = touch("go", box)
  endFrame()
  expect("a press grabs and does not yet click",
    t.grabbed and t.held and not t.clicked)

  frameAt(150.0, 120.0, true)
  t = touch("go", box)
  endFrame()
  expect("a held press is not grabbed again", t.held and not t.grabbed)

  frameAt(150.0, 120.0, false)
  t = touch("go", box)
  endFrame()
  expect("the click happens when the press comes up", t.clicked)

  frameAt(150.0, 120.0, false)
  t = touch("go", box)
  endFrame()
  expect("and happens once", not t.clicked)

proc checkPressLeaves() =
  settle()
  let box = rect(100.0, 100.0, 120.0, 40.0)
  frameAt(150.0, 120.0, false)
  discard touch("go", box)
  endFrame()
  frameAt(150.0, 120.0, true)
  discard touch("go", box)
  endFrame()
  frameAt(600.0, 400.0, true)
  var t = touch("go", box)
  endFrame()
  expect("a press that wandered off is still held", t.held)
  frameAt(600.0, 400.0, false)
  t = touch("go", box)
  endFrame()
  expect("letting go somewhere else is not a click", not t.clicked)

proc checkTopmost() =
  settle()
  let under = rect(100.0, 100.0, 200.0, 200.0)
  let over2 = rect(150.0, 150.0, 100.0, 100.0)
  frameAt(180.0, 180.0, false)
  discard touch("under", under)
  discard touch("over", over2)
  endFrame()
  frameAt(180.0, 180.0, false)
  let a = touch("under", under)
  let b = touch("over", over2)
  endFrame()
  expect("the one drawn later takes the pointer", b.hot and not a.hot)

  frameAt(180.0, 180.0, true)
  let a2 = touch("under", under)
  let b2 = touch("over", over2)
  endFrame()
  expect("and takes the press with it", b2.grabbed and not a2.grabbed)

proc checkScopedNames() =
  settle()
  let left = rect(100.0, 100.0, 50.0, 50.0)
  let right = rect(300.0, 100.0, 50.0, 50.0)
  frameAt(120.0, 120.0, true)
  pushId("left")
  let one = touch("cell", left)
  popId()
  pushId("right")
  let two = touch("cell", right)
  popId()
  endFrame()
  expect("the same widget name in two scopes is two widgets",
    one.grabbed and not two.grabbed)

# ------------------------------------------------------------ drag and drop --

let source = rect(100.0, 100.0, 60.0, 60.0)
let target = rect(400.0, 100.0, 60.0, 60.0)

proc bandage(): Carry = carry("item", "bandage", 2)

proc checkDrag() =
  settle()

  frameAt(130.0, 130.0, false)
  var d = drag("item", source, bandage())
  var z = dropZone("bin", target, "item")
  endFrame()
  expect("hovering carries nothing", not carrying() and not d.dragging)
  expect("a target that nothing is over is quiet", not z.over)

  frameAt(130.0, 130.0, true)
  d = drag("item", source, bandage())
  endFrame()
  expect("a press alone is not a drag", not carrying() and not d.dragging)

  frameAt(200.0, 130.0, true)
  d = drag("item", source, bandage())
  z = dropZone("bin", target, "item")
  endFrame()
  expect("moving far enough picks it up", d.dragging and carrying())
  expect("of the kind it said", carrying("item") and not carrying("gun"))
  expect("carrying what it was given",
    carried().id == "bandage" and carried().count == 2)
  expect("and remembering where it was taken hold of",
    carried().grip.x == 30.0 and carried().grip.y == 30.0)
  expect("and how big it was",
    carried().size.x == 60.0 and carried().size.y == 60.0)
  expect("and which source it left", carried().source == "item")
  expect("the ghost hangs under the pointer where it was picked up",
    ghostRect().x == 170.0 and ghostRect().y == 100.0)

  frameAt(430.0, 130.0, true)
  d = drag("item", source, bandage())
  z = dropZone("bin", target, "item")
  endFrame()
  expect("a target under a live drag lights up", z.over and not z.dropped)

  frameAt(430.0, 130.0, false)
  d = drag("item", source, bandage())
  z = dropZone("bin", target, "item")
  expect("letting go over a target drops there", z.dropped)
  expect("and hands over what was carried",
    z.load.id == "bandage" and z.load.count == 2)
  endFrame()

  frameAt(430.0, 130.0, false)
  let where = landing()
  expect("the landing is announced the frame after",
    where.happened and where.target == "bin")
  expect("with the load on it", where.load.id == "bandage")
  expect("and nothing is carried any more", not carrying())
  endFrame()

  frameAt(430.0, 130.0, false)
  expect("the landing is announced once", not landing().happened)
  endFrame()

proc checkRefusedDrag() =
  settle()
  frameAt(130.0, 130.0, false)
  discard drag("item", source, bandage())
  endFrame()
  frameAt(130.0, 130.0, true)
  discard drag("item", source, bandage())
  endFrame()
  frameAt(430.0, 130.0, true)
  discard drag("item", source, bandage())
  let z = dropZone("guns", target, "gun")
  endFrame()
  expect("a target that does not take this kind stays quiet", not z.over)

  frameAt(430.0, 130.0, false)
  let z2 = dropZone("guns", target, "gun")
  expect("and does not catch it", not z2.dropped)
  endFrame()

  frameAt(430.0, 130.0, false)
  let where = landing()
  expect("a drag nobody caught still lands, on nothing",
    where.happened and where.target.len == 0)
  expect("with the load still on it", where.load.id == "bandage")
  endFrame()

proc checkClickIsNotDrag() =
  settle()
  frameAt(130.0, 130.0, false)
  discard drag("item", source, bandage())
  endFrame()
  frameAt(130.0, 130.0, true)
  discard drag("item", source, bandage())
  endFrame()
  frameAt(131.0, 130.0, false)
  let d = drag("item", source, bandage())
  expect("a press that barely moved is a click and never a drag",
    d.clicked and not d.dragging)
  endFrame()
  frameAt(131.0, 130.0, false)
  expect("and never lands anything", not landing().happened)
  endFrame()

proc checkCancel() =
  settle()
  frameAt(130.0, 130.0, false)
  discard drag("item", source, bandage())
  endFrame()
  frameAt(130.0, 130.0, true)
  discard drag("item", source, bandage())
  endFrame()
  frameAt(200.0, 130.0, true)
  discard drag("item", source, bandage())
  expect("picked up before cancelling", carrying())
  cancelDrag()
  expect("cancelling puts it down at once", not carrying())
  endFrame()
  frameAt(200.0, 130.0, true)
  let where = landing()
  expect("a cancelled drag lands on nothing",
    where.happened and where.target.len == 0)
  endFrame()

proc checkTopmostTarget() =
  settle()
  let wide = rect(380.0, 80.0, 200.0, 200.0)
  frameAt(130.0, 130.0, false)
  discard drag("item", source, bandage())
  endFrame()
  frameAt(130.0, 130.0, true)
  discard drag("item", source, bandage())
  endFrame()
  frameAt(430.0, 130.0, true)
  discard drag("item", source, bandage())
  discard dropZone("wide", wide, "item")
  discard dropZone("bin", target, "item")
  endFrame()
  frameAt(430.0, 130.0, true)
  discard drag("item", source, bandage())
  let big = dropZone("wide", wide, "item")
  let small = dropZone("bin", target, "item")
  endFrame()
  expect("the target drawn later takes the drag",
    small.over and not big.over)
  frameAt(430.0, 130.0, false)
  discard dropZone("wide", wide, "item")
  discard dropZone("bin", target, "item")
  endFrame()
  frameAt(430.0, 130.0, false)
  expect("and catches it", landing().target == "bin")
  endFrame()

# ------------------------------------------------------- the worked example --

## The inventory in `example.nim`, driven through a real drag with the drawing
## turned off. Nothing is stubbed: the same `slot()` and `tile()` calls a player
## would click on, the same grid arithmetic, the same drop resolution. Only the
## host calls are muted, which is what makes this runnable with no screen.
proc frameOfExample(at: Vec2; down: bool) =
  beginFrame(at, down, area)
  inventoryScreen()
  endFrame()

proc dragInExample(fromAt, toAt: Vec2) =
  frameOfExample(fromAt, false)
  frameOfExample(fromAt, true)
  frameOfExample(vec2(fromAt.x + 20.0, fromAt.y), true)
  frameOfExample(toAt, true)
  frameOfExample(toAt, true)
  frameOfExample(toAt, false)
  frameOfExample(toAt, false)

proc checkExample() =
  mute(true)
  setUpBags()
  expect("the example starts where it says it does",
    arrangement() == "bandage@stash:0,0 rifle@stash:0,2 mag@pouch:2,0")

  let stash = bagOf(Stash)
  let pouch = bagOf(Pouch)
  settle()
  dragInExample(centre(cellAt(stash, 0, 0)), centre(cellAt(pouch, 1, 1)))
  expect("dragging a thing between two bags moves it",
    arrangement() == "bandage@pouch:1,1 rifle@stash:0,2 mag@pouch:2,0")

  settle()
  dragInExample(centre(cellAt(pouch, 1, 1)), centre(cellAt(pouch, 2, 0)))
  expect("dropping onto an occupied cell is refused and changes nothing",
    arrangement() == "bandage@pouch:1,1 rifle@stash:0,2 mag@pouch:2,0")

  settle()
  dragInExample(centre(cellAt(stash, 1, 2)), centre(cellAt(stash, 4, 4)))
  expect("a four-wide thing is picked up anywhere along it and lands as a block",
    arrangement() == "bandage@pouch:1,1 rifle@stash:4,4 mag@pouch:2,0")

  settle()
  dragInExample(centre(cellAt(stash, 4, 4)), centre(cellAt(stash, 6, 4)))
  expect("and is refused where it would hang off the edge",
    arrangement() == "bandage@pouch:1,1 rifle@stash:4,4 mag@pouch:2,0")
  mute(false)


# ------------------------------------------------------------- text fields --
#
# The caret rules, driven as rules: every one of these is `apply()` fed a
# keystroke made up out of nothing, with no keyboard, no clipboard and no
# screen. A picture could show a caret; it could not show that shift-left
# extends a selection the anchor already owns, that Ctrl+Z undoes a typed word
# and not a typed letter, or that backspace over an accented character takes the
# accent with it.

proc checkCaretMoves() =
  var e = editable("hello world")
  expect("a new field has the caret at the end", e.caret == 11 and not hasSelection(e))
  place(e, 0)
  discard apply(e, stroke(RightArrow))
  expect("right goes one character", e.caret == 1)
  discard apply(e, stroke(RightArrow, false, true))
  expect("ctrl-right goes to the end of the word", e.caret == 5)
  discard apply(e, stroke(RightArrow, false, true))
  expect("and then past the next one", e.caret == 11)
  discard apply(e, stroke(LeftArrow, false, true))
  expect("ctrl-left comes back to the start of the word", e.caret == 6)
  discard apply(e, stroke(Home))
  expect("home is the start", e.caret == 0)
  discard apply(e, stroke(End))
  expect("end is the end", e.caret == 11)

proc checkSelection() =
  var e = editable("hello world")
  place(e, 0)
  discard apply(e, stroke(RightArrow, true))
  discard apply(e, stroke(RightArrow, true))
  expect("shift-right selects as it goes",
    hasSelection(e) and selectedText(e) == "he")
  discard apply(e, stroke(LeftArrow, true))
  expect("shift-left gives one back", selectedText(e) == "h")
  discard apply(e, stroke(RightArrow))
  expect("a plain right off a selection lands at its far end and clears it",
    e.caret == 1 and not hasSelection(e))
  discard apply(e, stroke(End, true, true))
  expect("shift-ctrl-end takes the rest", selectedText(e) == "ello world")
  discard apply(e, stroke(A, false, true))
  expect("ctrl-a takes all of it", selectedText(e) == "hello world")

proc checkWords() =
  let line = "one two, three"
  let first = wordAround(line, 1)
  expect("a double-click in a word takes the word",
    first.first == 0 and first.last == 3)
  let comma = wordAround(line, 7)
  expect("a double-click on punctuation takes the punctuation",
    comma.first == 7 and comma.last == 8)
  let gap = wordAround(line, 3)
  expect("a double-click in a gap takes the gap",
    gap.first == 3 and gap.last == 4)

proc checkEditing() =
  var e = editable("hello world")
  place(e, 5)
  discard apply(e, stroke(Backspace))
  expect("backspace takes the character before the caret", e.text == "hell world")
  discard apply(e, stroke(Delete))
  expect("delete takes the one after", e.text == "hellworld")
  selectRange(e, 0, 4)
  discard apply(e, stroke(Backspace))
  expect("backspace over a selection takes the selection",
    e.text == "world" and e.caret == 0)
  insert(e, "hello ")
  expect("a paste goes in at the caret", e.text == "hello world" and e.caret == 6)
  selectAll(e)
  insert(e, "new")
  expect("a paste over a selection replaces it", e.text == "new")

proc checkUndo() =
  var e = editable("")
  typeIn(e, "h")
  typeIn(e, "i")
  typeIn(e, "!")
  expect("typing runs together", e.text == "hi!" and undoDepth(e) == 1)
  discard undo(e)
  expect("one undo takes the whole run, not one letter", e.text == "")
  discard redo(e)
  expect("redo puts it back", e.text == "hi!")
  place(e, 0)
  typeIn(e, "oh ")
  expect("moving the caret starts a new run", undoDepth(e) == 2)
  discard undo(e)
  expect("so undo takes only the second run", e.text == "hi!")
  discard undo(e)
  expect("and the next takes the first", e.text == "")
  expect("nothing left to undo", not undo(e))

proc checkUtf8() =
  # "café" is five bytes: the e-acute is two of them. And a decomposed one -
  # "cafe" plus a combining acute - is one character to a person and two code
  # points to a machine, which is the case a byte-counting field gets wrong.
  var e = editable("caf\xC3\xA9")
  expect("the string is five bytes", e.text.len == 5)
  discard apply(e, stroke(Backspace))
  expect("backspace takes the whole accented character, both its bytes",
    e.text == "caf")
  var d = editable("cafe\xCC\x81")
  expect("a decomposed accent is six bytes", d.text.len == 6)
  discard apply(d, stroke(Backspace))
  expect("backspace takes the letter and the mark that sits on it",
    d.text == "caf")
  var j = editable("a\xE2\x9C\x8B\xE2\x80\x8D\xF0\x9F\xA6\xBAb")
  place(j, j.text.len - 1)
  discard apply(j, stroke(Backspace))
  expect("a joined emoji is one backspace, not two", j.text == "ab")

proc checkPasteIsOneStep() =
  var e = editable("")
  insert(e, "a line\nand another")
  expect("a paste with newlines in it comes into one line as spaces",
    e.text == "a line and another")
  discard undo(e)
  expect("and undoes in one step", e.text == "")

## The pointer half of a field, driven with no pointer: which field has the
## caret is a state machine like every other one in this library, and clicking
## the second field has to take the caret off the first. Where a click puts the
## caret needs the font and is proved by running it, not here - but which field
## it went to does not.
proc checkFieldFocus() =
  var first = editable("one")
  var second = editable("two")
  let a = rect(10.0, 10.0, 200.0, 24.0)
  let b = rect(10.0, 40.0, 200.0, 24.0)
  settle()
  focusField("")
  mute(true)
  frameAt(300.0, 300.0, false)
  discard textField("first", a, first)
  discard textField("second", b, second)
  endFrame()
  expect("nothing has the caret before anything is clicked",
    focusedField().len == 0)
  frameAt(20.0, 20.0, true)
  discard textField("first", a, first)
  discard textField("second", b, second)
  endFrame()
  expect("clicking a field gives it the caret", focusedField() == "first")
  frameAt(20.0, 50.0, false)
  discard textField("first", a, first)
  discard textField("second", b, second)
  endFrame()
  frameAt(20.0, 50.0, true)
  discard textField("first", a, first)
  discard textField("second", b, second)
  endFrame()
  expect("clicking the other one moves the caret to it",
    focusedField() == "second")
  frameAt(400.0, 400.0, false)
  discard textField("first", a, first)
  discard textField("second", b, second)
  endFrame()
  frameAt(400.0, 400.0, true)
  discard textField("first", a, first)
  discard textField("second", b, second)
  endFrame()
  expect("clicking away from every field gives the caret up",
    focusedField().len == 0)
  mute(false)
  focusField("")
  settle()
# ---------------------------------------------------------- wheel and scissor --
#
# The two host calls this library had been waiting for, checked as rules rather
# than looked at. `beginFrame` takes the wheel the same way it takes the pointer
# - as a fact handed in - so a notch of wheel is scripted here with no mouse
# anywhere, and the region moves exactly as far as it would under a real one.

proc checkWheel() =
  mute(true)
  settle()
  let box = rect(100.0, 100.0, 200.0, 120.0)

  frameAt(150.0, 150.0, false)
  var s = beginScroll("list", box, 600.0)
  endScroll(s)
  endFrame()
  expect("a region nobody turned the wheel over is at the top", s.offset == 0.0)

  frameAt(150.0, 150.0, false, -1.0)
  s = beginScroll("list", box, 600.0)
  endScroll(s)
  endFrame()
  expect("a notch towards you moves it down", s.offset > 0.0)
  let after = s.offset

  frameAt(150.0, 150.0, false, 1.0)
  s = beginScroll("list", box, 600.0)
  endScroll(s)
  endFrame()
  expect("a notch away from you moves it back the same distance",
    s.offset == 0.0 and after > 0.0)

  # The pointer decides which region hears it, so two lists side by side do not
  # both move - which is the whole reason the wheel is not simply a global.
  frameAt(700.0, 500.0, false, -1.0)
  s = beginScroll("list", box, 600.0)
  endScroll(s)
  endFrame()
  expect("the wheel does not move a region the pointer is not over",
    s.offset == 0.0)

  frameAt(150.0, 150.0, false, -20.0)
  s = beginScroll("list", box, 600.0)
  endScroll(s)
  endFrame()
  expect("and never past the end of what there is to see",
    s.offset == 600.0 - box.height)
  mute(false)
  settle()

## A field with more text in it than fits. Every number here is the offset the
## field slid its own text by, which is what "scrolls horizontally" means: it
## was flatly zero for ever before the host had a scissor, because with nothing
## to cut a glyph against sliding the text would only have moved the spill.
proc checkFieldScroll() =
  mute(true)
  settle()
  let box = rect(100.0, 300.0, 120.0, 30.0)
  var e = editable("a line of text far wider than the box it is being typed into")
  let id = "wide"

  focusField("")
  frameAt(4.0, 4.0, false)
  discard textField(id, box, e)
  endFrame()
  expect("a field nobody has clicked shows its start", scrollOf(id & "/x") == 0.0)

  # Click into it, which puts the caret where the pointer is - and then send the
  # caret to the end, which is the case that used to overflow the border.
  frameAt(150.0, 315.0, true)
  discard textField(id, box, e)
  endFrame()
  expect("clicking it takes the caret", focusedField() == id)

  place(e, e.text.len)
  frameAt(150.0, 315.0, false)
  discard textField(id, box, e)
  endFrame()
  let slid = scrollOf(id & "/x")
  expect("the caret at the end slides the text left", slid > 0.0)
  let inner = box.inset(6.0)
  expect("and slides it exactly far enough to keep the caret in view, no further",
    caretX(e.text, e.caret, style().text) - slid <= inner.width and
    caretX(e.text, e.caret, style().text) - slid >= inner.width - 4.0)

  place(e, 0)
  frameAt(150.0, 315.0, false)
  discard textField(id, box, e)
  endFrame()
  expect("the caret back at the start slides it home again",
    scrollOf(id & "/x") == 0.0)

  # Shorten the text until it fits and the field must come back to zero on its
  # own, rather than leaving a blank box with a caret in it.
  setText(e, "short")
  place(e, 5)
  frameAt(150.0, 315.0, false)
  discard textField(id, box, e)
  endFrame()
  expect("text that fits is never scrolled", scrollOf(id & "/x") == 0.0)
  focusField("")
  mute(false)
  settle()

# ---------------------------------------------------------------- lifecycle --

## The example screen is not drawn unless something asks for it - this is a
## library and libraries do not put panels on other people's games. A headless
## run turns it on to photograph it, or to drive it through the real painting
## path rather than the muted one.
var showing = false

proc showExample() =
  setUpBags()
  showing = true

proc hideExample() = showing = false

## Put the caret at the end of the example's caption, which is longer than the
## box it is in. That is the case the field could not draw before the host had a
## scissor - the string ran out past the border - and it is the case a headless
## run and a screenshot both want to see. A hook rather than a scripted click
## because a click puts the caret where the pointer is, and the end of the line
## is not somewhere a pointer can reach while the line is still spilling.
proc focusCaption() =
  setUpNotes()
  focusField("notes/caption")
  place(caption, caption.text.len)

proc drawGui() =
  if not showing: return
  beginFrame()
  inventoryScreen()
  endFrame()

## Where the example's things are now, said out loud, so a headless run reads
## the arrangement back instead of a picture of it.
proc sayArrangement() = log("ui example: " & arrangement())

proc start() =
  checkLayout()
  checkGrid()
  checkClipAndId()
  checkButton()
  checkPressLeaves()
  checkTopmost()
  checkScopedNames()
  checkDrag()
  checkRefusedDrag()
  checkClickIsNotDrag()
  checkCancel()
  checkTopmostTarget()
  checkExample()
  checkCaretMoves()
  checkSelection()
  checkWords()
  checkEditing()
  checkUndo()
  checkUtf8()
  checkPasteIsOneStep()
  checkFieldFocus()
  checkWheel()
  checkFieldScroll()
  settle()
  if failures == 0:
    log("ui self-check passed " & $checks & " checks")
  else:
    log("ui self-check FAILED " & $failures & " of " & $checks & " checks")

proc stop() =
  discard
