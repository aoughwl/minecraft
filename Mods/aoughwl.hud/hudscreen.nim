## The HUD on the screen, and the inventory screen behind it - drawn out of the
## player's own copy of Minecraft when they have one, and out of our own art
## when they have not.
##
## Everything here is drawing and pointing. The arithmetic is `hudcore` and
## `hudrecipe` for what a slot *means*, and `aoughwl.mcui`'s `mcuihud` for
## where a slot *is*; none of the three is repeated here. A click asks this file
## where the pointer was and asks those three what that means, so the rules stay
## in the files a test can reach.
##
## ## Why the layout is not in this file
##
## It used to be, and that is what was wrong with it. This file had a `Cell` of
## 40 pixels and a `Gap` of 2, laid a nine-cell strip out to 376 across, and
## then put the hunger bar at `left + 376 - 200 + 2` - which is 178 along a row
## that is itself 200 wide, so the health and the hunger overlapped by twenty-two
## pixels at every window size the game has ever been run at. Every number in
## that sentence was a number somebody chose, and there was nowhere a test could
## have caught any of them.
##
## Minecraft chooses none of them. The whole bottom strip is laid out against
## **the hotbar sprite**, which is 182 by 22 and is one file in the jar: the
## hearts start at its left edge, the hunger ends at its right edge, and the gap
## between them is what 182 leaves after two rows of ten. `mcuihud` is that
## arithmetic, it calls no host, and `Tests/mcui_test.exe` asserts the two rows
## are disjoint over every window size and every scale the integer GUI-scale
## loop can choose - with a control that reproduces the arithmetic above and
## requires it to collide.
##
## ## Two skins, one layout
##
## `aoughwl.minecraft` publishes the interface out of the granted jar under
## `published:aoughwl.minecraft/<name>` and answers `minecraft.gui sizes`
## with how big each one is in the pixels the game lays out in. When a name is
## there it is drawn; when it is not, the same rectangle is filled with our own
## art. The **layout does not change** between the two, which is the point: a
## player who installs Minecraft later sees the same screen with better pictures
## on it, not a different screen. `mcuigrant` says which of the six reasons a
## missing Minecraft is and the inventory screen prints its first line, so a
## player with none gets our skin and a sentence rather than a broken screen.
##
## Nothing Mojang made is in this repository. Every pixel here is either ours or
## the player's own.
##
## ## What a frame may not do
##
## Ask the importer anything. The sizes, the reason and the player's language
## file arrive over the `minecraft.gui` service, and the language file is the
## whole of `en_us.json` - 519 KB in the 26.2 jar - handed across as one string.
## `mcuilang.parseTable` costs about fifteen microseconds a character in the
## interpreter, so reading it is a load cost of hundreds of milliseconds and up,
## and it used to be paid inside `drawGui()`: `measure()` asked, `drawHud()`
## measures, and a player boot logged `aoughwl.hud spent 255ms in one
## drawGui()`. `warmSkin()` does the asking from `update()` now, and the rule
## this file keeps is **0 service calls inside drawGui()** - a number
## `CLAIMS.tsv` checks by running the mod and counting them, because it was 21
## before and no test could see it.
##
## ## The input
##
## `aoughwl.ui`'s drag and drop machine rather than one of this mod's own.
## Two things a Minecraft inventory does that a Tarkov one does not, and both
## are why this is not `gridview`:
##
## - **the hand outlives the frame.** Minecraft picks a stack up on one click
##   and puts it down on another, with the stack riding the pointer in between.
##   That is not a drag, so it cannot be `ui`'s payload; it is `Hud.carried`,
##   and a slot asks `touch()` rather than `drag()` while it is full.
## - **a drag is still a drag.** With an empty hand a press that moves is an
##   ordinary drag between two slots, payload and all, and `ui` does the whole
##   of it. Both gestures work, and neither is a special case of the other.

import jester
import vec
import color
import input
import textures
import services
import aoughwl_ui/ui
import aoughwl_mcui/mcuicore
import aoughwl_mcui/mcuiscale
import aoughwl_mcui/mcuihud
import aoughwl_mcui/mcuigrant
import aoughwl_mcui/mcuilang
import hudcore
import hudrecipe

const
  StatusSheet = "hud.png"
    ## Our own art, one row of cells, used wherever the player's own copy has
    ## not answered for that piece.
  ItemSheet = "items.png"
  SlotTag* = "hud.slot"
    ## The kind every carry in this inventory has.

  HeartFull = 0
  HeartEmpty = 1
  HaunchFull = 2
  HaunchEmpty = 3
  ShieldFull = 4
  ShieldEmpty = 5

  Provider = "aoughwl.minecraft"
    ## Who publishes the interface. Named once; nothing branches on it.
  GuiService = "minecraft.gui"

  # The published names. They are the resource paths the pictures have in the
  # jar, because that is what `publishPicture` was handed, so a name here is a
  # thing somebody can go and look at on their own disk.
  HotbarSprite = "gui/sprites/hud/hotbar"
  SelectSprite = "gui/sprites/hud/hotbar_selection"
  BarBackSprite = "gui/sprites/hud/experience_bar_background"
  BarFillSprite = "gui/sprites/hud/experience_bar_progress"
  HeartFullSprite = "gui/sprites/hud/heart/full"
  HeartHalfSprite = "gui/sprites/hud/heart/half"
  HeartBackSprite = "gui/sprites/hud/heart/container"
  FoodFullSprite = "gui/sprites/hud/food_full"
  FoodHalfSprite = "gui/sprites/hud/food_half"
  FoodBackSprite = "gui/sprites/hud/food_empty"
  ArmourFullSprite = "gui/sprites/hud/armor_full"
  ArmourHalfSprite = "gui/sprites/hud/armor_half"
  ArmourBackSprite = "gui/sprites/hud/armor_empty"
  SlotSprite = "gui/sprites/container/slot"
  SlotHotSprite = "gui/sprites/container/slot_highlight_front"
  InventorySheet = "gui/container/inventory"
  BenchSheet = "gui/container/crafting_table"

  # The keys. Every word this screen says that Minecraft has a word for comes
  # out of the player's own language file under the key the game uses, so a
  # player running the game in German reads German.
  KeyInventory = "container.inventory"
  KeyCrafting = "container.crafting"
  KeyHead = "container.inventory"
  KeyDeath = "deathScreen.title"
  KeyRespawn = "deathScreen.respawn"

var
  dragFrom = -1
    ## Which slot a live drag started in, or -1. It is a `var` and not part of
    ## `Hud` because it is a fact about the pointer rather than about the
    ## player, and it dies with the drag.
  saidLast = ""

  art = placeholderArt()
    ## The sprite sizes this screen lays out in. Our own until the importer has
    ## answered, and the player's own afterwards.
  skinned = false
    ## Whether the importer has **answered** yet this session - not whether it
    ## has been asked. Those were the same flag and that was a bug: the first
    ## frame set it before asking, the importer had not read the jar yet, and
    ## the empty answer it gave on that frame was what this screen wore for the
    ## rest of the session.
  worded = false
    ## Whether the language table has been read. Separate from `skinned`
    ## because it costs a thousand times more and is needed a thousand times
    ## less: the sizes are wanted on every frame the HUD draws, the words only
    ## on a screen with a word on it.
  langCode = "en_us"
  askAgainAt = 0.0
    ## When it is worth asking again. Asking costs a service call, which re-
    ## enters the provider's own `answer()` - measured at about 1.2 ms, which is
    ## a tenth of a frame and far too much to spend once a frame on a machine
    ## that has no Minecraft on it and never will. Once a second instead: the
    ## thing being waited for is a person installing a game or an importer
    ## finishing a jar, and neither of those happens between two frames.
  scale = 1
  guiW = 0
  guiH = 0
  words = noLang()
  notice = parseNotice("")

## What the HUD last had to say - a refusal, or what was crafted.
proc said*(): string = saidLast
proc say*(words0: string) = saidLast = words0

## Ask the importer again next time round. Called when an import finishes.
proc forgetSkin*() =
  skinned = false
  worded = false
  askAgainAt = 0.0

# ---------------------------------------------------------------------------
# The skin, and the scale
# ---------------------------------------------------------------------------

## Whether the player's own copy answered for that picture. One host call and no
## branch on a version, a folder name or a pack: the question is whether the
## picture is there, which is the only question with an answer that cannot rot.
proc worn(name: string): bool = hasPicture(Provider, name)

## Ask the importer for the sizes, the language and the reason, once.
##
## ## Why this is not called from a draw
##
## It used to be. `measure()` called it, `drawHud()` calls `measure()`, and
## `drawHud()` is `drawGui()` - so the whole of this ran inside a frame.
##
## The expensive line is the last one. `lang <code>` hands the player's entire
## language file across the service seam as one string: `en_us.json` in the
## 26.2 jar is 519 KB, and `parseTable` costs about **fifteen microseconds a
## character** in the interpreter - measured, 658 ms for 43 KB and 2702 ms for
## 176 KB, linear in between. A table of any real size is therefore hundreds of
## milliseconds to seconds, and the frame it lands in is a window that does not
## repaint. That is a load cost and it belongs in `update()`, which is where
## `warmSkin()` is called from and where it stays.
##
## ## Why it is not latched until the importer answers
##
## The old flag was set *before* asking. On the first frame the importer has
## usually not opened the jar yet - it is still `importing` - so it answered
## with nothing, the flag stayed set, and `forgetSkin()` was called by nobody.
## The result was a HUD permanently wearing our own art on a machine with a
## perfectly good Minecraft on it. Now the state word decides: while the
## importer is still working this costs one service call a frame and nothing
## else, and the sizes and the words are read once, when there are some.
proc warmSkin*() =
  if skinned: return
  let now = gameTime()
  if now < askAgainAt: return
  askAgainAt = now + 1.0
  if not serves(GuiService): return
  notice = parseNotice(callService(GuiService, "notice"))
  if notice.state != GrantReady and notice.state != PackMismatch:
    # Nothing to read yet - nothing granted, no Minecraft in what was, or it is
    # still being read. One `notice` a frame until there is, which is what makes
    # a HUD that started before the importer finished wear the skin afterwards
    # instead of wearing our own art for the rest of the session.
    return
  skinned = true
  art = artFrom(callService(GuiService, "sizes"))
  langCode = languageFrom(callService(GuiService, "language"))

## The player's own words, read the first time this screen has one to say.
##
## Kept apart from `warmSkin` because of what it costs. `lang <code>` hands the
## whole language file across the seam - `en_us.json` is 519 KB in the 26.2 jar
## - and `parseTable` measures at about **fifteen microseconds a character** in
## the interpreter, so this is hundreds of milliseconds to seconds, once.
##
## Four keys come out of it: the two container titles and the two lines on the
## death screen. Nothing else this mod draws is a word, so nothing else has to
## wait for it - which is why the boot does not, and why a player who never
## opens their inventory and never dies never pays at all. When they do, the
## cost lands on the frame they pressed E, which is a frame they were already
## expecting to change.
##
## Reading the file to answer four questions is still the wrong shape. The fix
## for that is not here: it is a narrower verb on `minecraft.gui`, so that a mod
## wanting four words asks for four words. Until there is one, this is where the
## cost is least badly placed.
proc warmWords*() =
  if worded: return
  if not skinned: return
  if not serves(GuiService): return
  worded = true
  var table = callService(GuiService, "lang " & langCode)
  if table.len == 0: table = callService(GuiService, "lang en_us")
  words = parseTable(table)

## Whether the importer has answered and this screen is wearing what it said.
proc skinWarm*(): bool = skinned

## The one line to put on the inventory screen when there is no Minecraft here.
## `mcuigrant` owns the six reasons and their six disjoint sentences; this file
## adds none of its own, which is why there is no seventh.
proc reason*(): string =
  if settled(notice): return ""
  let lines = noticeLines(notice)
  if lines.len == 0: return ""
  lines[0]

## Whichever word the player's own language file has for that key, and the key
## itself when it has not - which is what Minecraft shows too, and is a great
## deal more useful than a blank.
proc tr(key: string): string = translate(words, key)

## Refresh the scale from the window. Minecraft's own loop, in `mcuiscale`, so
## the interface is a whole number of screen pixels per interface pixel and the
## art lands on pixel boundaries instead of shimmering.
proc measure() =
  let area = screenArea()
  let w = int(area.width)
  let h = int(area.height)
  scale = guiScale(w, h)
  guiW = guiWidth(w, scale)
  guiH = guiHeight(h, scale)

## An interface rectangle as a screen rectangle. The only place the two spaces
## meet, and it is a multiplication by a whole number.
proc onScreen(r: MRect): Rect =
  rect(r.x * float64(scale), r.y * float64(scale),
       r.w * float64(scale), r.h * float64(scale))

# ---------------------------------------------------------------------------
# Pictures
# ---------------------------------------------------------------------------

## One cell of our own status sheet, `portion` of it wide. A half heart is the
## left half of a full one drawn over an empty one; a half haunch is the right
## half, because that is the side Minecraft leaves.
proc paintStatus(box: Rect; cell: int; portion = 1.0; fromRight = false) =
  let w = iconWindow(cell)
  if portion >= 1.0:
    paintImage(StatusSheet, box, White, w.u0, w.v0, w.u1, w.v1)
    return
  if portion <= 0.0: return
  let span = w.u1 - w.u0
  if fromRight:
    paintImage(StatusSheet,
      rect(box.x + box.width * (1.0 - portion), box.y,
        box.width * portion, box.height), White,
      w.u1 - span * portion, w.v0, w.u1, w.v1)
  else:
    paintImage(StatusSheet,
      rect(box.x, box.y, box.width * portion, box.height), White,
      w.u0, w.v0, w.u0 + span * portion, w.v1)

## A whole published sprite into an interface rectangle. Each of these is its
## own file in the modern jar, so the whole picture goes in the whole rectangle
## and there is no window to work out.
proc paintSprite(name: string; at: MRect) =
  if not worn(name): return
  paintImage(pictureUri(Provider, name), onScreen(at), White)

## Part of a published sheet. `u`/`v` and `w`/`h` are in the sheet's own nominal
## pixels; the fractions are the same whatever resolution the player's pack is,
## which is the whole reason a source rectangle is spelled this way.
proc paintSheet(name: string; at: MRect; u, v, w, h: float) =
  if not worn(name): return
  let sw = float(art.sheetW)
  let sh = float(art.sheetH)
  if sw <= 0.0 or sh <= 0.0: return
  paintImage(pictureUri(Provider, name), onScreen(at), White,
    u / sw, v / sh, (u + w) / sw, (v + h) / sh)

## One item, as a picture when something published one for it and as a swatch of
## its own colour when nothing did.
##
## Three cases and they are tried in that order. A `published:` uri in the item's
## icon facet is somebody else's picture and is drawn whole - that is how an
## imported Minecraft item gets its own texture, and how a block gets a face.
## A digit names a cell of this mod's own sheet. Anything else is a colour.
## Whether an icon names somebody else's published picture rather than a cell of
## our own sheet or a colour. `published:<mod>/<name>` is the only uri a mod may
## hand another mod, so the prefix is the whole test.
proc publishedUri(icon: string): bool =
  const Head = "published:"
  if icon.len <= Head.len: return false
  var i = 0
  while i < Head.len:
    if icon[i] != Head[i]: return false
    inc i
  true

proc paintItem*(box: Rect; reg: Registry; item: string) =
  if item.len == 0: return
  let d = definitionOf(reg, item)
  if publishedUri(d.icon):
    paintImage(d.icon, box, White)
    return
  let cell = iconCell(d.icon)
  if cell >= 0:
    let w = iconWindow(cell)
    paintImage(ItemSheet, box, White, w.u0, w.v0, w.u1, w.v1)
    return
  let c = iconColour(item, d.icon)
  let face = rgb(c.r, c.g, c.b, 1.0)
  paint(box.inset(1.0), face)
  paint(rect(box.x + 1.0, box.y + 1.0, box.width - 2.0, box.height * 0.2),
    face.dimmed(1.35).withAlpha(1.0))
  border(box.inset(1.0), 1.0, Black.withAlpha(0.5))

## One stack: its picture, and how many of it there are.
##
## The number is drawn in the host's font and not Minecraft's. Minecraft's own
## glyphs are `mcui`'s, they need the font sheet's 256 column measurements and a
## run of quads a glyph, and none of that is here yet - so this is honestly the
## host's font over Minecraft's art rather than a claim to be the game's.
proc paintStack*(box: Rect; reg: Registry; s: ItemStack) =
  if isEmpty(s): return
  paintItem(box, reg, s.item)
  if s.count <= 1: return
  let size = box.height * 0.42
  let at = rect(box.x, box.y + box.height - size - 1.0, box.width - 1.0, size)
  # Written twice, a pixel apart, because a white number over a bright icon is
  # unreadable - which is what Minecraft's own one-pixel drop shadow is for.
  paint($s.count, rect(at.x + float64(scale), at.y + float64(scale), at.width,
    at.height), size, AlignRight, Black.withAlpha(0.85))
  paint($s.count, at, size, AlignRight, White)

# ---------------------------------------------------------------------------
# The bars along the bottom
# ---------------------------------------------------------------------------

## A row of ten, each either whole, half or empty, into rectangles somebody else
## worked out. The row does not know which end it started at - that is the whole
## point of it not knowing, because the bug this replaced was two rows that both
## thought they started at the left.
proc paintRow(boxes: seq[MRect]; points: int; full, half, back: string;
    ourFull, ourEmpty: int; fromRight: bool) =
  var i = 0
  while i < boxes.len:
    let box = onScreen(boxes[i])
    let left = points - i * 2
    if worn(back):
      paintSprite(back, boxes[i])
      if left >= 2: paintSprite(full, boxes[i])
      elif left == 1:
        if worn(half): paintSprite(half, boxes[i])
        else: paintSprite(full, boxes[i])
    else:
      paintStatus(box, ourEmpty)
      if left >= 2: paintStatus(box, ourFull, 1.0, fromRight)
      elif left == 1: paintStatus(box, ourFull, 0.5, fromRight)
    i = i + 1

## The whole of the always-on HUD: hotbar, hearts, haunches, armour, and the
## experience bar with its level over it. Every rectangle comes from `mcuihud`
## and every one of them is anchored to the hotbar.
proc drawHud*(h: var Hud; reg: Registry) =
  measure()
  let hotbar = hotbarRect(art, guiW, guiH)

  # The experience bar, over the hotbar, exactly as wide as it.
  let bar = barRect(art, hotbar)
  let filled = levelProgress(h.life.experience)
  if worn(BarBackSprite):
    paintSprite(BarBackSprite, bar)
    if filled > 0.0:
      # The fill is the left of the same-sized sprite, cut where the level is.
      # A whole number of interface pixels, which is what the game does: a bar
      # that slid by a fraction of a pixel would shimmer against the frame.
      let run = float(int(float(art.barW) * filled))
      if run > 0.0 and worn(BarFillSprite):
        paintImage(pictureUri(Provider, BarFillSprite),
          onScreen(mrect(bar.x, bar.y, run, bar.h)), White,
          0.0, 0.0, run / float(art.barW), 1.0)
  else:
    paint(onScreen(bar), rgb(0.05, 0.06, 0.08, 0.85))
    if filled > 0.0:
      paint(onScreen(mrect(bar.x, bar.y, bar.w * filled, bar.h)),
        rgb(0.44, 0.85, 0.26, 1.0))
    border(onScreen(bar), 1.0, rgb(0.0, 0.0, 0.0, 0.6))

  let level = levelOf(h.life.experience)
  if level > 0:
    let size = float64(art.iconH * scale)
    let over = onScreen(mrect(bar.x, bar.y - float(art.iconH), bar.w, size))
    paint($level, rect(over.x + float64(scale), over.y + float64(scale),
      over.width, over.height), size, AlignCentre, Black.withAlpha(0.85))
    paint($level, over, size, AlignCentre, rgb(0.52, 0.95, 0.32, 1.0))

  # Health on the left of the hotbar, hunger on the right of it, armour over
  # the health. Mirrored about the hotbar's middle, which is why they cannot
  # meet however wide the window is.
  paintRow(heartsRow(art, hotbar), h.life.health, HeartFullSprite,
    HeartHalfSprite, HeartBackSprite, HeartFull, HeartEmpty, false)
  paintRow(hungerRow(art, hotbar), h.life.hunger, FoodFullSprite,
    FoodHalfSprite, FoodBackSprite, HaunchFull, HaunchEmpty, true)
  if h.life.armour > 0:
    paintRow(armourRow(art, hotbar), h.life.armour, ArmourFullSprite,
      ArmourHalfSprite, ArmourBackSprite, ShieldFull, ShieldEmpty, false)

  # The hotbar itself: one sprite, nine items in it, and the highlight over the
  # selected cell hanging a pixel off each side of it.
  if worn(HotbarSprite):
    paintSprite(HotbarSprite, hotbar)
  else:
    paint(onScreen(hotbar), rgb(0.08, 0.09, 0.12, 0.72))
    border(onScreen(hotbar), 1.0, rgb(1.0, 1.0, 1.0, 0.22))
  var i = 0
  while i < HotbarSlots:
    if i == h.selected:
      let sel = selectionRect(art, hotbar, i)
      if worn(SelectSprite): paintSprite(SelectSprite, sel)
      else: border(onScreen(sel), float64(scale), White.withAlpha(0.92))
    paintStack(onScreen(hotbarItemRect(art, hotbar, i)), reg, h.inv.at(i))
    i = i + 1

  # What is held, named over the hotbar for a moment after it changes.
  let holding = held(h)
  let lineH = float64(art.iconH * scale)
  if not isEmpty(holding):
    let d = definitionOf(reg, holding.item)
    let over = onScreen(mrect(hotbar.x, statusRowY(art, hotbar, 2), hotbar.w,
      float(art.iconH)))
    paint(d.display, over, lineH, AlignCentre, White.withAlpha(0.75))

  if saidLast.len > 0:
    let over = onScreen(mrect(hotbar.x, statusRowY(art, hotbar, 3), hotbar.w,
      float(art.iconH)))
    paint(saidLast, over, lineH, AlignCentre, rgb(1.0, 0.82, 0.35, 0.95))

  if h.life.dead:
    let area = screenArea()
    paint(area, rgb(0.45, 0.03, 0.03, 0.45))
    paint(tr(KeyDeath), rect(area.x, area.height * 0.34, area.width, 40.0),
      38.0, AlignCentre, White)
    paint(tr(KeyRespawn),
      rect(area.x, area.height * 0.34 + 46.0, area.width, 22.0), 18.0,
      AlignCentre, White.withAlpha(0.85))

# ---------------------------------------------------------------------------
# The inventory screen
# ---------------------------------------------------------------------------

proc countIn(h: Hud; slot: int): int64 =
  int64(stackAtWide(h, slot).count)

## One slot, drawn and worked, in an interface rectangle. This is the whole of
## the input: a click with an empty hand takes, a click with a full hand puts,
## the right button halves and places one, and a press that moves is a drag
## `ui` carries for us.
##
## The rectangle it is hit-tested in is the rectangle it was drawn in, and there
## is no second copy of the arithmetic anywhere: `mcuihud` answered with it and
## both the picture and the pointer use that answer.
proc slotWidget(name: string; at: MRect; slot: int; h: var Hud;
    reg: Registry; recipes: seq[Recipe]) =
  let box = onScreen(at)
  # The sheet already has a slot drawn in it wherever the game puts one, so the
  # slot sprite goes down only when there is no sheet to have drawn it.
  if not worn(InventorySheet):
    if worn(SlotSprite): paintSprite(SlotSprite, at)
    else:
      paint(box, rgb(0.55, 0.55, 0.58, 0.30))
      border(box, 1.0, rgb(1.0, 1.0, 1.0, 0.18))

  let here = stackAtWide(h, slot)
  let inner = onScreen(mrect(at.x + float(SlotBorder), at.y + float(SlotBorder),
    float(itemSize(art)), float(itemSize(art))))

  let zone = dropZone(name, box, SlotTag)
  if zone.over or over(box):
    # Minecraft's own hover: a white wash over the whole 18 by 18, not a border.
    if worn(SlotHotSprite): paintSprite(SlotHotSprite, at)
    else: paint(box, White.withAlpha(0.35))

  if isEmpty(h.carried):
    let load = carry(SlotTag, $slot, countIn(h, slot))
    let d = drag(name, box, load)
    if d.dragging and dragFrom != slot and not isEmpty(here): dragFrom = slot
    if d.clicked:
      if slot >= FirstBenchSlot: clickBench(h, reg, slot - FirstBenchSlot, recipes)
      else: clickAt(h, reg, slot)
  else:
    let t = touch(name, box)
    if t.clicked:
      if slot >= FirstBenchSlot: clickBench(h, reg, slot - FirstBenchSlot, recipes)
      else: clickAt(h, reg, slot)

  # The right button is not part of `ui`'s state machine, which knows one
  # button, so it is asked of the host and gated on the clip-aware hit test.
  if over(box) and clicked(RightButton):
    if slot >= FirstBenchSlot:
      clickBench(h, reg, slot - FirstBenchSlot, recipes, true)
    else:
      clickAt(h, reg, slot, true)

  if not (isEmpty(h.carried) and dragFrom == slot and carrying(SlotTag)):
    paintStack(inner, reg, stackAtWide(h, slot))

  if zone.dropped and dragFrom >= 0 and dragFrom != slot:
    if not dragSlot(h, reg, dragFrom, slot, recipes):
      say("that does not go there")
    else:
      say("")

## The result of a recipe. It is not a slot: nothing may be put in it, and
## taking it out of it spends the bench.
proc resultWidget(at: MRect; h: var Hud; reg: Registry; recipes: seq[Recipe]) =
  let box = onScreen(at)
  if not worn(InventorySheet):
    if worn(SlotSprite): paintSprite(SlotSprite, at)
    else:
      paint(box, rgb(0.55, 0.55, 0.58, 0.30))
      border(box, 1.0, rgb(1.0, 1.0, 1.0, 0.18))
  paintStack(onScreen(mrect(at.x + float(SlotBorder), at.y + float(SlotBorder),
    float(itemSize(art)), float(itemSize(art)))), reg, h.bench.made)
  let t = touch("result", box)
  if t.hot and not isEmpty(h.bench.made):
    if worn(SlotHotSprite): paintSprite(SlotHotSprite, at)
    else: paint(box, White.withAlpha(0.35))
  if t.clicked and not isEmpty(h.bench.made):
    let name0 = definitionOf(reg, h.bench.made.item).display
    if takeMade(h, reg, recipes): say("made " & name0)
    else: say("no room for " & name0)

proc runOfSlots(name: string; boxes: seq[MRect]; first: int; h: var Hud;
    reg: Registry; recipes: seq[Recipe]) =
  var i = 0
  while i < boxes.len:
    slotWidget(name & $i, boxes[i], first + i, h, reg, recipes)
    i = i + 1

## The inventory screen: the panel out of the player's own sheet, the armour
## down its left, the crafting grid with its result, the main grid and the
## hotbar, with the hand drawn over all of it.
proc drawInventory*(h: var Hud; reg: Registry; recipes: seq[Recipe]) =
  measure()
  let s = screenArea()
  paint(s, rgb(0.0, 0.0, 0.0, 0.55))

  let bench = h.bench.wide >= 3 or h.bench.tall >= 3
  let panel = panelRect(art, guiW, guiH)
  let sheet = if bench: BenchSheet else: InventorySheet
  if worn(sheet):
    paintSheet(sheet, panel, 0.0, 0.0, float(art.panelW), float(art.panelH))
  else:
    panel(onScreen(panel))
  pushId("hudinv")

  # The title, in the player's own language under the game's own key.
  let title = if bench: tr(KeyCrafting) else: tr(KeyInventory)
  let head = onScreen(mrect(panel.x + float(MainOriginX),
    panel.y + float(ArmourOriginY) - float(art.iconH) + 3.0,
    panel.w, float(art.iconH)))
  paint(title, head, float64(art.iconH * scale), AlignLeft,
    rgb(0.25, 0.25, 0.25, 1.0))

  runOfSlots("armour", armourColumn(art, panel), FirstArmour, h, reg, recipes)
  runOfSlots("bench", craftGrid(art, panel, h.bench.wide, h.bench.tall),
    FirstBenchSlot, h, reg, recipes)
  resultWidget(craftResult(art, panel, h.bench.wide, h.bench.tall), h, reg,
    recipes)
  runOfSlots("main", mainGrid(art, panel), FirstMain, h, reg, recipes)
  runOfSlots("hot", quickRow(art, panel), 0, h, reg, recipes)

  # One line under the panel. A refusal if there was one, otherwise the reason
  # this screen is wearing our own art if it is, otherwise nothing - there is
  # nothing useful to say about a screen that is working.
  var footer = saidLast
  if footer.len == 0: footer = reason()
  if footer.len > 0:
    hint(onScreen(mrect(panel.x, panel.bottom + 2.0, panel.w,
      float(art.iconH))), footer)

  popId()

## Whatever is riding the pointer, over everything else. Called last, after
## every panel, because it has to be on top of all of them.
proc drawHand*(h: Hud; reg: Registry) =
  let side = float64(itemSize(art) * scale)
  if carrying(SlotTag):
    paintStack(ghostRect(), reg, stackAtWide(h, dragFrom))
    return
  if isEmpty(h.carried): return
  let at = pointerAt()
  paintStack(rect(at.x - side * 0.5, at.y - side * 0.5, side, side), reg,
    h.carried)

## Forget the drag once it is over, whether or not anything caught it. Called
## once a frame, after the screen.
proc settleHudDrag*() =
  if landing().happened: dragFrom = -1

# ---------------------------------------------------------------------------
# The layout, at the size the game is actually running at
# ---------------------------------------------------------------------------

## `Tests/mcui_test.exe` proves this arithmetic over a sweep of two thousand
## window sizes with no host anywhere in sight, and that is the stronger of the
## two statements. This is the other one, and it is the one a pure test cannot
## make: that the size the *running game* handed it is one of those sizes, and
## that the rectangles a person is looking at right now are the rectangles the
## arithmetic said they would be.
##
## It costs one frame and runs when the screen opens, so a headless play script
## can open the inventory and read the answer out of the log rather than out of
## a photograph of some slots.
proc proveLayout*() =
  measure()
  let hotbar = hotbarRect(art, guiW, guiH)
  let hearts = rowExtent(heartsRow(art, hotbar))
  let hunger = rowExtent(hungerRow(art, hotbar))
  let panel = panelRect(art, guiW, guiH)
  let main = mainGrid(art, panel)
  var ok = true
  # The reported bug, asserted at this window: the two bars do not meet, and
  # each is anchored to its own end of the hotbar rather than to the screen.
  if overlaps(hearts, hunger): ok = false
  if hearts.x != hotbar.x: ok = false
  if hunger.right != hotbar.right: ok = false
  if hunger.x <= hearts.right: ok = false
  # Every slot is inside the panel, and the middle of the first one hits the
  # first one - the hit test and the drawing are the same rectangle.
  if not within(main, panel): ok = false
  if main.len != MainSlots: ok = false
  if main.len > 0:
    let b = main[0]
    if slotAt(main, b.x + b.w * 0.5, b.y + b.h * 0.5) != 0: ok = false
    if slotAt(main, main[main.len - 1].right, main[0].y) != -1: ok = false
  log("[assert] hud.scale=" & $scale)
  log("[assert] hud.guiwidth=" & $guiW)
  log("[assert] hud.guiheight=" & $guiH)
  log("[assert] hud.hotbarwidth=" & $art.hotbarW)
  log("[assert] hud.barsclear=" & $int(hunger.x - hearts.right))
  log("[assert] hud.slot0x=" & $int(main[0].x - panel.x))
  log("[assert] hud.slot0y=" & $int(main[0].y - panel.y))
  log("[assert] hud.slotpitch=" & $slotPitch(art))
  log("[assert] hud.slots=" & $main.len)
  log("[assert] hud.skin=" & (if art.granted: "minecraft" else: "ours"))
  log("[assert] hud.layout=" & (if ok: "ok" else: "wrong"))
