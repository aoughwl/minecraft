## The world list, and the screen that makes a new one.
##
## Singleplayer used to drop straight into a world. That is the complaint:
## *"no settings screen/singleplayer screen - goes right into a world"*. In
## Minecraft, Singleplayer opens `GuiWorldSelection` - a list of your worlds
## with Play, Create New World, Edit, Delete and Re-Create under it - and
## Create New World is its own screen with a name, a seed and a game mode on it.
## Both of those are here, as arithmetic, calling nothing.
##
## ## What the host can and cannot tell us, said plainly
##
## Three things this screen would like do not exist below it, and the design has
## to be honest about each rather than invent them:
##
## **There is no way to list saved worlds.** The host has `enterWorld(name)`,
## `startFreshWorld(name)`, `worldName()` and `leaveWorld()`, and nothing that
## enumerates the saves folder. So the list is a *registry this mod keeps*:
## every world it made, written into this mod's own state with `save`, read back
## with `remember`. A world made some other way is not in it, and the screen
## does not pretend otherwise.
##
## **There is no wall clock.** `gameTime()` is seconds since the process
## started; nothing reaches a mod that knows what day it is. Minecraft's world
## row shows a date, and a date is exactly the thing that cannot be made up -
## an invented one is worse than none. So "last played" is carried as an
## *order*: every time a world is entered it takes the highest turn number yet,
## the list is sorted by that, and the most recent one sits at the top. That is
## the part of a date the screen was really using.
##
## **There is no folder size.** Minecraft shows one. Nothing here does, and
## nothing here shows a number that stands in for one.
##
## All three are in `docs/MCUI.md` under what the host does not have.
##
## ## Seeds
##
## The voxel world takes a number and the player types words, so `mcuitext`
## hashes a non-numeric seed the way Java does and the world is the same world
## every time those words are typed. An empty box is a fresh one.
##
## ## Every word is a key
##
## `selectWorld.title`, `selectWorld.select`, `selectWorld.create`,
## `selectWorld.edit`, `selectWorld.delete`, `selectWorld.recreate`,
## `selectWorld.enterName`, `selectWorld.resultFolder`, `selectWorld.enterSeed`,
## `selectWorld.seedInfo`, `selectWorld.gameMode`, `gameMode.survival`,
## `gameMode.creative`, `selectWorld.empty`, `gui.cancel`. Every one of them is
## in the player's own language file and not one of them is a word here.

import mcuicore
import mcuilist
import mcuitext

const
  KeyWorldsTitle* = "selectWorld.title"
  KeyPlay* = "selectWorld.select"
  KeyCreate* = "selectWorld.create"
  KeyEdit* = "selectWorld.edit"
  KeyDelete* = "selectWorld.delete"
  KeyRecreate* = "selectWorld.recreate"
  KeyCancel* = "gui.cancel"
  KeyEmpty* = "selectWorld.empty"
  KeyEnterName* = "selectWorld.enterName"
  KeyResultFolder* = "selectWorld.resultFolder"
  KeyEnterSeed* = "selectWorld.enterSeed"
  KeySeedInfo* = "selectWorld.seedInfo"
  KeyGameMode* = "selectWorld.gameMode"
  KeySurvival* = "gameMode.survival"
  KeyCreative* = "gameMode.creative"
  KeyDeleteQuestion* = "selectWorld.deleteQuestion"
  KeyDeleteWarning* = "selectWorld.deleteWarning"
  KeyDeleteButton* = "selectWorld.deleteButton"

  NameFieldTop* = 60
  NameLabelTop* = 47
  FolderNoteTop* = 85
  SeedFieldTop* = 130
  SeedLabelTop* = 117
  SeedNoteTop* = 155
  GameModeTop* = 178
    ## Minecraft puts the seed behind a **More World Options** button and the
    ## game mode at 115. There is nothing else behind that button here - no
    ## structures, no bonus chest, no world type - so a button that led to a
    ## screen with one field on it would be a click for nothing. The seed is on
    ## the first page and the game mode moved down under it. That is the one
    ## place this screen knowingly differs from the game's, and this is it
    ## written down.

  FooterFullWidth* = 150
  FooterSmallWidth* = 72
  CreateButtonWidth* = 150

type
  GameMode* = enum
    Survival, Creative

  World* = object
    ## One row of the registry. Every field is either the player's own words or
    ## a number this mod put there.
    folder*: string     ## what `enterWorld` is called with; unique
    name*: string       ## what the player typed; need not be unique
    seed*: int
    mode*: GameMode
    turn*: int          ## which visit was the last one; higher is newer
    plays*: int

  WorldChoice* = object
    worlds*: seq[World] ## already in the order the screen shows them
    pick*: int          ## a row, or -1
    scroll*: int

proc noWorlds*(): WorldChoice =
  WorldChoice(worlds: @[], pick: -1, scroll: 0)

proc modeKey*(m: GameMode): string =
  if m == Creative: KeyCreative else: KeySurvival

proc modeWord*(m: GameMode): string =
  ## For the registry, which is a file and not a screen.
  if m == Creative: "creative" else: "survival"

proc modeOf*(word: string): GameMode =
  if word == "creative": Creative else: Survival

proc nextMode*(m: GameMode): GameMode =
  if m == Survival: Creative else: Survival

# ---------------------------------------------------------------------------
# The registry
#
# One line a world, tab separated, in this mod's own state. It is written back
# whenever it changes, which is rarely: making a world, deleting one, and
# entering one.

proc escapeField(text: string): string =
  result = ""
  var i = 0
  while i < text.len:
    let c = text[i]
    if c == '\\': result.add "\\\\"
    elif c == '\n': result.add "\\n"
    elif c == '\t': result.add "\\t"
    else: result.add c
    inc i

proc unescapeField(text: string): string =
  result = ""
  var i = 0
  while i < text.len:
    let c = text[i]
    if c == '\\' and i + 1 < text.len:
      let n = text[i + 1]
      i = i + 2
      if n == 'n': result.add '\n'
      elif n == 't': result.add '\t'
      elif n == '\\': result.add '\\'
      else:
        result.add c
        result.add n
    else:
      result.add c
      inc i

proc splitOn(line: string; sep: char): seq[string] =
  result = @[]
  var piece = ""
  var i = 0
  while i <= line.len:
    if i == line.len or line[i] == sep:
      result.add piece
      piece = ""
    else:
      if line[i] != '\r': piece.add line[i]
    inc i

proc wholeOf(text: string): int =
  var sign = 1
  var i = 0
  if i < text.len and text[i] == '-':
    sign = -1
    inc i
  var value = 0
  var digits = 0
  while i < text.len and text[i] >= '0' and text[i] <= '9':
    value = value * 10 + (int(text[i]) - int('0'))
    inc digits
    inc i
  if digits == 0: 0 else: value * sign

## The registry as it is written down: `folder<TAB>name<TAB>seed<TAB>mode<TAB>turn<TAB>plays`.
proc writeRegistry*(worlds: seq[World]): string =
  result = ""
  var i = 0
  while i < worlds.len:
    let w = worlds[i]
    inc i
    result.add escapeField(w.folder) & "\t" & escapeField(w.name) & "\t" &
      $w.seed & "\t" & modeWord(w.mode) & "\t" & $w.turn & "\t" & $w.plays &
      "\n"

## And read back. A short line is dropped rather than half-read: the registry is
## a file this mod wrote and a file that is not what this mod wrote is not a
## registry, so the wrong answer is to guess at it.
proc readRegistry*(body: string): seq[World] =
  result = @[]
  var line = ""
  var i = 0
  while i <= body.len:
    if i == body.len or body[i] == '\n':
      if line.len > 0:
        let f = splitOn(line, '\t')
        if f.len >= 6 and f[0].len > 0:
          result.add World(folder: unescapeField(f[0]),
            name: unescapeField(f[1]), seed: wholeOf(f[2]),
            mode: modeOf(f[3]), turn: wholeOf(f[4]), plays: wholeOf(f[5]))
      line = ""
    else:
      line.add body[i]
    inc i

## Newest first, which is the order the screen shows and the only sense in which
## this build knows when a world was last played. A stable sort by insertion, so
## two worlds never visited keep the order they were made in.
proc byRecency*(worlds: seq[World]): seq[World] =
  result = @[]
  var left = worlds
  while left.len > 0:
    var best = 0
    var i = 1
    while i < left.len:
      if left[i].turn > left[best].turn: best = i
      inc i
    result.add left[best]
    var kept: seq[World] = @[]
    i = 0
    while i < left.len:
      if i != best: kept.add left[i]
      inc i
    left = kept

proc highestTurn*(worlds: seq[World]): int =
  result = 0
  var i = 0
  while i < worlds.len:
    if worlds[i].turn > result: result = worlds[i].turn
    inc i

proc folders*(worlds: seq[World]): seq[string] =
  result = @[]
  var i = 0
  while i < worlds.len:
    result.add worlds[i].folder
    inc i

## Mark a world as just entered: the newest turn, and one more play. Answers the
## whole list because the list is what is written back.
proc visit*(worlds: seq[World]; folder: string): seq[World] =
  let turn = highestTurn(worlds) + 1
  result = @[]
  var i = 0
  while i < worlds.len:
    var w = worlds[i]
    if w.folder == folder:
      w.turn = turn
      w.plays = w.plays + 1
    result.add w
    inc i

proc without*(worlds: seq[World]; folder: string): seq[World] =
  result = @[]
  var i = 0
  while i < worlds.len:
    if worlds[i].folder != folder: result.add worlds[i]
    inc i

## A new world from what the create screen holds. The folder is derived from the
## name by `mcuitext`'s rule and made unique against what is already there, so
## three worlds called `test` are allowed and are three folders.
proc newWorld*(worlds: seq[World]; name: string; seed: int;
               mode: GameMode): World =
  World(folder: uniqueFolder(folderNameOf(name), folders(worlds)),
        name: trimmed(name), seed: seed, mode: mode,
        turn: highestTurn(worlds) + 1, plays: 0)

# ---------------------------------------------------------------------------
# Where the world list is

proc worldBox*(guiW, guiH, rows: int): ListBox =
  listBox(ListTop, guiH - ListBottomTwoRows,
          guiW div 2 - ListWidth div 2, ListWidth, WorldRowHeight, rows)

type
  WorldAction* = enum
    NoWorldAction, PlayWorld, CreateWorld, EditWorld, DeleteWorld,
    RecreateWorld, LeaveWorlds

  FooterButton* = object
    action*: WorldAction
    key*: string
    rect*: MRect
    enabled*: bool

## The six buttons under the list, in the game's own places. The four that act
## on a world are disabled with nothing picked - offered and refused, which is
## what the game does and is why the row does not jump about as you click.
proc worldFooter*(guiW, guiH: int; picked: bool): seq[FooterButton] =
  let mid = guiW div 2
  let up = footerRow(guiH, 0)
  let down = footerRow(guiH, 1)
  result = @[]
  result.add FooterButton(action: PlayWorld, key: KeyPlay,
    rect: mrect(float(mid - 154), float(up), float(FooterFullWidth), 20.0),
    enabled: picked)
  result.add FooterButton(action: CreateWorld, key: KeyCreate,
    rect: mrect(float(mid + 4), float(up), float(FooterFullWidth), 20.0),
    enabled: true)
  result.add FooterButton(action: EditWorld, key: KeyEdit,
    rect: mrect(float(mid - 154), float(down), float(FooterSmallWidth), 20.0),
    enabled: picked)
  result.add FooterButton(action: DeleteWorld, key: KeyDelete,
    rect: mrect(float(mid - 76), float(down), float(FooterSmallWidth), 20.0),
    enabled: picked)
  result.add FooterButton(action: RecreateWorld, key: KeyRecreate,
    rect: mrect(float(mid + 4), float(down), float(FooterSmallWidth), 20.0),
    enabled: picked)
  result.add FooterButton(action: LeaveWorlds, key: KeyCancel,
    rect: mrect(float(mid + 82), float(down), float(FooterSmallWidth), 20.0),
    enabled: true)

proc footerUnder*(buttons: seq[FooterButton]; x, y: float): int =
  result = -1
  var i = 0
  while i < buttons.len:
    if buttons[i].rect.holds(x, y): return i
    inc i

## The three lines of a world's row: what the player called it, which folder it
## is in, and how it is played. The middle one is the folder and not a date,
## because there is no clock - see the head of this file.
proc rowLines*(w: World): seq[string] =
  @[w.name, w.folder, ""]

# ---------------------------------------------------------------------------
# Create New World

type
  CreateForm* = object
    name*: Field
    seed*: Field
    mode*: GameMode
    onSeed*: bool     ## which field has the caret

proc newForm*(name = ""; seed = ""): CreateForm =
  var f = CreateForm(name: field(name), seed: field(seed), mode: Survival,
                     onSeed: false)
  f.name.focused = true
  f

proc focusName*(f: var CreateForm) =
  f.onSeed = false
  f.name.focused = true
  f.seed.focused = false

proc focusSeed*(f: var CreateForm) =
  f.onSeed = true
  f.name.focused = false
  f.seed.focused = true

## Tab moves between the two, which is what every form does and what a player
## will try before they try anything else.
proc nextField*(f: var CreateForm) =
  if f.onSeed: focusName(f) else: focusSeed(f)

proc nameRect*(guiW: int): MRect =
  mrect(float(guiW div 2 - FieldWidth div 2), float(NameFieldTop),
        float(FieldWidth), float(FieldHeight))
proc seedRect*(guiW: int): MRect =
  mrect(float(guiW div 2 - FieldWidth div 2), float(SeedFieldTop),
        float(FieldWidth), float(FieldHeight))
proc modeRect*(guiW: int): MRect =
  mrect(float(guiW div 2 - 75), float(GameModeTop), 150.0, 20.0)
proc createRect*(guiW, guiH: int): MRect =
  mrect(float(guiW div 2 - 155), float(guiH - 28), float(CreateButtonWidth),
        20.0)
proc cancelRect*(guiW, guiH: int): MRect =
  mrect(float(guiW div 2 + 5), float(guiH - 28), float(CreateButtonWidth),
        20.0)

## Where the caret goes for a click in a field: nowhere yet, because a click in
## a field only focuses it. Answers which field the point is in, or -1.
proc fieldUnder*(guiW: int; x, y: float): int =
  if nameRect(guiW).holds(x, y): return 0
  if seedRect(guiW).holds(x, y): return 1
  -1

## The folder this form would make, for the `selectWorld.resultFolder` line
## under the name. Shown as the player types, which is the whole reason that
## line exists in the game: it is where a name with a slash in it stops being a
## surprise.
proc previewFolder*(f: CreateForm; worlds: seq[World]): string =
  uniqueFolder(folderNameOf(f.name.text), folders(worlds))
