## A field you can type in, as arithmetic - and the rule that turns what was
## typed into a folder name.
##
## Two screens here need one: Create New World wants a name and a seed, and
## Direct Connect wants an address. Minecraft's `GuiTextField` is a rectangle,
## a string, a caret and a maximum length, and its editing is four operations.
## The host gives this mod the letters - `typed()` answers whatever the player
## pressed since the last frame, in their own keyboard layout - and the keys
## that are not letters arrive as keys. So everything below the letters is here
## and calls nothing.
##
## The SDK ships a `textField` of its own and `aoughwl.ui` ships a very
## good one with selection, undo and an IME. Neither is used here, and the
## reason is the same reason this mod draws its own buttons: a Minecraft field
## is a specific rectangle with a specific border drawn in a specific order, and
## a field that looked like the rest of our interface on a screen that looks
## like Minecraft would be the one thing on it that gave the game away.
##
## ## The folder rule, which is the interesting half
##
## `GuiCreateWorld.calcSaveDirName` is three lines and every one of them is a
## decision somebody had to make once:
##
##     saveDirName = worldNameField.getText().trim();
##     for (char c : ILLEGAL_FILE_CHARACTERS) saveDirName = saveDirName.replace(c, '_');
##     if (isEmpty(saveDirName)) saveDirName = "World";
##     saveDirName = FileUtil.getUniqueName(savesDir, saveDirName, "");
##
## Replace and not strip, so `a/b` and `ab` stay two different folders. `"World"`
## and not the empty string, because a folder has to be called something. And a
## numeric suffix on a collision, so naming two worlds the same is allowed and
## costs nothing - which is what a player who has three worlds called `test`
## needs. `"World"` there is a *file name* and not a word on the screen: it is
## never drawn, and `selectWorld.resultFolder` is the key that shows it.

const
  MaxFieldLength* = 32
    ## `GuiTextField`'s default. The seed field and the name field both take it.
  MaxAddressLength* = 128
    ## An address is longer than a name and Minecraft gives its own server
    ## address field 128.
  FieldWidth* = 200
  FieldHeight* = 20
  FieldTextInset* = 4
    ## The text starts four pixels inside the border.
  CaretBlinkTicks* = 6
    ## `cursorCounter / 6 % 2 == 0` - the caret is on for six ticks and off for
    ## six, which at twenty ticks a second is a little over three a second.
  FallbackFolder* = "World"
    ## Not a word on the screen. A folder has to be called something and this is
    ## what Minecraft calls it when the name was all punctuation.

  Illegal* = "/\n\r\t\x0C`?*\\<>|\":"
    ## `ILLEGAL_FILE_CHARACTERS`. Each of these becomes an underscore in the
    ## folder name, and each of them is legal in the *displayed* name - which is
    ## why the two are different strings and why the screen shows both.

type
  Field* = object
    text*: string
    caret*: int        ## how many characters are in front of it
    limit*: int
    focused*: bool

proc field*(text = ""; limit = MaxFieldLength): Field =
  Field(text: text, caret: text.len, limit: limit, focused: false)

## Whether a character may be typed into a field at all. Minecraft's
## `SharedConstants.isAllowedChatCharacter`: printable, and not the section sign
## it uses for colour codes. Everything below a space is a key and not a letter.
proc typeable*(c: char): bool =
  let n = int(c)
  n >= 32 and n != 127 and n != 167

proc insert*(f: var Field; what: string) =
  var i = 0
  while i < what.len:
    let c = what[i]
    inc i
    if not typeable(c): continue
    if f.text.len >= f.limit: return
    var built = ""
    var k = 0
    while k < f.text.len:
      if k == f.caret: built.add c
      built.add f.text[k]
      inc k
    if f.caret >= f.text.len: built.add c
    f.text = built
    inc f.caret

proc backspace*(f: var Field) =
  if f.caret <= 0: return
  var built = ""
  var k = 0
  while k < f.text.len:
    if k != f.caret - 1: built.add f.text[k]
    inc k
  f.text = built
  dec f.caret

proc deleteAhead*(f: var Field) =
  if f.caret >= f.text.len: return
  var built = ""
  var k = 0
  while k < f.text.len:
    if k != f.caret: built.add f.text[k]
    inc k
  f.text = built

proc caretLeft*(f: var Field) =
  if f.caret > 0: dec f.caret
proc caretRight*(f: var Field) =
  if f.caret < f.text.len: inc f.caret
proc caretHome*(f: var Field) = f.caret = 0
proc caretEnd*(f: var Field) = f.caret = f.text.len

proc setText*(f: var Field; what: string) =
  f.text = ""
  f.caret = 0
  insert(f, what)

## Whether the caret is drawn this tick. A blink is not decoration: a focused
## empty field and an unfocused empty field look identical without it.
proc caretShowing*(ticks: int; focused: bool): bool =
  if not focused: return false
  (ticks div CaretBlinkTicks) mod 2 == 0

## What is in front of the caret, which is how far along the run it is drawn.
proc beforeCaret*(f: Field): string =
  result = ""
  var i = 0
  while i < f.caret and i < f.text.len:
    result.add f.text[i]
    inc i

# ---------------------------------------------------------------------------
# The folder rule

proc isIllegal(c: char): bool =
  var i = 0
  while i < Illegal.len:
    if Illegal[i] == c: return true
    inc i
  false

proc trimmed*(text: string): string =
  var first = 0
  while first < text.len and (text[first] == ' ' or text[first] == '\t'):
    inc first
  var last = text.len
  while last > first and (text[last - 1] == ' ' or text[last - 1] == '\t'):
    dec last
  result = ""
  var i = first
  while i < last:
    result.add text[i]
    inc i

## The name trimmed, with every illegal character replaced - not removed - and
## `World` when nothing survives.
proc folderNameOf*(display: string): string =
  let clean = trimmed(display)
  result = ""
  var i = 0
  while i < clean.len:
    if isIllegal(clean[i]): result.add '_'
    else: result.add clean[i]
    inc i
  if result.len == 0: result = FallbackFolder

## `getUniqueName`: the name itself when nothing has it, and the name with a
## number after it when something does. The number starts at 1 and counts up
## until it is free, so three worlds called `test` are `test`, `test1`, `test2`
## - which is what the game does and is why naming two worlds the same is
## allowed.
proc uniqueFolder*(wanted: string; taken: seq[string]): string =
  var candidate = wanted
  var n = 0
  var clash = true
  while clash:
    clash = false
    var i = 0
    while i < taken.len:
      if taken[i] == candidate: clash = true
      inc i
    if clash:
      inc n
      candidate = wanted & $n
  candidate

# ---------------------------------------------------------------------------
# Seeds
#
# The voxel world takes a number. A player types words. Minecraft hashes a
# non-numeric seed with `String.hashCode` and uses the number when the text is
# one, and an empty box means a random one - so `"1"` and `"one"` are different
# worlds and the same words always give the same world, which is the whole
# social point of a seed.

## Java's `String.hashCode`: `s[0]*31^(n-1) + s[1]*31^(n-2) + ... + s[n-1]`, in
## 32 bits with wraparound. Written out because there is no `hash` on this side
## and because the wraparound is the part that has to be right - a seed that
## agreed with Java for short strings and not for long ones would be worse than
## one that never agreed at all.
proc javaHash*(text: string): int =
  var h = 0
  var i = 0
  while i < text.len:
    h = h * 31 + int(text[i])
    # Fold back into signed 32 bits at every step, so the value never depends
    # on how wide this machine's `int` is.
    h = h and 0xFFFFFFFF
    if h >= 0x80000000: h = h - 0x100000000
    inc i
  h

## Whether the text is a plain decimal number, optionally signed. `""` is not.
proc numericSeed*(text: string): bool =
  let t = trimmed(text)
  if t.len == 0: return false
  var i = 0
  if t[0] == '-' or t[0] == '+': i = 1
  if i >= t.len: return false
  while i < t.len:
    if t[i] < '0' or t[i] > '9': return false
    inc i
  true

## The seed the world is really made from. `fallback` is used for an empty box -
## the caller passes something that varies, because "random" has to come from
## somewhere and this module has no clock.
proc seedOf*(text: string; fallback: int): int =
  let t = trimmed(text)
  if t.len == 0: return fallback
  if not numericSeed(t): return javaHash(t)
  var sign = 1
  var i = 0
  if t[0] == '-':
    sign = -1
    i = 1
  elif t[0] == '+':
    i = 1
  var value = 0
  while i < t.len:
    value = value * 10 + (int(t[i]) - int('0'))
    inc i
  value * sign
