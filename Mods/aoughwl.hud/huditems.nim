## Where the HUD's items and recipes come from: catalogs, and nothing else.
##
## This is the only file in the mod that talks to the host about content. It
## sits on `aoughwl.inventory`'s item definitions rather than beside them,
## so a block registered by `aoughwl.voxel` or an item imported by
## `aoughwl.minecraft` turns up in this inventory without either mod
## naming this one. What it adds is the handful of facets a survival HUD needs
## and an inventory library has no business knowing about - what an item looks
## like, whether it is food, and whether it is armour - and one catalog kind of
## its own, for recipes.
##
## The facets follow the library's spelling rule: the base catalog's id plus a
## suffix, so a content mod that never calls a builder here still puts its
## numbers where this reader looks.
##
## | facet catalog | kind | value |
## | --- | --- | --- |
## | `<base>.icon` | `aoughwl.hud.icon` | text: a sheet cell, or `#rrggbb` |
## | `<base>.food` | `aoughwl.hud.food` | integer: half-haunches restored |
## | `<base>.saturation` | `aoughwl.hud.saturation` | number |
## | `<base>.armour` | `aoughwl.hud.armour` | integer: points, out of twenty |
## | `<base>.armourpart` | `aoughwl.hud.armourpart` | text: head/chest/legs/feet |
##
## Recipes are their own kind, `aoughwl.hud.recipe`, one row per recipe,
## and the row is the whole recipe - `hudrecipe.nim` says what the text means.
## A mod publishes a catalog of them and says so; this mod reads every catalog
## anybody published, in the order they were published, so the last one wins.

import jester
import catalogs
import aoughwl_grid/gridspace
import hudcore
import hudrecipe

const
  IconKind* = "aoughwl.hud.icon"
  FoodKind* = "aoughwl.hud.food"
  SaturationKind* = "aoughwl.hud.saturation"
  ArmourKind* = "aoughwl.hud.armour"
  ArmourPartKind* = "aoughwl.hud.armourpart"
  RecipeKind* = "aoughwl.hud.recipe"
    ## The catalog kind this mod exists to declare. One row is one recipe.
  SourceKind* = "aoughwl.hud.source"

  IconFacet* = ".icon"
  FoodFacet* = ".food"
  SaturationFacet* = ".saturation"
  ArmourFacet* = ".armour"
  ArmourPartFacet* = ".armourpart"

  RecipeSources* = "aoughwl.hud.recipes"
    ## The registry of recipe catalogs. Rows are catalog ids; the text is the
    ## word `recipes`, so the row is readable rather than a bare marker.
    ##
    ## It exists for the reason `aoughwl.inventory.sources` does: a
    ## module-level `var` has one instance per mod that imports the module, so
    ## a mod registering its catalog with its own copy of this library tells
    ## nobody. Anything two mods must genuinely agree about goes through the
    ## host, and the host's word for agreement is a catalog.

var kindsDeclared = false

## Say that these six kinds can exist. The first mod to call it in a session
## owns them and every later call is a no-op, so a content mod may call it
## defensively rather than depend on load order.
##
## The no-op has to be asked of the host and not remembered in the `var` above:
## that `var` is per-mod, so a second mod importing this library does reach
## `defineCatalogKind`, and the host raises when a kind is already owned by
## somebody else - which takes the calling mod's interpreter slot with it.
## There is no host call that asks whether a kind exists, so the question is
## asked of the registry catalog created alongside them, exactly as
## `declareGridKinds` and the SDK's own `ensureCatalog` ask it.
proc declareHudKinds*() =
  if kindsDeclared: return
  kindsDeclared = true
  declareGridKinds()
  if catalogSignature(RecipeSources).len > 0: return
  defineCatalogKind(IconKind, "text",
    "What an item looks like: a cell of a sprite sheet, or a colour.")
  defineCatalogKind(FoodKind, "integer",
    "How many half-haunches eating one of these restores.")
  defineCatalogKind(SaturationKind, "number",
    "How much saturation eating one of these restores.")
  defineCatalogKind(ArmourKind, "integer",
    "How many armour points wearing this is worth, out of twenty.")
  defineCatalogKind(ArmourPartKind, "text",
    "Which armour slot a piece belongs in: head, chest, legs or feet.")
  defineCatalogKind(RecipeKind, "text",
    "One recipe: what goes on a bench and what comes off it.")
  defineCatalogKind(SourceKind, "text",
    "A catalog somebody published, and what is in it.")
  createCatalog(RecipeSources, SourceKind,
    "Which catalogs hold recipes.")

# ---------------------------------------------------------------------------
# Reading a facet
# ---------------------------------------------------------------------------

proc present(id: string): bool = catalogSignature(id).len > 0

# ---------------------------------------------------------------------------
# One catalog, read once
# ---------------------------------------------------------------------------
#
# A facet used to be read with `named(cat).find(id)`, and `find` walks every
# row of the catalog asking the host for each one's id - it cannot stop early,
# because the rule is that the last row of a name wins. That is nothing on the
# dozen rows a hand-written modpack publishes and it is a catastrophe on 1,505:
# see the note at the top of `hudcore.nim` for the six-minute frame it caused.
#
# So a catalog is read once - one host call per row, here - and asked through
# the index in `hudcore.nim` after that. The reading is the same number of host
# calls the first `find` alone would have made.

type Rows = object
  ## One catalog's row ids, read once and indexed.
  catalog: string
  here: bool
  names: NameIndex

proc readRows(catalog: string): Rows =
  result = Rows(catalog: catalog, here: false, names: noNames())
  if not present(catalog): return result
  result.here = true
  var ids: seq[string] = @[]
  let n = catalogCount(catalog)
  var i = 0
  while i < n:
    ids.add catalogItemId(catalog, i)
    i = i + 1
  result.names = namesFrom(ids)

proc rowAt(r: Rows; id: string): int =
  ## Which row of it is called that, or -1 - the last such row, which is the
  ## one `find` would have settled on.
  if not r.here: return -1
  rowOf(r.names, id)

proc rowCount(r: Rows): int =
  if not r.here: return 0
  nameCount(r.names)

proc rowText(r: Rows; id, fallback: string): string =
  let at = rowAt(r, id)
  if at < 0: fallback else: catalogText(r.catalog, at)

proc rowNumber(r: Rows; id: string; fallback: float64): float64 =
  let at = rowAt(r, id)
  if at < 0: fallback else: catalogNumber(r.catalog, at)

proc rowInteger(r: Rows; id: string; fallback: int): int =
  let at = rowAt(r, id)
  if at < 0: fallback else: int(catalogInteger(r.catalog, at))

## The word for an armour slot, and the slot a word means. An unknown word is
## `NotArmour` rather than a throw, because a catalog row is somebody else's
## typing.
proc partName*(p: ArmourPart): string =
  case p
  of NotArmour: ""
  of Head: "head"
  of Chest: "chest"
  of Legs: "legs"
  of Feet: "feet"

proc partNamed*(word: string): ArmourPart =
  case trimmed(word)
  of "head": Head
  of "chest": Chest
  of "legs": Legs
  of "feet": Feet
  else: NotArmour

# ---------------------------------------------------------------------------
# Writing definitions
# ---------------------------------------------------------------------------

## A catalog of items a survival HUD can show, and every facet catalog that
## goes with it - the inventory library's five and this mod's five. Published
## as it is made, so a mod that draws an inventory sees it without being told.
proc hudItemCatalog*(id: string; description = ""): Catalog =
  declareHudKinds()
  let c = itemCatalog(id, description)
  createCatalog(id & IconFacet, IconKind, "Icons for " & id)
  createCatalog(id & FoodFacet, FoodKind, "Food values for " & id)
  createCatalog(id & SaturationFacet, SaturationKind, "Saturation for " & id)
  createCatalog(id & ArmourFacet, ArmourKind, "Armour points for " & id)
  createCatalog(id & ArmourPartFacet, ArmourPartKind, "Armour slots for " & id)
  publishItems(id)
  c

## One item, written across the base catalog and all ten facets in one call.
proc defineHudItem*(c: Catalog; id, display: string; stack = 64; icon = "";
    food = 0; saturation = 0.0; armour = 0; part = NotArmour; tags = "") =
  let base = name(c)
  defineItem(c, id, display, stack = stack, tags = tags)
  addToCatalog(base & IconFacet, id, icon)
  addToCatalog(base & FoodFacet, id, int64(food))
  addToCatalog(base & SaturationFacet, id, saturation)
  addToCatalog(base & ArmourFacet, id, int64(armour))
  addToCatalog(base & ArmourPartFacet, id, partName(part))

## A catalog of recipes, and the registry row that tells everyone about it.
proc hudRecipeCatalog*(id: string; description = ""): Catalog =
  declareHudKinds()
  createCatalog(id, RecipeKind, description)
  addToCatalog(RecipeSources, id, "recipes")
  Catalog(id)

## One recipe, as the text `hudrecipe.nim` reads.
proc defineRecipeText*(c: Catalog; id, text: string) =
  addToCatalog(name(c), id, text)

## The same, said as a shape rather than as a string. `rows` is one string per
## row of the bench, one character per cell, `.` for an empty one; `keys` is
## `k=item,k=item`.
proc defineShaped*(c: Catalog; id: string; rows: seq[string]; keys: string;
    made: string; count = 1) =
  var wide = 0
  if rows.len > 0: wide = rows[0].len
  var shape = ""
  var i = 0
  while i < rows.len:
    if i > 0: shape.add "/"
    shape.add rows[i]
    i = i + 1
  defineRecipeText(c, id, "shaped|" & $wide & "x" & $rows.len & "|" & shape &
    "|" & keys & "|" & made & "*" & $count)

proc defineShapeless*(c: Catalog; id: string; needs: seq[string];
    made: string; count = 1) =
  var listed = ""
  var i = 0
  while i < needs.len:
    if i > 0: listed.add ","
    listed.add needs[i]
    i = i + 1
  defineRecipeText(c, id, "shapeless|" & listed & "|" & made & "*" & $count)

# ---------------------------------------------------------------------------
# Reading everything back
# ---------------------------------------------------------------------------

## Every item anybody published, gathered into the registry the pure modules
## read. Nothing in here names an item: whatever a content mod defined turns
## up, which is what makes a block a voxel mod invented five minutes ago
## carryable without a line of code here.
proc loadRegistry*(): Registry =
  declareHudKinds()
  discard adoptPublished()
  result = newRegistry()
  if not present(SourceCatalog): return result

  # Every catalog of items, and the six facet catalogs beside each - read once
  # here rather than once per item down in the loop. This is the whole fix: the
  # number of host calls is now the number of rows there are, not the number of
  # rows times the number of items times thirteen.
  var bases: seq[Rows] = @[]
  var stacks: seq[Rows] = @[]
  var icons: seq[Rows] = @[]
  var foods: seq[Rows] = @[]
  var sats: seq[Rows] = @[]
  var armours: seq[Rows] = @[]
  var parts: seq[Rows] = @[]
  for row in entries(named(SourceCatalog)):
    if row.text != "items": continue
    if not present(row.id): continue
    bases.add readRows(row.id)
    stacks.add readRows(row.id & ".stack")
    icons.add readRows(row.id & IconFacet)
    foods.add readRows(row.id & FoodFacet)
    sats.add readRows(row.id & SaturationFacet)
    armours.add readRows(row.id & ArmourFacet)
    parts.add readRows(row.id & ArmourPartFacet)

  # The items, catalog by catalog and row by row - which is the order
  # `publishedItems()` hands them back in, and it is walked here instead
  # because the ids are already read and that walk deduplicated by comparing
  # each id against every id it had already seen.
  var k = 0
  while k < bases.len:
    var j = 0
    while j < rowCount(bases[k]):
      let id = bases[k].names.ids[j]
      # Only the row that wins. A catalog holding an id twice is settled the
      # way `find` settled it - the last row - and this is that row when it is.
      if rowAt(bases[k], id) != j:
        j = j + 1
        continue
      var d = unknownItem(id)
      # `display` and `known` came from `itemOf`, which found the same row this
      # already has by walking six catalogs to get there. The display name IS
      # the base catalog's text for the row.
      d.known = true
      d.display = catalogText(bases[k].catalog, j)
      if d.display.len == 0: d.display = id
      # An inventory library's stack size defaults to one, which is right for a
      # rifle and wrong for a block. So the number is taken only when the
      # catalog actually holds one, and anything that never said stacks to
      # sixty four - otherwise every block a voxel mod registered through the
      # plain builder would be one to a slot.
      d.stack = rowInteger(stacks[k], id, 0)
      if d.stack < 1: d.stack = 64
      d.icon = rowText(icons[k], id, "")
      d.food = rowInteger(foods[k], id, 0)
      d.saturation = rowNumber(sats[k], id, 0.0)
      d.armour = rowInteger(armours[k], id, 0)
      d.part = partNamed(rowText(parts[k], id, ""))
      # A later catalog's definition replaces an earlier one, which is the rule
      # the walk this replaced arrived at by letting the last `base` win.
      define(result, d)
      j = j + 1
    k = k + 1

## Every recipe anybody published, in the order the catalogs were published, so
## a modpack that wants to replace a dependency's recipe publishes its own
## after it. A row that does not spell a recipe is logged once and left out.
proc loadRecipes*(): seq[Recipe] =
  declareHudKinds()
  result = @[]
  if not present(RecipeSources): return result
  for source in entries(named(RecipeSources)):
    if source.text != "recipes": continue
    if not present(source.id): continue
    for row in entries(named(source.id)):
      let r = parseRecipe(row.id, row.text)
      if usable(r): result.add r
      else: log("aoughwl.hud: " & row.id & " is not a recipe: " & r.problem)

## How many catalogs of recipes have been published, for a HUD that wants to
## say so out loud rather than count them itself.
proc recipeCatalogCount*(): int =
  result = 0
  if not present(RecipeSources): return result
  for row in entries(named(RecipeSources)):
    if row.text == "recipes": result = result + 1
