## Where the hotbar, the bars over it and the inventory panel go, in interface
## pixels, derived from the sprites rather than remembered.
##
## This is the file the complaint *"the health hearts and hunger bar overlap in
## the middle"* is answered in, and it is worth saying why that bug was possible
## at all: the HUD laid its two bars out against **the screen**. One started at
## the left of a 376-pixel row and the other started 178 pixels along it, and
## since each row is 200 pixels wide at that spacing they ran into each other by
## twenty-two. Every number in that sentence is a number somebody chose.
##
## Minecraft chooses none of them. It lays the whole bottom strip out against
## **the hotbar**, which is one sprite of one size:
##
##     int i = width / 2 - 91;              // the hotbar's left edge
##     hearts   at i + m * 8                // left to right
##     hunger   at i + 182 - 9 - m * 8      // right to left
##
## The two rows are mirrored about the hotbar's middle and they cannot meet,
## because ten icons on an 8-pixel stride are 81 wide and 81 + 81 is 162, which
## is twenty short of 182. The gap is a *consequence* of the hotbar's width and
## of nothing else - which is why this module derives from the hotbar's width
## and `Tests/mcui_test.exe` asserts the two rows are disjoint over every window
## size and every scale the integer loop can choose, rather than at 1280x720.
##
## ## What is data and what is structure
##
## Every size here arrives in an `Art`, measured out of the player's own copy by
## `aoughwl.minecraft` and handed over as text. Nothing below writes down a
## sprite's size. What is written down is the *structure* those sizes are
## arranged in, which is the game's code and not any file:
##
## | number | where it comes from |
## | --- | --- |
## | hotbar 182x22, selection 24x23, icon 9x9, slot 18x18 | the sprites |
## | the hotbar holds nine slots | the game |
## | the hotbar sprite has a one-pixel frame | the game |
## | the panel is the top-left 176x166 of a 256x256 sheet | the game's blit |
## | the slot origins inside that panel | the game's menu |
##
## Everything else is arithmetic on those two columns: the cell pitch is what is
## left of the hotbar's width after its frame, divided by nine; the selection
## overhangs by half the difference between its own width and that pitch; an
## item is the slot sprite less its border; a status row is one icon plus a
## pixel. Hand this module a different set of sprite sizes and every rectangle
## moves, and the test does exactly that - which is the only way to show that
## nothing here is a remembered number wearing a derivation.

import mcuicore

const
  HotbarCells*: int = 9
    ## Nine, and it is the game's number rather than the sprite's: a 182-pixel
    ## sprite could be nine cells of twenty or ten of eighteen and the picture
    ## cannot say which.
  HotbarFrame*: int = 1
    ## The hotbar sprite's own outer frame, left and right. With this and the
    ## slot count the cell pitch falls out: (182 - 2) / 9 = 20.
  SlotBorder*: int = 1
    ## The slot sprite's border. An 18x18 slot holds a 16x16 item.
  StatusRowGap*: int = 1
    ## Between one row of status icons and the next, so the stride up the screen
    ## is one icon plus one.
  BarLift*: int = 7
    ## How far the experience bar's top sits above the hotbar's top. This is the
    ## one number in the file that is a taste rather than a consequence -
    ## `height - 32 + 3` against `height - 22` in the game's own code - and it is
    ## Mojang's taste, so it is written here rather than rounded to something
    ## tidier. `mcuiload.BarCentreFraction` is the same kind of number.
  StatusRows*: int = 10
    ## Ten hearts, ten haunches, ten shields. Twenty points at two a piece.

type
  Art* = object
    ## Every sprite size the bottom strip and the inventory need, in the
    ## interface pixels the game lays out in - the **jar's** pixels, not the
    ## resource pack's. A 64x pack's hotbar.png is 728 by 88 and the game still
    ## draws it 182 by 22; taking the size off the pack would move every
    ## rectangle on the screen the moment somebody turned a pack on.
    hotbarW*, hotbarH*: int
    selectW*, selectH*: int
    iconW*, iconH*: int        ## one heart, one haunch, one shield, one bubble
    barW*, barH*: int          ## the experience bar
    slotW*, slotH*: int        ## one container slot
    sheetW*, sheetH*: int      ## the container sheet a panel is cut out of
    panelW*, panelH*: int      ## the part of that sheet a screen is
    granted*: bool
      ## Whether these came out of a Minecraft at all. False means the caller is
      ## drawing our own placeholder art, and it is the same six-state question
      ## `mcuigrant` answers - this field only records which side of it we are
      ## on so that a layout can be asked for either way.

## The sizes to lay out against when there is no Minecraft here.
##
## They are the vanilla integers, and that is not a smuggled copy of Mojang's
## art: it is the grid **our own placeholder art is drawn on**, chosen to be the
## same grid so that a player who installs Minecraft later sees the same screen
## with better pictures on it rather than a different screen. Nothing about
## these numbers is Minecraft's property; the pictures are, and none ship.
proc placeholderArt*(): Art =
  Art(hotbarW: 182, hotbarH: 22, selectW: 24, selectH: 23,
      iconW: 9, iconH: 9, barW: 182, barH: 5, slotW: 18, slotH: 18,
      sheetW: 256, sheetH: 256, panelW: 176, panelH: 166, granted: false)

# ---------------------------------------------------------------------------
# The sizes, as they arrive
#
# `aoughwl.minecraft` answers `minecraft.gui sizes` with one line a
# picture: `<published name><TAB><width><TAB><height>`. It is the same seam the
# font's measurements come over and it exists for the same reason - this mod has
# no PNG reader and must not grow one.

proc fieldsOf(line: string; sep: char): seq[string] =
  result = @[]
  var piece = ""
  var i = 0
  while i <= line.len:
    if i == line.len or line[i] == sep:
      result.add piece
      piece = ""
    else:
      piece.add line[i]
    inc i

proc wholeOf(text: string; fallback: int): int =
  var value = 0
  var digits = 0
  var i = 0
  while i < text.len:
    if text[i] >= '0' and text[i] <= '9':
      value = value * 10 + (int(text[i]) - int('0'))
      inc digits
    else:
      return fallback
    inc i
  if digits == 0: fallback else: value

proc sameName(a, b: string): bool =
  if a.len != b.len: return false
  var i = 0
  while i < a.len:
    if a[i] != b[i]: return false
    inc i
  true

## One picture's size out of the table, or `w`/`h` unchanged when the table does
## not mention it. A missing line is the normal case and not an error: an
## install without a `hotbar.png` simply keeps the placeholder's number, and the
## caller has already decided not to draw that sprite.
proc sizeIn*(table, name: string; w, h: var int) =
  var line = ""
  var i = 0
  while i <= table.len:
    if i == table.len or table[i] == '\n':
      if line.len > 0:
        let f = fieldsOf(line, '\t')
        if f.len >= 3 and sameName(f[0], name):
          w = wholeOf(f[1], w)
          h = wholeOf(f[2], h)
      line = ""
    elif table[i] != '\r':
      line.add table[i]
    inc i

## The whole table, read into an `Art`. Anything the table does not carry keeps
## the placeholder's number, so a half-published install lays out rather than
## collapsing to zero-sized rectangles.
proc artFrom*(table: string): Art =
  result = placeholderArt()
  if table.len == 0: return result
  result.granted = true
  sizeIn(table, "gui/sprites/hud/hotbar", result.hotbarW, result.hotbarH)
  sizeIn(table, "gui/sprites/hud/hotbar_selection", result.selectW,
         result.selectH)
  sizeIn(table, "gui/sprites/hud/heart/full", result.iconW, result.iconH)
  sizeIn(table, "gui/sprites/hud/experience_bar_background", result.barW,
         result.barH)
  sizeIn(table, "gui/sprites/container/slot", result.slotW, result.slotH)
  sizeIn(table, "gui/container/inventory", result.sheetW, result.sheetH)
  result

# ---------------------------------------------------------------------------
# The bottom strip
#
# Everything is measured off one rectangle: the hotbar's. That is the rule the
# overlap bug broke and it is the rule the test asserts, rather than asserting
# that two particular rows happen not to touch at one particular size.

## How wide one hotbar cell is. The frame off each end, the rest split nine
## ways - 20 for the real sprite, and something else for any other.
proc cellPitch*(a: Art): int =
  if HotbarCells <= 0: return 0
  (a.hotbarW - HotbarFrame * 2) div HotbarCells

## How big an item drawn in a slot is: the slot sprite without its border.
proc itemSize*(a: Art): int = a.slotW - SlotBorder * 2

## Where in a cell that item sits, centred.
proc itemInset*(a: Art): int = (cellPitch(a) - itemSize(a)) div 2

## How far the selection sprite hangs over its cell on each side. The real one
## is 24 over a 20, so two - and it is read off the two sizes rather than
## written down, because a pack that redraws the highlight bigger is a pack
## whose highlight must still be centred on the cell.
proc selectOverhang*(a: Art): int = (a.selectW - cellPitch(a)) div 2

## The stride from one row of status icons up to the next.
proc rowStride*(a: Art): int = a.iconH + StatusRowGap

## The hotbar itself, centred on the interface and sitting on its bottom edge.
##
## Integer division on the way in, exactly as the game does it, so an interface
## an odd number of pixels wide puts the spare pixel on the same side the game
## puts it and every rectangle below stays on a whole pixel.
proc hotbarRect*(a: Art; guiW, guiH: int): MRect =
  mrect(float(guiW div 2 - a.hotbarW div 2), float(guiH - a.hotbarH),
        float(a.hotbarW), float(a.hotbarH))

## One cell of the hotbar - the 20 by 22 the frame leaves, not the item in it.
proc cellRect*(a: Art; hotbar: MRect; index: int): MRect =
  mrect(hotbar.x + float(HotbarFrame + index * cellPitch(a)), hotbar.y,
        float(cellPitch(a)), hotbar.h)

## The item in one cell of the hotbar, centred both ways.
proc hotbarItemRect*(a: Art; hotbar: MRect; index: int): MRect =
  let cell = cellRect(a, hotbar, index)
  mrect(cell.x + float(itemInset(a)),
        cell.y + float((a.hotbarH - itemSize(a)) div 2),
        float(itemSize(a)), float(itemSize(a)))

## The selection highlight over one cell: its own size, centred on the cell, so
## it overhangs by the same amount on both sides and by the same amount top and
## bottom as the difference between it and the hotbar allows.
proc selectionRect*(a: Art; hotbar: MRect; index: int): MRect =
  let cell = cellRect(a, hotbar, index)
  mrect(cell.x - float(selectOverhang(a)),
        hotbar.y - float((a.selectH - a.hotbarH) div 2),
        float(a.selectW), float(a.selectH))

## The experience bar: as wide as the hotbar, over it, and starting where it
## starts. Not "as wide as the screen" and not centred separately - the same
## anchor as everything else in the strip.
proc barRect*(a: Art; hotbar: MRect): MRect =
  mrect(hotbar.x, hotbar.y - float(BarLift), float(a.barW), float(a.barH))

## The baseline of one row of status icons, counting up from the experience bar.
## Row 0 is the hearts and the haunches, row 1 the armour above them, row 2
## whatever a caller puts there next.
proc statusRowY*(a: Art; hotbar: MRect; row: int): float =
  barRect(a, hotbar).y - float(rowStride(a) * (row + 1))

## A row of status icons anchored to one end of the hotbar.
##
## `rightward` is the whole of the difference between the two bars and it is one
## argument rather than two procedures on purpose: the failure this file exists
## to prevent is the two rows sharing an origin, and two rows that share a
## procedure cannot share an origin by accident.
##
## Left to right, the first icon is at the hotbar's left edge. Right to left,
## the first icon is the **rightmost** one, its right edge on the hotbar's right
## edge - which is what makes a hunger bar empty from the middle outward the way
## the game's does.
proc statusRow*(a: Art; hotbar: MRect; row: int; rightward: bool;
                count = StatusRows): seq[MRect] =
  result = @[]
  if count <= 0: return result
  let stride = a.iconW - 1
    ## Ten nine-wide icons overlap by a pixel, which is why a row of ten is 81
    ## across and not 90. Taken off the icon rather than written down, so a pack
    ## that redraws a heart wider spreads the row rather than stacking it.
  let y = statusRowY(a, hotbar, row)
  var i = 0
  while i < count:
    var x = hotbar.x + float(i * stride)
    if not rightward:
      x = hotbar.right - float(a.iconW) - float(i * stride)
    result.add mrect(x, y, float(a.iconW), float(a.iconH))
    inc i
  result

proc heartsRow*(a: Art; hotbar: MRect; count = StatusRows): seq[MRect] =
  statusRow(a, hotbar, 0, true, count)

proc hungerRow*(a: Art; hotbar: MRect; count = StatusRows): seq[MRect] =
  statusRow(a, hotbar, 0, false, count)

proc armourRow*(a: Art; hotbar: MRect; count = StatusRows): seq[MRect] =
  statusRow(a, hotbar, 1, true, count)

## The breath bubbles, right to left above the hunger, which is where they go.
proc breathRow*(a: Art; hotbar: MRect; count = StatusRows): seq[MRect] =
  statusRow(a, hotbar, 1, false, count)

## The rectangle a whole row of `count` icons occupies, for the one assertion
## that matters: that two rows do not intersect. Spelled here rather than in the
## test so that the layout and the check on it cannot drift apart.
proc rowExtent*(row: seq[MRect]): MRect =
  if row.len == 0: return mrect(0.0, 0.0, 0.0, 0.0)
  var left = row[0].x
  var right = row[0].right
  var top = row[0].y
  var bottom = row[0].bottom
  var i = 1
  while i < row.len:
    if row[i].x < left: left = row[i].x
    if row[i].right > right: right = row[i].right
    if row[i].y < top: top = row[i].y
    if row[i].bottom > bottom: bottom = row[i].bottom
    inc i
  mrect(left, top, right - left, bottom - top)

## Whether two rectangles share any area at all. Touching edges do not count -
## a bar whose last pixel is the next bar's first pixel is not an overlap.
proc overlaps*(a, b: MRect): bool =
  a.x < b.right and b.x < a.right and a.y < b.bottom and b.y < a.bottom

# ---------------------------------------------------------------------------
# The inventory panel
#
# A container screen is a rectangle blitted out of the top-left corner of a
# 256-pixel sheet, and the slots inside it are at fixed offsets the game's own
# menu classes carry. Those offsets are the game's and are written down; the
# **pitch** between them is not, it is the slot sprite's own size, and neither
# is the size of the item inside one.

const
  ArmourOriginX*: int = 8
  ArmourOriginY*: int = 8
  MainOriginX*: int = 8
  MainOriginY*: int = 84
  QuickOriginY*: int = 142
    ## The hotbar's row inside the panel, which is not `MainOriginY + 3 * 18`:
    ## the game leaves four extra pixels between the last main row and it.
  OffhandX*: int = 77
  OffhandY*: int = 62
  InvCraftX*: int = 98
  InvCraftY*: int = 18
  InvResultX*: int = 154
  InvResultY*: int = 28
  BenchCraftX*: int = 30
  BenchCraftY*: int = 17
  BenchResultX*: int = 124
  BenchResultY*: int = 35
  MainColumns*: int = 9
  MainRows*: int = 3

## Where the panel goes: centred, on whole pixels, the game's own two lines.
proc panelRect*(a: Art; guiW, guiH: int): MRect =
  mrect(float((guiW - a.panelW) div 2), float((guiH - a.panelH) div 2),
        float(a.panelW), float(a.panelH))

## Which part of the container sheet the panel is, as a source rectangle in the
## sheet's own nominal pixels. `mcuisprite` and `mcuinine` both speak in these.
proc panelSource*(a: Art): MRect =
  mrect(0.0, 0.0, float(a.panelW), float(a.panelH))

## One slot's background - the 18 by 18 sprite - given the item's own origin
## inside the panel, which is what the game's menus record. The background sits
## one pixel up and left of the item, which is the border.
proc slotBox*(a: Art; panel: MRect; itemX, itemY: int): MRect =
  mrect(panel.x + float(itemX - SlotBorder), panel.y + float(itemY - SlotBorder),
        float(a.slotW), float(a.slotH))

## The item inside that slot.
proc itemBox*(a: Art; panel: MRect; itemX, itemY: int): MRect =
  mrect(panel.x + float(itemX), panel.y + float(itemY),
        float(itemSize(a)), float(itemSize(a)))

## The pitch from one slot to the next: the slot sprite's own size, so a pack
## that redraws the slot bigger spaces the grid to match.
proc slotPitch*(a: Art): int = a.slotW

## A grid of slot backgrounds, row-major from the top-left, at that origin.
proc slotGrid*(a: Art; panel: MRect; originX, originY, columns,
               rows: int): seq[MRect] =
  result = @[]
  let pitch = slotPitch(a)
  var r = 0
  while r < rows:
    var c = 0
    while c < columns:
      result.add slotBox(a, panel, originX + c * pitch, originY + r * pitch)
      inc c
    inc r
  result

## The three rows of twenty-seven.
proc mainGrid*(a: Art; panel: MRect): seq[MRect] =
  slotGrid(a, panel, MainOriginX, MainOriginY, MainColumns, MainRows)

## The nine along the bottom, which are the same nine the hotbar shows.
proc quickRow*(a: Art; panel: MRect): seq[MRect] =
  slotGrid(a, panel, MainOriginX, QuickOriginY, MainColumns, 1)

## The four down the left, head at the top.
proc armourColumn*(a: Art; panel: MRect): seq[MRect] =
  slotGrid(a, panel, ArmourOriginX, ArmourOriginY, 1, 4)

proc offhandSlot*(a: Art; panel: MRect): MRect =
  slotBox(a, panel, OffhandX, OffhandY)

## The crafting grid. Two by two on the inventory screen and three by three on
## the crafting table's, and they are at different places on different sheets,
## so which screen it is decides both.
proc craftGrid*(a: Art; panel: MRect; wide, tall: int): seq[MRect] =
  if wide >= 3 or tall >= 3:
    return slotGrid(a, panel, BenchCraftX, BenchCraftY, wide, tall)
  slotGrid(a, panel, InvCraftX, InvCraftY, wide, tall)

proc craftResult*(a: Art; panel: MRect; wide, tall: int): MRect =
  if wide >= 3 or tall >= 3:
    return slotBox(a, panel, BenchResultX, BenchResultY)
  slotBox(a, panel, InvResultX, InvResultY)

## Which of those rectangles the pointer is in, or -1. The hit test is the same
## rectangle the slot was drawn in and not a rectangle worked out again, which
## is the only way a slot cannot be clickable somewhere it is not drawn.
proc slotAt*(boxes: seq[MRect]; x, y: float): int =
  result = -1
  var i = 0
  while i < boxes.len:
    if boxes[i].holds(x, y): return i
    inc i
  result

## Whether every rectangle in a list is inside the panel. Nothing branches on
## it; it is the property the test asserts about the game's own origins, which
## is what would catch an origin typed in wrong.
proc within*(boxes: seq[MRect]; panel: MRect): bool =
  var i = 0
  while i < boxes.len:
    let b = boxes[i]
    if b.x < panel.x or b.y < panel.y or b.right > panel.right or
       b.bottom > panel.bottom: return false
    inc i
  true
