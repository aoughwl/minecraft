## The pause screen: Escape, the dimmed world behind it, and who has the mouse.
##
## Every number here is Minecraft's own `PauseScreen.createPauseMenu`, in
## interface pixels, and nothing in this module draws or reads anything:
##
##     int i = -16;
##     returnToGame  (width / 2 - 100, height / 4 +  24 + i, 200, 20)
##     advancements  (width / 2 - 100, height / 4 +  48 + i,  98, 20)
##     stats         (width / 2 +   2, height / 4 +  48 + i,  98, 20)
##     options       (width / 2 - 100, height / 4 +  96 + i,  98, 20)
##     shareToLan    (width / 2 +   2, height / 4 +  96 + i,  98, 20)
##     returnToMenu  (width / 2 - 100, height / 4 + 120 + i, 200, 20)
##     title         drawCenteredString(..., width / 2, 40, 0xFFFFFF)
##
## `i` is the game's own lift and it is spelled here as a lift rather than
## folded into the four row numbers, because folding it in is how the 48-pixel
## hole between the second and third pair - which is real, and is where the
## column breathes - turns into four numbers somebody has to remember. Every
## row is a whole multiple of `RowStep` above the same base, and the test
## asserts exactly that rather than the four numbers.
##
## ## Does the world stop?
##
## **No, and that is a decision rather than an omission.** What this screen
## takes is the mouse; what it does not take is the clock.
##
##   * The game itself does not claim otherwise. The full escape screen's title
##     is `menu.game` - *Game Menu* - and `menu.paused` is a second key the game
##     keeps for the moment it really did stop. A screen that said *Game Paused*
##     over a world still ticking would be the one lie on it, so `pauseTitleKey`
##     below derives the title from `PausesTheWorld` and cannot drift from it.
##   * Stopping the tick would be wrong the instant anybody is on a socket.
##     `joinGame` is real here and the server list is not decoration; Minecraft
##     does not stop a multiplayer world for one player's escape key either.
##   * Stopping physics mid-fall is a bug shaped like a feature. It reads as
##     "I pressed Escape at forty blocks and walked away", and the player did
##     not do anything to earn that. `player.step(mine())` already stops the
##     *steering* the moment the mouse changes hands, which is the half of it a
##     player would ask for.
##   * Stopping generation is the one that sounds like a feature and is not.
##     The LOD horizon is still building behind this screen; a menu that stopped
##     it would make the horizon worse every time it was opened, and would hand
##     back a frame budget the menu was not short of.
##
## So the whole of what this screen does to the world is one word on the
## handoff queue - `pointer`, `free` on the way in and `held` on the way out -
## and `handoffsFor` below is the only place that is spelled. The test asserts
## the set of verbs it can ever emit has exactly one member in it, which is what
## makes "this does not pause the world" a mechanism instead of a sentence.
##
## ## Whose Escape is it
##
## Not always this mod's. `aoughwl.hud` opens an inventory over the same
## world and closes it on Escape, and in Minecraft that Escape closes the
## inventory and does **not** then open the pause menu. `escapeMove` is the gate
## and it is deliberately narrow: only the world itself and this screen answer
## to Escape at all, and a screen opened *over* this one - Options, and Resource
## Packs over that - keeps its own. Take the gate away and one Escape on the
## options screen closes the options screen and the pause screen together and
## drops the player back into the world with the mouse in a state nobody chose.
##
## The other half of that gate is not here, because it is not arithmetic: the
## mod also refuses to open while another mod's screen has the mouse, which it
## learns from the same `pointer` handoff the world learns it from, skipping the
## rows it posted itself by `from0`. `docs/MCUI.md` says why that is not a
## breach of the queue's one rule.
##
## ## Labels are keys
##
## No string in this module is a word. `menu.returnToGame` is what the button
## *is*; what it says is the player's own language file's business.

import mcuicore
import mcuimenu
import mcuistack

const
  KeyGameMenu* = "menu.game"
    ## The full escape screen's title. *Game Menu*, in a language file this mod
    ## never reads.
  KeyPaused* = "menu.paused"
    ## The other one, which the game shows when it really did stop the tick.
    ## Never drawn here - see `pauseTitleKey` - and present because a key that
    ## is not written down cannot be asserted to be unused.
  KeyReturnToGame* = "menu.returnToGame"
  KeyAdvancements* = "gui.advancements"
  KeyStats* = "gui.stats"
  KeyShareToLan* = "menu.shareToLan"
  KeyReturnToMenu* = "menu.returnToMenu"

  PauseLift* = -16
    ## The game's own `int i = -16`, applied to every row.
  PauseResumeRow* = 24
  PauseRecordsRow* = 48
    ## Advancements and Statistics - the pair the game keeps the records on.
  PauseSettingsRow* = 96
    ## Options and Open to LAN. The 48-pixel hole above this pair is the game's
    ## own and is not closed up here.
  PauseLeaveRow* = 120
  PauseTitleTop* = 40
    ## `drawCenteredString(..., width / 2, 40, 0xFFFFFF)`.
  PauseGap* = 4
    ## Between the two halves of a pair, which is what makes a pair span exactly
    ## one full button: 98 + 4 + 98 = 200. Nothing here writes 200 twice; the
    ## test asserts that identity instead.

  PausesTheWorld* = false
    ## The decision, in one place. See the module comment for the four reasons.
    ## Everything that would have to change with it - the title key, and the
    ## verbs on the handoff queue - is derived from it or asserted against it,
    ## so flipping this constant fails the test until the rest of it is done,
    ## rather than quietly drawing *Game Paused* over a world that is running.

  # ---- the dim ------------------------------------------------------------
  #
  # Minecraft does not put a solid sheet over the world. `Screen.renderBackground`
  # on an in-world screen fills a vertical gradient from `0xC0101010` at the top
  # to `0xD0101010` at the bottom: one colour, near-black, and an alpha that
  # walks from 192 to 208 down the screen. Sixteen steps of alpha over the whole
  # height is a small thing to be exact about and it is the difference between
  # "the menu is over the world" and "the world is gone".
  DimTopAlpha* = 192
    ## `0xC0`.
  DimBottomAlpha* = 208
    ## `0xD0`.
  DimRed* = 16
  DimGreen* = 16
  DimBlue* = 16
    ## `0x101010`.
  DimBandCount* = DimBottomAlpha - DimTopAlpha
    ## How many bands the gradient is drawn as, and it is **derived**: the
    ## surface below can fill a rectangle with one colour and cannot ramp one,
    ## so a gradient is a stack of flat bands. One band per 8-bit step of alpha
    ## is the coarsest stack that is still as fine as the destination can hold -
    ## sixteen bands, sixteen steps, and the error against the real ramp is
    ## under one step everywhere. Widen the two constants and the stack widens
    ## with them; there is no 16 written anywhere in this module.

type
  DimBand* = object
    ## One flat band of the gradient. `alpha` is what a fill takes; `alpha8` is
    ## the same number in the units the game's own constant is written in, so an
    ## assertion can be made against `0xC0` rather than against 0.7529.
    rect*: MRect
    alpha*: float
    alpha8*: int

  PauseMove* = enum
    ## What an Escape did.
    NoMove,       ## nothing: this Escape belongs to whatever screen is up
    OpenPause,    ## the world had the screen; now this does
    ClosePause    ## back to the world

## The alpha the real gradient has at `y` down a `height`-tall screen, in 8-bit
## units. Nothing in the mod calls it: it is the thing the bands are asserted
## against, spelled once here so that the assertion and the drawing cannot drift
## apart - the same shape, and the same reason, as `mcuiscale.snapped`.
proc trueDim*(y, height: float): float =
  if height <= 0.0: return float(DimTopAlpha)
  float(DimTopAlpha) + float(DimBottomAlpha - DimTopAlpha) * y / height

## The gradient, as bands, over a rectangle that size.
##
## In *screen* pixels and not interface pixels, deliberately. The dim is a
## colour ramp and not a widget: there is no art in it to keep crisp, nothing on
## it lands on a grid, and `guiHeight` floors - so a dim laid out in interface
## pixels would leave the last few rows of the window undimmed on most windows,
## which is a bright strip under a dark screen and is exactly the kind of thing
## that is invisible at the one size somebody checked.
##
## The bands tile the rectangle exactly: each one starts where the last one
## ended, the first at the top and the last at the bottom, with no seam and no
## overlap.
proc dimBands*(width, height: float): seq[DimBand] =
  result = @[]
  if width <= 0.0 or height <= 0.0: return result
  var i = 0
  while i < DimBandCount:
    let top = height * float(i) / float(DimBandCount)
    let bottom = height * float(i + 1) / float(DimBandCount)
    let eight = DimTopAlpha + i
    result.add DimBand(rect: mrect(0.0, top, width, bottom - top),
                       alpha: float(eight) / 255.0, alpha8: eight)
    inc i

## What the bands really put at that height, in 8-bit units, or -1 above and
## below them. The reading half of `dimBands`, so an assertion can be about the
## mapping rather than about the list - which is what `mcuicore.sampleAt` is for
## the quads.
proc dimAt*(bands: seq[DimBand]; y: float): int =
  result = -1
  var i = 0
  while i < bands.len:
    if y >= bands[i].rect.y and y < bands[i].rect.y + bands[i].rect.h:
      result = bands[i].alpha8
    inc i

## An 8-bit channel as the 0..1 a fill takes.
proc dimLevel*(eight: int): float = float(eight) / 255.0

# ---------------------------------------------------------------------------
# The column

## Where the column starts: the game's `height / 4` and the game's `i`.
proc pauseTop*(guiH: int): int = guiH div 4 + PauseLift

## Whether Open to LAN can do anything. `hostGame` is a real host call, so this
## is not `menu.online`: it is a button that works, and works once. A world that
## is already served, or one that is somebody else's to serve, has nothing for
## it to do - and the game itself does not offer it in either case. It is drawn
## refused rather than left out, for the same reason `menu.online` is on the
## title screen: the column is the shape people know, and a missing row moves
## every row under it.
proc shareable*(hosting, joined: bool): bool =
  (not hosting) and (not joined)

const
  PauseKeys* = [KeyReturnToGame, KeyAdvancements, KeyStats, KeyOptions,
                KeyShareToLan, KeyReturnToMenu]
    ## Top to bottom and left to right, which is the order `pauseButtons`
    ## answers in and the order the test walks.

  PauseWired* = [true, false, false, true, true, true]
    ## Which of them have something behind them. Advancements and Statistics do
    ## not: nothing in this tree awards an advancement and nothing counts a
    ## statistic, so both are offered in the game's own place and refused, which
    ## is what the title screen does with `menu.online`. The alternative was to
    ## leave them out, and leaving them out moves the two rows under them.

  PauseEffects* = ["resumeWorld()", "", "", "stack.go OptionsPage",
                   "hostGame(", "leaveWorld()"]
    ## The phrase in `main.nim` that is the thing each row moves - the same
    ## device `mcuiopts`'s own `effect` column is, and for the same reason. This
    ## is not read by the mod; `Tests/mcui_test.exe` reads `main.nim` back and
    ## fails naming the row nobody wired. A refused row has no effect and must have
    ## none, so the two arrays are asserted against each other as well: an
    ## enabled row with nothing named, or a refused row with something named,
    ## is a contradiction rather than a style.

proc effectOfPause*(key: string): string =
  var i = 0
  while i < PauseKeys.len:
    if PauseKeys[i] == key: return PauseEffects[i]
    inc i
  ""

## The six buttons of the pause screen, in the game's own places.
proc pauseButtons*(guiW, guiH: int; canShare: bool): seq[MenuButton] =
  result = @[]
  let base = pauseTop(guiH)
  let left = float(guiW div 2 - ButtonWidth div 2)
  let right = float(guiW div 2 + PauseGap div 2)
  let full = float(ButtonWidth)
  let half = float(HalfButtonWidth)
  let tall = float(ButtonHeight)
  result.add MenuButton(key: KeyReturnToGame,
    rect: mrect(left, float(base + PauseResumeRow), full, tall), enabled: true)
  result.add MenuButton(key: KeyAdvancements,
    rect: mrect(left, float(base + PauseRecordsRow), half, tall),
    enabled: false)
  result.add MenuButton(key: KeyStats,
    rect: mrect(right, float(base + PauseRecordsRow), half, tall),
    enabled: false)
  result.add MenuButton(key: KeyOptions,
    rect: mrect(left, float(base + PauseSettingsRow), half, tall),
    enabled: true)
  result.add MenuButton(key: KeyShareToLan,
    rect: mrect(right, float(base + PauseSettingsRow), half, tall),
    enabled: canShare)
  result.add MenuButton(key: KeyReturnToMenu,
    rect: mrect(left, float(base + PauseLeaveRow), full, tall), enabled: true)

## Where the title sits, as the point it is centred on.
proc pauseTitleAt*(guiW: int): MRect =
  mrect(float(guiW) * 0.5, float(PauseTitleTop), 0.0, 0.0)

## Which title this screen carries, derived from the decision above and never
## written down twice.
proc pauseTitleKey*(): string =
  if PausesTheWorld: KeyPaused else: KeyGameMenu

# ---------------------------------------------------------------------------
# Escape

## Which way an Escape would swing, given what is on the stack. `NoMove` for
## every screen but the two ends of it, which is the gate: a screen opened over
## the pause screen keeps its own Escape, and so does anything that is not the
## world at all.
proc escapeMove*(s: Stack): PauseMove =
  if here(s) == WorldPage: OpenPause
  elif here(s) == PausePage: ClosePause
  else: NoMove

## The one door in and out. Escape uses it and so does the Return to Game
## button, because two doors is how one of them ends up not handing the mouse
## back.
proc togglePause*(s: var Stack): PauseMove =
  result = escapeMove(s)
  if result == OpenPause: s.go PausePage
  elif result == ClosePause: s.back()

## Everything the world is told when the screen swings, as `verb subject` rows.
##
## One verb. The whole claim of this module is that a pause screen here takes
## the mouse and nothing else, and this is where that claim is falsifiable: a
## second verb - a `pause`, a `freeze`, a `tick` - shows up in the test as a
## verb set with two things in it. It is a `seq[string]` rather than a call so
## that the test can hold the whole of it at once.
proc handoffsFor*(move: PauseMove): seq[string] =
  if move == OpenPause: @["pointer free"]
  elif move == ClosePause: @["pointer held"]
  else: @[]

## The verb of such a row, which is the word up to the first space.
proc verbOf*(row: string): string =
  result = ""
  var i = 0
  while i < row.len and row[i] != ' ':
    result.add row[i]
    inc i

## The subject, which is the rest of it.
proc subjectOf*(row: string): string =
  result = ""
  var i = 0
  while i < row.len and row[i] != ' ': inc i
  inc i
  while i < row.len:
    result.add row[i]
    inc i
