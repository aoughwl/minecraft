## A text field a person can actually type into.
##
## Everything above the widget in this file is arithmetic on a string and two
## integers. One pair of procs in it - `caretNear` and `caretX`, which turn a
## pixel into a caret and back - has to measure, and measuring needs the font, so
## those two reach `textWidth` and nothing else does. That is not tidiness; it is
## where the boundary had to fall. The host surface is being frozen; this library is
## not. So the host answers only what an operating system knows (the clipboard,
## the input method, how fast a held key repeats) and every rule about what a
## caret does lives here, where it can still be wrong on a Tuesday and right on a
## Wednesday.
##
##   var box = editable("Hello")
##
##   proc drawGui() =
##     beginFrame()
##     textField("name", rect(20.0, 20.0, 300.0, 28.0), box)
##     endFrame()
##
## **What a field is.** A string in UTF-8, a caret, and an anchor. The selection
## is everything between the caret and the anchor; when they are equal there is
## none. Both are **byte offsets**, always on a character boundary, because the
## text is UTF-8 and a caret counted in anything else has to be converted by
## whoever draws it.
##
## **What it does.** Click to place the caret, drag to select, double-click a
## word, triple-click the lot. Left and right by one character; with Ctrl by one
## word; with Shift, extending instead of moving. Home and End. Backspace and
## Delete, over a selection when there is one. Ctrl+A, Ctrl+C, Ctrl+X, Ctrl+V,
## Ctrl+Z and Ctrl+Y. A held key repeats at whatever rate the person set in their
## own settings. And a composition in progress is drawn at the caret, underlined,
## outside the document - which is the part everybody gets wrong, and the reason
## a field that works in English is unusable in Japanese.
##
## **What a character is, honestly.** `nextChar` and `prevChar` step over one
## code point and then over anything that hangs off it - combining accents,
## variation selectors, and a zero-width joiner with whatever follows it. That
## covers accented Latin, most emoji, and Hebrew and Arabic marks. It is not the
## whole of UAX #29: Hangul jamo sequences and Indic consonant clusters step one
## code point at a time. Fixing that is a table in this file, which is to say a
## mod update, which is exactly why the rule is here and not in the host.
##
## **What it is not.** One line. A paste with newlines in it puts spaces in
## instead, because a single-line field that silently swallowed half a clipboard
## would be worse. Multi-line wants a line index and a preferred column, and both
## are more arithmetic in this same file whenever somebody needs them.

import jester
import vec
import color
import input
import draw
import text
import ui
export ui
export input

# =========================================================== pure arithmetic ==
#
# From here to the widget the only host call is textWidth, and only the two
# procs that turn pixels into carets make it. Every rule below runs in a test
# with no Unity, no screen and no keyboard.

type Edit* = object
  ## One field's whole state. Keep it in a `var` the mod owns, the same way it
  ## keeps whatever a `toggle` last answered.
  text*: string
  caret*: int
    ## Byte offset into `text`, always on a character boundary.
  anchor*: int
    ## The other end of the selection. Equal to `caret` when nothing is selected.
  history: seq[string]
  historyCaret: seq[int]
  future: seq[string]
  futureCaret: seq[int]
  joining: bool
    ## The last edit was typing, so the next typed character joins it rather than
    ## becoming an undo step of its own. Otherwise Ctrl+Z would undo one letter
    ## at a time, which nobody wants and every first draft does.

## A field holding this text, with the caret at the end of it.
proc editable*(text = ""): Edit =
  Edit(text: text, caret: text.len, anchor: text.len,
    history: @[], historyCaret: @[], future: @[], futureCaret: @[],
    joining: false)

# ---- bytes and characters ---------------------------------------------------

proc continues(c: char): bool =
  ## A UTF-8 continuation byte - the second and later byte of one character.
  c >= '\x80' and c < '\xC0'

## The code point that starts at `at`, or -1 when there is none.
proc codeAt*(text: string; at: int): int =
  if at < 0 or at >= text.len: return -1
  let first = ord(text[at])
  if first < 0x80: return first
  if first < 0xE0:
    if at + 1 >= text.len: return first
    return ((first and 0x1F) shl 6) or (ord(text[at + 1]) and 0x3F)
  if first < 0xF0:
    if at + 2 >= text.len: return first
    return ((first and 0x0F) shl 12) or ((ord(text[at + 1]) and 0x3F) shl 6) or
      (ord(text[at + 2]) and 0x3F)
  if at + 3 >= text.len: return first
  ((first and 0x07) shl 18) or ((ord(text[at + 1]) and 0x3F) shl 12) or
    ((ord(text[at + 2]) and 0x3F) shl 6) or (ord(text[at + 3]) and 0x3F)

proc pointAfter(text: string; at: int): int =
  ## Past one code point.
  if at >= text.len: return text.len
  var j = at + 1
  while j < text.len and continues(text[j]): j = j + 1
  j

proc pointBefore(text: string; at: int): int =
  if at <= 0: return 0
  var j = at - 1
  while j > 0 and continues(text[j]): j = j - 1
  j

proc hangsOn(code: int): bool =
  ## A code point that belongs to the character in front of it rather than being
  ## one of its own: combining marks, variation selectors, and the joiner.
  (code >= 0x0300 and code <= 0x036F) or
  (code >= 0x0483 and code <= 0x0489) or
  (code >= 0x0591 and code <= 0x05BD) or
  (code >= 0x0610 and code <= 0x061A) or
  (code >= 0x064B and code <= 0x065F) or
  (code >= 0x1AB0 and code <= 0x1AFF) or
  (code >= 0x1DC0 and code <= 0x1DFF) or
  (code >= 0x20D0 and code <= 0x20FF) or
  (code >= 0xFE00 and code <= 0xFE0F) or
  (code >= 0xFE20 and code <= 0xFE2F) or
  code == 0x200D

## The offset one character after `at` - a code point, plus whatever hangs off
## it. A joiner drags the next code point along with it, so a family emoji is one
## backspace and not seven.
proc nextChar*(text: string; at: int): int =
  if at >= text.len: return text.len
  var j = pointAfter(text, at)
  var joined = codeAt(text, at) == 0x200D
  var going = true
  while going and j < text.len:
    let code = codeAt(text, j)
    if joined:
      joined = false
      j = pointAfter(text, j)
    elif hangsOn(code):
      joined = code == 0x200D
      j = pointAfter(text, j)
    else:
      going = false
  j

## The offset one character before `at`.
proc prevChar*(text: string; at: int): int =
  if at <= 0: return 0
  var j = pointBefore(text, at)
  while j > 0:
    let code = codeAt(text, j)
    if not hangsOn(code): break
    j = pointBefore(text, j)
  # A joiner in front of what we landed on means the thing before it came along
  # too.
  while j > 0:
    let before = pointBefore(text, j)
    if codeAt(text, before) != 0x200D: break
    j = pointBefore(text, before)
  j

## The part of `text` from `a` up to but not including `b`. Spelled out rather
## than sliced because the interpreter intercepts a proc called `substr`.
proc piece*(text: string; a, b: int): string =
  result = ""
  var i = a
  if i < 0: i = 0
  var stop = b
  if stop > text.len: stop = text.len
  while i < stop:
    result.add text[i]
    i = i + 1

# ---- words ------------------------------------------------------------------

type CharClass* = enum
  Blank, Wordish, Marking

## What kind of thing this byte begins. Everything outside ASCII counts as part
## of a word, which is right for every language whose words are letters and
## wrong for Chinese, where word boundaries need a dictionary and Ctrl+arrow
## therefore steps a run of ideographs at a time. That is the same thing a
## browser does.
proc classOf*(text: string; at: int): CharClass =
  if at < 0 or at >= text.len: return Blank
  let c = text[at]
  if c == ' ' or c == '\t' or c == '\n' or c == '\r': return Blank
  if (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
     (c >= '0' and c <= '9') or c == '_' or c >= '\x80': return Wordish
  Marking

## Where the word containing or preceding `at` starts - what Ctrl+Left goes to.
## Blanks in front of the caret are stepped over first, which is what every text
## field on the machine does.
proc wordBefore*(text: string; at: int): int =
  var i = at
  while i > 0 and classOf(text, prevChar(text, i)) == Blank: i = prevChar(text, i)
  if i == 0: return 0
  let kind = classOf(text, prevChar(text, i))
  while i > 0 and classOf(text, prevChar(text, i)) == kind: i = prevChar(text, i)
  i

## Where the word after `at` ends - what Ctrl+Right goes to.
proc wordAfter*(text: string; at: int): int =
  var i = at
  while i < text.len and classOf(text, i) == Blank: i = nextChar(text, i)
  if i >= text.len: return text.len
  let kind = classOf(text, i)
  while i < text.len and classOf(text, i) == kind: i = nextChar(text, i)
  i

type Span* = object
  ## A run of text, as two byte offsets.
  first*, last*: int

## The word `at` is inside, as a start and an end - what a double-click selects.
## Landing in a run of blanks selects the blanks, so double-clicking a gap does
## something rather than nothing.
proc wordAround*(text: string; at: int): Span =
  if text.len == 0: return Span(first: 0, last: 0)
  var where = at
  if where >= text.len: where = prevChar(text, text.len)
  let kind = classOf(text, where)
  var a = where
  while a > 0 and classOf(text, prevChar(text, a)) == kind: a = prevChar(text, a)
  var b = where
  while b < text.len and classOf(text, b) == kind: b = nextChar(text, b)
  Span(first: a, last: b)

# ---- the selection ----------------------------------------------------------

proc selectionStart*(e: Edit): int =
  if e.caret < e.anchor: e.caret else: e.anchor
proc selectionEnd*(e: Edit): int =
  if e.caret < e.anchor: e.anchor else: e.caret
proc hasSelection*(e: Edit): bool = e.caret != e.anchor
## The selected text, or empty when nothing is selected. What Ctrl+C puts on the
## clipboard.
proc selectedText*(e: Edit): string =
  piece(e.text, selectionStart(e), selectionEnd(e))

proc place*(e: var Edit; at: int; extend = false) =
  ## Put the caret at a byte offset, dragging the anchor with it unless the
  ## selection is being extended.
  var to = at
  if to < 0: to = 0
  if to > e.text.len: to = e.text.len
  e.caret = to
  if not extend: e.anchor = to
  e.joining = false

proc selectAll*(e: var Edit) =
  e.anchor = 0
  e.caret = e.text.len
  e.joining = false

proc selectRange*(e: var Edit; a, b: int) =
  e.anchor = a
  e.caret = b
  e.joining = false

# ---- undo -------------------------------------------------------------------

const UndoDepth = 200

proc snapshot(e: var Edit; joins: bool) =
  ## Remember where the text was before an edit, unless this edit is a
  ## continuation of the last one. Typing a sentence is one undo step; typing a
  ## sentence, moving the caret, and typing another is two.
  if joins and e.joining: return
  e.history.add e.text
  e.historyCaret.add e.caret
  if e.history.len > UndoDepth:
    # Drop the oldest by rebuilding, because there is no cheap shift here and a
    # field this deep in history is not in a hot loop.
    var keptText: seq[string] = @[]
    var keptCaret: seq[int] = @[]
    var i = e.history.len - UndoDepth
    while i < e.history.len:
      keptText.add e.history[i]
      keptCaret.add e.historyCaret[i]
      i = i + 1
    e.history = keptText
    e.historyCaret = keptCaret
  e.future = @[]
  e.futureCaret = @[]
  e.joining = joins

## Put the text back the way it was before the last edit. True when there was
## one.
proc undo*(e: var Edit): bool =
  if e.history.len == 0: return false
  e.future.add e.text
  e.futureCaret.add e.caret
  let last = e.history.len - 1
  e.text = e.history[last]
  e.caret = e.historyCaret[last]
  e.anchor = e.caret
  e.history.setLen last
  e.historyCaret.setLen last
  e.joining = false
  true

## Put back what undo took away.
proc redo*(e: var Edit): bool =
  if e.future.len == 0: return false
  e.history.add e.text
  e.historyCaret.add e.caret
  let last = e.future.len - 1
  e.text = e.future[last]
  e.caret = e.futureCaret[last]
  e.anchor = e.caret
  e.future.setLen last
  e.futureCaret.setLen last
  e.joining = false
  true

## How many undo steps are waiting - what a menu greys itself out by.
proc undoDepth*(e: Edit): int = e.history.len

# ---- editing ----------------------------------------------------------------

## Take the selection out. True when there was one.
proc removeSelection*(e: var Edit): bool =
  if not hasSelection(e): return false
  let a = selectionStart(e)
  let b = selectionEnd(e)
  snapshot(e, false)
  e.text = piece(e.text, 0, a) & piece(e.text, b, e.text.len)
  e.caret = a
  e.anchor = a
  true

proc putIn(e: var Edit; what: string; joins: bool) =
  if hasSelection(e):
    let a = selectionStart(e)
    let b = selectionEnd(e)
    snapshot(e, false)
    e.text = piece(e.text, 0, a) & what & piece(e.text, b, e.text.len)
    e.caret = a + what.len
  else:
    snapshot(e, joins)
    e.text = piece(e.text, 0, e.caret) & what & piece(e.text, e.caret, e.text.len)
    e.caret = e.caret + what.len
  e.anchor = e.caret

## What the person typed, one keystroke at a time. Consecutive typing is one
## undo step.
proc typeIn*(e: var Edit; what: string) =
  if what.len == 0: return
  putIn(e, what, true)

## Text from somewhere that is not the keyboard - a paste, a completion, a value
## dropped in. Always its own undo step, because undoing a paste a letter at a
## time is not what anybody means by Ctrl+Z.
##
## Newlines become spaces: this is a one-line field, and a paste that silently
## lost everything after the first line would be worse than one that flattened
## it.
proc insert*(e: var Edit; what: string) =
  if what.len == 0: return
  var flat = ""
  var i = 0
  while i < what.len:
    let c = what[i]
    if c == '\n' or c == '\r' or c == '\t': flat.add ' '
    else: flat.add c
    i = i + 1
  putIn(e, flat, false)

## Backspace: the selection when there is one, otherwise the character before
## the caret - the whole character, accents and all.
proc backOne*(e: var Edit) =
  if removeSelection(e): return
  if e.caret <= 0: return
  let from0 = prevChar(e.text, e.caret)
  snapshot(e, false)
  e.text = piece(e.text, 0, from0) & piece(e.text, e.caret, e.text.len)
  e.caret = from0
  e.anchor = from0

## Delete: the selection when there is one, otherwise the character after.
proc deleteOne*(e: var Edit) =
  if removeSelection(e): return
  if e.caret >= e.text.len: return
  let to = nextChar(e.text, e.caret)
  snapshot(e, false)
  e.text = piece(e.text, 0, e.caret) & piece(e.text, to, e.text.len)
  e.anchor = e.caret

## Replace everything, as a single undo step - what a mod does when the value
## behind the field changed underneath it.
proc setText*(e: var Edit; what: string) =
  if e.text == what: return
  snapshot(e, false)
  e.text = what
  e.caret = what.len
  e.anchor = what.len

# ---- keys, as rules rather than as reads ------------------------------------

type Stroke* = object
  ## One key going down, with the modifiers that were held with it. The widget
  ## builds these from the host; a test builds them out of thin air, which is
  ## how every rule below is proved without a keyboard.
  key*: Key
  shift*, ctrl*: bool

proc stroke*(k: Key; shift = false; ctrl = false): Stroke =
  Stroke(key: k, shift: shift, ctrl: ctrl)

## What one key does to a field, and nothing about where the key came from.
##
## Clipboard keys are not here: Ctrl+C, Ctrl+X and Ctrl+V need the host, so the
## widget wires them, out of `selectedText`, `removeSelection` and `insert`.
## Everything else - moving, extending, deleting, selecting, undoing - is a rule,
## and rules live where they can be changed.
proc apply*(e: var Edit; s: Stroke): bool =
  result = true
  case s.key
  of LeftArrow:
    if s.ctrl: place(e, wordBefore(e.text, e.caret), s.shift)
    elif hasSelection(e) and not s.shift: place(e, selectionStart(e))
    else: place(e, prevChar(e.text, e.caret), s.shift)
  of RightArrow:
    if s.ctrl: place(e, wordAfter(e.text, e.caret), s.shift)
    elif hasSelection(e) and not s.shift: place(e, selectionEnd(e))
    else: place(e, nextChar(e.text, e.caret), s.shift)
  of Home, UpArrow: place(e, 0, s.shift)
  of End, DownArrow: place(e, e.text.len, s.shift)
  of Backspace:
    if s.ctrl and not hasSelection(e):
      selectRange(e, wordBefore(e.text, e.caret), e.caret)
    backOne(e)
  of Delete:
    if s.ctrl and not hasSelection(e):
      selectRange(e, e.caret, wordAfter(e.text, e.caret))
    deleteOne(e)
  of A:
    if s.ctrl: selectAll(e) else: result = false
  of Z:
    if s.ctrl and s.shift: result = redo(e)
    elif s.ctrl: result = undo(e)
    else: result = false
  of Y:
    if s.ctrl: result = redo(e) else: result = false
  else: result = false

# ---- where a click lands ----------------------------------------------------

## Which byte offset a point `x` pixels into the drawn text is nearest to.
##
## This measures, so it is the one thing above the widget that reaches the host -
## `textWidth` is a host call because only the host has the font. It rounds to
## the nearer edge of a character rather than its start, which is why clicking
## the right half of a letter puts the caret after it, and why anything else
## feels wrong without a person being able to say why.
proc caretNear*(text: string; x, size: float64): int =
  if text.len == 0 or x <= 0.0: return 0
  var at = 0
  var last = 0.0
  while at < text.len:
    let to = nextChar(text, at)
    let width = textWidth(piece(text, 0, to), size)
    if x < (last + width) * 0.5: return at
    if x < width: return to
    last = width
    at = to
  text.len

## How far into the drawn text a byte offset is, in pixels - where to draw the
## caret, and where a selection starts and stops.
proc caretX*(text: string; at: int; size: float64): float64 =
  textWidth(piece(text, 0, at), size)

# ================================================================ the widget ==
#
# From here down the host is read: the keys that are down, the clipboard, the
# composition, and the clock a repeat is timed against.

type Pressing = object
  key: Key
  shift, ctrl: bool
  next: float64

var
  focused = ""
  repeating = Pressing(key: NoKey, shift: false, ctrl: false, next: 0.0)
  lastClickAt = 0.0
  lastClickWhere = 0.0
  clickRun = 0
  blinkFrom = 0.0

## Which field has the caret, by its full id. Empty when none does.
proc focusedField*(): string = focused

## Give a field the caret, or take it away with an empty name. A mod calls this
## to open a dialogue with the cursor already in the right box.
proc focusField*(id: string) =
  if focused == id: return
  focused = id
  composedText(id.len > 0)
  blinkFrom = gameTime()
  # The host keeps typed characters until somebody asks for them, and while no
  # field has the caret nobody does. Without this, walking around on WASD and
  # then clicking a field types "wasd" into it.
  if id.len > 0: discard typed()

const Repeatable = [LeftArrow, RightArrow, Home, End, Backspace, Delete,
  UpArrow, DownArrow]

proc repeats(k: Key): bool =
  var i = 0
  while i < Repeatable.len:
    if Repeatable[i] == k: return true
    i = i + 1
  false

## Every key that should act this frame: the ones that went down, plus the one
## being held once it has waited out the person's own repeat delay. Held at the
## rate their settings say, not at a number picked here - somebody who turned
## their repeat speed up did that on purpose.
proc strokesThisFrame(): seq[Stroke] =
  result = @[]
  let shift = held(LeftShift) or held(RightShift)
  let ctrl = held(LeftCtrl) or held(RightCtrl)
  var i = 0
  const Watched = [LeftArrow, RightArrow, Home, End, Backspace, Delete,
    UpArrow, DownArrow, A, Z, Y]
  while i < Watched.len:
    let k = Watched[i]
    if pressed(k):
      result.add stroke(k, shift, ctrl)
      if repeats(k):
        repeating = Pressing(key: k, shift: shift, ctrl: ctrl,
          next: gameTime() + keyRepeatDelay())
    i = i + 1
  if repeating.key != NoKey:
    if not held(repeating.key):
      repeating = Pressing(key: NoKey, shift: false, ctrl: false, next: 0.0)
    elif gameTime() >= repeating.next:
      var rate = keyRepeatRate()
      if rate < 1.0: rate = 1.0
      repeating.next = gameTime() + 1.0 / rate
      repeating.shift = shift
      repeating.ctrl = ctrl
      result.add stroke(repeating.key, shift, ctrl)

## A field. Draws it, drives it, and answers true on any frame its text changed.
##
## Clicking inside it takes the caret; clicking anywhere else gives it up, which
## is why this has to be called every frame whether or not it is focused.
proc textField*(name: string; r: Rect; e: var Edit; hintText = ""): bool =
  result = false
  let id = here(name)
  let t = touch(name, r)
  let size = style().text
  let inner = r.inset(6.0)
  let mine = focused == id
  # How far the text has been slid left inside the box. Kept by name beside every
  # other scroll offset, so it survives the field being drawn somewhere else next
  # frame and survives a hot swap. The pointer is read against the offset the
  # last frame settled on, because this frame's is not known until the caret has
  # moved - which is the same order a scrolling list does it in.
  let track = id & "/x"
  let was = scrollOf(track)

  if t.grabbed and not mine: focusField(id)
  elif pointerPressed() and mine and not over(r): focusField("")

  # ---- the pointer picks the caret ----
  if t.grabbed:
    let at = caretNear(e.text, pointerAt().x - inner.x + was, size)
    let now = gameTime()
    var moved = pointerAt().x - lastClickWhere
    if moved < 0.0: moved = -moved
    if now - lastClickAt < doubleClickTime() and moved < 6.0:
      clickRun = clickRun + 1
    else:
      clickRun = 1
    lastClickAt = now
    lastClickWhere = pointerAt().x
    if clickRun >= 3:
      selectAll(e)
    elif clickRun == 2:
      let word = wordAround(e.text, at)
      selectRange(e, word.first, word.last)
    else:
      place(e, at)
    blinkFrom = now
  elif t.held and mine and clickRun == 1:
    place(e, caretNear(e.text, pointerAt().x - inner.x + was, size), true)

  # ---- the keyboard ----
  if mine:
    var strokes = strokesThisFrame()
    var i = 0
    while i < strokes.len:
      if apply(e, strokes[i]): result = true
      i = i + 1
    let ctrl = held(LeftCtrl) or held(RightCtrl)
    # Cut still cuts on a host with no clipboard - the text a person asked to
    # remove is removed, and only the copy half is lost. Silently doing neither
    # would be the worse of the two, and `clipboardTrouble()` is how a mod tells
    # them which one happened.
    let canCopy = clipboardAvailable()
    if ctrl and pressed(C) and hasSelection(e) and canCopy:
      clipboard(selectedText(e))
    if ctrl and pressed(X) and hasSelection(e):
      if canCopy: clipboard(selectedText(e))
      discard removeSelection(e)
      result = true
    if ctrl and pressed(V) and canCopy and clipboardHasText():
      insert(e, clipboard())
      result = true
    if not ctrl:
      let said = typed()
      if said.len > 0:
        typeIn(e, said)
        result = true
    if result: blinkFrom = gameTime()

  # ---- what it looks like ----
  var edge = style().edge
  if mine: edge = style().accent
  elif t.hot: edge = style().hot
  paint(r, style().slot)
  border(r, 1.0, edge)

  # ---- how far the text has slid ----
  #
  # The caret is kept inside the visible span and the text is drawn from
  # `inner.x - off`. This is only possible because the host has a scissor now:
  # without one, sliding the text left would move the spill rather than contain
  # it, so the field drew the whole string, overflowed its own border, and could
  # not scroll at all. The clip below is what cuts the glyph the border falls in.
  var off = 0.0
  if mine:
    off = was
    let atCaret = caretX(e.text, e.caret, size)
    let room = inner.width - 2.0
    if atCaret - off > room: off = atCaret - room
    if atCaret - off < 0.0: off = atCaret
    # Never scroll further than there is text to see, so deleting the tail of a
    # long line slides the start of it back into view instead of leaving a blank
    # box with a caret in it.
    let whole = textWidth(e.text, size) - room
    if off > whole: off = whole
    if off < 0.0: off = 0.0
  setScroll(track, off)
  let penX = inner.x - off

  pushClip(inner)

  if hasSelection(e):
    let a = penX + caretX(e.text, selectionStart(e), size)
    let b = penX + caretX(e.text, selectionEnd(e), size)
    paint(rect(a, inner.y + 2.0, b - a, inner.height - 4.0),
      style().accent.withAlpha(0.35))

  if e.text.len == 0 and hintText.len > 0 and not mine:
    paint(hintText, inner, size, AlignLeft, style().faint)
  elif mine:
    # The whole string, laid out from wherever the scroll put its start. The box
    # is widened by however far it slid so the line is still laid out left to
    # right inside something; what shows is decided by the clip, one glyph at a
    # time, not by shortening the string - which would put the caret in the
    # wrong place.
    paint(e.text, rect(penX, inner.y, inner.width + off, inner.height),
      size, AlignLeft, style().ink)
  else:
    paint(fitted(e.text, inner.width, size), inner, size, AlignLeft, style().ink)

  if mine:
    let x = penX + caretX(e.text, e.caret, size)
    # The composition is drawn where the caret is, underlined, and is NOT in the
    # document - it is not committed and may never be. Its own caret goes inside
    # it, which is how a person picking between candidates knows where they are.
    if composing():
      let run = composition()
      let wide = textWidth(run, size)
      paint(rect(x, inner.y + 2.0, wide, inner.height - 4.0),
        style().panel.withAlpha(0.9))
      paint(run, rect(x, inner.y, wide, inner.height), size, AlignLeft,
        style().ink)
      paint(rect(x, inner.y + inner.height - 3.0, wide, 1.0), style().accent)
      let inside = x + textWidth(piece(run, 0, compositionCaret()), size)
      paint(rect(inside, inner.y + 2.0, 1.0, inner.height - 4.0), style().ink)
      composeNear(vec2(x, inner.y + inner.height))
    else:
      # Blinking is timed from the last thing that happened, so the caret is
      # always solid at the moment a person looks for it.
      let phase = (gameTime() - blinkFrom) - float64(int((gameTime() - blinkFrom) / 1.06)) * 1.06
      if phase < 0.6:
        paint(rect(x, inner.y + 2.0, 1.0, inner.height - 4.0), style().ink)
      composeNear(vec2(x, inner.y + inner.height))

  popClip()
