## Every control Minecraft has a name for, what it is bound to, and what the
## player's own language file calls that binding.
##
## Three separate things live here and only the first is obvious.
##
## **The list.** Minecraft's controls are a fixed list in a fixed order with a
## fixed set of category headings over it, and the order is not alphabetical
## and not arbitrary: it is the order `KeyMapping.CATEGORY_SORT_ORDER` puts the
## categories in and the order the game registers the bindings within each.
## `Bindings` below is that list. Every row is a translation key and not a word,
## exactly as everywhere else in this mod.
##
## **The name of a key.** This is the part that is quietly hard. The floor here
## speaks Unity's Input System names - `W`, `LeftShift`, `Digit1`, `Numpad1` -
## and Minecraft's language file speaks its own, as translation keys:
## `key.keyboard.w`, `key.keyboard.left.shift`, `key.keyboard.1`,
## `key.keyboard.keypad.1`. So a binding has two spellings and they are not the
## same spelling with a different case. `boundKey` is the mapping, and it is a
## mapping and not a pattern: `Equals` is `key.keyboard.equal`, `Backquote` is
## `key.keyboard.grave.accent`, and `Digit1` and `Numpad1` differ by a word in
## the middle rather than by a prefix. A rule that lower-cased the Unity name
## would be right for twenty-six letters out of a hundred and ten keys, and it
## is exactly the sort of thing that looks finished.
##
## An unbound control is `key.keyboard.unknown`, which the game's own language
## file translates to *Not bound* - so this mod does not have to know the words
## "not bound" exist.
##
## **Whether anything is behind it.** The same rule the options screen follows:
## a control that can be rebound and does nothing when you press it is worse
## than one that is drawn refused, because the second one is honest. Six of
## these - the movement six - are really bound, through `voxel.settings`, and
## one - full screen - is this mod's own. Every other row carries a reason
## naming what is missing, and the screen draws the reason in place of a
## control. `Reasons` is that column and `Tests/mcui_test.exe` asserts that
## every row has exactly one of a wiring and a reason, never both and never
## neither.
##
## Nothing in this module calls a host or imports the SDK. A key is a *name*
## here, as text, and `main.nim` turns it into the SDK's `Key` with `key(name)`
## on the way out - which is the same split every other pure module in this
## folder makes and the reason this one is provable without Unity.

import mcuicore

const
  Unbound* = ""
    ## What a control bound to nothing holds. Deliberately the empty string
    ## rather than a sentinel word, so that `boundKey("")` answering
    ## `key.keyboard.unknown` is the one place "nothing" is spelled.
  UnknownKeyKey* = "key.keyboard.unknown"
    ## *Not bound*, in the player's own language.

  MouseLeft* = "mouse.left"
  MouseRight* = "mouse.right"
  MouseMiddle* = "mouse.middle"
    ## The three the floor takes as `clicked("left")`. Spelled with a dot so
    ## that nothing can confuse one with a Unity key name, which never has one.

  # ---- the categories, in the game's own order ---------------------------
  CatMovement* = "key.categories.movement"
  CatGameplay* = "key.categories.gameplay"
  CatInventory* = "key.categories.inventory"
  CatCreative* = "key.categories.creative"
  CatMultiplayer* = "key.categories.multiplayer"
  CatUi* = "key.categories.ui"
  CatMisc* = "key.categories.misc"

  Categories* = [CatMovement, CatGameplay, CatInventory, CatCreative,
                 CatMultiplayer, CatUi, CatMisc]

## Every binding, in the game's own order: the control's translation key, the
## category it is filed under, and what the game binds it to out of the box.
##
## Three parallel arrays rather than one array of objects, for the same reason
## `mcuiopts` keeps its rows as lines: a const array of objects with strings in
## it is a thing the mod compiler and the test compiler disagree about, and
## three arrays of the same length are a thing the test can assert the length of.
const
  Bindings* = [
    "key.forward", "key.left", "key.back", "key.right", "key.jump",
    "key.sneak", "key.sprint",
    "key.attack", "key.pickItem", "key.use",
    "key.drop", "key.hotbar.1", "key.hotbar.2", "key.hotbar.3", "key.hotbar.4",
    "key.hotbar.5", "key.hotbar.6", "key.hotbar.7", "key.hotbar.8",
    "key.hotbar.9", "key.inventory", "key.swapOffhand",
    "key.loadToolbarActivator", "key.saveToolbarActivator",
    "key.playerlist", "key.chat", "key.command", "key.socialInteractions",
    "key.advancements", "key.spectatorOutlines",
    "key.screenshot", "key.smoothCamera", "key.fullscreen",
    "key.togglePerspective"]

  BindingCategory* = [
    CatMovement, CatMovement, CatMovement, CatMovement, CatMovement,
    CatMovement, CatMovement,
    CatGameplay, CatGameplay, CatGameplay,
    CatInventory, CatInventory, CatInventory, CatInventory, CatInventory,
    CatInventory, CatInventory, CatInventory, CatInventory,
    CatInventory, CatInventory, CatInventory,
    CatCreative, CatCreative,
    CatMultiplayer, CatMultiplayer, CatMultiplayer, CatMultiplayer,
    CatUi, CatUi,
    CatMisc, CatMisc, CatMisc,
    CatMisc]

  BindingDefault* = [
    "W", "A", "S", "D", "Space",
    "LeftShift", "LeftCtrl",
    MouseLeft, MouseMiddle, MouseRight,
    "Q", "Digit1", "Digit2", "Digit3", "Digit4",
    "Digit5", "Digit6", "Digit7", "Digit8",
    "Digit9", "E", "F",
    "X", "C",
    "Tab", "T", "Slash", "P",
    "L", Unbound,
    "F2", Unbound, "F11",
    "F5"]

  ## Which mod-side action each binding really drives, or the empty string when
  ## nothing does. `world:<action>` is a `bind.<action>` line on the
  ## `voxel.settings` service; `self:<what>` is something this mod does itself.
  ## Anything else is not a wiring and the row is refused.
  BindingWiring* = [
    "world:forward", "world:left", "world:back", "world:right", "world:jump",
    "", "world:sprint",
    "", "", "",
    "", "", "", "", "",
    "", "", "", "",
    "", "", "",
    "", "",
    "", "", "", "",
    "", "",
    "", "", "self:fullscreen",
    ""]

  ## Why a refused row is refused, said in place of the control. Every one of
  ## these names the thing that is missing rather than apologising: a reason a
  ## reader cannot act on is the same as no reason.
  BindingReason* = [
    "", "", "", "", "",
    "the character has no crouch: ModSdk bindKey takes forward, back, left, " &
      "right, jump and run and nothing else",
    "",
    "digging is wired to the mouse inside aoughwl.voxel; it would need a " &
      "bind.attack line on voxel.settings",
    "picking a block is wired to the middle button inside aoughwl.voxel",
    "placing is wired to the mouse inside aoughwl.voxel; it would need a " &
      "bind.use line on voxel.settings",
    "dropping is Q inside aoughwl.voxel",
    "the hotbar is Digit1..9 inside aoughwl.voxel",
    "the hotbar is Digit1..9 inside aoughwl.voxel",
    "the hotbar is Digit1..9 inside aoughwl.voxel",
    "the hotbar is Digit1..9 inside aoughwl.voxel",
    "the hotbar is Digit1..9 inside aoughwl.voxel",
    "the hotbar is Digit1..9 inside aoughwl.voxel",
    "the hotbar is Digit1..9 inside aoughwl.voxel",
    "the hotbar is Digit1..9 inside aoughwl.voxel",
    "the hotbar is Digit1..9 inside aoughwl.voxel",
    "the bag is opened on E inside aoughwl.hud",
    "nothing in this tree gives the player an off hand to swap into",
    "there is no creative toolbar to load",
    "there is no creative toolbar to save",
    "there is no player list: nothing here knows who else is on the server",
    "chat is opened inside aoughwl.chat",
    "chat is opened inside aoughwl.chat",
    "there is no social interactions screen",
    "nothing in this tree awards an advancement",
    "there is no spectator mode",
    "no host call takes a screenshot from inside a mod",
    "there is no cinematic camera",
    "",
    "F5 is read inside aoughwl.voxel; it would need a bind.perspective " &
      "line on voxel.settings"]

## Every key a rebinding may capture, spelled the way the Input System spells
## it. This is `ModSdk/input.nim`'s own `Key` enum, as text and in its own order,
## less `NoKey` - and it is here rather than derived from the enum because a
## pure module on this side of the boundary has no SDK on its module path at
## all.
##
## That makes it a copy, so it is a copy with a gate on it:
## `Tests/mcui_test.exe` reads `ModSdk/input.nim` back and fails when the two
## lists differ, naming the keys one of them has and the other does not. A copy
## that cannot drift is a table; a copy that can is a bug waiting for a Unity
## release.
const CaptureKeys* = [
  "Space", "Enter", "Tab", "Backquote", "Quote", "Semicolon", "Comma",
  "Period", "Slash", "Backslash", "LeftBracket", "RightBracket", "Minus",
  "Equals", "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
  "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
  "Digit1", "Digit2", "Digit3", "Digit4", "Digit5", "Digit6", "Digit7",
  "Digit8", "Digit9", "Digit0",
  "LeftShift", "RightShift", "LeftAlt", "RightAlt", "LeftCtrl", "RightCtrl",
  "LeftMeta", "RightMeta", "ContextMenu", "Escape", "LeftArrow", "RightArrow",
  "UpArrow", "DownArrow", "Backspace", "PageDown", "PageUp", "Home", "End",
  "Insert", "Delete", "CapsLock", "NumLock", "PrintScreen", "ScrollLock",
  "Pause", "NumpadEnter", "NumpadDivide", "NumpadMultiply", "NumpadPlus",
  "NumpadMinus", "NumpadPeriod", "NumpadEquals", "Numpad0", "Numpad1",
  "Numpad2", "Numpad3", "Numpad4", "Numpad5", "Numpad6", "Numpad7", "Numpad8",
  "Numpad9", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10",
  "F11", "F12", "OEM1", "OEM2", "OEM3", "OEM4", "OEM5"]

## Whether a row has something behind it.
proc bindingWired*(i: int): bool =
  if i < 0 or i >= BindingWiring.len: return false
  BindingWiring[i].len > 0

proc bindingIndex*(action: string): int =
  result = -1
  var i = 0
  while i < Bindings.len:
    if Bindings[i] == action: return i
    inc i

# ---------------------------------------------------------------------------
# What a key is called

proc lowered(text: string): string =
  result = ""
  var i = 0
  while i < text.len:
    var c = text[i]
    if c >= 'A' and c <= 'Z': c = char(int(c) + 32)
    result.add c
    inc i

## The spelling of every key that is not a letter, a digit or a mouse button.
## A table and not a rule - see the module comment.
proc namedKey(name: string): string =
  case name
  of "Space": "key.keyboard.space"
  of "Enter": "key.keyboard.enter"
  of "Tab": "key.keyboard.tab"
  of "Backquote": "key.keyboard.grave.accent"
  of "Quote": "key.keyboard.apostrophe"
  of "Semicolon": "key.keyboard.semicolon"
  of "Comma": "key.keyboard.comma"
  of "Period": "key.keyboard.period"
  of "Slash": "key.keyboard.slash"
  of "Backslash": "key.keyboard.backslash"
  of "LeftBracket": "key.keyboard.left.bracket"
  of "RightBracket": "key.keyboard.right.bracket"
  of "Minus": "key.keyboard.minus"
  of "Equals": "key.keyboard.equal"
  of "LeftShift": "key.keyboard.left.shift"
  of "RightShift": "key.keyboard.right.shift"
  of "LeftAlt": "key.keyboard.left.alt"
  of "RightAlt": "key.keyboard.right.alt"
  of "LeftCtrl": "key.keyboard.left.control"
  of "RightCtrl": "key.keyboard.right.control"
  of "LeftMeta": "key.keyboard.left.win"
  of "RightMeta": "key.keyboard.right.win"
  of "ContextMenu": "key.keyboard.menu"
  of "Escape": "key.keyboard.escape"
  of "LeftArrow": "key.keyboard.left"
  of "RightArrow": "key.keyboard.right"
  of "UpArrow": "key.keyboard.up"
  of "DownArrow": "key.keyboard.down"
  of "Backspace": "key.keyboard.backspace"
  of "PageDown": "key.keyboard.page.down"
  of "PageUp": "key.keyboard.page.up"
  of "Home": "key.keyboard.home"
  of "End": "key.keyboard.end"
  of "Insert": "key.keyboard.insert"
  of "Delete": "key.keyboard.delete"
  of "CapsLock": "key.keyboard.caps.lock"
  of "NumLock": "key.keyboard.num.lock"
  of "PrintScreen": "key.keyboard.print.screen"
  of "ScrollLock": "key.keyboard.scroll.lock"
  of "Pause": "key.keyboard.pause"
  of "NumpadEnter": "key.keyboard.keypad.enter"
  of "NumpadDivide": "key.keyboard.keypad.divide"
  of "NumpadMultiply": "key.keyboard.keypad.multiply"
  of "NumpadPlus": "key.keyboard.keypad.add"
  of "NumpadMinus": "key.keyboard.keypad.subtract"
  of "NumpadPeriod": "key.keyboard.keypad.decimal"
  of "NumpadEquals": "key.keyboard.keypad.equal"
  of "F1": "key.keyboard.f1"
  of "F2": "key.keyboard.f2"
  of "F3": "key.keyboard.f3"
  of "F4": "key.keyboard.f4"
  of "F5": "key.keyboard.f5"
  of "F6": "key.keyboard.f6"
  of "F7": "key.keyboard.f7"
  of "F8": "key.keyboard.f8"
  of "F9": "key.keyboard.f9"
  of "F10": "key.keyboard.f10"
  of "F11": "key.keyboard.f11"
  of "F12": "key.keyboard.f12"
  else: UnknownKeyKey

## The translation key for what a bound key is *called*. `key.keyboard.unknown`
## for nothing, `key.mouse.*` for the three buttons, and Minecraft's own
## spelling for everything else.
##
## `OEM1`..`OEM5`, and anything the floor grows that this has not been told
## about, come back as `key.keyboard.unknown`. *Not bound* is the wrong word for
## a key that is bound to something unnameable - but it is the honest one,
## because the alternative is drawing a name this mod invented onto a button.
proc boundKey*(name: string): string =
  if name.len == 0: return UnknownKeyKey
  if name == MouseLeft: return "key.mouse.left"
  if name == MouseRight: return "key.mouse.right"
  if name == MouseMiddle: return "key.mouse.middle"
  # The twenty-six letters, which are the one place the rule really is the
  # lower-cased name.
  if name.len == 1 and name[0] >= 'A' and name[0] <= 'Z':
    return "key.keyboard." & lowered(name)
  # `Digit1` and `Numpad1`, which differ by a word in the middle rather than by
  # a prefix.
  if name.len == 6 and name[0] == 'D' and name[1] == 'i' and name[2] == 'g' and
     name[5] >= '0' and name[5] <= '9':
    result = "key.keyboard."
    result.add name[5]
    return result
  if name.len == 7 and name[0] == 'N' and name[1] == 'u' and name[2] == 'm' and
     name[3] == 'p' and name[4] == 'a' and name[5] == 'd' and
     name[6] >= '0' and name[6] <= '9':
    result = "key.keyboard.keypad."
    result.add name[6]
    return result
  namedKey(name)

# ---------------------------------------------------------------------------
# Holding the bindings

type Binds* = object
  ## What every control is bound to *now*. One string per row of `Bindings`,
  ## in the same order, so the two are indexed together and there is no second
  ## list of names to fall out of step.
  to*: seq[string]

proc defaultBinds*(): Binds =
  result = Binds(to: @[])
  var i = 0
  while i < BindingDefault.len:
    result.to.add BindingDefault[i]
    inc i

proc boundTo*(b: Binds; i: int): string =
  if i < 0 or i >= b.to.len: return Unbound
  b.to[i]

## Bind one control, and *unbind whatever else held that key*.
##
## That second half is Minecraft's own behaviour and it is easy to leave out.
## The game does not refuse a duplicate and it does not silently keep two: it
## marks the clash in red on the controls screen and leaves both bound, so the
## player can see what they did. This does the same - the clash is kept, and
## `clashes` below is what the screen paints red with - because a rebinding
## that quietly stole a key from another row would be a change the player never
## asked for and never saw.
proc rebind*(b: var Binds; i: int; name: string) =
  if i < 0 or i >= b.to.len: return
  b.to[i] = name

proc unbind*(b: var Binds; i: int) = rebind(b, i, Unbound)

proc resetOne*(b: var Binds; i: int) =
  if i < 0 or i >= BindingDefault.len: return
  rebind(b, i, BindingDefault[i])

proc resetAll*(b: var Binds) =
  b = defaultBinds()

## How many *other* controls hold the same key. Zero for an unbound row, always,
## because "not bound" is not a key two rows can fight over - which is the case
## a count of equal strings gets wrong.
proc clashes*(b: Binds; i: int): int =
  result = 0
  if i < 0 or i >= b.to.len: return
  if b.to[i].len == 0: return
  var j = 0
  while j < b.to.len:
    if j != i and b.to[j] == b.to[i]: inc result
    inc j

proc anyClash*(b: Binds): bool =
  var i = 0
  while i < b.to.len:
    if clashes(b, i) > 0: return true
    inc i
  false

## What a binding's button says while it is waiting for a key, and what it says
## when two controls hold the same one.
##
## Both are punctuation and not words, which is what makes them allowed to be
## here: Minecraft builds them in code too - `Component.literal("> ")` round the
## key's own name, and `§c` either side of a clash - because there is nothing in
## a language file to translate. The key's *name* still comes from the player's
## own file; only the brackets are ours.
proc waitingLabel*(keyName: string): string = "> " & keyName & " <"
proc clashLabel*(keyName: string): string = "[ " & keyName & " ]"

proc atDefaults*(b: Binds): bool =
  if b.to.len != BindingDefault.len: return false
  var i = 0
  while i < b.to.len:
    if b.to[i] != BindingDefault[i]: return false
    inc i
  true

# ---------------------------------------------------------------------------
# Keeping them
#
# One line per row that is not at its default, `<action> <key>`. Not every row,
# deliberately: a store that wrote all thirty-four would pin today's defaults
# into every player's save, so a default that changed later would never reach
# anybody who had once opened this screen.

proc writeBinds*(b: Binds): string =
  result = ""
  var i = 0
  while i < b.to.len and i < Bindings.len:
    if b.to[i] != BindingDefault[i]:
      result.add Bindings[i]
      result.add ' '
      result.add b.to[i]
      result.add '\n'
    inc i

proc readBinds*(body: string): Binds =
  result = defaultBinds()
  var line = ""
  var i = 0
  while i <= body.len:
    if i == body.len or body[i] == '\n':
      var action = ""
      var j = 0
      while j < line.len and line[j] != ' ':
        action.add line[j]
        inc j
      var name = ""
      inc j
      while j < line.len:
        if line[j] != '\r': name.add line[j]
        inc j
      let at = bindingIndex(action)
      if at >= 0: result.to[at] = name
      line = ""
    else:
      line.add body[i]
    inc i

# ---------------------------------------------------------------------------
# The controls screen's own shape
#
# Minecraft's `ControlsScreen` is two buttons over a scrolling list over two
# more buttons:
#
#     mouseSettings (width / 2 - 155, 18, 150, 20)
#     autoJump      (width / 2 + 5,   18, 150, 20)
#     the list      between 43 and height - 32, rows 20 tall
#     resetAll      (width / 2 - 155,       height - 29, 150, 20)
#     done          (width / 2 - 155 + 160, height - 29, 150, 20)
#
# and one row of the list is the control's name, right-aligned at 90 pixels in,
# a 75-wide button holding the key, and a 50-wide Reset beside it.

const
  KeyControlsTitle* = "controls.title"
  KeyBindReset* = "controls.reset"
  KeyResetAll* = "controls.resetAll"
  ControlsTitleTop* = 8
    ## `drawCenteredString(title, width / 2, 8, 0xFFFFFF)`.
  ControlsTopRow* = 18
  ControlsListTop* = 43
  ControlsListBottom* = 32
    ## `height - 32`.
  ControlsFooter* = 29
    ## `height - 29`.
  BindRowHeight* = 20
  BindNameRight* = 90
    ## The control's name ends this far in from the left of the row.
  BindButtonLeft* = 105
  BindButtonWidth* = 75
  BindResetLeft* = 190
  BindResetWidth* = 50
  ControlsGridLeft* = 155
    ## `width / 2 - 155`, the left edge of every 310-wide screen in the options
    ## family.
  ControlsHalfWidth* = 150
  ControlsColumnStep* = 160

proc bindRowLeft*(guiW: int): int = guiW div 2 - ControlsGridLeft

proc bindKeyRect*(guiW: int; row: MRect): MRect =
  mrect(float(bindRowLeft(guiW) + BindButtonLeft), row.y,
        float(BindButtonWidth), float(BindRowHeight))

proc bindResetRect*(guiW: int; row: MRect): MRect =
  mrect(float(bindRowLeft(guiW) + BindResetLeft), row.y,
        float(BindResetWidth), float(BindRowHeight))

## Where the control's name ends, which is what a right-aligned run is laid out
## against.
proc bindNameRight*(guiW: int): float =
  float(bindRowLeft(guiW) + BindNameRight)

# ---------------------------------------------------------------------------
# The list, with headings in it
#
# The game's key-bind list is not a list of bindings: it is a list of *entries*,
# and a category heading is an entry of its own with no controls on it. That
# matters for the scroll arithmetic - a list that scrolled past bindings only
# would put every heading in the wrong place - so the entry list is built once,
# here, and both the drawing and the hit testing walk the same one.

type
  EntryKind* = enum
    HeadingRow,   ## a category heading, which is an entry with no control on it
    BindingRow    ## one control

  BindEntry* = object
    kind*: EntryKind
    at*: int    ## which row of `Bindings`, or which of `Categories`

## Every entry of the controls list, headings and all, in the game's own order.
proc bindEntries*(): seq[BindEntry] =
  result = @[]
  var c = 0
  while c < Categories.len:
    var any = false
    var i = 0
    while i < Bindings.len:
      if BindingCategory[i] == Categories[c]: any = true
      inc i
    if any:
      result.add BindEntry(kind: HeadingRow, at: c)
      i = 0
      while i < Bindings.len:
        if BindingCategory[i] == Categories[c]:
          result.add BindEntry(kind: BindingRow, at: i)
        inc i
    inc c
