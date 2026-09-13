## Recipes: `data/minecraft/recipe/*.json` out of the jar.
##
## Pure: nothing here calls the host.
##
## A recipe is the one part of Minecraft that is *data* rather than art, and it
## is the part a HUD needs to show a crafting grid at all. There are a dozen
## `type`s in the jar - smelting, blasting, smithing, stonecutting, a handful of
## one-off special ones the game hard-codes - and this reads the two that make
## up nine tenths of the file count and all of the crafting table:
## `crafting_shaped` and `crafting_shapeless`. Everything else is read far enough
## to say what it is and what it makes, which is what a recipe book needs even
## when it cannot draw the grid.
##
## ## Three spellings of the same thing
##
## The format moved twice and a player's jar may be either side of both moves,
## so all of it is read rather than the newest:
##
##   * The **folder** is `data/minecraft/recipes/` before 1.21 and
##     `data/minecraft/recipe/` after. `main.nim` asks for both.
##   * An **ingredient** was `{"item": "minecraft:stick"}` or
##     `{"tag": "minecraft:planks"}`, or an array of those for a choice. Since
##     1.21.2 it is the bare string `"minecraft:stick"`, or an array of strings,
##     and a tag is `"#minecraft:planks"`.
##   * A **result** was `{"item": "x", "count": 3}` and is now `{"id": "x",
##     "count": 3}`. Both are read; `count` defaults to one either way.
##
## A tag comes out with its `#`, because a tag is not an item and a HUD that
## drew it as one would be showing a picture that does not exist. Resolving a
## tag into its members needs `data/minecraft/tags/`, which is not read: it is
## another whole file of the same shape as this one and it can be added behind
## this without changing what is published.
##
## ## What comes out
##
## A `Recipe`, and `recipeLine` writes it as the single scalar a catalog row
## holds. The spelling is `field=value;` pairs, the same one `aoughwl.voxel`
## uses for a block, because a second encoding in the same repository is a second
## parser to keep in step.

import mcjson
import mcmodel

const
  Shaped* = 0
  Shapeless* = 1
  Other* = 2

  MaxGrid* = 9
    ## A crafting table. A recipe wanting a bigger grid is not one this game has
    ## a table for, and it is read as `Other` rather than truncated.

type
  Recipe* = object
    kind*: int
    typeName*: string    ## the `type` with its namespace stripped
    group*: string
    width*, height*: int ## shaped only
    slot*: seq[string]   ## shaped: width*height entries, "" for an empty cell
    part*: seq[string]   ## shapeless: one entry per ingredient
    made*: string        ## what it produces
    count*: int
    problem*: string

proc noRecipe*(): Recipe =
  Recipe(kind: Other, typeName: "", group: "", width: 0, height: 0,
         slot: @[], part: @[], made: "", count: 1, problem: "")

## One ingredient, in any of the three spellings, as a single name. A choice of
## several - `[{"item": "a"}, {"item": "b"}]` - comes out as `a|b`, which is the
## same alternatives spelling a blockstate condition uses.
proc readIngredient*(doc: Json; node: int): string =
  result = ""
  if node < 0: return result
  if kindAt(doc, node) == jString:
    return text(doc, node)
  if kindAt(doc, node) == jArray:
    var i = 0
    while i < len(doc, node):
      let one = readIngredient(doc, item(doc, node, i))
      if one.len > 0:
        if result.len > 0: result.add "|"
        result.add one
      inc i
    return result
  if kindAt(doc, node) != jObject: return result
  let item0 = member(doc, node, "item")
  if item0 >= 0: return text(doc, item0)
  let tag = member(doc, node, "tag")
  if tag >= 0: return "#" & text(doc, tag)
  # 1.21.2 wraps a choice in an object with `items` in it.
  readIngredient(doc, member(doc, node, "items"))

proc readResult(doc: Json; node: int; made: var string; count: var int) =
  made = ""
  count = 1
  if node < 0: return
  if kindAt(doc, node) == jString:
    made = text(doc, node)
    return
  let id = member(doc, node, "id")
  if id >= 0: made = text(doc, id)
  else: made = text(doc, member(doc, node, "item"))
  count = int(number(doc, member(doc, node, "count"), 1.0))
  if count < 1: count = 1

proc readShaped(r: var Recipe; doc: Json) =
  let pattern = member(doc, doc.root, "pattern")
  let keys = member(doc, doc.root, "key")
  if pattern < 0 or kindAt(doc, pattern) != jArray or len(doc, pattern) == 0:
    r.problem = "a shaped recipe with no pattern"
    return
  r.height = len(doc, pattern)
  var row = 0
  while row < r.height:
    let line = text(doc, item(doc, pattern, row))
    if line.len > r.width: r.width = line.len
    inc row
  if r.width < 1 or r.width * r.height > MaxGrid:
    r.kind = Other
    r.problem = "a " & $r.width & " by " & $r.height &
      " pattern is not a crafting grid"
    return
  row = 0
  while row < r.height:
    let line = text(doc, item(doc, pattern, row))
    var col = 0
    while col < r.width:
      var name = ""
      if col < line.len and line[col] != ' ':
        var symbol = ""
        symbol.add line[col]
        let entry = member(doc, keys, symbol)
        if entry < 0:
          if r.problem.len == 0:
            r.problem = "the pattern uses '" & symbol & "', which the key does not define"
        else:
          name = readIngredient(doc, entry)
      r.slot.add name
      inc col
    inc row

proc readShapeless(r: var Recipe; doc: Json) =
  let list = member(doc, doc.root, "ingredients")
  if list < 0 or kindAt(doc, list) != jArray:
    r.problem = "a shapeless recipe with no ingredients"
    return
  if len(doc, list) > MaxGrid:
    r.kind = Other
    r.problem = "a shapeless recipe of " & $len(doc, list) &
      " does not fit a crafting grid"
    return
  var i = 0
  while i < len(doc, list):
    let name = readIngredient(doc, item(doc, list, i))
    if name.len == 0:
      if r.problem.len == 0: r.problem = "an ingredient names nothing"
    else:
      r.part.add name
    inc i

## One recipe file. A type this does not know comes back as `Other` with its
## name and its result, which is enough for a recipe book to list it and say
## which station makes it.
proc readRecipe*(doc: Json): Recipe =
  result = noRecipe()
  if doc.root < 0:
    result.problem = "this recipe would not parse"
    return result
  result.typeName = resourcePath(text(doc, member(doc, doc.root, "type")))
  result.group = text(doc, member(doc, doc.root, "group"))
  readResult(doc, member(doc, doc.root, "result"), result.made, result.count)
  if result.typeName == "crafting_shaped":
    result.kind = Shaped
    readShaped(result, doc)
  elif result.typeName == "crafting_shapeless":
    result.kind = Shapeless
    readShapeless(result, doc)
  else:
    result.kind = Other
    # Smelting and its three cousins name one ingredient rather than a list, and
    # that one is worth carrying: a furnace recipe with its input is a complete
    # thing to show.
    let one = readIngredient(doc, member(doc, doc.root, "ingredient"))
    if one.len > 0: result.part.add one
  if result.made.len == 0 and result.problem.len == 0:
    result.problem = "this recipe says nothing about what it makes"

proc kindName*(kind: int): string =
  if kind == Shaped: "shaped"
  elif kind == Shapeless: "shapeless"
  else: "other"

proc joined(list: seq[string]; sep: string): string =
  result = ""
  var i = 0
  while i < list.len:
    if i > 0: result.add sep
    result.add list[i]
    inc i

## The catalog row. `field=value` pairs separated by semicolons, the same shape
## `aoughwl.voxel` reads a block from:
##
##   type=shaped;made=minecraft:oak_door;count=3;w=3;h=2;
##   slots=minecraft:oak_planks,minecraft:oak_planks,,minecraft:oak_planks,...
##
## An empty cell is an empty entry between two commas, so the grid's shape is in
## the string and a reader does not have to infer it. `parts=` replaces `slots=`
## for a shapeless recipe, and a recipe of any other type carries `type=` and
## `made=` and whatever single ingredient it named.
proc recipeLine*(r: Recipe): string =
  result = "type=" & kindName(r.kind) & ";made=" & r.made & ";count=" & $r.count
  if r.typeName.len > 0: result.add ";station=" & r.typeName
  if r.group.len > 0: result.add ";group=" & r.group
  if r.kind == Shaped:
    result.add ";w=" & $r.width & ";h=" & $r.height
    result.add ";slots=" & joined(r.slot, ",")
  elif r.part.len > 0:
    result.add ";parts=" & joined(r.part, ",")

# ---------------------------------------------------------------------------
# The row `aoughwl.hud` reads
#
# `aoughwl.hud/hudrecipe.nim` declares the catalog kind
# `aoughwl.hud.recipe` and owns its grammar, which is fields separated by
# `|`:
#
#     shaped|3x3|xxx/.s./.s.|x=oak_planks,s=stick|oak_door*3
#     shapeless|stick,coal|torch*4
#
# So this file writes that, rather than inventing a second spelling for the same
# thing. `recipeLine` above is still what a mod with no HUD reads; this is what
# the HUD reads, and `hudRecipeText(readRecipe(...))` is meant to be identical
# to what that mod's own `recipeText` would have written for the same recipe -
# same marks, same order, same everything - because a row written two ways is a
# row somebody eventually diffs.
#
# Three things have to be given up on the way, and all three are the grammar
# saying no rather than this reader being lazy:
#
#   * **`|` is the field separator**, so an ingredient that is a *choice* -
#     `coal|charcoal` - cannot be written. The first alternative is taken.
#   * **A bench is at most 3x3.** A recipe with a bigger pattern has no row.
#   * **Nine marks**, `a` to `i`, so nine distinct ingredients at most - which
#     is every cell of a 3x3 being different, so it is not a real limit.
#
# Item ids are the **leaf** of the Minecraft id: `minecraft:oak_planks` is
# `oak_planks`, because that is the id this importer's own item catalog uses and
# a recipe naming an item nothing published matches nothing. A tag keeps its
# hash - `#minecraft:planks` is `#planks` - so a reader can still tell it is
# looking at a tag rather than at an item that does not exist.

const HudMarks = "abcdefghi"

## One ingredient as the HUD spells an item id.
proc hudItem*(reference: string): string =
  var first = ""
  var i = 0
  while i < reference.len:
    if reference[i] == '|': break
    first.add reference[i]
    inc i
  if first.len == 0: return ""
  if first[0] == '#':
    var rest = ""
    i = 1
    while i < first.len:
      rest.add first[i]
      inc i
    let bare = leaf(rest)
    if bare.len == 0: return ""
    return "#" & bare
  leaf(first)

proc markOf(distinct0: seq[string]; want: string): int =
  var i = 0
  while i < distinct0.len:
    if distinct0[i] == want: return i
    inc i
  -1

## The catalog row, or "" when this recipe is not one a bench can hold. A caller
## publishes what comes back and skips what does not, rather than writing a row
## the HUD would then have to reject.
proc hudRecipeText*(r: Recipe): string =
  let made = hudItem(r.made)
  if made.len == 0: return ""
  var count = r.count
  if count < 1: count = 1

  if r.kind == Shapeless:
    if r.part.len == 0 or r.part.len > 9: return ""
    result = "shapeless|"
    var i = 0
    while i < r.part.len:
      let one = hudItem(r.part[i])
      if one.len == 0: return ""
      if i > 0: result.add ","
      result.add one
      inc i
    result.add "|"
    result.add made
    result.add "*"
    result.add $count
    return result

  if r.kind != Shaped: return ""
  if r.width < 1 or r.width > 3 or r.height < 1 or r.height > 3: return ""
  if r.slot.len != r.width * r.height: return ""

  # One mark per distinct ingredient, in the order they are first met, from a
  # fixed alphabet - the same rule `hudrecipe.recipeText` uses, so the two write
  # the same string for the same recipe.
  var distinct0: seq[string] = @[]
  var cells: seq[string] = @[]
  var i = 0
  while i < r.slot.len:
    var cell = ""
    if r.slot[i].len > 0:
      cell = hudItem(r.slot[i])
      if cell.len == 0: return ""
      if markOf(distinct0, cell) < 0:
        if distinct0.len >= 9: return ""
        distinct0.add cell
    cells.add cell
    inc i

  result = "shaped|"
  result.add $r.width
  result.add "x"
  result.add $r.height
  result.add "|"
  var row = 0
  while row < r.height:
    if row > 0: result.add "/"
    var column = 0
    while column < r.width:
      let cell = cells[row * r.width + column]
      if cell.len == 0: result.add "."
      else: result.add HudMarks[markOf(distinct0, cell)]
      inc column
    inc row
  result.add "|"
  i = 0
  while i < distinct0.len:
    if i > 0: result.add ","
    result.add HudMarks[i]
    result.add "="
    result.add distinct0[i]
    inc i
  result.add "|"
  result.add made
  result.add "*"
  result.add $count
