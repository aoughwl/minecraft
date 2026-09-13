## Minecraft's options screens, and what an option is allowed to be.
##
## ## The rule this module exists to hold
##
## **A control on these screens either moves something or says why it cannot.**
## There is no third state. An option that cycles a label and changes nothing is
## worse than one that is absent, because the absent one is honest and the
## cycling one takes a player's time twice - once to set it and once to work out
## why it did nothing. And a screen that is *missing* the row is worse than one
## that has it greyed: the missing row moves every row under it, so the screen
## stops being the screen people know.
##
## So every row below carries exactly one of two things: an `effect`, which is a
## phrase that must really appear in `main.nim`, or a `reason`, which is a
## sentence naming what is missing and which the screen draws in place of the
## control. `Tests/mcui_test.exe` asserts both halves - that no row has neither
## and no row has both, and that every named effect is in `main.nim` - so
## "everything on this screen is real" is a mechanism rather than a sentence.
## It is the same device `mcuipause.PauseEffects` is, widened to nine screens.
##
## A third case needs the runtime and cannot be decided here: a row wired
## `world:<name>` is honoured by whatever is drawing the world, which answers
## `ok` or `no <reason>` over the `voxel.settings` service. That row is greyed
## with the *world's own* reason, so a setting that stops being reachable stops
## claiming to be reachable on the same frame, with no list here to keep in step.
##
## ## The rows are a table, not code
##
## Each row is one line of `name=value` fields separated by semicolons, and all
## nine screens' rows live in one array, told apart by their `page` field. That
## is deliberately the shape `aoughwl.voxel`'s `vxdefaults` already uses,
## and it is what keeps nine screens and roughly seventy controls from being
## seventy branches: the layout walks the table, the drawing walks the table,
## the store walks the table, and adding a row is a line.
##
## It is `name=value` and not a row of pipes for one reason, learned the
## expensive way: a positional row with thirteen columns in it has four empty
## ones in the middle of every refused control, and a row with one pipe too few
## puts the *reason* in the *effect* column - which is a row that claims to be
## wired, silently, and is exactly the failure this whole module is against.
## A named field cannot be miscounted, and `Tests/mcui_test.exe` still asserts
## that every row parses and that no row carries a field name nobody reads.
##
## `store` is the name the setting has in Minecraft's own `options.txt`, so what
## this mod remembers under `save`/`remember` is keyed the way the game keys it:
## `mouseSensitivity` and not `sensitivity`, `maxFps` and not `framerateLimit`.
## Nothing reads or writes a real `options.txt` yet - see `docs/MCUI.md` - and
## that is exactly why the names have to be right now rather than later.
##
## ## The layouts are the game's own integers
##
## Three shapes cover nine screens, and each is written out as the game writes
## it:
##
##     grid     x = width / 2 - 155 + (i % 2) * 160
##              y = height / 6 + 24 * (i / 2)
##              done at (width / 2 - 100, height / 6 + 168, 200, 20)
##
##     list     an OptionsList between 32 and height - 32, rows 25 tall, two
##              150-wide columns at width / 2 - 155 and width / 2 + 5
##              done at (width / 2 - 100, height - 27, 200, 20)
##
##     root     the grid, with the first row lifted to height / 6 - 12 and the
##              block of screen buttons starting at height / 6 + 48 - 6
##
## The root screen's two numbers look like a mistake and are not: `OptionsScreen`
## puts its sliders at `height / 6 - 12` and every one of its eight sub-screen
## buttons at `height / 6 + <a multiple of 24> - 6`, which leaves a 54-pixel gap
## between the two blocks. They are spelled here as a lift and a block top, the
## way `mcuipause` spells its `-16` as a lift, so the test asserts one rule
## rather than six remembered numbers.
##
## ## Labels are keys
##
## No string on any of these screens is a word. `options.renderDistance` is what
## the row *is*; what it says is the player's own language file's business, and
## so is `options.generic_value` - `%s: %s` - which is the pattern the label is
## built out of and the reason this mod needs argument substitution at all.
##
## The `reason` column is the one exception and it is the same exception
## `mcuigrant` is: there is nothing to translate against, because Minecraft has
## no key for *this game cannot reach RenderSettings*. Those go through
## `main.nim`'s `ours()` like every other sentence of ours.

import mcuicore
import mcuimenu
import mcuistack

const
  # ---- the grid ----------------------------------------------------------
  RowWidth* = 150
  ColumnStep* = 160
  GridLeft* = 155
    ## `width / 2 - 155`, so the left column's right edge is five pixels left of
    ## centre and the right column's left edge is five right of it.
  RowHeight* = 20
  DoneDrop* = 168
    ## `height / 6 + 168`, where every grid screen puts its Done.

  # ---- the root screen ---------------------------------------------------
  RootLift* = -12
    ## `height / 6 - 12`: where `OptionsScreen` puts its top row.
  RootBlockTop* = 42
    ## `height / 6 + 48 - 6`: the top of the block of eight sub-screen buttons.
  LockWidth* = 20
  LockLeft* = 135
    ## `width / 2 - 155 + 160 + 150 - 20`, which is the right-hand end of the
    ## right-hand column: the padlock sits *on* the difficulty button's right
    ## edge and the button is made short by exactly the padlock's width. The
    ## game shrinks the button rather than moving either of them, which is why
    ## the two are written as one rule here and asserted to meet.

  # ---- the scrolling option list -----------------------------------------
  OptListTop* = 32
  OptListBottom* = 32
    ## `height - 32`.
  OptListRow* = 25
  OptListDone* = 27
    ## `height - 27`.
  OptListTitle* = 5
    ## `drawCenteredString(title, width / 2, 5, 0xFFFFFF)` - higher than the
    ## grid screens' 15, because the list starts at 32 and would run into it.

  GridTitleTop* = 15
    ## Every grid screen's title.

  # ---- the slider --------------------------------------------------------
  #
  # A Minecraft slider is a button-shaped track with an 8-wide knob drawn over
  # it, and the knob is two 4-wide blits out of `widgets.png` at (0, 66) and
  # (196, 66), moved down a band when the pointer is over it. The knob's left
  # edge runs from the track's left edge to `width - 8` past it, which is why
  # the value-to-position rule and the position-to-value rule below both have an
  # 8 in them and neither has a half-pixel fudge in it.
  KnobWidth* = 8
  KnobPieceWidth* = 4
  KnobSpriteX* = 0.0
  KnobSpriteRight* = 196.0
  KnobSpriteTop* = 66.0
  KnobSpriteStride* = 20.0

  WideWidth* = 310
    ## Both columns and the channel between them: the width of a list band on
    ## every screen in this family, and of the one control that spans the pair.
  ReasonBaseline* = 12
    ## `height - 12`, where a refused control's reason is written. Ours, and the
    ## only thing on these screens that is: Minecraft has no refused controls
    ## and therefore nowhere to put one's reason.
  UnicodeReason* = "there is one font sheet, and forcing unicode would need a " &
    "second one the granted copy does not publish"
  FallbackLanguage* = "en_us"
    ## What Minecraft falls back to, key by key, for anything a language file
    ## does not carry. Spelled once here and read by the language screen.

  KeyFullscreen* = "options.fullscreen"
  KeyFullscreenStore* = "fullscreen"
  KeyFramerate* = "options.framerateLimit"
  KeyGuiScaleStore* = "guiScale"
  KeyFramerateStore* = "maxFps"
    ## The three `options.txt` names anything outside the table needs to say.
    ## Everything else reads its store off its own row.
  KeyPercentValue* = "options.percent_value"
    ## `%s: %s%%` - so even the per cent sign is the language file's.
  KeyOn* = "options.on"
  KeyOff* = "options.off"
  WorldMark* = "world:"
    ## The wiring that is honoured by whatever is drawing the world rather than
    ## by this mod.

type
  OptionKind* = enum
    CycleOption,   ## steps round a short list of values
    SliderOption,  ## a number dragged between two ends
    ScreenOption   ## a button that opens another screen

  ValueStyle* = enum
    PlainValue,    ## the number itself
    PercentValue,  ## `options.percent_value`
    SwitchValue,   ## `options.on` / `options.off`
    NamedValue,    ## one of a short list of keys, indexed by the value
    ScaleValue,    ## the GUI scale, where 0 is a key and 1..4 are numbers
    NoValue        ## a screen button, which has no value at all

  Option* = object
    page*: Page
    key*: string        ## the translation key, which is the row's identity
    store*: string      ## what `options.txt` calls it
    kind*: OptionKind
    style*: ValueStyle
    lo*, hi*, stride*: int
    fallback*: int      ## the value a player who has never touched it has
    pattern*: string    ## a key the value goes inside first - `options.chunks`
    minKey*, maxKey*: string  ## what the two ends are called instead of numbers
    effect*: string     ## the phrase in `main.nim` that moves it, or empty
    reason*: string     ## why nothing does, or empty
    rect*: MRect

  Shown* = object
    ## What a row's label is made of, so that `main.nim` translates and
    ## substitutes and this module decides nothing about words.
    pattern*: string       ## `options.generic_value` or `options.percent_value`
    valueKey*: string      ## the value's own key, when it has one
    valueText*: string     ## the value as a number, when it has not
    valuePattern*: string  ## a key the number goes inside first, or empty

# ---------------------------------------------------------------------------
# The table

const
  Rows* = [
    # ---- the options screen itself ---------------------------------------
    "page=options;key=options.fov;store=fov;kind=slider;lo=30;hi=110;default=70;min=options.fov.min;max=options.fov.max;effect=world:fov",
    "page=options;key=options.difficulty;store=difficulty;style=named;hi=3;default=2;effect=world:difficulty",
    "page=options;key=options.skinCustomisation;kind=screen;style=none;effect=stack.go SkinPage",
    "page=options;key=options.sounds;kind=screen;style=none;effect=stack.go SoundPage",
    "page=options;key=options.video;kind=screen;style=none;effect=stack.go VideoPage",
    "page=options;key=options.controls;kind=screen;style=none;effect=stack.go ControlsPage",
    "page=options;key=options.language;kind=screen;style=none;effect=stack.go LanguagePage",
    "page=options;key=options.chat.title;kind=screen;style=none;effect=stack.go ChatPage",
    "page=options;key=options.resourcepack;kind=screen;style=none;effect=stack.go PacksPage",
    "page=options;key=options.accessibility.title;kind=screen;style=none;effect=stack.go AccessPage",

    # ---- video -----------------------------------------------------------
    "page=video;key=options.graphics;store=graphicsMode;style=named;hi=2;default=1;reason=no host call chooses a render path, and RenderSettings is a static class the mod seam cannot reach at all",
    "page=video;key=options.renderDistance;store=renderDistance;kind=slider;lo=2;hi=32;default=12;pattern=options.chunks;effect=world:renderDistance",
    "page=video;key=options.simulationDistance;store=simulationDistance;kind=slider;lo=5;hi=32;default=8;pattern=options.chunks;reason=the near world is a fixed window of chunks round the player and nothing reaches its span from here",
    "page=video;key=options.guiScale;store=guiScale;style=scale;hi=4;default=0;effect=scaleSetting = value",
    "page=video;key=options.framerateLimit;store=maxFps;kind=slider;lo=10;hi=260;step=10;default=120;pattern=options.framerate;max=options.framerateLimit.max;effect=frameRate(frameCap)",
    "page=video;key=options.vsync;store=enableVsync;style=switch;default=1;reason=no host call sets QualitySettings.vSyncCount",
    "page=video;key=options.fullscreen;store=fullscreen;style=switch;effect=displayMode(",
    "page=video;key=options.gamma;store=gamma;kind=slider;hi=100;default=50;style=percent;min=options.gamma.min;max=options.gamma.max;reason=no host call sets RenderSettings.ambientLight, and docs/SKY.md specifies the sky_ calls that would carry it",
    "page=video;key=options.ao;store=ao;style=switch;default=1;reason=the mesh host takes no vertex colours, so smooth lighting cannot be baked into a chunk",
    "page=video;key=options.viewBobbing;store=bobView;style=switch;default=1;effect=world:viewBobbing",
    "page=video;key=options.renderClouds;store=renderClouds;style=switch;default=1;reason=nothing in this modpack draws clouds",
    "page=video;key=options.particles;store=particles;style=named;hi=2;reason=nothing in this modpack spawns a particle",
    "page=video;key=options.mipmapLevels;store=mipmapLevels;kind=slider;hi=4;default=4;reason=no host call sets a texture's mipmap count",
    "page=video;key=options.entityShadows;store=entityShadows;style=switch;default=1;reason=no host call turns one renderer's shadows off",
    "page=video;key=options.biomeBlendRadius;store=biomeBlendRadius;kind=slider;hi=7;default=2;reason=the generator has one biome, so there is nothing to blend between",
    "page=video;key=options.entityDistanceScaling;store=entityDistanceScaling;kind=slider;style=percent;lo=50;hi=500;step=25;default=100;reason=no host call sets a renderer's cull distance",
    "page=video;key=options.attackIndicator;store=attackIndicator;style=named;hi=2;default=1;reason=nothing draws an attack cooldown",
    "page=video;key=options.screenEffectScale;store=screenEffectScale;kind=slider;style=percent;hi=100;default=100;reason=no post-processing is reachable: no RenderTexture, no command buffers, no Graphics calls",
    "page=video;key=options.fovEffectScale;store=fovEffectScale;kind=slider;style=percent;hi=100;default=100;reason=the field of view is set once and nothing modulates it per frame",

    # ---- controls --------------------------------------------------------
    "page=controls;key=options.mouse_settings;kind=screen;style=none;effect=stack.go MousePage",
    "page=controls;key=options.autoJump;store=autoJump;style=switch;effect=world:autoJump",

    # ---- mouse settings --------------------------------------------------
    "page=mouse;key=options.sensitivity;store=mouseSensitivity;kind=slider;style=percent;hi=200;default=100;min=options.sensitivity.min;max=options.sensitivity.max;effect=world:sensitivity",
    "page=mouse;key=options.invertMouse;store=invertYMouse;style=switch;effect=world:invertMouse",
    "page=mouse;key=options.discrete_mouse_scroll;store=discrete_mouse_scroll;style=switch;reason=the wheel arrives already counted in notches, so there is nothing left to discretise",
    "page=mouse;key=options.touchscreen;store=touchscreen;style=switch;reason=there is no touch input on this floor",
    "page=mouse;key=options.rawMouseInput;store=rawMouseInput;style=switch;default=1;reason=no host call chooses between raw and accelerated pointer input",

    # ---- sound -----------------------------------------------------------
    "page=sound;key=soundCategory.master;store=soundCategory_master;kind=slider;style=percent;hi=100;default=100;effect=busVolume(",
    "page=sound;key=soundCategory.music;store=soundCategory_music;kind=slider;style=percent;hi=100;default=100;effect=busVolume(",
    "page=sound;key=soundCategory.record;store=soundCategory_record;kind=slider;style=percent;hi=100;default=100;effect=busVolume(",
    "page=sound;key=soundCategory.weather;store=soundCategory_weather;kind=slider;style=percent;hi=100;default=100;effect=busVolume(",
    "page=sound;key=soundCategory.block;store=soundCategory_block;kind=slider;style=percent;hi=100;default=100;effect=busVolume(",
    "page=sound;key=soundCategory.hostile;store=soundCategory_hostile;kind=slider;style=percent;hi=100;default=100;effect=busVolume(",
    "page=sound;key=soundCategory.neutral;store=soundCategory_neutral;kind=slider;style=percent;hi=100;default=100;effect=busVolume(",
    "page=sound;key=soundCategory.player;store=soundCategory_player;kind=slider;style=percent;hi=100;default=100;effect=busVolume(",
    "page=sound;key=soundCategory.ambient;store=soundCategory_ambient;kind=slider;style=percent;hi=100;default=100;effect=busVolume(",
    "page=sound;key=options.showSubtitles;store=showSubtitles;style=switch;reason=nothing in this modpack produces a subtitle",

    # ---- chat ------------------------------------------------------------
    "page=chat;key=options.chat.visibility;store=chatVisibility;style=named;hi=2;reason=aoughwl.chat serves no settings - it would need a chat.settings service with a visibility line on it",
    "page=chat;key=options.chat.color;store=chatColors;style=switch;default=1;reason=the same service, with a colour line on it",
    "page=chat;key=options.chat.links;store=chatLinks;style=switch;default=1;reason=nothing in the chat window makes a link out of a url",
    "page=chat;key=options.chat.links.prompt;store=chatLinksPrompt;style=switch;default=1;reason=there are no links to prompt about",
    "page=chat;key=options.chat.opacity;store=chatOpacity;kind=slider;style=percent;hi=100;default=100;reason=the same service, with an opacity line on it",
    "page=chat;key=options.chat.scale;store=chatScale;kind=slider;style=percent;hi=100;default=100;reason=the same service, with a scale line on it",
    "page=chat;key=options.chat.width;store=chatWidth;kind=slider;style=percent;hi=100;default=100;reason=the same service, with a width line on it",
    "page=chat;key=options.chat.height.focused;store=chatHeightFocused;kind=slider;style=percent;hi=100;default=100;reason=the same service, with a height line on it",
    "page=chat;key=options.chat.height.unfocused;store=chatHeightUnfocused;kind=slider;style=percent;hi=100;default=44;reason=the same service, with a height line on it",
    "page=chat;key=options.chat.line_spacing;store=chatLineSpacing;kind=slider;style=percent;hi=100;reason=the same service, with a line-spacing line on it",
    "page=chat;key=options.chat.delay_instant;store=chatDelay;kind=slider;hi=60;reason=nothing delays a chat line",
    "page=chat;key=options.autoSuggestCommands;store=autoSuggestCommands;style=switch;default=1;reason=there are no commands to suggest",
    "page=chat;key=options.hideMatchedNames;store=hideMatchedNames;style=switch;default=1;reason=there is no ignore list to match a name against",

    # ---- skin customisation ----------------------------------------------
    "page=skin;key=options.modelPart.cape;store=modelPart_cape;style=switch;default=1;reason=the player model in aoughwl.voxel is six boxes and has no cape",
    "page=skin;key=options.modelPart.jacket;store=modelPart_jacket;style=switch;default=1;reason=the player model has no outer layer to hide",
    "page=skin;key=options.modelPart.left_sleeve;store=modelPart_left_sleeve;style=switch;default=1;reason=the player model has no outer layer to hide",
    "page=skin;key=options.modelPart.right_sleeve;store=modelPart_right_sleeve;style=switch;default=1;reason=the player model has no outer layer to hide",
    "page=skin;key=options.modelPart.left_pants_leg;store=modelPart_left_pants_leg;style=switch;default=1;reason=the player model has no outer layer to hide",
    "page=skin;key=options.modelPart.right_pants_leg;store=modelPart_right_pants_leg;style=switch;default=1;reason=the player model has no outer layer to hide",
    "page=skin;key=options.modelPart.hat;store=modelPart_hat;style=switch;default=1;reason=the head's second layer is drawn unconditionally in vxskin",
    "page=skin;key=options.mainHand;store=mainHand;style=named;hi=1;default=1;reason=the hand in the corner of the screen is drawn on one side only",

    # ---- accessibility ---------------------------------------------------
    "page=access;key=options.accessibility.text_background_opacity;store=textBackgroundOpacity;kind=slider;style=percent;hi=100;default=50;reason=nothing draws a background behind text",
    "page=access;key=options.chat.line_spacing;store=chatLineSpacing;kind=slider;style=percent;hi=100;reason=aoughwl.chat serves no settings",
    "page=access;key=options.chat.delay_instant;store=chatDelay;kind=slider;hi=60;reason=nothing delays a chat line",
    "page=access;key=options.autoJump;store=autoJump;style=switch;effect=world:autoJump",
    "page=access;key=options.showSubtitles;store=showSubtitles;style=switch;reason=nothing produces a subtitle",
    "page=access;key=options.accessibility.toggle_sprint;store=toggleSprint;style=switch;reason=sprint is held rather than toggled inside the character, and ModSdk bindKey has no say over which",
    "page=access;key=options.accessibility.toggle_crouch;store=toggleCrouch;style=switch;reason=there is no crouch in this world, so there is nothing to hold down or to toggle",
    "page=access;key=options.darkMojangStudiosBackgroundColor;store=darkMojangStudiosBackground;style=switch;reason=the studio screen is drawn from the granted copy's own picture",
    "page=access;key=options.hideLightningFlashes;store=hideLightningFlashes;style=switch;reason=there is no weather in this world, and therefore no lightning to flash",
    "page=access;key=options.monochromeLogo;store=monochromeLogo;style=switch;reason=the logo is the granted copy's own picture and has one colouring",
    "page=access;key=options.screenEffectScale;store=screenEffectScale;kind=slider;style=percent;hi=100;default=100;reason=no post-processing is reachable",
    "page=access;key=options.fovEffectScale;store=fovEffectScale;kind=slider;style=percent;hi=100;default=100;reason=nothing modulates the field of view per frame"]

  FieldNames* = ["page", "key", "store", "kind", "style", "lo", "hi", "step",
                 "default", "pattern", "min", "max", "effect", "reason"]
    ## Every field name a row may carry. Nothing reads this but the test, which
    ## fails on a row with a field nobody reads - the typo that would otherwise
    ## be a setting silently taking its default for ever.

## The list of value keys a `named` cycle steps through, in order. Answered by
## the row's key rather than carried on the row, because a `seq[string]` inside
## a `const` array is the one shape the mod compiler and the test compiler
## disagree about.
proc valueKeys*(key: string): seq[string] =
  if key == "options.difficulty":
    @["options.difficulty.peaceful", "options.difficulty.easy",
      "options.difficulty.normal", "options.difficulty.hard"]
  elif key == "options.graphics":
    @["options.graphics.fast", "options.graphics.fancy",
      "options.graphics.fabulous"]
  elif key == "options.particles":
    @["options.particles.all", "options.particles.decreased",
      "options.particles.minimal"]
  elif key == "options.attackIndicator":
    @[KeyOff, "options.attack.crosshair", "options.attack.hotbar"]
  elif key == "options.chat.visibility":
    @["options.chat.visibility.full", "options.chat.visibility.system",
      "options.chat.visibility.hidden"]
  elif key == "options.mainHand":
    @["options.mainHand.left", "options.mainHand.right"]
  else: @[]

# ---------------------------------------------------------------------------
# Reading a row

## The value of one named field, or the empty string. A field runs from after
## its `=` to the next `;` or the end - so a `reason` may hold anything but a
## semicolon, which is why none of them does.
proc fieldOf*(line, want: string): string =
  result = ""
  var at = 0
  while at < line.len:
    # The name runs to the `=`.
    var name = ""
    while at < line.len and line[at] != '=' and line[at] != ';':
      name.add line[at]
      inc at
    var value = ""
    if at < line.len and line[at] == '=':
      inc at
      while at < line.len and line[at] != ';':
        value.add line[at]
        inc at
    if at < line.len and line[at] == ';': inc at
    if name == want: return value
  ""

## Every field name a row carries, so the test can find one nobody reads.
proc fieldNamesOf*(line: string): seq[string] =
  result = @[]
  var at = 0
  while at < line.len:
    var name = ""
    while at < line.len and line[at] != '=' and line[at] != ';':
      name.add line[at]
      inc at
    if name.len > 0: result.add name
    if at < line.len and line[at] == '=':
      inc at
      while at < line.len and line[at] != ';': inc at
    if at < line.len and line[at] == ';': inc at

proc wholeOf(text: string; fallback: int): int =
  if text.len == 0: return fallback
  var i = 0
  var sign = 1
  if text[0] == '-':
    sign = -1
    i = 1
  var value = 0
  var digits = 0
  while i < text.len:
    if text[i] < '0' or text[i] > '9': return fallback
    value = value * 10 + (int(text[i]) - int('0'))
    inc digits
    inc i
  if digits == 0: fallback else: value * sign

proc kindOf(word: string): OptionKind =
  if word == "slider": SliderOption
  elif word == "screen": ScreenOption
  else: CycleOption

proc styleOf(word: string): ValueStyle =
  if word == "percent": PercentValue
  elif word == "switch": SwitchValue
  elif word == "named": NamedValue
  elif word == "scale": ScaleValue
  elif word == "none": NoValue
  else: PlainValue

## Which screen a row belongs to. The page words are short because they are only
## ever written here and read here.
proc pageOf*(word: string): Page =
  if word == "video": VideoPage
  elif word == "controls": ControlsPage
  elif word == "mouse": MousePage
  elif word == "language": LanguagePage
  elif word == "sound": SoundPage
  elif word == "chat": ChatPage
  elif word == "skin": SkinPage
  elif word == "access": AccessPage
  else: OptionsPage

## One row of the table, read apart. The rectangle is filled in by whichever
## layout the screen uses; this is the row and not its place.
proc readRow*(line: string): Option =
  Option(page: pageOf(fieldOf(line, "page")),
         key: fieldOf(line, "key"),
         store: fieldOf(line, "store"),
         kind: kindOf(fieldOf(line, "kind")),
         style: styleOf(fieldOf(line, "style")),
         lo: wholeOf(fieldOf(line, "lo"), 0),
         hi: wholeOf(fieldOf(line, "hi"), 1),
         stride: wholeOf(fieldOf(line, "step"), 1),
         fallback: wholeOf(fieldOf(line, "default"), 0),
         pattern: fieldOf(line, "pattern"),
         minKey: fieldOf(line, "min"),
         maxKey: fieldOf(line, "max"),
         effect: fieldOf(line, "effect"),
         reason: fieldOf(line, "reason"),
         rect: mrect(0.0, 0.0, 0.0, 0.0))

## The title every options screen carries, by its own translation key. Spelled
## here rather than at the drawing, so a screen cannot be added without one.
proc titleKey*(p: Page): string =
  if p == OptionsPage: KeyOptionsTitle
  elif p == VideoPage: "options.videoTitle"
  elif p == ControlsPage: "controls.title"
  elif p == MousePage: "options.mouse_settings.title"
  elif p == LanguagePage: "options.language"
  elif p == SoundPage: "options.sounds.title"
  elif p == ChatPage: "options.chat.title"
  elif p == SkinPage: "options.skinCustomisation.title"
  elif p == AccessPage: "options.accessibility.title"
  else: ""

## Whether a page is one of the options family at all - which is what decides
## whether `drawOptions` is the thing that draws it.
proc isOptionsPage*(p: Page): bool = titleKey(p).len > 0

## Which page a `stack.go <Page>` effect names. The one place the effect column
## and the stack meet, so a screen button's wiring is the same string the test
## looks for in `main.nim` and the thing the mod really does.
proc opensPage*(effect: string): Page =
  if effect == "stack.go VideoPage": VideoPage
  elif effect == "stack.go ControlsPage": ControlsPage
  elif effect == "stack.go MousePage": MousePage
  elif effect == "stack.go LanguagePage": LanguagePage
  elif effect == "stack.go SoundPage": SoundPage
  elif effect == "stack.go ChatPage": ChatPage
  elif effect == "stack.go SkinPage": SkinPage
  elif effect == "stack.go AccessPage": AccessPage
  elif effect == "stack.go PacksPage": PacksPage
  else: OptionsPage

## The name on the `voxel.settings` line a `world:` row is honoured by, or the
## empty string for a row that is not one.
proc worldName*(effect: string): string =
  if effect.len <= WorldMark.len: return ""
  var i = 0
  while i < WorldMark.len:
    if effect[i] != WorldMark[i]: return ""
    inc i
  result = ""
  i = WorldMark.len
  while i < effect.len:
    result.add effect[i]
    inc i

proc wired*(o: Option): bool = o.effect.len > 0

# ---------------------------------------------------------------------------
# Where the rows go

proc gridRect*(guiW, guiH, i: int): MRect =
  mrect(float(guiW div 2 - GridLeft + (i mod 2) * ColumnStep),
        float(guiH div 6 + RowStep * (i div 2)), float(RowWidth),
        float(RowHeight))

proc gridDone*(guiW, guiH: int): MRect =
  mrect(float(guiW div 2 - ButtonWidth div 2), float(guiH div 6 + DoneDrop),
        float(ButtonWidth), float(ButtonHeight))

## The scrolling option list's band. Two controls to a row, so the list is half
## as many entries long as there are controls - which is the count the
## scrollbar's thumb is a function of and the easiest thing on this screen to
## get wrong by a factor of two.
proc optListRows*(controls: int): int = (controls + 1) div 2

proc listRect*(guiW, guiH, i, scroll: int): MRect =
  mrect(float(guiW div 2 - GridLeft + (i mod 2) * ColumnStep),
        float(OptListTop + (i div 2) * OptListRow - scroll),
        float(RowWidth), float(RowHeight))

proc listDone*(guiW, guiH: int): MRect =
  mrect(float(guiW div 2 - ButtonWidth div 2), float(guiH - OptListDone),
        float(ButtonWidth), float(ButtonHeight))

## The root screen: the top row is lifted, and the block of eight sub-screen
## buttons starts lower than the grid would have put it.
proc rootRect*(guiW, guiH, i: int): MRect =
  let x = float(guiW div 2 - GridLeft + (i mod 2) * ColumnStep)
  if i < 2:
    return mrect(x, float(guiH div 6 + RootLift), float(RowWidth),
                 float(RowHeight))
  mrect(x, float(guiH div 6 + RootBlockTop + RowStep * ((i - 2) div 2)),
        float(RowWidth), float(RowHeight))

## The padlock beside the difficulty button. Twenty wide at `width / 2 + 105`,
## and the difficulty button is short by exactly that rather than moved.
proc lockRect*(guiW, guiH: int): MRect =
  mrect(float(guiW div 2 + LockLeft), float(guiH div 6 + RootLift),
        float(LockWidth), float(RowHeight))

proc difficultyRect*(guiW, guiH: int): MRect =
  let full = rootRect(guiW, guiH, 1)
  mrect(full.x, full.y, full.w - float(LockWidth), full.h)

## Whether a screen lays its rows out on the grid or in the scrolling list.
##
## Video is the one screen with more controls than a grid holds - nineteen is
## ten rows, and the tenth is past where Done goes. Every other screen fits, and
## `Tests/mcui_test.exe` asserts exactly that: a screen scrolls when and only
## when a grid would not hold it. So a screen that grows a row moves itself into
## a list rather than off the bottom of the window, which is the failure this is
## instead of.
##
## Minecraft scrolls its Accessibility screen too, and this does not, because
## this one has twelve controls where the game has more and twelve fit. That is
## the one place in this module the shape is derived rather than copied, and it
## is derived because the alternative is a scrollbar on a screen with nothing
## to scroll.
proc scrolls*(p: Page): bool = p == VideoPage

## Every control on a screen, in order, with its place filled in.
##
## `inWorld` decides one row and only one: Minecraft offers the difficulty on
## the options screen while a world is up and not on the title screen, because
## there is no world to set it on. It is left out rather than refused - which is
## what the game does, and is the one place in this module a missing row is
## right, because it is the last row of its own block and moves nothing.
proc options*(p: Page; guiW, guiH: int; inWorld = false;
              scroll = 0): seq[Option] =
  result = @[]
  var i = 0
  var at = 0
  while i < Rows.len:
    var one = readRow(Rows[i])
    inc i
    if one.page != p: continue
    if p == OptionsPage and one.key == "options.difficulty" and not inWorld:
      # Left out, but its *place* is not: the eight screen buttons under it are
      # a block, and closing the hole up would slide every one of them into the
      # slot above. The game leaves the right of the top row empty on the title
      # screen for exactly this reason.
      inc at
      continue
    if p == OptionsPage: one.rect = rootRect(guiW, guiH, at)
    elif scrolls(p): one.rect = listRect(guiW, guiH, at, scroll)
    else: one.rect = gridRect(guiW, guiH, at)
    if p == OptionsPage and one.key == "options.difficulty":
      one.rect = difficultyRect(guiW, guiH)
    result.add one
    inc at

## Every row of the table, in order, whatever screen it is on. The store, the
## defaults and the test all want this; nothing draws it.
proc allRows*(): seq[Option] =
  result = @[]
  var i = 0
  while i < Rows.len:
    result.add readRow(Rows[i])
    inc i

proc doneRect*(p: Page; guiW, guiH: int): MRect =
  if scrolls(p): listDone(guiW, guiH) else: gridDone(guiW, guiH)

proc titleTop*(p: Page): int =
  if scrolls(p): OptListTitle else: GridTitleTop

proc optionUnder*(list: seq[Option]; x, y: float): int =
  result = -1
  var i = 0
  while i < list.len:
    if list[i].rect.holds(x, y): return i
    inc i

# ---------------------------------------------------------------------------
# The values

## The next value a cycle takes, wrapping back to the bottom.
proc nextValue*(o: Option; value: int): int =
  if o.hi <= o.lo: return o.lo
  var step = o.stride
  if step <= 0: step = 1
  let n = value + step
  if n > o.hi: o.lo else: n

proc clampValue*(o: Option; value: int): int =
  if value < o.lo: o.lo
  elif value > o.hi: o.hi
  else: value

## Where the knob's left edge sits inside the track, in interface pixels.
proc knobAt*(o: Option; value: int): float =
  if o.hi <= o.lo: return o.rect.x
  let v = clampValue(o, value)
  o.rect.x + float(v - o.lo) * (o.rect.w - float(KnobWidth)) /
    float(o.hi - o.lo)

## The value a point on the track means, rounded to the row's own step. The
## inverse of `knobAt`: the pointer holds the *middle* of the knob, so the
## travel is `w - 8` and the origin is half a knob in, which is the pair of
## eights the module comment is about.
proc valueAt*(o: Option; x: float): int =
  if o.hi <= o.lo: return o.lo
  let travel = o.rect.w - float(KnobWidth)
  if travel <= 0.0: return o.lo
  var f = (x - o.rect.x - float(KnobWidth) * 0.5) / travel
  if f < 0.0: f = 0.0
  if f > 1.0: f = 1.0
  var step = o.stride
  if step <= 0: step = 1
  var v = o.lo + int(f * float(o.hi - o.lo) + 0.5)
  v = o.lo + ((v - o.lo + step div 2) div step) * step
  clampValue(o, v)

## The knob, as the two blits the game draws it with.
proc knobQuads*(o: Option; value: int; hovered: bool): seq[Quad] =
  var band = 0.0
  if hovered: band = KnobSpriteStride
  let x = knobAt(o, value)
  @[quad(mrect(x, o.rect.y, float(KnobPieceWidth), o.rect.h),
         mrect(KnobSpriteX, KnobSpriteTop + band, float(KnobPieceWidth),
               KnobSpriteStride)),
    quad(mrect(x + float(KnobPieceWidth), o.rect.y, float(KnobPieceWidth),
               o.rect.h),
         mrect(KnobSpriteRight, KnobSpriteTop + band, float(KnobPieceWidth),
               KnobSpriteStride))]

## What a row's label is made of. Answers *keys* wherever the game has one and
## the number itself where it has not, so the caller translates what came back
## and gets the number through unchanged - a number is never a key anybody's
## language file answers.
proc shownValue*(o: Option; value: int): Shown =
  result = Shown(pattern: KeyGenericValue, valueKey: "", valueText: "",
                 valuePattern: "")
  if o.style == NoValue: return result
  if value <= o.lo and o.minKey.len > 0:
    result.valueKey = o.minKey
    return result
  if value >= o.hi and o.maxKey.len > 0:
    result.valueKey = o.maxKey
    return result
  if o.style == SwitchValue:
    if value != 0: result.valueKey = KeyOn
    else: result.valueKey = KeyOff
    return result
  if o.style == NamedValue:
    let names = valueKeys(o.key)
    if value >= 0 and value < names.len: result.valueKey = names[value]
    else: result.valueText = $value
    return result
  if o.style == ScaleValue:
    if value <= 0: result.valueKey = KeyGuiScaleAuto
    else: result.valueText = $value
    return result
  if o.style == PercentValue:
    result.pattern = KeyPercentValue
    result.valueText = $value
    return result
  result.valueText = $value
  result.valuePattern = o.pattern

# ---------------------------------------------------------------------------
# The two this mod owns outright
#
# Both were here before the table was and both stay, because both are read by
# `main.nim` on a path that has no `Option` in it - the scale at boot, the cap
# at boot - and a rule used in two places belongs in one.

proc nextScale*(setting, maxScale: int): int =
  let n = setting + 1
  if n > maxScale: 0 else: n

proc scaleValue*(setting: int): string =
  if setting <= 0: KeyGuiScaleAuto else: $setting

const
  FrameCapMin* = 10
  FrameCapMax* = 260
    ## The top of Minecraft's own `framerateLimit` slider, which the game draws
    ## as *Unlimited* rather than as two hundred and sixty frames.
  FrameCapStep* = 10

## What the host is told, which is not what the slider holds: the top of the
## slider means *no cap*, and the host's word for no cap is zero.
proc frameCapFor*(setting: int): int =
  if setting >= FrameCapMax: 0 else: setting

## And back, so a stored zero lands on the top of the slider rather than below
## its bottom.
proc frameCapSetting*(cap: int): int =
  if cap <= 0: FrameCapMax
  elif cap < FrameCapMin: FrameCapMin
  elif cap > FrameCapMax: FrameCapMax
  else: cap

# ---------------------------------------------------------------------------
# Sound
#
# Every row of the sound screen is one bus on the mixer, and the bus's name is
# the tail of the row's own translation key: `soundCategory.block` is the
# `block` bus. A rule rather than a second table on purpose - a modpack that
# publishes a tenth category gets a row and a bus without either list being
# edited - and the test asserts the rule against every row the screen has.

const SoundMark* = "soundCategory."

proc busOf*(key: string): string =
  ## The word after the last dot, or the empty string when there is none.
  var cut = -1
  var i = 0
  while i < key.len:
    if key[i] == '.': cut = i
    inc i
  if cut < 0: return ""
  result = ""
  i = cut + 1
  while i < key.len:
    result.add key[i]
    inc i

proc isSoundRow*(key: string): bool =
  if key.len <= SoundMark.len: return false
  var i = 0
  while i < SoundMark.len:
    if key[i] != SoundMark[i]: return false
    inc i
  true

# ---------------------------------------------------------------------------
# The language screen
#
# `LanguageSelectScreen` is a list of languages between 32 and `height - 65`,
# rows 18 tall, with a warning line above two 150-wide buttons:
#
#     forceUnicode (width / 2 - 155,       height - 38, 150, 20)
#     done         (width / 2 - 155 + 160, height - 38, 150, 20)
#     warning      centred at (width / 2, height - 56)
#     title        centred at (width / 2, 16)

const
  LangListTop* = 32
  LangListBottom* = 65
    ## `height - 65`.
  LangRowHeight* = 18
  LangFooter* = 38
    ## `height - 38`.
  LangWarning* = 56
    ## `height - 56`.
  LangTitleTop* = 16
  KeyLanguageWarning* = "options.languageWarning"
  KeyForceUnicode* = "options.forceUnicodeFont"

proc langDoneRect*(guiW, guiH: int): MRect =
  mrect(float(guiW div 2 - GridLeft + ColumnStep), float(guiH - LangFooter),
        float(RowWidth), float(RowHeight))

proc langUnicodeRect*(guiW, guiH: int): MRect =
  mrect(float(guiW div 2 - GridLeft), float(guiH - LangFooter),
        float(RowWidth), float(RowHeight))
