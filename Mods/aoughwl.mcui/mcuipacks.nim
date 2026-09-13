## The resource-pack screen: two columns, and which pack is in which.
##
## Minecraft's `GuiScreenResourcePacks` is two lists side by side - Available on
## the left, Selected on the right - with a pack moving between them when you
## click the arrow on its row, and moving up and down within Selected to change
## which one wins. The Selected column is *ordered*, and the order is the whole
## point of the screen: a pack near the top of it overrides a pack below it, key
## by key and file by file, with the jar underneath everything.
##
## `aoughwl.minecraft` already does the layering. It reads `options.txt`'s
##
##     resourcePacks:["vanilla","file/Faithful.zip","file/my folder"]
##
## backwards - Minecraft writes lowest priority first - drops the built-ins, and
## stacks `Imported/packs/<name>` over `Imported/` so that `find` returns the
## first layer that has the file. So the *model* of this screen is not new; what
## is new is letting the player state it instead of `options.txt` stating it.
##
## ## The order in this module
##
## Index 0 of `selected` is the **top** of the Selected column and the **highest
## priority**, which is the order the importer already wants and the reverse of
## the order `options.txt` is written in. `optionsOrder` below is the one place
## that reversal is spelled, so nothing else has to remember which way round it
## is.
##
## ## Compatibility, which this screen exists to show
##
## A pack declares which pack formats it is for. Modern packs declare a range -
## Faithful 64x says 79 to 100 - and a version of Minecraft speaks exactly one:
## the user's 26.2 jar speaks 88 and 1.21.11 speaks 75. So the same Faithful is
## *inside* the range for one install and *below* it for the other, and the
## screen has to say which, in the direction it is wrong in, because "older" and
## "newer" need different things done about them. That is the whole of
## `fitness` below, and it is three states rather than a boolean for exactly
## that reason.
##
## The keys are Minecraft's own: `resourcePack.incompatible`,
## `resourcePack.incompatible.old`, `resourcePack.incompatible.new`. Nothing
## here says a word.

import mcuicore
import mcuilist

const
  PackTitle* = "resourcePack.title"
  PackAvailable* = "resourcePack.available.title"
  PackSelected* = "resourcePack.selected.title"
  PackFolderInfo* = "resourcePack.folderInfo"
  PackIncompatible* = "resourcePack.incompatible"
  PackTooOld* = "resourcePack.incompatible.old"
  PackTooNew* = "resourcePack.incompatible.new"
  PackDone* = "gui.done"

  ColumnWidth* = 200
  ColumnGap* = 4
    ## `width / 2 - 4 - 200` and `width / 2 + 4` - a four-pixel channel either
    ## side of the middle, so eight between the columns.
  ColumnTop* = 32
  ColumnBottomInset* = 51
    ## `GuiResourcePackList` is built with `height - 55 + 4`.
  PackTitleTop* = 16
    ## Both column titles, and there is no single title over the middle: the
    ## screen's own name is only ever seen on the button that opens it.
  FooterInset* = 48
    ## `height - 48`, one row of buttons and not two.
  FooterButtonWidth* = 150
  IconSize* = 32
    ## `pack.png`, when there is one.
  IconGap* = 2
  DescriptionLines* = 2

type
  Fitness* = enum
    PackFits,   ## the version this install speaks is inside the pack's range
    PackOld,    ## the pack was made for an older Minecraft than this one
    PackNew     ## the pack was made for a newer Minecraft than this one

  PackEntry* = object
    ## One pack, as the importer knows it. Every field is the player's own data
    ## and none of it is a word of ours.
    name*: string          ## the folder or archive under `resourcepacks/`
    description*: string   ## whatever its own `pack.mcmeta` says
    lowest*: int           ## `min_format`, or `pack_format` when it says one
    highest*: int          ## `max_format`, or `pack_format`
    icon*: bool            ## whether a `pack.png` came out of it

  PackChoice* = object
    ## The screen's whole state: which packs there are, which are on, in what
    ## order, and where each column is scrolled to.
    packs*: seq[PackEntry]
    selected*: seq[int]    ## indices into `packs`, highest priority first
    available*: seq[int]   ## indices into `packs`, in the order found
    leftScroll*: int
    rightScroll*: int
    leftPick*: int         ## a row of `available`, or -1
    rightPick*: int        ## a row of `selected`, or -1

proc noChoice*(): PackChoice =
  PackChoice(packs: @[], selected: @[], available: @[], leftScroll: 0,
             rightScroll: 0, leftPick: -1, rightPick: -1)

## Which side of the range this install falls on. `format` of zero means the
## install has not said - a jar whose `pack.mcmeta` could not be read - and an
## unknown is not a mismatch, so it fits. That is the same judgement
## `mcgui.fitsPack` makes and the test asserts the two agree.
proc fitness*(e: PackEntry; format: int): Fitness =
  if format <= 0 or e.highest <= 0: return PackFits
  if format > e.highest: return PackOld
  if e.lowest > 0 and format < e.lowest: return PackNew
  PackFits

## The key that says what is wrong with it, or "" when nothing is. `old` and
## `new` are from the *pack's* point of view, which is Minecraft's: a pack whose
## range stops below this version was made for an older one.
proc fitnessKey*(f: Fitness): string =
  if f == PackOld: PackTooOld
  elif f == PackNew: PackTooNew
  else: ""

## Build the screen's state from what the importer answered with and what
## `options.txt` had turned on. Anything named in `on` that is not in `packs` is
## dropped - a pack the player deleted from disk is not a pack - and anything in
## `packs` that `on` did not name goes to Available in the order it was found.
proc chooseFrom*(packs: seq[PackEntry]; on: seq[string]): PackChoice =
  result = noChoice()
  result.packs = packs
  var taken: seq[bool] = @[]
  var i = 0
  while i < packs.len:
    taken.add false
    inc i
  i = 0
  while i < on.len:
    var k = 0
    while k < packs.len:
      if packs[k].name == on[i] and not taken[k]:
        taken[k] = true
        result.selected.add k
        k = packs.len
      else:
        inc k
    inc i
  i = 0
  while i < packs.len:
    if not taken[i]: result.available.add i
    inc i

## The names, in the order `options.txt` wants them: lowest priority first, so
## the reverse of the column. The one place the reversal is spelled.
proc optionsOrder*(c: PackChoice): seq[string] =
  result = @[]
  var i = c.selected.len - 1
  while i >= 0:
    result.add c.packs[c.selected[i]].name
    dec i

## The names in priority order - highest first - which is what
## `aoughwl.minecraft` stacks its layers in. The importer's own
## `enabledPacks` answers in this order too, and the test asserts the round trip
## through `optionsOrder` and back is the identity.
proc priorityOrder*(c: PackChoice): seq[string] =
  result = @[]
  var i = 0
  while i < c.selected.len:
    result.add c.packs[c.selected[i]].name
    inc i

proc removeAt(list: var seq[int]; at: int) =
  var kept: seq[int] = @[]
  var i = 0
  while i < list.len:
    if i != at: kept.add list[i]
    inc i
  list = kept

proc insertAt(list: var seq[int]; at, value: int) =
  var kept: seq[int] = @[]
  var i = 0
  while i < list.len:
    if i == at: kept.add value
    kept.add list[i]
    inc i
  if at >= list.len: kept.add value
  list = kept

## Turn an available pack on. Minecraft puts it at the **top** of Selected -
## `getSelectedResourcePacks().add(0, this)` - so a pack you just turned on wins
## over everything, which is what somebody who just turned it on meant.
proc enable*(c: var PackChoice; row: int) =
  if row < 0 or row >= c.available.len: return
  let which = c.available[row]
  removeAt(c.available, row)
  insertAt(c.selected, 0, which)
  c.leftPick = -1
  c.rightPick = 0

## Turn a selected pack off. It goes back to Available, at the end, because
## Available has no meaningful order and putting it back where it came from
## would need a memory of where that was.
proc disable*(c: var PackChoice; row: int) =
  if row < 0 or row >= c.selected.len: return
  let which = c.selected[row]
  removeAt(c.selected, row)
  c.available.add which
  c.rightPick = -1

## Reorder within Selected. Up is towards index 0, which is towards winning.
proc raisePack*(c: var PackChoice; row: int) =
  if row <= 0 or row >= c.selected.len: return
  let which = c.selected[row]
  removeAt(c.selected, row)
  insertAt(c.selected, row - 1, which)
  c.rightPick = row - 1

proc lowerPack*(c: var PackChoice; row: int) =
  if row < 0 or row + 1 >= c.selected.len: return
  let which = c.selected[row]
  removeAt(c.selected, row)
  insertAt(c.selected, row + 1, which)
  c.rightPick = row + 1

## Whether anything about the selection differs from what it was built from.
## The screen only pays for a re-import when this says so - clicking a pack on
## and off again costs nothing, which matters when the price is reading the
## whole jar.
proc changedFrom*(c: PackChoice; was: seq[string]): bool =
  let now = priorityOrder(c)
  if now.len != was.len: return true
  var i = 0
  while i < now.len:
    if now[i] != was[i]: return true
    inc i
  false

# ---------------------------------------------------------------------------
# Where everything is

## The left column's band.
proc availableBox*(guiW, guiH, rows: int): ListBox =
  listBox(ColumnTop, guiH - ColumnBottomInset,
          guiW div 2 - ColumnGap - ColumnWidth, ColumnWidth,
          PackRowHeight, rows)

## The right column's band.
proc selectedBox*(guiW, guiH, rows: int): ListBox =
  listBox(ColumnTop, guiH - ColumnBottomInset, guiW div 2 + ColumnGap,
          ColumnWidth, PackRowHeight, rows)

## The two column titles, centred over their own columns.
proc availableTitleAt*(guiW: int): MRect =
  mrect(float(guiW div 2 - ColumnGap - ColumnWidth div 2),
        float(PackTitleTop), 0.0, 0.0)
proc selectedTitleAt*(guiW: int): MRect =
  mrect(float(guiW div 2 + ColumnGap + ColumnWidth div 2),
        float(PackTitleTop), 0.0, 0.0)

## Where a row's icon goes, and where its words start beside it.
proc iconRect*(row: MRect): MRect =
  mrect(row.x, row.y, float(IconSize), float(IconSize))
proc textLeft*(row: MRect): float =
  row.x + float(IconSize + IconGap * 2)

## The three parts of a row that can be clicked, when the row is in Available:
## the whole row selects it and a double click - or the arrow - moves it. This
## answers the arrow's rectangle, on the left of the icon where Minecraft draws
## the little chevron over a darkened icon.
proc arrowRect*(row: MRect): MRect =
  mrect(row.x, row.y, float(IconSize), float(IconSize))

## The bottom row: Done on the left of centre and the folder note on the right,
## which is the one screen in the game with a one-row footer and no Cancel -
## because the selection is applied when you leave, not when you confirm.
proc packDoneRect*(guiW, guiH: int): MRect =
  mrect(float(guiW div 2 - 154), float(guiH - FooterInset),
        float(FooterButtonWidth), 20.0)
proc packFolderRect*(guiW, guiH: int): MRect =
  mrect(float(guiW div 2 + 4), float(guiH - FooterInset),
        float(FooterButtonWidth), 20.0)
