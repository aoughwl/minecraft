## Recipes as data, and the arithmetic that matches one against a bench.
##
## Pure: nothing here calls the host. `huditems.nim` reads the catalog and
## hands the text in; this file decides what it means and what it matches.
##
## A recipe is one row of a catalog, and a catalog row is one string, so a
## recipe is one string. The grammar is fields separated by `|`:
##
##     shaped|3x3|xxx/.s./.s.|x=hud.plank,s=hud.stick|hud.pickaxe*1
##     shapeless|hud.plank,hud.plank|hud.stick*4
##
## A shaped recipe's rows use one character per cell, `.` for an empty one, and
## the key field says which item each character is. A shapeless one lists its
## ingredients and does not care where they sit. Both end in `item*count`.
##
## Everything else about it - which mod put it there, whether the player has a
## bench big enough - is somebody else's question.

import hudcore

type Recipe* = object
  ## One recipe, parsed. `problem` is set for a row that does not spell one,
  ## and a recipe with a problem never matches anything, so a mod publishing
  ## nonsense costs a log line rather than a crash.
  id*: string
  shaped*: bool
  wide*, tall*: int
  cells*: seq[string]
    ## `wide * tall` item ids, row by row, empty for an empty cell. Shaped only.
  needs*: seq[string]
    ## The ingredients, in no order. Shapeless only.
  made*: string
  count*: int
  problem*: string

proc broken(id, why: string): Recipe =
  Recipe(id: id, shaped: false, wide: 0, tall: 0, cells: @[], needs: @[],
    made: "", count: 0, problem: why)

proc usable*(r: Recipe): bool = r.problem.len == 0 and r.made.len > 0

## `item*count`, or `item` on its own for one of them.
proc parseOutput(text: string; made: var string; count: var int): bool =
  let parts = splitOn(text, '*')
  made = trimmed(parts[0])
  count = 1
  if parts.len > 2: return false
  if parts.len == 2:
    count = wholeOf(parts[1], -1)
    if count < 1: return false
  made.len > 0

## `k=item,k=item` into two parallel lists.
proc parseKeys(text: string; marks: var seq[char];
    items: var seq[string]): bool =
  marks = @[]
  items = @[]
  let body = trimmed(text)
  if body.len == 0: return true
  let pairs = splitOn(body, ',')
  var i = 0
  while i < pairs.len:
    let one = trimmed(pairs[i])
    if one.len > 0:
      let halves = splitOn(one, '=')
      if halves.len != 2: return false
      let mark = trimmed(halves[0])
      let item = trimmed(halves[1])
      if mark.len != 1 or item.len == 0: return false
      marks.add mark[0]
      items.add item
    i = i + 1
  true

proc itemForMark(marks: seq[char]; items: seq[string]; mark: char): string =
  result = ""
  var i = 0
  while i < marks.len:
    if marks[i] == mark: result = items[i]
    i = i + 1

## One catalog row into a recipe. Never raises; a row it cannot read comes back
## with a `problem` and matches nothing.
proc parseRecipe*(id, text: string): Recipe =
  let fields = splitOn(text, '|')
  if fields.len < 3: return broken(id, "a recipe is at least three fields")
  let form = trimmed(fields[0])
  if form == "shapeless":
    if fields.len != 3: return broken(id, "a shapeless recipe is three fields")
    var needs: seq[string] = @[]
    let listed = splitOn(fields[1], ',')
    var i = 0
    while i < listed.len:
      let one = trimmed(listed[i])
      if one.len > 0: needs.add one
      i = i + 1
    if needs.len == 0: return broken(id, "a recipe needs an ingredient")
    if needs.len > 9: return broken(id, "no bench has ten slots")
    var made = ""
    var count = 0
    if not parseOutput(fields[2], made, count):
      return broken(id, "a recipe ends in item*count")
    return Recipe(id: id, shaped: false, wide: 0, tall: 0, cells: @[],
      needs: needs, made: made, count: count, problem: "")
  if form != "shaped": return broken(id, "a recipe is shaped or shapeless")
  if fields.len != 5: return broken(id, "a shaped recipe is five fields")
  let size = splitOn(trimmed(fields[1]), 'x')
  if size.len != 2: return broken(id, "a shape is spelled WxH")
  let wide = wholeOf(size[0], -1)
  let tall = wholeOf(size[1], -1)
  if wide < 1 or tall < 1 or wide > 3 or tall > 3:
    return broken(id, "a shape is between 1x1 and 3x3")
  let rows = splitOn(trimmed(fields[2]), '/')
  if rows.len != tall: return broken(id, "the shape says " & $tall & " rows")
  var marks: seq[char] = @[]
  var items: seq[string] = @[]
  if not parseKeys(fields[3], marks, items):
    return broken(id, "the keys are spelled k=item,k=item")
  var cells: seq[string] = @[]
  var row = 0
  while row < tall:
    let line = rows[row]
    if line.len != wide: return broken(id, "row " & $row & " is not " & $wide & " wide")
    var column = 0
    while column < wide:
      let mark = line[column]
      if mark == '.' or mark == ' ':
        cells.add ""
      else:
        let item = itemForMark(marks, items, mark)
        if item.len == 0: return broken(id, "nothing is keyed to that mark")
        cells.add item
      column = column + 1
    row = row + 1
  var made = ""
  var count = 0
  if not parseOutput(fields[4], made, count):
    return broken(id, "a recipe ends in item*count")
  Recipe(id: id, shaped: true, wide: wide, tall: tall, cells: cells,
    needs: @[], made: made, count: count, problem: "")

## The catalog row a recipe would be written as, so a mod that builds one in
## code and a mod that publishes one as text put the same string in the
## catalog. `parseRecipe(id, recipeText(r))` is `r`.
proc recipeText*(r: Recipe): string =
  if not r.shaped:
    result = "shapeless|"
    var i = 0
    while i < r.needs.len:
      if i > 0: result.add ","
      result.add r.needs[i]
      i = i + 1
    result.add "|" & r.made & "*" & $r.count
    return result
  # One mark per distinct ingredient, taken from a fixed alphabet so the text
  # is the same every time the same recipe is written out.
  const Marks = "abcdefghi"
  var distinct0: seq[string] = @[]
  var i = 0
  while i < r.cells.len:
    if r.cells[i].len > 0:
      var seen = false
      var j = 0
      while j < distinct0.len:
        if distinct0[j] == r.cells[i]: seen = true
        j = j + 1
      if not seen: distinct0.add r.cells[i]
    i = i + 1
  result = "shaped|" & $r.wide & "x" & $r.tall & "|"
  var row = 0
  while row < r.tall:
    if row > 0: result.add "/"
    var column = 0
    while column < r.wide:
      let cell = r.cells[row * r.wide + column]
      if cell.len == 0: result.add "."
      else:
        var at = 0
        var j = 0
        while j < distinct0.len:
          if distinct0[j] == cell: at = j
          j = j + 1
        result.add Marks[at]
      column = column + 1
    row = row + 1
  result.add "|"
  i = 0
  while i < distinct0.len:
    if i > 0: result.add ","
    result.add Marks[i]
    result.add "="
    result.add distinct0[i]
    i = i + 1
  result.add "|" & r.made & "*" & $r.count

# ---------------------------------------------------------------------------
# The bench
# ---------------------------------------------------------------------------

type Bench* = object
  ## The crafting grid and what it currently makes. Two by two in the
  ## inventory screen, three by three at a table; the arithmetic is the same
  ## and only the size differs, which is why there is one type.
  wide*, tall*: int
  cells*: seq[ItemStack]
  made*: ItemStack
  recipe*: int
    ## Which recipe made it, or -1. A screen shows the name; taking the result
    ## uses it to know what to spend.

proc newBench*(wide, tall: int): Bench =
  result = Bench(wide: wide, tall: tall, cells: @[], made: nothingStack(),
    recipe: -1)
  var i = 0
  while i < wide * tall:
    result.cells.add nothingStack()
    i = i + 1

proc benchAt*(b: Bench; slot: int): ItemStack =
  if slot < 0 or slot >= b.cells.len: nothingStack() else: b.cells[slot]

proc benchPut*(b: var Bench; slot: int; s: ItemStack) =
  if slot < 0 or slot >= b.cells.len: return
  b.cells[slot] = s

# ---------------------------------------------------------------------------
# Matching
# ---------------------------------------------------------------------------

proc filled(b: Bench): int =
  result = 0
  var i = 0
  while i < b.cells.len:
    if not isEmpty(b.cells[i]): result = result + 1
    i = i + 1

proc matchesShapeless(r: Recipe; b: Bench): bool =
  if filled(b) != r.needs.len: return false
  var used: seq[bool] = @[]
  var i = 0
  while i < b.cells.len:
    used.add false
    i = i + 1
  var need = 0
  while need < r.needs.len:
    var found = false
    var cell = 0
    while cell < b.cells.len and not found:
      if (not used[cell]) and (not isEmpty(b.cells[cell])) and
          b.cells[cell].item == r.needs[need]:
        used[cell] = true
        found = true
      cell = cell + 1
    if not found: return false
    need = need + 1
  true

## The smallest box the filled cells fit in. `wide` comes back at zero for an
## empty bench, which is what stops a recipe with no ingredients matching one.
proc extentOf(b: Bench; left, top, wide, tall: var int) =
  left = b.wide
  top = b.tall
  var right = -1
  var bottom = -1
  var row = 0
  while row < b.tall:
    var column = 0
    while column < b.wide:
      if not isEmpty(b.cells[row * b.wide + column]):
        if column < left: left = column
        if column > right: right = column
        if row < top: top = row
        if row > bottom: bottom = row
      column = column + 1
    row = row + 1
  if right < 0:
    left = 0
    top = 0
    wide = 0
    tall = 0
    return
  wide = right - left + 1
  tall = bottom - top + 1

proc matchesShapedAt(r: Recipe; b: Bench; left, top: int; mirrored: bool): bool =
  var row = 0
  while row < r.tall:
    var column = 0
    while column < r.wide:
      var take = column
      if mirrored: take = r.wide - 1 - column
      let wanted = r.cells[row * r.wide + take]
      let here = b.cells[(top + row) * b.wide + (left + column)]
      if wanted.len == 0:
        if not isEmpty(here): return false
      else:
        if isEmpty(here) or here.item != wanted: return false
      column = column + 1
    row = row + 1
  true

proc matchesShaped(r: Recipe; b: Bench): bool =
  if r.wide > b.wide or r.tall > b.tall: return false
  var left = 0
  var top = 0
  var wide = 0
  var tall = 0
  extentOf(b, left, top, wide, tall)
  if wide == 0: return false
  if wide != r.wide or tall != r.tall: return false
  if matchesShapedAt(r, b, left, top, false): return true
  matchesShapedAt(r, b, left, top, true)

## Whether this recipe is what is on the bench.
proc matches*(r: Recipe; b: Bench): bool =
  if not usable(r): return false
  if r.shaped: matchesShaped(r, b) else: matchesShapeless(r, b)

## Which of them is, or -1. The last one wins, which is the rule every catalog
## walk in this project follows: a mod that wants to replace somebody's recipe
## publishes its own after theirs.
proc matching*(recipes: seq[Recipe]; b: Bench): int =
  result = -1
  var i = 0
  while i < recipes.len:
    if matches(recipes[i], b): result = i
    i = i + 1

## Work out what the bench makes and write it into the bench. Call it after
## every change to a cell; nothing else needs to know a recipe exists.
proc settle*(b: var Bench; recipes: seq[Recipe]) =
  b.recipe = matching(recipes, b)
  if b.recipe < 0:
    b.made = nothingStack()
    return
  let r = recipes[b.recipe]
  b.made = stack(r.made, r.count)

## Take the result: one of every ingredient goes, and the bench settles again.
## Answers what was made, and nothing at all when there was nothing to take.
proc takeResult*(b: var Bench; recipes: seq[Recipe]): ItemStack =
  if b.recipe < 0 or isEmpty(b.made): return nothingStack()
  let made = b.made
  var i = 0
  while i < b.cells.len:
    if not isEmpty(b.cells[i]):
      b.cells[i].count = b.cells[i].count - 1
      if b.cells[i].count <= 0: b.cells[i] = nothingStack()
    i = i + 1
  settle(b, recipes)
  made

## Everything on the bench, back into an inventory - what closing the screen
## does, so a player never loses two planks to a stray Escape. Answers what
## would not fit, which stays on the bench.
proc clearBench*(b: var Bench; inv: var Inventory; reg: Registry;
    recipes: seq[Recipe]): int =
  result = 0
  var i = 0
  while i < b.cells.len:
    if not isEmpty(b.cells[i]):
      let left = give(inv, reg, b.cells[i].item, b.cells[i].count)
      if left <= 0: b.cells[i] = nothingStack()
      else:
        b.cells[i].count = left
        result = result + left
    i = i + 1
  settle(b, recipes)

# ---------------------------------------------------------------------------
# The player
#
# Everything a survival HUD is, as one value: what is carried, what is worn,
# what is on the bench, what is in the hand between two clicks, and how alive
# the player is. It lives here rather than in `hudcore` only because it has a
# bench in it, and it is a value rather than a set of globals for the same
# reason everything else here is - so a test can drive a whole inventory
# screen with no screen.
# ---------------------------------------------------------------------------

type Hud* = object
  inv*: Inventory
  bench*: Bench
  life*: Survival
  carried*: ItemStack
    ## What the pointer is holding between two clicks. Minecraft's inventory
    ## is click-to-take and click-to-place, not press-and-hold, so the hand
    ## outlives the frame and cannot be `ui`'s drag payload.
  selected*: int
    ## Which hotbar slot is up.
  open*: bool
    ## Whether the inventory screen is showing.

proc newHud*(benchWide = 2; benchTall = 2): Hud =
  Hud(inv: newInventory(), bench: newBench(benchWide, benchTall),
    life: newSurvival(), carried: nothingStack(), selected: 0, open: false)

## What is in the selected hotbar slot - the thing a click on the world uses.
proc held*(h: Hud): ItemStack = h.inv.at(h.selected)

## Spend one of whatever is in hand - placing a block, or firing something off.
proc spendHeld*(h: var Hud) =
  var s = h.inv.at(h.selected)
  if isEmpty(s): return
  s.count = s.count - 1
  if s.count <= 0: s = nothingStack()
  h.inv.put(h.selected, s)

## Eat what is in hand, if it is food and there is room for it. Answers whether
## anything happened, so a HUD knows whether to say so.
proc eatHeld*(h: var Hud; reg: Registry): bool =
  let s = h.inv.at(h.selected)
  if isEmpty(s): return false
  let d = definitionOf(reg, s.item)
  if not wouldEat(h.life, d.food): return false
  eat(h.life, d.food, d.saturation)
  spendHeld(h)
  true

## Keep the armour bar honest after anything that could have changed it.
proc refreshArmour*(h: var Hud; reg: Registry) =
  h.life.armour = armourWorn(h.inv, reg)

## A click on one of the forty slots. `right` is the right button.
proc clickAt*(h: var Hud; reg: Registry; slot: int; right = false) =
  if right:
    let next = rightClickSlot(h.inv, reg, slot, h.carried)
    h.carried = next
  else:
    let next = clickSlot(h.inv, reg, slot, h.carried)
    h.carried = next
  refreshArmour(h, reg)

## A click on one of the bench's cells. The bench is not part of the forty, so
## it has its own path, and it settles afterwards because that is the only way
## the result slot is ever right.
proc clickBench*(h: var Hud; reg: Registry; cell: int; recipes: seq[Recipe];
    right = false) =
  if cell < 0 or cell >= h.bench.cells.len: return
  var one = newInventory()
  one.put(0, h.bench.cells[cell])
  if right:
    let next = rightClickSlot(one, reg, 0, h.carried)
    h.carried = next
  else:
    let next = clickSlot(one, reg, 0, h.carried)
    h.carried = next
  h.bench.cells[cell] = one.at(0)
  settle(h.bench, recipes)

## Take what the bench made. It goes into the hand if the hand is empty or
## holding the same thing, and into the inventory otherwise - which is the one
## place Minecraft's rule and a tidy rule disagree, and the tidy one wins here
## because a result that refuses to come off the bench looks broken.
proc takeMade*(h: var Hud; reg: Registry; recipes: seq[Recipe]): bool =
  if isEmpty(h.bench.made): return false
  if isEmpty(h.carried):
    h.carried = takeResult(h.bench, recipes)
    return true
  if h.carried.item == h.bench.made.item and
      h.carried.count + h.bench.made.count <= stackLimit(reg, h.carried.item):
    let made = takeResult(h.bench, recipes)
    h.carried.count = h.carried.count + made.count
    return true
  let made = takeResult(h.bench, recipes)
  if isEmpty(made): return false
  let over = give(h.inv, reg, made.item, made.count)
  over <= 0

## Shut the screen: the bench and the hand both go back into the inventory, so
## a stray Escape never costs a player two planks. Answers how much would not
## fit, which stays where it was.
proc closeScreen*(h: var Hud; reg: Registry; recipes: seq[Recipe]): int =
  result = clearBench(h.bench, h.inv, reg, recipes)
  if not isEmpty(h.carried):
    let over = give(h.inv, reg, h.carried.item, h.carried.count)
    if over <= 0: h.carried = nothingStack()
    else:
      h.carried.count = over
      result = result + over
  h.open = false
  refreshArmour(h, reg)

## What a drag from one slot to another does. Slots below `PlayerSlots` are the
## inventory; from `PlayerSlots` up they are the bench, which is what lets one
## drag machine move things between the two without either knowing about the
## other.
const FirstBenchSlot* = PlayerSlots

proc stackAtWide*(h: Hud; slot: int): ItemStack =
  if slot < FirstBenchSlot: h.inv.at(slot)
  else: benchAt(h.bench, slot - FirstBenchSlot)

proc putWide(h: var Hud; slot: int; s: ItemStack) =
  if slot < FirstBenchSlot: h.inv.put(slot, s)
  else: benchPut(h.bench, slot - FirstBenchSlot, s)

## Move a whole stack from one slot to another, across the inventory and the
## bench alike. Merges onto the same thing and swaps with anything else, and
## refuses whatever an armour slot refuses.
proc dragSlot*(h: var Hud; reg: Registry; source, target: int;
    recipes: seq[Recipe]): bool =
  if source == target: return false
  let moving = stackAtWide(h, source)
  if isEmpty(moving): return false
  if target < FirstBenchSlot and not slotAccepts(reg, target, moving):
    return false
  var here = stackAtWide(h, target)
  if sameItem(here, moving):
    let left = pourInto(reg, here, moving)
    putWide(h, target, here)
    putWide(h, source, left)
  else:
    if source < FirstBenchSlot and not slotAccepts(reg, source, here):
      return false
    putWide(h, target, moving)
    putWide(h, source, here)
  settle(h.bench, recipes)
  refreshArmour(h, reg)
  true
