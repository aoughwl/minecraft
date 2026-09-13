## The title screen, as arithmetic.
##
## Every number in this module is Minecraft's own, in interface pixels, and
## nothing here draws or reads anything. `GuiMainMenu.initGui` and
## `GuiMainMenu.drawScreen` are two dozen integers and one sine, and those two
## dozen integers are what makes a screenshot of this and a screenshot of the
## game line up. They are written out here, on their own, so that the layout is
## a thing a test can walk rather than a thing buried in a draw call.
##
##     int j = this.height / 4 + 48;
##     singleplayer  (width / 2 - 100, j,            200, 20)
##     multiplayer   (width / 2 - 100, j + 24,       200, 20)
##     online        (width / 2 - 100, j + 48,       200, 20)
##     options       (width / 2 - 100, j + 72 + 12,   98, 20)
##     quit          (width / 2 + 2,   j + 72 + 12,   98, 20)
##
## The logo is two blits out of `gui/title/minecraft.png` and not one, because
## the sheet holds the word in two 155 by 44 bands stacked at y 0 and y 45. The
## game draws them side by side from x = width / 2 - 137. Drawing it as a single
## 256-wide sprite - the thing that looks reasonable until you compare - gets
## both the proportions and the position wrong.
##
## The splash is the part people notice moving: it hangs off the right shoulder
## of the logo at (width / 2 + 90, 70), turned twenty degrees anticlockwise, and
## its size breathes on a one-second sine while being scaled down to fit its own
## width. All three of those are here and none of them needs a host.
##
## ## Labels are keys
##
## No string in this module is a word. `menu.singleplayer` is what the button
## *is*; what it says is whatever the player's own language file says, and this
## mod never finds out. See `mcuilang`.

import mcuicore
import mcuifont

const
  ButtonWidth* = 200
  ButtonHeight* = 20
  HalfButtonWidth* = 98
  RowStep* = 24
  MenuTop* = 48
    ## `height / 4 + 48` is where the column starts.
  LogoTop* = 30
  LogoLeft* = 137
    ## `width / 2 - 137`, which is half of the 274 pixels the word really
    ## occupies rather than half of the 310 the two blits cover.
  LogoBandWidth* = 155
  LogoBandHeight* = 44
  LogoSecondBandTop* = 45
  SplashAnchorX* = 90
  SplashAnchorY* = 70
  SplashRise* = -8
    ## The splash is drawn centred at y = -8 in its own turned frame.
  SplashTurn* = -20.0
    ## Degrees, anticlockwise.
  CornerInset* = 2
  CornerBaseline* = 10
    ## `height - 10` is where both corner lines sit.
  BackgroundTile* = 32
    ## One repeat of the dirt, in interface pixels, whatever size the picture
    ## behind it is.
  BackgroundShade* = 0.25
    ## The dirt is drawn at a quarter brightness - `(64, 64, 64)` as a vertex
    ## colour - which is what makes it read as a backdrop and not as a floor.
  SplashColourR* = 255
  SplashColourG* = 255
  SplashColourB* = 0

  # ---- the sprite sheet ---------------------------------------------------
  #
  # `gui/widgets.png` is 256 by 256 and the button lives in three 200 by 20
  # bands at x = 0. Disabled is on top, then the normal one, then the hovered
  # one. The game addresses them as `46 + state * 20`.
  WidgetsSize* = 256.0
  ButtonSpriteX* = 0.0
  ButtonSpriteTop* = 46.0
  ButtonSpriteStride* = 20.0

  # ---- the keys -----------------------------------------------------------
  #
  # Every one of these is a real key out of `assets/minecraft/lang/en_us.json`.
  # Nothing here says what any of them means.
  KeySingleplayer* = "menu.singleplayer"
  KeyMultiplayer* = "menu.multiplayer"
  KeyOnline* = "menu.online"
  KeyOptions* = "menu.options"
  KeyQuit* = "menu.quit"
  KeyOptionsTitle* = "options.title"
  KeyDone* = "gui.done"
  KeyGuiScale* = "options.guiScale"
  KeyGuiScaleAuto* = "options.guiScale.auto"
  KeyGenericValue* = "options.generic_value"
    ## `%s: %s` - the row Minecraft builds every option label out of, and the
    ## reason this mod needs argument substitution at all.

type
  ButtonState* = enum
    ButtonDisabled, ButtonNormal, ButtonHovered

  MenuButton* = object
    key*: string      ## the translation key, which is the button's identity
    rect*: MRect      ## in interface pixels
    enabled*: bool

  Screen* = enum
    TitleScreen, OptionsScreen

## Which band of `widgets.png` a button in this state is drawn from.
proc buttonSprite*(state: ButtonState): MRect =
  var band = 1
  if state == ButtonDisabled: band = 0
  elif state == ButtonHovered: band = 2
  mrect(ButtonSpriteX, ButtonSpriteTop + float(band) * ButtonSpriteStride,
        float(ButtonWidth), float(ButtonHeight))

proc stateOf*(enabled, hovered: bool): ButtonState =
  if not enabled: ButtonDisabled
  elif hovered: ButtonHovered
  else: ButtonNormal

## The five buttons of the title screen, in the game's own places.
##
## `menu.online` is offered and disabled: it is on the real screen, this build
## has no service behind it, and leaving it out would move nothing but would
## make the column one row short of the one people know.
proc titleButtons*(guiW, guiH: int): seq[MenuButton] =
  result = @[]
  let j = guiH div 4 + MenuTop
  let left = float(guiW div 2 - ButtonWidth div 2)
  result.add MenuButton(key: KeySingleplayer,
    rect: mrect(left, float(j), float(ButtonWidth), float(ButtonHeight)),
    enabled: true)
  result.add MenuButton(key: KeyMultiplayer,
    rect: mrect(left, float(j + RowStep), float(ButtonWidth),
                float(ButtonHeight)),
    enabled: true)
  result.add MenuButton(key: KeyOnline,
    rect: mrect(left, float(j + RowStep * 2), float(ButtonWidth),
                float(ButtonHeight)),
    enabled: false)
  result.add MenuButton(key: KeyOptions,
    rect: mrect(left, float(j + 72 + 12), float(HalfButtonWidth),
                float(ButtonHeight)),
    enabled: true)
  result.add MenuButton(key: KeyQuit,
    rect: mrect(float(guiW div 2 + 2), float(j + 72 + 12),
                float(HalfButtonWidth), float(ButtonHeight)),
    enabled: true)

## The options screen used to be here, as two buttons: the GUI scale and Done.
## It is `mcuiopts` now - nine screens and about seventy controls, laid out off
## the same grid this module's `RowStep` and `ButtonWidth` define - and it was
## taken out rather than left beside the real one, because a second layout for
## the same screen is a layout somebody will read and believe.
##
## Which button that point in interface pixels is over, or -1. A disabled
## button is still hit: the game highlights it and refuses the click, rather
## than letting the click fall through to whatever is behind it.
proc buttonUnder*(buttons: seq[MenuButton]; x, y: float): int =
  result = -1
  var i = 0
  while i < buttons.len:
    if buttons[i].rect.holds(x, y): return i
    inc i

## Where the label sits inside a button: centred across, and on the baseline
## the game uses - `y + (height - 8) / 2`, which for a 20-high button is 6.
proc labelBaseline*(r: MRect): float =
  floorf(r.y + (r.h - NominalCell) * 0.5)

## The two blits that make the word, in interface pixels, on a `guiW`-wide
## screen. `sheet` is how many pixels the picture measures on a side - 256 for
## the vanilla one - so a doubled logo pack lands in exactly the same place.
proc logoQuads*(guiW: int; sheet = 256.0): seq[Quad] =
  let x = float(guiW div 2 - LogoLeft)
  let factor = sheet / 256.0
  result = @[]
  result.add quad(
    mrect(x, float(LogoTop), float(LogoBandWidth), float(LogoBandHeight)),
    mrect(0.0, 0.0, float(LogoBandWidth) * factor,
          float(LogoBandHeight) * factor))
  result.add quad(
    mrect(x + float(LogoBandWidth), float(LogoTop), float(LogoBandWidth),
          float(LogoBandHeight)),
    mrect(0.0, float(LogoSecondBandTop) * factor,
          float(LogoBandWidth) * factor, float(LogoBandHeight) * factor))

## The logo, the way anything from 1.20.2 on draws it: **one** blit and not two.
##
## The sheet changed with the layout. The old `minecraft.png` was 256 by 256
## with the word in two 155-wide bands stacked at y 0 and y 45; the modern one
## holds the word whole, and the game blits 256 by 44 out of a sheet it counts
## as 256 by 64 - the jar's file is 1024 by 256, which is that at 4x, and the
## nominal size is what the coordinates are in. Drawing the modern sheet with
## the old rule reads a quarter of the word twice.
const
  ModernLogoWidth* = 256
  ModernLogoHeight* = 44
  ModernLogoSheetW* = 256.0
  ModernLogoSheetH* = 64.0

proc logoQuadsModern*(guiW: int): seq[Quad] =
  @[quad(mrect(float(guiW div 2 - ModernLogoWidth div 2), float(LogoTop),
               float(ModernLogoWidth), float(ModernLogoHeight)),
        mrect(0.0, 0.0, float(ModernLogoWidth), float(ModernLogoHeight)))]

# ---------------------------------------------------------------------------
# The panorama
#
# The title screen's backdrop is a sky box: six faces, `panorama_0.png` to
# `panorama_5.png`, with the camera inside it turning slowly. Four of the six
# are the sides and cover the whole horizon between them, ninety degrees each.
#
# There is no camera here and no cube. What there is is a window ninety degrees
# wide walking round those four faces, cut at each face boundary into its own
# quad - which is the same picture the sky box shows at the horizon, and moves
# the same way. It is an approximation and `docs/MCUI.md` says which one: a real
# projection curves the verticals near the edges and this does not.
#
# The vertical extent is derived rather than picked. The window is ninety
# degrees across `guiW`, so a pixel is `90 / guiW` degrees; `guiH` pixels of it
# is `guiH / guiW` of a face, taken from the middle. A tall window sees more sky
# and a wide one sees less, which is what a camera does.

const
  PanoramaSides* = 4
  PanoramaShade* = 0.55
    ## The panorama is dimmed under the menu so the buttons read against it.
  PanoramaTurnsPerSecond* = 0.004
    ## A full turn in about four minutes, which is roughly the game's drift.

type PanoramaPiece* = object
  face*: int      ## 0..3
  dest*: MRect    ## interface pixels
  src*: MRect     ## 0..1 within that face, so the picture's size never matters

proc panoramaPieces*(guiW, guiH: int; spin: float): seq[PanoramaPiece] =
  result = @[]
  if guiW <= 0 or guiH <= 0: return result
  var tall = float(guiH) / float(guiW)
  if tall > 1.0: tall = 1.0
  if tall < 0.05: tall = 0.05
  let v0 = (1.0 - tall) * 0.5
  let sides = float(PanoramaSides)
  let start = (spin - floorf(spin)) * sides
  let stop = start + 1.0
  var at = start
  var guard = 0
  while at < stop and guard < PanoramaSides + 2:
    inc guard
    let base = floorf(at)
    var edge = base + 1.0
    if edge > stop: edge = stop
    if edge <= at: return result
    var face = int(base) mod PanoramaSides
    if face < 0: face = face + PanoramaSides
    result.add PanoramaPiece(face: face,
      dest: mrect((at - start) * float(guiW), 0.0,
                  (edge - at) * float(guiW), float(guiH)),
      src: mrect(at - base, v0, edge - at, tall))
    at = edge

## Where the splash hangs, in interface pixels.
proc splashAnchor*(guiW: int): MRect =
  mrect(float(guiW div 2 + SplashAnchorX), float(SplashAnchorY), 0.0, 0.0)

## How big the splash is drawn.
##
##     float f = 1.8F - abs(sin((time % 1000) / 1000.0 * PI * 2) * 0.1F);
##     f = f * 100.0F / (width + 32);
##
## Two things at once, and both matter: the breath, which is a tenth either side
## of 1.8 on a one-second period, and the fit, which shrinks a long splash so it
## does not run off the shoulder of the logo. A splash that only bobbed would
## overflow; one that only fitted would be dead.
proc splashScale*(splashWidth: int; seconds: float): float =
  let phase = seconds - floorf(seconds)
  let breath = 1.8 - absf(sine(phase * Pi * 2.0) * 0.1)
  breath * 100.0 / float(splashWidth + 32)

## The splash's own frame is turned; a glyph in it is placed along that turned
## baseline. Returns where the glyph at `along` interface pixels from the centre
## of the run lands, relative to the anchor.
proc splashPlace*(along, lift, size: float): MRect =
  let radians = SplashTurn * Pi / 180.0
  let c = cosine(radians)
  let s = sine(radians)
  let x = along * size
  let y = lift * size
  mrect(x * c - y * s, x * s + y * c, 0.0, 0.0)

## `texts/splashes.txt`, as lines. Blank lines and the bare carriage returns a
## Windows-edited pack leaves behind are dropped; nothing else is judged, and in
## particular nothing is filtered, because the file is the player's.
proc splashLines*(body: string): seq[string] =
  result = @[]
  var line = ""
  var i = 0
  while i <= body.len:
    if i == body.len or body[i] == '\n':
      var trimmed = ""
      var j = 0
      while j < line.len:
        let c = line[j]
        if c != '\r': trimmed.add c
        inc j
      var blank = true
      j = 0
      while j < trimmed.len:
        if trimmed[j] != ' ' and trimmed[j] != '\t': blank = false
        inc j
      if not blank: result.add trimmed
      line = ""
    else:
      line.add body[i]
    inc i

## Which one. The game picks at random once per screen; this picks once per
## session from a seed the caller supplies, so a headless run that asks twice
## gets the same answer twice.
proc splashAt*(lines: seq[string]; seed: int): string =
  if lines.len == 0: return ""
  var i = seed mod lines.len
  if i < 0: i = i + lines.len
  lines[i]

## Where the two corner lines go, in interface pixels.
proc bottomLeft*(guiH: int): MRect =
  mrect(float(CornerInset), float(guiH - CornerBaseline), 0.0, 0.0)
proc bottomRight*(guiW, guiH, width: int): MRect =
  mrect(float(guiW - width - CornerInset), float(guiH - CornerBaseline),
        0.0, 0.0)
