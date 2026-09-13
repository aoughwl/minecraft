## Minecraft, imported from the copy the player already owns.
##
## This game ships nothing of Mojang's, and never will. The player grants their
## own `.minecraft` folder in `imports.txt`, this mod finds the version jar in
## it, and the host copies what it needs out of that jar into this mod's own
## folder. From there they are ordinary content: catalogs of parts whose
## references read `minecraft://blockstate/oak_stairs`, resolved at spawn time by
## `resolvePart` below.
##
## Nothing imported is ever committed, and nothing imported leaves this
## machine. What is in this repository is the reader.
##
## ## Where the work is
##
## Almost none of it is here. `main.nim` is the host seam - keys, the import
## plan, the catalogs, the panel - and everything that is hard to get right
## lives next door, in files that call no host at all and are proved by
## `Tests/minecraft_test.exe` in about a second:
##
##   `mcjson.nim`    JSON as a flat arena, one per document, so a whole parent
##                   chain is readable at once
##   `mcmodel.nim`   parent inheritance, `#variable` resolution, element and
##                   face rotation, Minecraft's own default-uv derivation, and
##                   the full-cube test a chunk mesher needs
##   `mcstate.nim`   blockstates: `variants`, `multipart`, `x`/`y` rotation and
##                   `uvlock`
##   `mcitem.nim`    item models, `builtin/generated` and `builtin/entity`
##   `mcpack.nim`    resource packs stacked over the jar, and `options.txt`
##   `mcanim.nim`    the `.mcmeta` animation schedule
##   `mctint.nim`    the biome tint, so grass is not grey
##   `mcrecipe.nim`  shaped and shapeless recipes
##   `mcpng.nim`     PNG in and out, and base64, for block-sized pictures only
##   `mcatlas.nim`   several pictures into one sheet, because a mesh has one
##                   material
##
## ## What arrives
##
## | catalog | kind | value |
## | --- | --- | --- |
## | `minecraft.blocks` | `aoughwl.part` | `minecraft://blockstate/<name>` |
## | `minecraft.items` | `aoughwl.part` | `minecraft://item/<name>` |
## | `voxel.blocks` | `aoughwl.block` | `label=..;opaque=..;texture=..` |
## | `voxel.blocks.atlas` | `aoughwl.block.atlas` | six whole pictures, `\|` separated, as `published:` names |
## | `minecraft.inventory` + 10 facets | `aoughwl.item`, `aoughwl.hud.*` | one item definition |
## | `minecraft.recipes` | `aoughwl.hud.recipe` | `shaped|2x3|aa/aa/.b|a=oak_planks,b=stick|oak_door*3` |
## | `minecraft.animations` | `aoughwl.animation` | `frametime=..;frames=..` |
##
## The first two and the last are this mod's own. The other three belong to
## `aoughwl.voxel`, `aoughwl.inventory`/`aoughwl.grid` and
## `aoughwl.hud`; their kinds are **not** declared here, because declaring
## a kind somebody else owns raises inside the host. This mod polls for their
## catalogs and fills them when they turn up, and works without them.
##
## A reference may name a state - `minecraft://blockstate/oak_stairs[facing=east,half=top]`
## - and every state a blockstate file defines resolves whether or not it is in
## the catalog, because a catalog with every state of every block in it would be
## tens of thousands of rows nobody reads. The catalog holds one row a block, at
## its default state; a chunk mesher asks for the rest by name.
##
## Keys: M imports, R starts over, K takes the import back, B shows or hides
## the panel.
##
## The panel is news rather than state: it is up while an import is running and
## for `mcpanel.Linger` seconds after the last thing this mod said, and down the
## rest of the time. It used to be up always, which in `minecraft` -
## where this mod is a skin for somebody else's world and not the screen - meant
## four keys' worth of legend drawn across the top of the game for ever.

import jester
import importing
import textures
import mcjson
import mclangassets
import mcmodel
import mcstate
import mcitem
import mcplan
import mcpack
import mcanim
import mctint
import mcrecipe
import mcpng
import mcatlas
import mcgui
import mcpanel
import services

const
  Fingerprint = "versions"
  Extracted = "Imported"
  Scheme = "minecraft"

  TargetVersion = "1.21.11"
    ## The Minecraft this game is built against, and the version this importer
    ## asks for by name before it falls back to the newest one installed.
    ##
    ## **It is not a preference about assets.** `aoughwl.mcnet` speaks
    ## protocol 774 - `netproto.ProtocolVersion`, read out of this version's own
    ## `version.json` - because 774 is the newest wire with a machine-readable
    ## packet profile behind it, and 26.2 publishes no obfuscation mappings at
    ## all. A block set taken out of a *different* version and handed to a 774
    ## client is two halves of two different games. So the assets and the
    ## protocol are one choice, made once, written down here, and the picker is
    ## told about it rather than left guessing from version numbers.
    ##
    ## A player who wants a different one says so: `remember("target", ...)` is
    ## what a settings screen or a hand-edited save writes, and an empty value
    ## there means "newest with a jar in it", which is the rule that was here
    ## before anything else in this game had an opinion.
    ##
    ## When this version is not installed the old rule answers and the log says
    ## so. Refusing to import because one folder is missing would be worse than
    ## importing what is there and naming it.

  # What is pulled out of the jar. Every one of these is a glob the host walks
  # once; `recipe*.json` catches both `data/minecraft/recipes/` (before 1.21)
  # and `data/minecraft/recipe/` (after), which is a rename and not a choice.
  ModelsIn = "assets/minecraft/models/block/*.json"
  TexturesIn = "assets/minecraft/textures/block/*.png"
  StatesIn = "assets/minecraft/blockstates/*.json"
  ItemModelsIn = "assets/minecraft/models/item/*.json"
  # Where an item says which model it is, from 1.21.4 on. Before that every
  # item had a `models/item/<name>.json` of its own and this folder did not
  # exist; both jars measured here are past that line and 266 of 26.2's items -
  # every block item - have no model file at all. Nothing chooses between the
  # two by version: the glob runs either way, finds nothing on an old jar, and
  # `itemModelRef` below looks for the file before it trusts it. See
  # `mcitem.nim`.
  ItemDefsIn = "assets/minecraft/items/*.json"
  ItemTexturesIn = "assets/minecraft/textures/item/*.png"
  MetaIn = "assets/minecraft/textures/*.mcmeta"
  RecipesIn = "data/minecraft/recipe*.json"
  OptionsIn = "options.txt"
  PackIn = "assets/*"
  # What the interface is made of. `aoughwl.mcui` draws Minecraft's own
  # title screen and ships none of it, so every pixel and every word on that
  # screen comes out of the player's own copy through here. One glob each,
  # appended to the plan so the steps already numbered below do not move.
  GuiIn = "assets/minecraft/textures/gui/*"
  FontIn = "assets/minecraft/textures/font/*"
  LangIn = "assets/minecraft/lang/*"
  TextsIn = "assets/minecraft/texts/*"
  EnvironmentIn = "assets/minecraft/textures/environment/*"
    ## The sky: the sun, the eight moon phases on one sheet, the clouds, the
    ## rain and the snow. Four or five small PNGs, and the only pictures in the
    ## whole install that are not of a block, an item or a widget.

  OptionsFile = "Imported/options.txt"
  LangCache = "Imported/lang.cache"
  BlockIndex = "Imported/blocks.txt"
  StateIndex = "Imported/blockstates.txt"
  ItemIndex = "Imported/items.txt"
  RecipeIndex = "Imported/recipes.txt"
  IconFile = "pack.png"
  StudioFile = "Imported/aoughwlstudios.png"
    ## What a jar and a resource pack both call their own picture, at the root
    ## of each rather than under `assets/`.
  MetaIndex = "Imported/animated.txt"
  PackIndex = "Imported/packs.txt"
  Newline = char(10)
    ## Spelled once, as a character, because the two places that write a line
    ## and the one that reads it back character by character have to agree that
    ## it is one character and not an escape.

  PlanReceipt = "Imported/plan.txt"
    ## Where the import plan had got to, written beside the files it wrote.
    ##
    ## `startPlan` remembers its cursor in the player's saved state, which is
    ## the right place for a fact about the player and the wrong one for a fact
    ## about a folder. The two come apart the moment a build ships: `Imported/`
    ## is not committed and a fresh `builds/windows` has none of it, while the
    ## saved state in the player's own profile still says step 17. The plan then
    ## resumed at the last step, copied one `version.json`, and called itself
    ## done - five hundred and sixty interface pictures on disk, no blockstates,
    ## no block models, and a voxel world with only the twelve built-in blocks
    ## in it. The percentage went up the whole time, which is exactly why it
    ## read as an import that had worked.
    ##
    ## So the cursor is written where the files are as well, and the remembered
    ## one is believed only when this file agrees with it. A wiped folder has no
    ## receipt and starts over; a receipt naming a different jar starts over;
    ## and finishing an interrupted import is still cheap either way, because
    ## the extractor skips a file already there at the size it should be.

  Blocks = "minecraft.blocks"
  Items = "minecraft.items"
  Recipes = "minecraft.recipes"
  Animations = "minecraft.animations"
  PartKind = "aoughwl.part"

  # ---- what other mods own ------------------------------------------------
  #
  # Every name below is somebody else's, copied from the file that owns it, and
  # **nothing here declares any of their kinds.** `defineCatalogKind` on a kind
  # another mod already owns does not answer no - it raises inside the host and
  # takes the calling mod's interpreter slot with it - and `aoughwl.voxel`
  # and `aoughwl.hud` both declare theirs unconditionally in their own
  # `start()`. So this mod waits: it polls for the catalog its rows belong in,
  # and fills it when the mod that owns it has arrived. If neither ever does,
  # `minecraft.blocks` and `minecraft.items` are still there and still spawn,
  # which is what this importer is for.
  #
  # `aoughwl.voxel/main.nim`
  VoxelBlocks = "voxel.blocks"
  AtlasFacet = ".atlas"
  ## The third facet of that catalog: the pictures a block wears while it is
  ## being broken, in order, `|` separated. `aoughwl.voxel` declares it and
  ## reads the first row of it for any block that has none of its own, which is
  ## what lets ten pictures dress a whole world out of one row.
  WearFacet = ".wear"
  CrackReference = "block/destroy_stage_"
  CrackStages = 10
    ## `destroy_stage_0` .. `destroy_stage_9`. Ten because that is how many the
    ## game has; a pack with fewer is the voxel side's problem and it handles
    ## one, but this reads the jar and the jar has ten.
  TilesFacet = ".tiles"
  # `aoughwl.hud/huditems.nim`
  HudRecipeSources = "aoughwl.hud.recipes"
  HudRecipeKind = "aoughwl.hud.recipe"
  HudIconKind = "aoughwl.hud.icon"
  HudFoodKind = "aoughwl.hud.food"
  HudSaturationKind = "aoughwl.hud.saturation"
  HudArmourKind = "aoughwl.hud.armour"
  HudArmourPartKind = "aoughwl.hud.armourpart"
  IconFacet = ".icon"
  FoodFacet = ".food"
  SaturationFacet = ".saturation"
  ArmourFacet = ".armour"
  ArmourPartFacet = ".armourpart"
  # `aoughwl.inventory/inventory.nim`
  ItemKind = "aoughwl.item"
  ItemStackKind = "aoughwl.item.stack"
  ItemBulkKind = "aoughwl.item.bulk"
  ItemWeightKind = "aoughwl.item.weight"
  ItemShapeKind = "aoughwl.item.shape"
  ItemTagKind = "aoughwl.item.tags"
  StackFacet = ".stack"
  BulkFacet = ".bulk"
  WeightFacet = ".weight"
  ShapeFacet = ".shape"
  TagFacet = ".tags"
  # `aoughwl.grid/gridspace.nim`
  InventorySources = "aoughwl.inventory.sources"

  # This mod's own, and the only kind it declares. Nothing else in the tree
  # names it.
  AnimationKind = "aoughwl.animation"

  Inventory = "minecraft.inventory"

  # How much of the background pass to do in one frame. The pass reads text
  # files and parses them; nothing in it touches a picture, so it is cheap, and
  # it is budgeted anyway because an import is two thousand files and a frame is
  # sixteen milliseconds.
  RecipeBudget = 6
  # Model/blockstate baking is the expensive pass. One block per update keeps
  # the standalone loading screen repaintable while the catalog is filled.
  StateBudget = 1
  HudRowsBudget = 32
  PublishRowsBudget = 32
  MetaBudget = 8
  IconBudget = 4
    ## Icons are the one step of the pass that *does* touch a picture - it walks
    ## the model chain and offers the texture at the end of it under a public
    ## name - so it gets the smallest budget of the five. Fifteen hundred items
    ## at four a frame is about six seconds of a game that is already running,
    ## and until an item's turn comes its inventory row wears the swatch it has
    ## always worn.
  PackRowsPerPump = 8
    ## A resource-pack folder may answer with every file below every unpacked
    ## pack. Reading all those names after the asynchronous scan completed used
    ## to turn one update into a multi-second freeze.
  MinPackRowsPerPump = 1
  SlowPackFrameMs = 20
  FastPackFrameMs = 10
  # There is no budget on how many blocks are dressed, and there used not to be
  # a `there is no budget` comment either. It is here because there *was* one -
  # 64 blocks - and it existed only because a catalog row had to carry the
  # picture as base64, which made the cost quadratic. A row now carries a
  # `published:` name, so the whole pack is affordable and the cap is gone.

  GuiService = "minecraft.gui"
    ## The one question other mods ask this one about the interface: the font's
    ## measurements, a language file, the splashes, which version this is. The
    ## pictures do not come through here - they are `published:` names, which
    ## cost the length of a name rather than the size of a picture.

var
  root = ""
  jarPath = ""
  ask = AskNothing        ## what B last said, and it beats the rule below
  saidAt = -1000.0        ## when this mod last said anything, on the game clock
  lines: seq[string]
  names: seq[string]        ## block model names, for the older `block/` scheme
  stateNames: seq[string]   ## blockstate file names - the blocks themselves
  itemNames: seq[string]
  recipeNames: seq[string]
  metaNames: seq[string]    ## textures with a `.mcmeta` beside them
  packNames: seq[string]
  layers = noLayers()
  published = false
  publishInitialized = false
  publishBlockAt = 0
  publishItemAt = 0
  ledgerNoted = false
  running = false
  recipeAt = 0
  stateAt = 0
  metaAt = 0
  iconAt = 0
  iconCount = 0
  hudFilled = false
  hudStarted = false
  hudAt = 0
  animatedSeen: seq[string]

  # How many face pictures have gone out under a public name. A name is stable
  # across the layer stack - the file behind `block/stone` may be the jar's or a
  # resource pack's, and the name does not care - so the same name may be
  # offered more than once and this counts offers, not distinct pictures.
  pictureCount = 0
  dressedCount = 0
  # Whether the ten break-stage pictures have been offered yet. One row, once,
  # and retried each frame until the facet it goes in exists.
  cracksDressed = false

  # The interface half. `guiCount` is how many pictures went out under public
  # names; `fontLine` is the 256 column measurements, "-" once the sheet has
  # been looked for and not found, and "" while it has not been looked for.
  guiPublished = false
  guiCount = 0
  guiSizes = ""
    ## One line a picture - `<published name><TAB><width><TAB><height>` - for
    ## the pictures the interface has to be laid out *in*. `mcui` has no PNG
    ## reader and there is no host call that asks a picture its size, so this
    ## is the seam, the same one the font's measurements come over.
  fontRowReady = false
  fontMeasured = ""

  # Which Minecraft, and whether the player's packs fit it.
  jarEntries: seq[string] = @[]   ## every `versions/<v>/<v>.jar` the scan found
  jarVersion = ""                 ## the folder name of the one chosen
  jarFormat = 0                   ## the resource-pack format that jar speaks
  jarSearched = false             ## the look has happened, whatever it found
  fitLine = ""                    ## a pack that does not cover this jar
  fitChecked = false
  finding = 0
    ## The scan of `versions/`, in flight. Declared here rather than beside
    ## `lookForJar` because the state machine that reports what is going on -
    ## `stateWord` - has to know whether the look is still running, and it is
    ## spelled next to the drawing rather than next to the scanning.

proc note(text: string) =
  lines.add text
  log("[minecraft] " & text)
  # Something was said, so the panel is worth looking at again - and the key,
  # whichever way it was last pressed, stops applying to a screen that has
  # changed under it.
  saidAt = gameTime()
  ask = AskNothing
  if lines.len > 12:
    var i = 0
    while i + 1 < lines.len:
      let next = lines[i + 1]
      lines[i] = next
      inc i
    lines.setLen(lines.len - 1)

# ---------------------------------------------------------------------------
# The layer stack
#
# Every read of an imported file goes through `find`, which walks the stack the
# player's own `options.txt` described and answers with the first layer that has
# the file. A pack that replaced `stone.png` and nothing else replaces exactly
# that, and a model a pack replaced changes the parent chain underneath it,
# because the chain is walked through `find` too.

proc rebuildLayers() =
  layers = noLayers()
  var i = 0
  while i < packNames.len:
    discard addLayer(layers, packFolder(Extracted, packNames[i]), packNames[i])
    inc i
  discard addLayer(layers, Extracted, "the jar")

## Where a resource is, or "" when no layer has it.
proc find(namespace, path: string): string =
  let where = candidates(layers, namespace, path)
  var i = 0
  while i < where.len:
    if importHas(where[i]): return where[i]
    inc i
  ""

proc modelFile(reference: string): string =
  find(namespaceOf(reference), "models/" & resourcePath(reference) & ".json")

proc textureFile(reference: string): string =
  find(namespaceOf(reference), "textures/" & resourcePath(reference) & ".png")

proc stateFile(name: string): string =
  find(namespaceOf(name), "blockstates/" & resourcePath(name) & ".json")

proc itemDefFile(name: string): string =
  find(namespaceOf(name), itemDefinitionPath(name))

# ---------------------------------------------------------------------------
# Reading what was extracted

## A file in this mod's folder as bytes. `importRead` is the wrong door for a
## PNG: it answers with text, and text is UTF-8, which mangles every byte over
## 127.
##
## This used to go through `modelBytes`, which opens **only inside a scheme
## resolver** - and that one fact shaped the whole file. Every picture had to be
## read at spawn time, and anything that wanted bytes outside a spawn had to
## invent a part nobody wanted purely to be resolving while it read. `importing`
## now has its own byte door, open wherever this mod is, held to the same folder
## boundary by the same check. So there is no trick here any more: a file in
## this mod's folder reads as bytes because it is this mod's folder.
##
## Four bytes a call rather than one. A 64x pack's font sheet is twenty-one
## thousand bytes and every one of them used to be its own trip across the host
## boundary; a word at a time is the same bytes for a quarter of the trips. The
## tail is read singly because a word may not run off the end.
proc bytesOf(path: string; problem: var string): seq[int] =
  result = @[]
  if path.len == 0 or not importHas(path):
    problem = "'" & path & "' was not imported"
    return result
  let handle = readBytes(path)
  if handle == 0:
    problem = "'" & path & "' would not read: " & importProblem()
    return result
  let count = byteCount(handle)
  if count <= 0:
    problem = "'" & path & "' is empty"
    closeBytes(handle)
    return result
  var i = 0
  let whole = count - (count mod 4)
  while i < whole:
    let word = uint32At(handle, i)
    result.add word mod 256
    result.add (word div 256) mod 256
    result.add (word div 65536) mod 256
    result.add (word div 16777216) mod 256
    i = i + 4
  while i < count:
    result.add byteAt(handle, i)
    inc i
  closeBytes(handle)

## A JSON document out of the layer stack, parsed. An empty `problem` and a
## root of -1 mean the file was simply not there, which is a normal answer.
proc readJson(path: string; problem: var string): Json =
  result = parseJson("")
  if path.len == 0: return result
  let body = importRead(path)
  if body.len == 0:
    problem = "'" & path & "' would not read: " & importProblem()
    return result
  result = parseJson(body)
  if result.problem.len > 0:
    problem = leaf(path) & ": " & result.problem

## The whole parent chain of a model, child first. It stops at the top, at a
## `builtin/`, at a parent no layer has - an item model, most often - or at
## `MaxChain`, and every one of those is a normal ending rather than a failure:
## what has been collected by then is what the model is.
proc chainOf(path: string; problem: var string): seq[Json] =
  result = @[]
  var want = path
  var depth = 0
  while depth < MaxChain:
    let file = modelFile(want)
    if file.len == 0:
      if depth == 0:
        problem = "'" & want & "' is not among the models that were imported"
      return result
    var why = ""
    let doc = readJson(file, why)
    if why.len > 0:
      if depth == 0: problem = why
      return result
    result.add doc
    let parent = parentOf(doc)
    if parent.len == 0 or isBuiltin(parent): return result
    let next = resourcePath(parent)
    if next == want: return result   # a model that is its own parent
    want = next
    inc depth
  problem = "'" & path & "' has a parent chain more than " & $MaxChain & " deep"

## Every model in a chain's `textures`, merged child-first.
proc paletteOf(docs: seq[Json]): Textures =
  result = Textures(keys: @[], vals: @[])
  var i = 0
  while i < docs.len:
    absorb(result, docs[i])
    inc i

## One model, resolved and baked, with nothing turned yet.
proc bakeModel(path: string; problem: var string): Bake =
  result = emptyBake()
  let docs = chainOf(path, problem)
  if problem.len > 0 or docs.len == 0: return result
  let t = paletteOf(docs)
  let layer = geometryLayer(docs)
  if layer < 0:
    # No elements anywhere in the chain. It may still be an item.
    let kind = classifyItem(docs)
    if kind == ItemGenerated:
      return bakeGenerated(layersOf(t))
    if kind == ItemEntity:
      problem = "Minecraft draws this one itself; there is no model to read"
      return result
    problem = "no model in its chain has any elements"
    return result
  bakeElements(docs[layer], member(docs[layer], docs[layer].root, "elements"), t)

# ---------------------------------------------------------------------------
# The scheme
#
# Three shapes of reference, all resolved into one mesh and one sheet:
#
#   minecraft://block/stone                     one model file, as it is written
#   minecraft://blockstate/oak_stairs           a block, at its default state
#   minecraft://blockstate/oak_stairs[facing=east,half=top]
#   minecraft://item/apple                      an item, flat or as its block

## Split `blockstate/oak_stairs[facing=east]` into its three parts.
proc splitRef(want: string; kind, name, state: var string) =
  kind = ""
  name = ""
  state = ""
  var at = 0
  while at < want.len and want[at] != '/':
    kind.add want[at]
    inc at
  inc at
  var inState = false
  while at < want.len:
    let c = want[at]
    inc at
    if c == '[':
      inState = true
      continue
    if c == ']': continue
    if inState: state.add c
    else: name.add c

## Publish what a picture's own `.mcmeta` says, now that the picture has been
## decoded and the strip's length is finally known. Nothing else in this mod can
## learn that: the `.mcmeta` alone does not say how many frames the file has,
## and counting them needs the PNG, which needs a request.
proc noteAnimation(reference, file: string; strip: int) =
  var i = 0
  while i < animatedSeen.len:
    if animatedSeen[i] == reference: return
    inc i
  animatedSeen.add reference
  var why = ""
  let doc = readJson(metaPathOf(file), why)
  let a = readAnimation(doc, strip)
  addToCatalog(Animations, resourcePath(reference),
    "frames=" & $strip & ";steps=" & $stepCount(a) &
    ";frametime=" & $a.frametime & ";ticks=" & $loopTicks(a) &
    ";interpolate=" & (if a.interpolate: "true" else: "false"))

## Turn a finished bake into a mesh and a sheet. Every picture the bake names is
## found in the layer stack, decoded, tinted if a face asked for a tint, and
## packed into one padded sheet; every face's uv is moved into its own tile.
proc dress(b: Bake; model: string) =
  let wanted = palette(b)
  var tiles: seq[Image] = @[]
  var missing = 0
  var frames = 0
  var i = 0
  while i < wanted.len:
    let file = textureFile(wanted[i])
    var why = ""
    let bytes = bytesOf(file, why)
    if why.len > 0:
      note(model & ": " & why)
      inc missing
      tiles.add solidTile()
    else:
      var img = decodePng(bytes)
      if img.problem.len > 0:
        note(model & ": " & leaf(wanted[i]) & ".png: " & img.problem)
        inc missing
        tiles.add solidTile()
      else:
        let n = frameCount(img)
        if n > 1:
          frames = frames + 1
          noteAnimation(wanted[i], file, n)
        tiles.add img
    inc i

  # The tint, applied to the tile rather than to the face, because a mesh has
  # one material and no vertex colours. `mctint` says why that is right.
  var clash = ""
  let tints = tintOfTiles(b, wanted, model, clash)
  if clash.len > 0: note(model & ": " & clash)
  i = 0
  while i < tiles.len and i < tints.len:
    if tints[i] != NoTint: applyTint(tiles[i], tints[i])
    inc i

  if frames > 0:
    note(model & ": " & $frames & " of its textures are animated; frame 0 is used")

  var sheet = emptyAtlas()
  if tiles.len > 0:
    sheet = buildAtlas(tiles)
    if sheet.problem.len > 0: note(model & ": " & sheet.problem)

  beginMesh()
  var f = 0
  while f < b.count:
    let tile = tileOf(b, f, wanted)
    var index: array[4, int] = [0, 0, 0, 0]
    var c = 0
    while c < 4:
      var u = b.uv[f * 8 + c * 2]
      var v = b.uv[f * 8 + c * 2 + 1]
      if sheet.columns > 0:
        var ou = 0.0
        var ov = 0.0
        remap(sheet, tile, u, v, ou, ov)
        u = ou
        v = ov
      index[c] = addVertex(
        b.pos[f * 12 + c * 3], b.pos[f * 12 + c * 3 + 1], b.pos[f * 12 + c * 3 + 2],
        b.norm[f * 3], b.norm[f * 3 + 1], b.norm[f * 3 + 2], u, v)
      inc c
    addQuad(index[0], index[1], index[2], index[3])
    inc f
  finishMesh()

  if sheet.columns > 0 and missing < wanted.len:
    useTexture(dataUri(encodePng(sheet.image)))

## A block, at a state: every placement its blockstate names, each one baked,
## turned and joined into the one mesh.
proc bakeState(name, state: string; problem: var string): Bake =
  result = emptyBake()
  let file = stateFile(name)
  if file.len == 0:
    problem = "'" & name & "' has no blockstate among what was imported"
    return result
  var why = ""
  let doc = readJson(file, why)
  if why.len > 0:
    problem = why
    return result
  let bs = parseBlockState(doc)
  if bs.problem.len > 0:
    problem = leaf(name) & ": " & bs.problem
    return result
  var want = state
  if want.len == 0: want = defaultState(bs)
  let picks = placementsFor(bs, want)
  if picks.len == 0:
    problem = "'" & name & "' has no variant for [" & want & "]"
    return result
  var i = 0
  while i < picks.len:
    let pick = picks[i]
    inc i
    # Several placements under one variant key are Minecraft's weighted random
    # scatter. One shape is picked, and it is picked the same way every time so
    # that a block does not change its mind when it is looked at twice.
    let p = bs.place[pick]
    var piece = bakeModel(p.model, problem)
    if piece.count > 0:
      applyPlacement(piece, p)
      merge(result, piece)
  if result.count == 0 and result.problem.len == 0:
    result.problem = "every part of this block failed to bake"

# ---------------------------------------------------------------------------
# Dressing a voxel world: whole pictures, one per face
#
# `aoughwl.voxel` meshes a chunk by material and merges a run of identical
# faces into one quad. Whether it *may* merge is decided by whether the picture
# is packed: a whole picture has nothing next door and the host decodes every
# texture with `wrapMode = TextureWrapMode.Repeat`, so a `u` of sixteen is that
# picture sixteen times and sixteen blocks are one quad. A tile inside a padded
# sheet cannot do that - a `u` past the slot is the neighbour, which is what the
# padding exists to prevent - so a sheet forces one quad per block face.
#
# That was measured rather than guessed, on the same twenty frames of the same
# world: a shared sheet is 45 meshes and 52,009 host crossings; whole pictures
# are 75 meshes and 4,769. A mesh costs about five crossings and so does a quad,
# so the thirty extra meshes never had a chance of paying for the thirteen
# thousand extra quads. **This importer publishes whole pictures.** `mcatlas`
# still packs a sheet, correctly, for the one-mesh-one-material case a *part*
# is; it is simply the wrong shape to hand a chunk mesher.
#
# The row is up to six picture uris separated by `|`, in the world's own face
# order, and **no `voxel.blocks.tiles` row beside it** - the absence is the
# signal, and it reads the way somebody filling the rows would expect: if you
# did not say how your picture is packed, it is not packed.
#
# ## Nothing is decoded, and nothing is copied
#
# `publishPicture` offers a file of this mod's own under a public name, and
# `published:<mod>/<name>` is a uri anything that takes a uri accepts. So a
# block's face is a *name*, twenty-odd characters, and the picture stays the PNG
# on disk that the import already wrote. There is no decode, no base64, no part
# request and no budget: the five-megabyte cap that used to exist did so only
# because a catalog row had to carry the pixels, and it does not any more. A
# whole resource pack at 64x is affordable, which at 16x it also was and at 16x
# nobody would have noticed the difference.

const ModId = "aoughwl.minecraft"
  ## This mod's own id, as `mod.json` spells it, for naming its own published
  ## pictures. Its own - it is never used to recognise anybody else.

## The public name a texture is offered under: its resource path, so the name is
## stable whichever layer of the pack stack the file came from.
## The public name a texture is offered under, published.
##
## `file` is passed in rather than looked up, because the caller has just looked
## it up to ask whether the face was animated and finding it again is a walk
## down the whole layer stack for an answer already in hand.
##
## Nothing is remembered about which references have been offered before, and
## that is the point. This used to keep two parallel arrays and scan them, which
## is a linear scan inside a loop over every face of every block - seven
## thousand lookups against a list that grows to fifteen hundred, in an
## interpreter, on the frames a player is waiting to see a menu. A row is a
## claim and a mod restating its own claim now replaces it where it stands, so
## offering the same picture twice is the host writing the same thing down
## twice: cheap, and exactly as true the second time.
proc publishFace(reference, file: string): string =
  if file.len == 0: return ""
  let public = resourcePath(reference)
  publishPicture(public, file)
  inc pictureCount
  pictureUri(ModId, public)

## Whether a texture is a vertical strip of frames, from the `.mcmeta` beside it
## rather than from the picture. The picture could be opened now, and is not:
## a strip is a hundred and twenty-eight kilobytes at 64x and the answer wanted
## here is one bit, which the file beside it already carries.
##
## A strip published whole would arrive squeezed onto one face, so a block with
## one on it is left undressed and keeps its flat colour. That is fire, water,
## lava and about ninety others, and a still blue cube is a better answer than a
## column of thirty-two frames stretched over a block.
proc animatedFace(file: string): bool =
  if file.len == 0: return false
  importHas(metaPathOf(file))

## One block's six faces, published, as the row a voxel world wears.
##
## All six or none. A hole in the row would be read as a picture called nothing,
## and a block with an animated face or a texture no layer has keeps the flat
## colour it already had - which is the path every block took before any of this
## existed and still works.
proc dressBlock(name: string; b: Bake) =
  if b.count == 0: return
  if catalogSignature(VoxelBlocks & AtlasFacet).len == 0: return
  var uri: array[6, string] = ["", "", "", "", "", ""]
  var w = 0
  while w < 6:
    let f = worldFace(b, w)
    if f < 0 or b.texture[f].len == 0:
      # No face pointing that way. Repeat the one before it, which is what the
      # reader does with a short row anyway.
      if w > 0: uri[w] = uri[w - 1]
    else:
      # One walk down the layer stack for this face, not two: which file answers
      # for the texture settles both whether it is a strip and what is published.
      let file = textureFile(b.texture[f])
      if file.len == 0: return
      if animatedFace(file): return
      uri[w] = publishFace(b.texture[f], file)
      if uri[w].len == 0: return
    inc w
  # A leading gap - a model with no `down` face, say - is filled from the first
  # face that had one, so the row is six whole pictures or it is not published.
  var first = ""
  w = 0
  while w < 6:
    if uri[w].len > 0:
      first = uri[w]
      break
    inc w
  if first.len == 0: return
  w = 0
  while w < 6:
    if uri[w].len == 0: uri[w] = first
    inc w
  if not facesWhole(uri): return
  addToCatalog(VoxelBlocks & AtlasFacet, name, facesRow(uri))
  inc dressedCount

# ---------------------------------------------------------------------------
# What the interface is made of
#
# `aoughwl.mcui` draws Minecraft's own title screen: its dirt, its logo,
# its buttons, its font, and its words in the player's own language. It reaches
# none of that itself. It has no jar, no layer stack and no PNG decoder, and
# growing it any of the three would be a second reader of the same format,
# which is how two readers start disagreeing about a pack.
#
# So there are exactly two doors, and both were already in the surface.
#
# **The pictures go out as names.** `publishPicture` puts a public name against
# a file inside THIS mod's folder; anybody may then spell
# `published:aoughwl.minecraft/gui/widgets` at `drawImage`, and the host
# resolves it here. No path crosses, nothing is copied, and a row costs the
# length of a name instead of the size of a picture. The file each name points
# at is whatever `find` answered - so a resource pack that replaced
# `widgets.png` and nothing else replaces exactly that, and the jar answers for
# the rest, key by key, which is the layering this mod already does for blocks.
#
# **Everything that is not a picture goes out as one service.** The font's
# measurements, a language file, the splashes, which version was chosen, how far
# the reading has got, and whether the player's packs fit it. Text in, text out;
# what the text means is between these two mods.

const
  # Two layouts, and which one an install has is decided by what is in it.
  #
  # Up to 1.20.1 the whole interface was one sheet, `gui/widgets.png`, and a
  # button was a rectangle in it. From 1.20.2 that file does not exist: every
  # widget is its own sprite under `gui/sprites/`, with a `.mcmeta` beside it
  # saying how it may be stretched. Both are published, under both sets of
  # names, and neither is assumed - `guiLayout()` below answers by asking the
  # layer stack which files are actually there, because a version number in a
  # folder name is exactly the kind of evidence that rots. This player's install
  # is 1.21.11 and 26.2, and neither has a `widgets.png` at all.
  GuiNames = ["gui/widgets", "gui/options_background", "gui/icons",
              "gui/title/minecraft", "gui/title/edition", "font/ascii",
              "block/dirt",
              "gui/sprites/widget/button",
              "gui/sprites/widget/button_highlighted",
              "gui/sprites/widget/button_disabled",
              "gui/title/panorama_overlay",
              # The studio logo the game opens on, before the title screen. It
              # is in both jars measured here and is published like everything
              # else - the loading screen used to draw the game's wordmark on
              # the red field because this was not offered, which is a different
              # picture wearing the right colour.
              "gui/title/mojangstudios",
              # The container screens. These two are still sheets in both jars
              # measured here - 26.2 and 1.21.11 - and a screen is a rectangle
              # blitted out of the top-left corner of one. Nothing decides that
              # by version: `publishGui` offers whatever `find` answered and
              # `hasPicture` on the drawing side decides what to draw, which is
              # the same rule the button already follows.
              "gui/container/inventory",
              "gui/container/crafting_table",
              # The container sprites, which are the modern half of the same
              # screen: a slot and the highlight over the one under the pointer.
              "gui/sprites/container/slot",
              "gui/sprites/container/slot_highlight_back",
              "gui/sprites/container/slot_highlight_front",
              # The HUD. `gui/icons.png` is gone from both jars here exactly as
              # `gui/widgets.png` is - a heart is `gui/sprites/hud/heart/full`
              # and there are forty-eight of them, of which a survival HUD wants
              # these. Both spellings are offered and neither is assumed.
              "gui/sprites/hud/hotbar",
              "gui/sprites/hud/hotbar_selection",
              "gui/sprites/hud/experience_bar_background",
              "gui/sprites/hud/experience_bar_progress",
              "gui/sprites/hud/heart/full",
              "gui/sprites/hud/heart/half",
              "gui/sprites/hud/heart/container",
              "gui/sprites/hud/food_full",
              "gui/sprites/hud/food_half",
              "gui/sprites/hud/food_empty",
              "gui/sprites/hud/armor_full",
              "gui/sprites/hud/armor_half",
              "gui/sprites/hud/armor_empty",
              "gui/sprites/hud/air",
              "gui/sprites/hud/air_empty",
              "gui/sprites/hud/crosshair"]
  GuiFiles = ["textures/gui/widgets.png",
              "textures/gui/options_background.png",
              "textures/gui/icons.png",
              "textures/gui/title/minecraft.png",
              "textures/gui/title/edition.png",
              "textures/font/ascii.png",
              "textures/block/dirt.png",
              "textures/gui/sprites/widget/button.png",
              "textures/gui/sprites/widget/button_highlighted.png",
              "textures/gui/sprites/widget/button_disabled.png",
              "textures/gui/title/background/panorama_overlay.png",
              "textures/gui/title/mojangstudios.png",
              "textures/gui/container/inventory.png",
              "textures/gui/container/crafting_table.png",
              "textures/gui/sprites/container/slot.png",
              "textures/gui/sprites/container/slot_highlight_back.png",
              "textures/gui/sprites/container/slot_highlight_front.png",
              "textures/gui/sprites/hud/hotbar.png",
              "textures/gui/sprites/hud/hotbar_selection.png",
              "textures/gui/sprites/hud/experience_bar_background.png",
              "textures/gui/sprites/hud/experience_bar_progress.png",
              "textures/gui/sprites/hud/heart/full.png",
              "textures/gui/sprites/hud/heart/half.png",
              "textures/gui/sprites/hud/heart/container.png",
              "textures/gui/sprites/hud/food_full.png",
              "textures/gui/sprites/hud/food_half.png",
              "textures/gui/sprites/hud/food_empty.png",
              "textures/gui/sprites/hud/armor_full.png",
              "textures/gui/sprites/hud/armor_half.png",
              "textures/gui/sprites/hud/armor_empty.png",
              "textures/gui/sprites/hud/air.png",
              "textures/gui/sprites/hud/air_empty.png",
              "textures/gui/sprites/hud/crosshair.png"]
  Panoramas = 6
    ## `panorama_0.png` .. `panorama_5.png`, the six faces of the sky box the
    ## title screen turns behind the menu.
  ModernMark = "textures/gui/sprites/widget/button.png"
  ClassicMark = "textures/gui/widgets.png"
  HudModernMark = "textures/gui/sprites/hud/hotbar.png"
  HudClassicMark = "textures/gui/icons.png"
    ## The HUD moved on its own schedule and it moved the same way: a heart used
    ## to be a rectangle in `gui/icons.png` and is now `hud/heart/full.png`.
    ## Asked of the files for the same reason the button is - on this machine
    ## both 26.2 and 1.21.11 have the sprites and neither has the sheet, and a
    ## version number would have said nothing about that.

  # The pictures whose *size* the interface has to be laid out in. A hotbar is
  # 182 by 22 and there is no host call that asks a picture how big it is, so
  # the size goes over the service with everything else that is not a picture.
  #
  # Read out of the **jar** and never out of a resource pack. A 64x pack's
  # `hotbar.png` measures 728 by 88 and the game still draws it 182 by 22,
  # because the size is in the blit and the picture is only stretched onto it.
  # Measuring the topmost layer would move every rectangle on the screen the
  # moment somebody turned a pack on.
  SizeNames = ["gui/sprites/hud/hotbar",
               "gui/sprites/hud/hotbar_selection",
               "gui/sprites/hud/experience_bar_background",
               "gui/sprites/hud/heart/full",
               "gui/sprites/hud/food_full",
               "gui/sprites/hud/armor_full",
               "gui/sprites/container/slot",
               "gui/sprites/container/slot_highlight_front",
               "gui/container/inventory",
               "gui/container/crafting_table",
               "gui/icons",
               "gui/widgets"]
  SizeFiles = ["textures/gui/sprites/hud/hotbar.png",
               "textures/gui/sprites/hud/hotbar_selection.png",
               "textures/gui/sprites/hud/experience_bar_background.png",
               "textures/gui/sprites/hud/heart/full.png",
               "textures/gui/sprites/hud/food_full.png",
               "textures/gui/sprites/hud/armor_full.png",
               "textures/gui/sprites/container/slot.png",
               "textures/gui/sprites/container/slot_highlight_front.png",
               "textures/gui/container/inventory.png",
               "textures/gui/container/crafting_table.png",
               "textures/gui/icons.png",
               "textures/gui/widgets.png"]

## Which interface layout this install has, asked of the files rather than of a
## version number. A pack may supply either over a jar with the other, and the
## answer is whichever the stack actually resolves - the sprite layout first,
## because a pack shipping both is a pack that means the modern one.
proc guiLayout(): string =
  if find("minecraft", ModernMark).len > 0: return "modern"
  if find("minecraft", ClassicMark).len > 0: return "classic"
  ""

## The picture this install wears, from the topmost layer that has one.
##
## Not through `find()`: that spells a resource as `assets/<namespace>/<path>`
## and this file is at the root of a layer, above `assets/`. The layer order is
## the same one - an enabled pack over the jar - so a player running Faithful
## gets Faithful's picture and a player running none gets Mojang's.
proc packPicture(): string =
  var i = 0
  while i < packNames.len:
    let where = packFolder(Extracted, packNames[i]) & "/" & IconFile
    if importHas(where): return where
    inc i
  let jar = Extracted & "/" & IconFile
  if importHas(jar): return jar
  ""

## Offer it under the name every mod's emblem is offered under.
##
## **This is how the taskbar gets the Minecraft icon**, and it is the whole of
## how: the host dresses the window of whatever project is running from
## `published:<one of its mods>/icon`, so a mod publishing its emblem is a mod
## saying what the desktop should call the thing it is part of. Nothing is
## shipped, nothing is copied into the game, and the picture is the player's
## own - out of the jar they granted, or out of the pack they turned on.
proc publishOwnIcon() =
  let emblem = packPicture()
  if emblem.len == 0:
    log("[assert] minecraft.icon=none")
    return
  publishIcon(emblem)
  note("this install's own " & IconFile & " is offered as this mod's icon")
  log("[assert] minecraft.icon=" & emblem)

## Which HUD layout this install has, asked of the files rather than of a
## version number - the same rule `guiLayout` follows for the widgets, and it
## has to be asked separately because the two moved on different schedules.
proc hudLayout(): string =
  if find("minecraft", HudModernMark).len > 0: return "sprites"
  if find("minecraft", HudClassicMark).len > 0: return "sheet"
  ""

## How big one picture is in the pixels the *game* lays out in, measured off the
## jar's own copy and not the topmost layer. "" when the jar has not got it.
##
## Twenty-four bytes matter and `pngSize` reads no further; nothing is decoded.
proc measureGui(name, path: string): string =
  let where = Extracted & "/assets/minecraft/" & path
  if not importHas(where): return ""
  var why = ""
  let bytes = bytesOf(where, why)
  if why.len > 0: return ""
  let size = pngSize(bytes)
  if size.len < 2: return ""
  sizeLine(name, size[0], size[1])

proc measureGuiSizes() =
  guiSizes = ""
  var i = 0
  var measured = 0
  while i < SizeNames.len:
    let line = measureGui(SizeNames[i], SizeFiles[i])
    if line.len > 0:
      guiSizes.add line
      inc measured
    inc i
  log("[assert] minecraft.gui.sizes=" & $measured)

## The sky's own pictures, by the names `aoughwl.sky` asks for. Kept apart
## from `GuiNames` because these are not interface: nothing measures them, a
## resource pack that replaces them replaces exactly these keys, and a modpack
## with no sky mod in it should not pay for them.
const
  SkyNames = ["environment/sun", "environment/moon_phases",
              "environment/clouds", "environment/rain", "environment/snow"]
  SkyFiles = ["textures/environment/sun.png",
              "textures/environment/moon_phases.png",
              "textures/environment/clouds.png",
              "textures/environment/rain.png",
              "textures/environment/snow.png"]

var
  skyPublished = false
  skyCount = 0

## Offer the sky's pictures under `published:aoughwl.minecraft/<name>`.
## The bytes stay the PNG on disk the import already wrote; what crosses is a
## name of twenty-odd characters. Nothing here is shipped and nothing here is
## decoded - the sun is the player's own sun.
proc publishSky() =
  if skyPublished and skyCount > 0: return
  skyPublished = true
  skyCount = 0
  var i = 0
  while i < SkyNames.len:
    let where = find("minecraft", SkyFiles[i])
    if where.len > 0:
      publishPicture(SkyNames[i], where)
      inc skyCount
    inc i
  if skyCount == 0:
    note("no sky pictures in this import; the sky will be a plain colour")
  else:
    note($skyCount & " sky pictures published as " &
      "published:aoughwl.minecraft/environment/<name>")
  log("[assert] minecraft.sky.pictures=" & $skyCount)

proc publishGui() =
  if guiPublished and guiCount > 0: return
  guiPublished = true
  guiCount = 0
  var i = 0
  while i < GuiNames.len:
    let where = find("minecraft", GuiFiles[i])
    if where.len > 0:
      publishPicture(GuiNames[i], where)
      inc guiCount
    inc i
  i = 0
  while i < Panoramas:
    let where = find("minecraft",
      "textures/gui/title/background/panorama_" & $i & ".png")
    if where.len > 0:
      publishPicture("gui/title/panorama_" & $i, where)
      inc guiCount
    inc i
  # The loading identity is Jester's own studio mark, kept as a separate
  # authored asset so a Minecraft jar or resource pack can never replace it.
  if importHas(StudioFile):
    publishPicture("gui/title/aoughwlstudios", StudioFile)
    inc guiCount
  if guiCount == 0:
    note("no interface pictures in this import; nothing published")
  else:
    note($guiCount & " interface pictures published as " &
      "published:aoughwl.minecraft/<name>")
    let layout = guiLayout()
    note("the interface layout here is " &
      (if layout.len > 0: layout else: "neither sheet nor sprites"))
    log("[assert] minecraft.gui.layout=" &
      (if layout.len > 0: layout else: "none"))
    let hud = hudLayout()
    note("the hearts and the hotbar here are " &
      (if hud.len > 0: hud else: "neither a sheet nor sprites"))
    log("[assert] minecraft.gui.hud=" & (if hud.len > 0: hud else: "none"))
    measureGuiSizes()
  log("[assert] minecraft.gui.pictures=" & $guiCount)

## What one modern sprite's `.mcmeta` says about resizing it. `name` is the part
## after `gui/sprites/` and before `.png` - `widget/button`.
##
## Resolved through the layer stack in its own right, so a pack that ships a
## sprite and a border for it is answered with its border and not the jar's.
## That matters here and is not hypothetical: the 1.21.11 jar says the button's
## border is 3, and Faithful 64x says 20, 4, 20, 4 for the same button.
proc spriteScaling(name: string): string =
  let where = find("minecraft", "textures/gui/sprites/" & name & ".png.mcmeta")
  if where.len == 0: return ""
  var why = ""
  let doc = readJson(where, why)
  if why.len > 0: return ""
  scalingLine(doc)

## Where one jar's `version.json` is extracted to. Named the same way a pack
## folder is, so a version called `../..` cannot become one.
proc versionFolder(version: string): string =
  result = Extracted & "/versions/"
  var i = 0
  while i < version.len:
    let c = version[i]
    if c == '/' or c == '\\' or c == ':' or c == '.': result.add "_"
    else: result.add c
    inc i

## The resource-pack format one installed version speaks, or 0.
proc formatOfVersion(version: string): int =
  var why = ""
  let doc = readJson(versionFolder(version) & "/version.json", why)
  if why.len > 0 or doc.root < 0: return 0
  jarPackFormat(doc)

## Whether the packs the player turned on actually cover the jar they are being
## layered over, and if not, which of their other installed versions would.
##
## This is not pedantry about a number. Minecraft itself says "made for an older
## version" and applies the pack anyway; the layering here does the same, so
## every path the newer jar renamed falls through to the jar and the player gets
## a half-textured game with nothing said about it. That is the same silent
## degradation as a blank menu and it gets the same treatment: say it.
proc checkFit() =
  if fitChecked: return
  fitChecked = true
  fitLine = ""
  if jarVersion.len == 0: return
  jarFormat = formatOfVersion(jarVersion)
  log("[assert] minecraft.gui.format=" & $jarFormat)
  if jarFormat <= 0 or packNames.len == 0: return
  var i = 0
  while i < packNames.len:
    let name = packNames[i]
    inc i
    var why = ""
    let doc = readJson(packFolder(Extracted, name) & "/pack.mcmeta", why)
    if why.len > 0 or doc.root < 0: continue
    let info = readPackMeta(doc)
    if fitsPack(jarFormat, info.lowest, info.format): continue
    # It does not fit. Would one of the other installed versions have fitted?
    var better = ""
    var v = 0
    while v < jarEntries.len:
      let other = versionOf(jarEntries[v])
      inc v
      if other == jarVersion: continue
      let f = formatOfVersion(other)
      if f > 0 and fitsPack(f, info.lowest, info.format): better = other
    fitLine = name & "|" & $info.lowest & "|" & $info.format & "|" &
      $jarFormat & "|" & jarVersion & "|" & better
    note(name & " was made for pack formats " & $info.lowest & " to " &
      $info.format & "; " & jarVersion & " speaks " & $jarFormat)
    if better.len > 0:
      note("it would fit " & better & ", which is also installed")
    log("[assert] minecraft.gui.fit=no")
    return
  log("[assert] minecraft.gui.fit=yes")

## The font sheet, measured, and the answer written down.
##
## This used to happen inside a part request, because `modelBytes` was the only
## door a PNG could come through and it only opens inside a resolver. So there
## was a catalog with one row in it, a `minecraft://font/measure` reference
## nobody wanted, and a spawn whose only purpose was to be resolving. It cost a
## player the whole session: a scheme resolver must answer with a shape, a model
## file or a mesh, this one answered with none of the three because there was
## nothing to draw, and the host refused the spawn every single time - after
## paying for the measurement. `importing.readBytes` opens the same file with no
## request around it, so the trick is gone and so is the failure.
##
## The measurement is remembered because it is expensive and it is settled. A
## 64x pack's `ascii.png` is 512x512 and reading it is a whole frame; the answer
## cannot change until the import does, and the import is what clears it.
proc measureFont() =
  if fontMeasured.len > 0: return
  let where = find("minecraft", "textures/font/ascii.png")
  if where.len == 0:
    fontMeasured = "-"
    save("font", fontMeasured)
    note("no font/ascii.png in this import")
    return
  fontMeasured = imageGridAlphaRightmost(where, FontCells, FontCells)
  if fontMeasured.len == 0:
    fontMeasured = "-"
    save("font", fontMeasured)
    note("the font sheet could not be measured")
    return
  save("font", fontMeasured)
  note("the font sheet's 256 glyph columns were measured")
  var cell = ""
  var i = 0
  while i < fontMeasured.len and fontMeasured[i] != ' ':
    cell.add fontMeasured[i]
    inc i
  log("[assert] minecraft.gui.font=" & cell)

## Measure the font once, on the first frame after `publish()` has begun.
##
## Not in `publish()` itself, which runs in the same frame as everything else a
## fresh import produces, and not in `start()`, where a slow frame is a slow
## launch for every modpack this mod is in. One frame after, on its own. And
## gated on `fontRowReady` alone rather than on `published` - the catalogs may
## take many more frames to finish paging in every block and item, and none of
## that has anything to do with a sheet the import already dropped on disk. The
## loading screen wants the real widths on its own first frame, not on the
## catalogs' last one.
proc stepFont() =
  if fontMeasured.len > 0 or not fontRowReady: return
  measureFont()

## `en_us` as `en_US`, which is what the file was called before 1.11.
proc countryUpper(code: string): string =
  result = ""
  var seen = false
  var i = 0
  while i < code.len:
    var c = code[i]
    if c == '_': seen = true
    elif seen and c >= 'a' and c <= 'z': c = char(int(c) - 32)
    result.add c
    inc i

## One file of the stack, whichever of the three spellings it is in.
## `.json` from 1.13 on, `.lang` before it. The suffix is on the path already,
## so this branches on the path rather than guessing at the version.
proc jsonLangFile(where: string): bool =
  result = false
  if where.len > 5:
    let i = where.len - 5
    if where[i] == '.' and where[i + 1] == 'j' and where[i + 2] == 's' and
       where[i + 3] == 'o' and where[i + 4] == 'n': result = true

proc langFileAt(where: string): string =
  if where.len == 0 or not importHas(where): return ""
  if jsonLangFile(where):
    var why = ""
    let doc = readJson(where, why)
    if why.len > 0 or doc.root < 0: return ""
    return flattenLang(doc)
  let body = importRead(where)
  if body.len == 0: return ""
  flattenLegacyLang(body)

## A language file, out of the whole layer stack rather than out of one layer.
##
## `find` answers with the first layer that has a file, which is the right rule
## for a texture - a pack either replaced `stone.png` or it did not. It is the
## wrong rule for a language file: a pack that renames three strings ships a
## `lang/en_us.json` with three rows in it, and taking that file *instead of*
## the jar's would leave the menu with three translations and four thousand
## bare keys. So every layer that has the file is read, lowest first, and the
## rows are concatenated - the reader's own "a later row of the same key wins"
## then does the overriding, key by key, which is what the game does.
proc langFilesFor(code: string): seq[string] =
  result = @[]
  let asset = languageAsset(code)
  if asset.len > 0: result.add asset
  var spellings: seq[string] = @[]
  spellings.add "lang/" & code & ".json"
  spellings.add "lang/" & code & ".lang"
  spellings.add "lang/" & countryUpper(code) & ".lang"
  var s = 0
  while s < spellings.len:
    let where = candidates(layers, "minecraft", spellings[s], false)
    inc s
    # `candidates` answers highest layer first; the concatenation wants lowest
    # first, so that the pack on top is the one whose row is read last.
    var i = where.len - 1
    while i >= 0:
      if importHas(where[i]): result.add where[i]
      dec i

# ---------------------------------------------------------------------------
# The language table, built a few rows a frame
#
# **This was the eight-second frozen window.** `en_us.json` is eight thousand
# one hundred and twenty-three rows, and turning it into the flat table the menu
# reads cost 3.9 seconds of interpreter string work in one update() -
# `tools/run_mod.exe --time` over the mod pair, with the menu paying another 4.5
# on the way back in. A service answers inside the caller's frame, so there was
# nowhere for the caller to put that: the only place this can be paced is here,
# on this mod's own update(), with the service answering "not yet" until the
# table is whole.
#
# The rows are the unit and the budget is a count of them, because a mod cannot
# time itself: `jester_time` is sampled at the top of a frame and does not
# move while the mod runs, so the only honest signal is the frame that just went
# by. `paceLang` takes that and `LangRowsPerPump` is what it starts from -
# 3.9 seconds over 8,123 rows is about half a millisecond a row, so two dozen is
# a third of a sixty-a-second frame and the adjustment finds the rest.

const
  LangRowsPerPump = 24
    ## Rows folded into the table per update() when frames are healthy.
  LangRowsMost = 96
    ## And never more, however cheap the frames look: one long frame measured
    ## after the fact is one long frame the player already saw.
  LangRowsLeast = 6
    ## And never fewer, however slow: a table that grows six rows an update
    ## still finishes, and one that grows none does not.
    ##
    ## It is not, on its own, enough. See `LangMostFrames`.
  LangMostFrames = 8
    ## However slow the frames get, the table is whole within this many more
    ## updates - and this is the number that makes the pacing above safe rather
    ## than merely polite.
    ##
    ## **The floor was a floor on the wrong thing.** `deltaTime()` is the whole
    ## frame and not this mod's share of it, so a modpack whose voxel world is
    ## meshing chunks behind the menu reads as "take less" on every single
    ## update. Six rows is then what the table grows by for ever: the budget
    ## only comes back up under ten milliseconds and a frame like that never
    ## arrives. Measured, with an instrumented build: 162 rows of 7,767 in sixty
    ## seconds, and the loading screen still up at the end of it. The player saw
    ## the same thing from the other side and reported it as `menu.singleplayer`
    ## on the buttons - the table never finished, so `translate` never had a
    ## word for any of them.
    ##
    ## A feedback loop that makes a slow session slower is backwards here for a
    ## second reason too: this work only ever happens while the loading screen
    ## is up. There is no game to keep smooth. So the rule is a ceiling on how
    ## many more updates it may take, and the budget is raised to whatever meets
    ## it - 7,767 rows over a hundred and twenty updates is sixty-five a time,
    ## about a millisecond and a half of this mod's own work, on a frame that is
    ## already showing nothing but a progress bar.
  SlowFrameMs = 20
    ## Longer than a sixty-a-second frame: take less of the next one.
  FastFrameMs = 10
    ## Room to spare: take more.

var
  langCode = ""
    ## The code the table below is for, or is being built for.
  langReady = false
  langTable = ""
  langFiles: seq[string] = @[]
  langFileAt0 = 0
  langOpen = false
  langDoc: Json
  langRow = 0
  langRowsIn = 0
  langPerPump = LangRowsPerPump
  langPumpsLeft = LangMostFrames
    ## How many more updates the rest of the file may take. Counted DOWN, which
    ## is the whole of what makes `LangMostFrames` mean anything: dividing what
    ## is left by a constant every time is Zeno's budget - it shrinks with the
    ## remainder and converges on the end without reaching it. Measured, on the
    ## build that had it: 5,419 rows of 7,767 after twenty-nine updates, each
    ## one taking four per cent of what was left.

## The budget for this update: what the frame before it suggested, raised to
## whatever finishes the file within the updates it has left.
proc langBudget(): int =
  result = langPerPump
  # Never inflate a pump to meet a wall-clock deadline.  The JSON parser has
  # already paid its fixed cost when the file opens; forcing the remaining
  # thousands of rows through the same frame turned a healthy 24-row budget
  # into a multi-second menu freeze.  Progress may take a few more frames, but
  # every frame remains repaintable and the loading screen can show it.
  if langPumpsLeft > 1: langPumpsLeft = langPumpsLeft - 1

proc paceLang(frameMs: int) =
  if frameMs > SlowFrameMs:
    langPerPump = langPerPump div 2
    if langPerPump < LangRowsLeast: langPerPump = LangRowsLeast
  elif frameMs < FastFrameMs:
    langPerPump = langPerPump + 8
    if langPerPump > LangRowsMost: langPerPump = LangRowsMost

proc beginLang(code: string) =
  langCode = code
  langReady = false
  langTable = ""
  langFiles = langFilesFor(code)
  langFileAt0 = 0
  langOpen = false
  langRow = 0
  langRowsIn = 0
  # The flattened table is content derived from the granted jar and its pack
  # stack. Keep it beside the imported files so a normal relaunch does not
  # reparses the 430 KB language JSON on the menu's first request.
  if importHas(LangCache):
    let cached = importRead(LangCache)
    var split = -1
    var i = 0
    while i < cached.len:
      if cached[i] == '\n': split = i; break
      inc i
    if split > 0 and cached[0 ..< split] == code:
      langTable = cached[(split + 1) .. ^1]
      langReady = true

## One update()'s worth of folding files into the table. Does nothing once the
## table is whole, and nothing at all until a menu has asked for a language.
proc stepLang() =
  if langReady or langCode.len == 0: return
  var left = langBudget()
  while left > 0:
    if langFileAt0 >= langFiles.len:
      langReady = true
      discard importWrite(LangCache, langCode & "\n" & langTable)
      log("[assert] minecraft.langbytes=" & $langTable.len)
      return
    let where = langFiles[langFileAt0]
    if not langOpen:
      langOpen = true
      langRow = 0
      langRowsIn = 0
      # Each file of the stack gets its own allowance. The jar's is the eight
      # thousand rows this is all about; a pack layered over it that renames
      # three strings is one update and does not need sixteen.
      langPumpsLeft = LangMostFrames
      if jsonLangFile(where):
        var why = ""
        langDoc = readJson(where, why)
        if why.len == 0 and langDoc.root >= 0:
          langRowsIn = langKeyCount(langDoc)
      else:
        # The pre-1.13 spelling. These are one small file and never the jar's
        # own eight thousand rows, so they are folded in whole and charged the
        # whole budget rather than given a second cursor.
        let body = importRead(where)
        if body.len > 0: langTable.add flattenLegacyLang(body)
        left = 0
    if langRow < langRowsIn:
      var take = langRowsIn - langRow
      if take > left: take = left
      langTable.add flattenLangRows(langDoc, langRow, take)
      langRow = langRow + take
      left = left - take
    if langRow >= langRowsIn:
      langOpen = false
      langDoc = parseJson("")
      inc langFileAt0

## What a menu is given when it asks for a language.
##
## **Empty means "ask again next frame", and it always did.** The old spelling
## answered "" for a language no layer had a file for, and a menu that reads ""
## comes back rather than giving up - which is exactly the behaviour a table
## that is still being built needs. So the contract did not have to change, and
## a menu written against the old one still works against this one.
##
## Two rules keep that true:
##
##   * a code no layer has a file for is answered "" *without starting a build*,
##     so a menu that asks for `de_de` and then falls back to `en_us` on the same
##     frame gets the same answer it always got;
##   * a build in progress is never abandoned for a different code, so a menu
##     that asks for two codes a frame cannot restart the work every frame and
##     never finish it. Whichever was asked for first is built and answered;
##     the other is answered once that one is done.
proc langAnswer(code: string): string =
  if langCode != code:
    # Somebody else's build is already running: let it finish. This one will be
    # answered when it is asked for again.
    if langCode.len > 0 and not langReady: return ""
    if langFilesFor(code).len == 0: return ""
    beginLang(code)
    return ""
  if not langReady: return ""
  langTable

## Whether any layer holds a file for this code at all. The menu asks this
## before it asks for the table, because an empty table means "not yet" and it
## must not read that as "this language is missing" and switch to en_us on the
## next frame - which would restart the build, every frame, for ever.
proc langPresent(code: string): bool = langFilesFor(code).len > 0

## Which of the six things is true right now, in one word. These are not
## shades of the same thing and collapsing any two of them is the bug this
## exists to prevent: "you have granted nothing", "you granted a folder with no
## Minecraft in it", and "there is a Minecraft here and nobody has read it yet"
## need three different sentences and the middle one is the one a player who has
## not installed the game needs to see.
proc stateWord(): string =
  if root.len == 0: return "nogrant"
  if finding != 0 or running: return "importing"
  if jarSearched and jarPath.len == 0: return "nojar"
  if jarPath.len == 0: return "importing"
  if guiCount == 0: return "notimported"
  if fitLine.len > 0: return "mismatch"
  "ready"

## Everything a menu needs to say what is going on, in one call: the state, the
## folder that was granted, the file to add a line to, an example of that line,
## which version was chosen, how far the reading has got, and any pack that does
## not cover it. Tab separated, because every field is a path or a sentence and
## a tab is the one character none of them contains.
# ---------------------------------------------------------------------------
# The packs on disk, and the player's own choice of them
#
# `options.txt` says which packs Minecraft had turned on. That is the right
# thing to start from and the wrong thing to be stuck with: a resource pack
# screen that can only show what another program chose is a read-out and not a
# screen. So two more things are known here - every pack the player *has*, and
# whichever set they have since chosen - and `aoughwl.mcui` draws the two
# columns out of them.
#
# The choice is not paid for inside the service call that makes it. A service
# answers in the caller's frame and an import must not start there, so the
# choice is written down and `update()` starts the work on the next frame -
# which is also what puts the loading screen up, because the state word becomes
# `importing` exactly then.

var packsScan = 0
var packsListed = false
var packsWanted = false
var packsFound: seq[string] = @[]
var packsAt = 0
var packsTotal = -1
var packRowsThisPump = PackRowsPerPump
var chosenPacks: seq[string] = @[]
var chosenSaid = false
var packChangeWanted = false

## Every resource pack in the granted folder, whether or not it is turned on.
## One scan, kept: the folder does not change while the game is running, and a
## scan a frame would be a scan a frame for a screen almost nobody opens.
proc pacePacks(frameMs: int) =
  if frameMs > SlowPackFrameMs:
    packRowsThisPump = packRowsThisPump div 2
    if packRowsThisPump < MinPackRowsPerPump:
      packRowsThisPump = MinPackRowsPerPump
  elif frameMs < FastPackFrameMs:
    packRowsThisPump = packRowsThisPump + 8
    if packRowsThisPump > PackRowsPerPump:
      packRowsThisPump = PackRowsPerPump

proc listPacks() =
  if not packsWanted or packsListed or root.len == 0: return
  if packsScan == 0:
    packsScan = importScan(root, "resourcepacks", "*")
    if packsScan == 0: packsListed = true
    return
  if not importDone(packsScan): return
  if packsTotal < 0:
    packsFound = @[]
    packsAt = 0
    packsTotal = importCount(packsScan)
  var budget = packRowsThisPump
  while budget > 0 and packsAt < packsTotal:
    let name = importName(packsScan, packsAt)
    inc packsAt
    dec budget
    # Top level only. A pack that is a folder answers with everything inside it
    # as well, and `my pack/assets/minecraft/lang/en_us.json` is not a pack.
    var deep = false
    var k = 0
    while k < name.len:
      if name[k] == '/' or name[k] == '\\': deep = true
      inc k
    if not deep and name.len > 0: packsFound.add name
  if packsAt < packsTotal: return
  importRelease(packsScan)
  packsScan = 0
  packsAt = 0
  packsTotal = -1
  packsListed = true
  note($packsFound.len & " resource pack(s) on disk")

## What one pack's own `pack.mcmeta` says, for the screen that has to show
## whether it fits. Zeros when it has never been turned on and therefore never
## been extracted - which the screen shows as "not known yet" and not as "fits",
## because those are different and only one of them is safe to imply.
proc packMetaOf(name: string): string =
  var why = ""
  let doc = readJson(packFolder(Extracted, name) & "/pack.mcmeta", why)
  if why.len > 0 or doc.root < 0: return "0\t0\t"
  let info = readPackMeta(doc)
  $info.lowest & "\t" & $info.format & "\t" & escapeLangValue(info.description)

## One line a pack: `name`, its place in the selection (0 for off, 1 for the
## one that wins, 2 for the next down), then what its `pack.mcmeta` said. Tab
## separated, because a pack description is other people's prose and may hold
## anything except the two characters `escapeLangValue` takes out.
proc packsRecord(): string =
  # Starting Minecraft must not enumerate an entire resourcepacks tree. The
  # screen's first request arms that work; update() starts and drains it outside
  # the requesting mod's callback.
  packsWanted = true
  result = ""
  var i = 0
  while i < packsFound.len:
    let name = packsFound[i]
    inc i
    var place = 0
    var k = 0
    while k < packNames.len:
      if packNames[k] == name: place = k + 1
      inc k
    result.add name & "\t" & $place & "\t" & packMetaOf(name) & "\n"

## The screen's answer: the packs it wants, highest priority first, `|`
## separated. An empty list is a real answer and means every pack off.
proc choosePacks(argument: string): string =
  if root.len == 0: return "nogrant"
  chosenPacks = @[]
  var piece = ""
  var i = 0
  while i <= argument.len:
    if i == argument.len or argument[i] == '|':
      if piece.len > 0: chosenPacks.add piece
      piece = ""
    elif not (piece.len == 0 and argument[i] == ' '):
      piece.add argument[i]
    inc i
  chosenSaid = true
  packChangeWanted = true
  "ok"

proc noticeRecord(): string =
  var progress = ""
  if running: progress = $planPercent() & "% " & $planIndex() & "/" &
    $planLength() & " " & planNote()
  elif finding != 0: progress = "0% 0/0 locating Minecraft"
  elif root.len == 0: progress = "0% 0/0 waiting for Minecraft folder"
  elif jarPath.len == 0: progress = "0% 0/0 preparing Minecraft data"
  stateWord() & "\t" & root & "\t" & importPolicyFile() & "\t" &
    (importKnown("appdata") & "\\.minecraft") & "\t" & jarVersion & "\t" &
    progress & "\t" & fitLine

proc asks(argument, verb: string): bool =
  if argument.len < verb.len: return false
  var i = 0
  while i < verb.len:
    if argument[i] != verb[i]: return false
    inc i
  true

proc after(argument: string; skip: int): string =
  result = ""
  var i = skip
  while i < argument.len:
    result.add argument[i]
    inc i

## The service. One answer, always, even when the answer is nothing: a caller
## tells "nobody served it" from "it served nothing" by the problem beside it.
proc serveRequest() =
  if serviceName() != GuiService:
    answerService("")
    return
  let ask = serviceArgument()
  if ask == "notice":
    answerService(noticeRecord())
  elif ask == "state":
    answerService(stateWord())
  elif ask == "ready":
    answerService(if guiCount > 0: "yes" else: "no")
  elif ask == "pictures":
    answerService($guiCount)
  elif ask == "layout":
    answerService(guiLayout())
  elif ask == "font":
    answerService(if fontMeasured == "-": "" else: fontMeasured)
  elif ask == "sizes":
    answerService(guiSizes)
  elif ask == "hudlayout":
    answerService(hudLayout())
  elif ask == "splashes":
    let where = find("minecraft", "texts/splashes.txt")
    answerService(if where.len > 0: importRead(where) else: "")
  elif ask == "language":
    answerService(optionLine(importRead(OptionsFile), "lang"))
  elif ask == "languages":
    answerService(assetLanguages())
  elif ask == "version":
    answerService(jarVersion)
  elif ask == "pack":
    answerService(if packNames.len > 0: packNames[0] else: "")
  elif ask == "format":
    # Which resource-pack format this jar speaks. The screen needs it to say
    # whether a pack's declared range covers this install, and it is only ever
    # in the notice when it does *not* - which is too late to draw a column
    # with.
    answerService($jarFormat)
  elif ask == "packs":
    answerService(packsRecord())
  elif asks(ask, "choose"):
    answerService(choosePacks(after(ask, 6)))
  elif asks(ask, "sprite "):
    answerService(spriteScaling(after(ask, 7)))
  elif asks(ask, "lang "):
    answerService(langAnswer(after(ask, 5)))
  elif asks(ask, "haslang "):
    answerService(if langPresent(after(ask, 8)): "yes" else: "no")
  else:
    answerService("")

## Turn one reference into a mesh and a picture.
##
## Every failure here is a log line and an empty answer. A resource pack is
## other people's data and a malformed one must cost the player a missing block,
## never the session.
proc resolvePart() =
  let want = resourcePath(partLocator())
  var kind = ""
  var name = ""
  var state = ""
  splitRef(want, kind, name, state)
  var problem = ""
  var baked = emptyBake()
  var label = want

  if kind == "blockstate":
    baked = bakeState(name, state, problem)
    label = name
  elif kind == "item":
    # Which of the two layouts this item is in is settled by looking for the
    # file, not by asking the jar what version it is. `items/<name>.json` is
    # where 1.21.4 and later put the mapping and it is the only place a block
    # item is described at all; when no layer has one, `item/<name>` is still
    # the model, exactly as it was.
    var path = "item/" & name
    let defFile = itemDefFile(name)
    if defFile.len > 0:
      var why = ""
      let doc = readJson(defFile, why)
      if why.len > 0:
        note(leaf(defFile) & ": " & why)
      else:
        let named = definitionModel(doc)
        if named.len > 0:
          path = named
          let several = definitionCases(doc)
          if several > 0:
            note("item/" & name & ": one of " & $several &
                 " appearances; showing the resting one")
        else:
          note("item/" & name & ": its definition names no model")
    baked = bakeModel(path, problem)
    label = "item/" & name
  elif kind == "block":
    baked = bakeModel("block/" & name, problem)
    label = "block/" & name
  else:
    # An older reference, or one a mod wrote by hand: treat it as a model path.
    baked = bakeModel(want, problem)

  if problem.len > 0:
    note(label & ": " & problem)
    return
  if baked.count == 0:
    note(label & ": " & (if baked.problem.len > 0: baked.problem else: "nothing to draw"))
    return
  if baked.problem.len > 0:
    # Some of it came out. Say what did not rather than hiding it.
    note(label & ": " & baked.problem)
  dress(baked, label)

# ---------------------------------------------------------------------------
# Finding the install, and the plan that empties it into this mod

## Which jar. Every `.jar` under `versions/` is offered and `chooseJar` picks
## the newest version number among them - see `mcgui.nim` for why that is the
## rule and why the biggest file and the launcher's own profile are both worse
## ones. A folder holding only a `.json` is a version the launcher has heard of
## and never downloaded, and contributes nothing to the scan, so an install with
## eight folders and two jars offers two.
##
## Nothing here waits: the look is a job like every other, polled from update()
## until it answers, and what it answers - including "there is no Minecraft in
## that folder" - is a state the menu shows rather than a silence.

proc lookForJar() =
  if root.len == 0:
    note("no granted folder holds a Minecraft install yet.")
    jarSearched = true
    return
  finding = importScan(root, "versions", "*.jar")
  if finding <= 0:
    note("could not look in versions/: " & importProblem())
    return
  note("looking for a version jar")

proc queue() =
  planClear()
  planScan("listing the jar", root, jarPath, ModelsIn)
  planExtract("block models", root, jarPath, ModelsIn, Extracted)
  planExtract("block textures", root, jarPath, TexturesIn, Extracted)
  planExtract("blockstates", root, jarPath, StatesIn, Extracted)
  planExtract("item models", root, jarPath, ItemModelsIn, Extracted)
  planExtract("item textures", root, jarPath, ItemTexturesIn, Extracted)
  planExtract("texture metadata", root, jarPath, MetaIn, Extracted)
  planExtract("recipes", root, jarPath, RecipesIn, Extracted)
  # Step 8, and it has to be step 8: `mcplan.jarRole` names it there. An old
  # jar has no such folder, the step copies nothing, and the item index keeps
  # what the item *models* step gave it.
  planExtract("item definitions", root, jarPath, ItemDefsIn, Extracted)
  # `options.txt` is not in the jar; it is beside the saves folder in the same
  # granted root, and it is the only thing that says which resource packs the
  # player actually turned on.
  planExtract("the player's settings", root, "", OptionsIn, Extracted)
  # The interface. Appended, so `StepStates` and the rest keep their numbers,
  # and each one lands in the "wrote N files" arm below rather than in an index.
  planExtract("the interface", root, jarPath, GuiIn, Extracted)
  planExtract("the font", root, jarPath, FontIn, Extracted)
  planExtract("the language files", root, jarPath, LangIn, Extracted)
  planExtract("the splashes", root, jarPath, TextsIn, Extracted)
  # `pack.png` - the grass block on the resource-pack line in the game's own
  # menu, and the one picture in the whole install that means "this is
  # Minecraft" rather than "this is a block". It is beside `assets/` and not
  # inside it, so no glob above reaches it. Appended: `mcplan.jarRole` says a
  # step past the numbered ones is a `RoleFiles` step and indexes nothing.
  planExtract("the pack picture", root, jarPath, IconFile, Extracted)
  # The sky. Appended for the same reason the interface was: `mcplan.jarRole`
  # answers `RoleFiles` for any step past the numbered ones, so this lands in
  # the "wrote N files" arm and moves nothing.
  planExtract("the sky", root, jarPath, EnvironmentIn, Extracted)
  # Every jar's own `version.json`, which is where a jar says which resource
  # pack format it speaks. The chosen one is needed to tell a player their pack
  # does not cover it; the others are needed to tell them which of their
  # installed versions it would cover instead. Two files, a few hundred bytes.
  var v = 0
  while v < jarEntries.len:
    let one = jarEntries[v]
    inc v
    planExtract("version " & versionOf(one), root, "versions/" & one,
      "version.json", versionFolder(versionOf(one)))

## Which step of `queue()` above is which now lives in `mcplan.nim`, with the
## two subtractions that were wrong here - the cursor has already moved when a
## step reports done, and the resource-pack plan starts its own numbering at
## zero - written down where `Tests/minecraft_test.nim` can hold them to it.

## The two lines of `PlanReceipt`: which jar the plan was reading, and which
## step it had finished. Written on every step, so the folder and the saved
## cursor move together or not at all.
##
proc writeReceipt() =
  var body = jarPath
  body.add Newline
  body.add $planIndex()
  body.add Newline
  if not importWrite(PlanReceipt, body):
    note("could not write " & PlanReceipt & ": " & importProblem())

## Does the folder agree that this jar's plan had reached `at`? False when
## there is no receipt at all, which is a folder that was emptied or shipped
## fresh under a saved state that outlived it, and false when the receipt names
## a different jar.
proc receiptAgrees(at: int): bool =
  if not importHas(PlanReceipt): return false
  let body = importRead(PlanReceipt)
  var said = ""
  var cursor = ""
  var line = 0
  var i = 0
  while i < body.len:
    let c = body[i]
    inc i
    if c == Newline:
      inc line
    elif c == char(13):
      discard
    elif line == 0: said.add c
    elif line == 1: cursor.add c
  said == jarPath and cursor == $at

proc settleFinding(again: bool) =
  if finding == 0 or not importDone(finding): return
  let why = importError(finding)
  jarEntries = @[]
  var sizes: seq[int] = @[]
  if why.len == 0:
    var i = 0
    while i < importCount(finding):
      jarEntries.add importName(finding, i)
      sizes.add importSize(finding, i)
      inc i
  importRelease(finding)
  finding = 0
  jarSearched = true
  if why.len > 0:
    note("versions/: " & why)
    return
  if jarEntries.len == 0:
    # This is the "install Minecraft first" case, and it is not the same as
    # "nothing granted". The folder is right here and there is no game in it:
    # `versions/` on a launcher that has never downloaded anything is full of
    # folders holding one `.json` each, which is a version it has HEARD of.
    note("no .jar under " & root & "/versions/")
    note("that folder lists versions the launcher knows; none is downloaded")
    return
  # Not the biggest. The biggest is a proxy for nothing - it would pick a modded
  # jar with a shader bundle in it over the vanilla one beside it - and it is
  # not a rule a player could check. The newest version number wins, over the
  # folders that actually contain a jar, and the log says which and why.
  let want = remember("target", TargetVersion)
  let asked = jarNamed(jarEntries, want)
  let pick = chooseJar(jarEntries, want)
  if pick < 0: return
  jarPath = "versions/" & jarEntries[pick]
  jarVersion = versionOf(jarEntries[pick])
  var others = ""
  var i = 0
  while i < jarEntries.len:
    if i != pick:
      if others.len > 0: others.add ", "
      others.add versionOf(jarEntries[i])
    inc i
  # Which, and why. The two are genuinely different reasons and a player with
  # three Minecrafts installed needs to be told which one this is and whether
  # it is the one the rest of this game was built against.
  let size = $(sizes[pick] div 1048576) & " MB"
  if asked >= 0:
    note("using Minecraft " & jarVersion & ", " & size &
      " - the version this game's protocol client targets")
  else:
    note("using Minecraft " & jarVersion & ", " & size &
      " - the newest version with a jar in it")
    if want.len > 0:
      note(want & " is what this game targets, and it is not installed")
  log("[assert] minecraft.version=" & jarVersion)
  log("[assert] minecraft.target=" & want)
  if others.len > 0: note("also installed: " & others)
  queue()
  # Start where the *folder* says, not where the player's saved state says.
  # `startPlan` restores the remembered cursor; the receipt beside the files is
  # what decides whether that cursor is about this folder at all.
  startPlan("minecraft")
  if again or not receiptAgrees(planIndex()):
    if not again and planIndex() > 0:
      note("an interrupted import is remembered at step " & $planIndex() &
        " but this folder does not hold it; reading it all again")
    restartPlan("minecraft")
  writeReceipt()
  running = true

var startingOver = false

proc beginImport(again: bool) =
  if running or finding != 0: return
  hudFilled = false
  hudStarted = false
  hudAt = 0
  # Whatever is about to arrive may be a different font sheet - a pack turned on
  # or off changes which layer answers for `font/ascii.png`. The remembered
  # measurement is a fact about an import, so it goes out with the import that
  # made it rather than being checked against one that has not finished.
  fontMeasured = ""
  save("font", "")
  startingOver = again
  lookForJar()

# ---------------------------------------------------------------------------
# The index files
#
# A list of two thousand names is a document, not a scalar, so it is kept as a
# file in the mod's own folder rather than in `remember`.

proc writeIndex(path: string; list: seq[string]) =
  var body = ""
  var i = 0
  while i < list.len:
    body.add list[i]
    body.add "\n"
    inc i
  if not importWrite(path, body):
    note("could not write " & path & ": " & importProblem())

proc readIndex(path: string): seq[string] =
  result = @[]
  if not importHas(path): return result
  let body = importRead(path)
  var current = ""
  var i = 0
  while i < body.len:
    if body[i] == '\n':
      if current.len > 0: result.add current
      current = ""
    else:
      current.add body[i]
    inc i
  if current.len > 0: result.add current

proc collect(job: int): seq[string] =
  result = @[]
  var i = 0
  while i < importCount(job):
    let name = leaf(importName(job, i))
    if name.len > 0: result.add name
    inc i

## The `.mcmeta` list keeps its whole path, because it is a path into the
## texture tree and its leaf alone would not say whether it was a block or an
## item.
proc collectPaths(job: int): seq[string] =
  result = @[]
  var i = 0
  while i < importCount(job):
    let name = importName(job, i)
    if name.len > 0: result.add name
    inc i

# ---------------------------------------------------------------------------
# The catalogs

proc titleOf(name: string): string =
  ## `oak_stairs` as `Oak stairs`. A label is for a person to read, and the
  ## file name is the only name Minecraft's assets carry.
  result = ""
  var start = true
  var i = 0
  while i < name.len:
    var c = name[i]
    if c == '_':
      result.add ' '
      start = false
    else:
      if start and c >= 'a' and c <= 'z': c = char(int(c) - 32)
      result.add c
      start = false
    inc i

proc publish() =
  if published: return
  if not publishInitialized:
    publishInitialized = true
    createCatalog(Blocks, PartKind, "Blocks from the Minecraft this player owns.")
    createCatalog(Items, PartKind, "Items from the Minecraft this player owns.")
    publishGui()
    publishSky()
    publishOwnIcon()
    note("publishing Minecraft content")
    # The font sheet has nothing to do with the block and item catalogs, so it
    # no longer waits on them. It used to: this flag was only raised once every
    # row of both catalogs had gone out, which on a jar with thousands of
    # blocks and items was seconds of frames after the loading screen was
    # already up showing text laid out with `FallbackAdvance` - a visible pop
    # once the real widths finally arrived. Raising it here, the same frame
    # publishing starts, lets `stepFont` measure the sheet one frame later
    # regardless of how long the catalogs take.
    if fontMeasured.len == 0: fontMeasured = remember("font", "")
    fontRowReady = true

  var done = 0
  while done < PublishRowsBudget and publishBlockAt < stateNames.len:
    let i = publishBlockAt
    addToCatalog(Blocks, stateNames[i], Scheme & "://blockstate/" & stateNames[i])
    inc publishBlockAt
    inc done
  while done < PublishRowsBudget and publishItemAt < itemNames.len:
    let i = publishItemAt
    addToCatalog(Items, itemNames[i], Scheme & "://item/" & itemNames[i])
    inc publishItemAt
    inc done
  if publishBlockAt < stateNames.len or publishItemAt < itemNames.len: return

  published = true
  # The models themselves stay addressable. A blockstate is the block; a model
  # is one shape a block wears, and a mod that wants `block/oak_stairs_inner`
  # outright can still have it.
  note($stateNames.len & " blocks and " & $names.len & " block models")
  log("[assert] minecraft.blockstates=" & $stateNames.len)
  log("[assert] minecraft.blockmodels=" & $names.len)
  note($itemNames.len & " items in " & Items)

  defineCatalogKind(AnimationKind, "text",
    "How a texture animates: its frames, its frametime and its loop.")
  createCatalog(Animations, AnimationKind,
    "Animated textures from this player's Minecraft.")

  if not ledgerNoted:
    ledgerNoted = true
    noteImport("minecraft/" & leaf(jarPath),
      Blocks & "|" & $stateNames.len & "|" & $itemNames.len & " items, " &
      $recipeNames.len & " recipes and " & $stateNames.len &
      " blocks from " & jarPath)
  note("waiting for voxel.blocks and aoughwl.hud.recipes to appear")

# ---------------------------------------------------------------------------
# Filling other mods' catalogs
#
# Two of them, and both are polled rather than assumed, because a modpack may
# hold either, both or neither and load them in any order. The poll is one host
# call a frame and it stops the moment it succeeds.

var voxelFilled = false
## `voxel.blocks`, of kind `aoughwl.block`, whose row is that mod's own
## `field=value;` line - `vxblocks.parseBlockSpec` reads exactly this.
##
## `solid` and `opaque` start true, which is what the great majority of blocks
## are, and are replaced from the block's own model by `stepStates` below. A
## later row of the same name replaces an earlier one, which is the catalog's
## own rule, so a reader that walked it early is not wrong, only early.
##
## That rule is a *host* rule and the host only started keeping it at
## `459ba89`. A player built before that raises
## `'<name>' is already registered in 'voxel.blocks'` on the second row and
## quarantines this mod - which is what a stale `builds/windows` did the first
## time the blockstate index held real blockstates rather than the `.png` names
## the plan-cursor bug had put in it. Nothing here works around it: rebuild the
## player. The workaround was written, measured, and thrown away, because
## carrying a workaround for a bug the repository has already fixed is how a
## file ends up with two ideas of whose rule this is.
proc fillVoxel() =
  if voxelFilled or stateNames.len == 0: return
  if catalogSignature(VoxelBlocks).len == 0: return
  voxelFilled = true
  var i = 0
  while i < stateNames.len:
    addToCatalog(VoxelBlocks, stateNames[i],
      "label=" & titleOf(stateNames[i]) &
      ";texture=" & Scheme & "://blockstate/" & stateNames[i])
    inc i
  stateAt = 0
  dressedCount = 0
  note($stateNames.len & " blocks offered to " & VoxelBlocks)
  log("[assert] minecraft.voxelblocks=" & $stateNames.len)

## The item half: `aoughwl.inventory`'s definition catalog and its five
## facets, `aoughwl.hud`'s five on top, and the registry row from
## `aoughwl.grid` that tells every other mod the catalog is there. Written
## out here rather than imported, so this importer does not depend on a survival
## HUD to be an importer - but written out *from those files*, so the spelling
## is theirs and not a second one.
##
## The icon facet wants a sprite-sheet cell or a `#rrggbb`, and what goes in it
## is a part reference. That is deliberate and it is written down in
## `docs/MINECRAFT-IMPORT.md` section 6: the HUD falls back to a swatch for a
## value it does not recognise, so the reference costs nothing to offer. It is
## no longer a picture that *cannot* be built - `readBytes` opens one anywhere
## now - it is fifteen hundred pictures nobody has asked for yet, and this is
## the one line that changes when somebody does.
proc fillHud() =
  if hudFilled or itemNames.len == 0: return
  if catalogSignature(HudRecipeSources).len == 0: return
  if not hudStarted:
    hudStarted = true
    createCatalog(Inventory, ItemKind, "Items from this player's Minecraft.")
    createCatalog(Inventory & StackFacet, ItemStackKind, "Stack sizes")
    createCatalog(Inventory & BulkFacet, ItemBulkKind, "Bulk")
    createCatalog(Inventory & WeightFacet, ItemWeightKind, "Weights")
    createCatalog(Inventory & ShapeFacet, ItemShapeKind, "Shapes")
    createCatalog(Inventory & TagFacet, ItemTagKind, "Tags")
    createCatalog(Inventory & IconFacet, HudIconKind, "Icons")
    createCatalog(Inventory & FoodFacet, HudFoodKind, "Food values")
    createCatalog(Inventory & SaturationFacet, HudSaturationKind, "Saturation")
    createCatalog(Inventory & ArmourFacet, HudArmourKind, "Armour points")
    createCatalog(Inventory & ArmourPartFacet, HudArmourPartKind, "Armour slots")
    addToCatalog(InventorySources, Inventory, "items")

  var done = 0
  while done < HudRowsBudget and hudAt < itemNames.len:
    let id = itemNames[hudAt]
    inc hudAt
    inc done
    let part = Scheme & "://item/" & id
    addToCatalog(Inventory, id, titleOf(id))
    addToCatalog(Inventory & StackFacet, id, int64(64))
    addToCatalog(Inventory & BulkFacet, id, 1.0)
    addToCatalog(Inventory & WeightFacet, id, 0.0)
    addToCatalog(Inventory & ShapeFacet, id, part)
    addToCatalog(Inventory & TagFacet, id, "minecraft")
    addToCatalog(Inventory & IconFacet, id, part)
    addToCatalog(Inventory & FoodFacet, id, int64(0))
    addToCatalog(Inventory & SaturationFacet, id, 0.0)
    addToCatalog(Inventory & ArmourFacet, id, int64(0))
    addToCatalog(Inventory & ArmourPartFacet, id, "")
  if hudAt < itemNames.len: return
  hudFilled = true
  note($itemNames.len & " items into " & Inventory & " and its ten facets")

  # The recipe catalog, and the registry row that says it holds recipes.
  createCatalog(Recipes, HudRecipeKind, "Recipes from this player's Minecraft.")
  addToCatalog(HudRecipeSources, Recipes, "recipes")
  recipeAt = 0
  # Every item starts as the swatch its row was just filled with and gets its
  # own picture a few a frame from here. Reset with the rows, so a second import
  # looks at every item again rather than at the tail of the last list.
  iconAt = 0
  iconCount = 0


# ---------------------------------------------------------------------------
# The background pass
#
# Three things need every file of a kind read: the recipes, so a HUD has them;
# the blockstates, so the voxel registry knows which blocks hide what is behind
# them; and the `.mcmeta` files, so an animation is described before anything
# has spawned. None of them touches a picture - they are text and JSON - and all
# of them are budgeted, because two thousand files is not a frame's work.

# ---------------------------------------------------------------------------
# What an item looks like in a slot
#
# The inventory's icon facet used to carry a part reference - `minecraft://item/
# oak_planks` - which no drawing surface can do anything with, so every one of
# fifteen hundred items came out as a coloured swatch. It carries a
# `published:` picture now, and the two cases are genuinely different jobs.
#
# **A flat item is exact.** Most of Minecraft's items are `builtin/generated`:
# the model is one texture extruded a sixteenth of a block, and what a slot
# shows is that texture, face on, at 16 by 16. So the icon *is* the texture and
# there is nothing to approximate - `layer0` is published and that is the whole
# of it. `mcitem.classifyItem` says which items those are, off the model chain,
# and it is the reader that already exists rather than a second one.
#
# **A block is not, and this is the honest part.** Minecraft draws a block item
# as a real isometric render: the model is turned 30 degrees about one axis and
# 45 about another and its three visible faces come out as a rhombus and two
# parallelograms. **None of that can be drawn here.** A recorded quad in this
# host is axis-aligned - there is no transform and no rotation on one - so the
# three faces cannot be sheared into place. The two things that would work are
# both real and neither is available today:
#
#   * a transform on a recorded quad, which is a host call this mod may not add
#     and which is reported rather than smuggled in;
#   * a shear built out of strips - sixteen one-pixel rows per face, each offset
#     by one, which *is* a genuine projection and not a trick. Forty-eight quads
#     an icon, and an inventory screen showing forty-six of them is two thousand
#     quads a frame for the icons alone. That is affordable on a screen that is
#     not the world, and it is the thing to build when somebody wants it.
#
# So what is drawn instead is **the block's top face, flat**, and it is called
# that. It is the face a player recognises a block by - grass, stone, planks,
# the ores - it is already published (`dressBlock` offered all six for the voxel
# world), and it is honestly a face rather than a picture of a cube. A flat top
# face that says "this is oak planks" is worth more than a shaded lozenge that
# claims to be a render and is not one.

## The picture an item wears in a slot, published, or "" when it has none.
proc itemIcon(name: string): string =
  # Which model it wears. `items/<name>.json` is where every item is described
  # from 1.21.4 on and is the only place a block item is described at all; the
  # older `item/<name>` model is the fallback, and which one an install has is
  # settled by looking for the file. Same rule, same reader, as `partFor`.
  var path = "item/" & name
  let defFile = itemDefFile(name)
  if defFile.len > 0:
    var whyDef = ""
    let doc = readJson(defFile, whyDef)
    if whyDef.len == 0:
      let named = definitionModel(doc)
      if named.len > 0: path = named
  var why = ""
  let docs = chainOf(path, why)
  if why.len > 0 or docs.len == 0: return ""
  let t = paletteOf(docs)
  let kind = classifyItem(docs)
  if kind == ItemGenerated:
    let layers = layersOf(t)
    if layers.len == 0: return ""
    let file = textureFile(layers[0])
    # An animated texture is a vertical strip of frames and would arrive
    # squeezed into the slot, so it keeps the swatch - the same rule
    # `dressBlock` follows for a block's face, and for the same reason.
    if file.len == 0 or animatedFace(file): return ""
    return publishFace(layers[0], file)
  let layer = geometryLayer(docs)
  if layer < 0: return ""
  var b = bakeElements(docs[layer],
    member(docs[layer], docs[layer].root, "elements"), t)
  if b.count == 0: return ""
  # The `+Y` face, which is `WorldFaces[2]` - the top, flat.
  let f = worldFace(b, 2)
  if f < 0 or b.texture[f].len == 0: return ""
  let file = textureFile(b.texture[f])
  if file.len == 0 or animatedFace(file): return ""
  publishFace(b.texture[f], file)

## A few items a frame, until every one of them has been looked at once.
##
## The row is restated rather than added: `addToCatalog` replaces a claim where
## it stands, so an item whose icon arrives on frame two hundred simply stops
## being a swatch. Nothing has to wait for this and nothing breaks without it.
proc stepIcons() =
  if not hudFilled: return
  var done = 0
  while done < IconBudget and iconAt < itemNames.len:
    let id = itemNames[iconAt]
    inc iconAt
    inc done
    let uri = itemIcon(id)
    if uri.len == 0: continue
    addToCatalog(Inventory & IconFacet, id, uri)
    inc iconCount
  if iconAt == itemNames.len and itemNames.len > 0:
    inc iconAt
    note($iconCount & " of " & $itemNames.len & " items wear their own picture")
    log("[assert] minecraft.icons=" & $iconCount)

proc stepRecipes() =
  if not hudFilled: return
  var done = 0
  while done < RecipeBudget and recipeAt < recipeNames.len:
    let name = recipeNames[recipeAt]
    inc recipeAt
    inc done
    var why = ""
    var path = Extracted & "/data/minecraft/recipe/" & name & ".json"
    if not importHas(path):
      path = Extracted & "/data/minecraft/recipes/" & name & ".json"
    if not importHas(path): continue
    let doc = readJson(path, why)
    if why.len > 0: continue
    let r = readRecipe(doc)
    if r.made.len == 0: continue
    # The row `aoughwl.hud/hudrecipe.nim` reads, written by `mcrecipe`
    # against that file's own grammar. A recipe no bench can hold - a furnace,
    # a four-row pattern - comes back empty and is skipped rather than published
    # as a row the HUD would have to reject.
    let row = hudRecipeText(r)
    if row.len == 0: continue
    addToCatalog(Recipes, name, row)
  if recipeAt == recipeNames.len and recipeNames.len > 0:
    inc recipeAt
    note($recipeNames.len & " recipes read into " & Recipes)

## The ten pictures a block wears as it comes apart, offered as one catalog row.
##
## **Nothing is added to the extraction plan for these.** They are block
## textures, `TexturesIn` is `assets/minecraft/textures/block/*.png`, and
## `destroy_stage_0.png` is in it - so they arrive with every other block
## picture, they come through the same layer stack, and a resource pack that
## replaces the cracks replaces exactly them. All that is left to do is publish
## them and say what they are for.
##
## The row is named after the pictures rather than after a block, because it is
## not about a block: `aoughwl.voxel` reads the *first* row of this facet
## for any block that has no row of its own, so one row here dresses everything
## and neither mod has to know a name the other chose. A provider that wants a
## different crack on one block adds a row called after that block beside this
## one, and the per-block lookup finds it first.
##
## All ten or none. A row with a hole in it would be read as a picture called
## nothing, and nine stages out of ten is worse than the flat highlight this
## world already had.
proc dressCracks() =
  if cracksDressed: return
  if catalogSignature(VoxelBlocks & WearFacet).len == 0: return
  var row = ""
  var i = 0
  while i < CrackStages:
    let reference = CrackReference & $i
    let file = textureFile(reference)
    if file.len == 0: return
    let public = publishFace(reference, file)
    if public.len == 0: return
    if i > 0: row.add "|"
    row.add public
    inc i
  cracksDressed = true
  addToCatalog(VoxelBlocks & WearFacet, CrackReference, row)
  note($CrackStages & " break stages published for " & VoxelBlocks)

proc stepStates() =
  if not voxelFilled: return
  # Retried every frame until the facet exists rather than done once beside the
  # blocks: `aoughwl.voxel` declares the catalog in its own `start()`, and
  # which of the two mods runs first is not a thing either of them may assume.
  dressCracks()
  var done = 0
  while done < StateBudget and stateAt < stateNames.len:
    let name = stateNames[stateAt]
    inc stateAt
    inc done
    var why = ""
    let doc = readJson(stateFile(name), why)
    if why.len > 0: continue
    let bs = parseBlockState(doc)
    if bs.problem.len > 0: continue
    let picks = placementsFor(bs, defaultState(bs))
    if picks.len == 0: continue
    # One model decides it: Minecraft's own occlusion test is per model, and a
    # multipart block is never a full cube anyway.
    var solid = false
    let docs = chainOf(bs.place[picks[0]].model, why)
    let layer = geometryLayer(docs)
    if layer >= 0:
      solid = isFullCube(docs[layer],
        member(docs[layer], docs[layer].root, "elements"))
      # The same walk pays for the block's pictures. Everything about which
      # texture is on which face is in the JSON that is already open, and a
      # picture is published by name rather than by value, so there is nothing
      # here that needs a byte of any file.
      if solid:
        let t = paletteOf(docs)
        var b = bakeElements(docs[layer],
          member(docs[layer], docs[layer].root, "elements"), t)
        if b.count > 0:
          applyPlacement(b, bs.place[picks[0]])
          dressBlock(name, b)
    addToCatalog(VoxelBlocks, name,
      "label=" & titleOf(name) &
      ";solid=" & (if solid: "true" else: "false") &
      ";opaque=" & (if solid: "true" else: "false") &
      ";texture=" & Scheme & "://blockstate/" & name)
  if stateAt == stateNames.len and stateNames.len > 0:
    inc stateAt
    note($stateNames.len & " blocks measured for " & VoxelBlocks & ", " &
      $dressedCount & " dressed with " & $pictureCount & " pictures")

proc stepMeta() =
  var done = 0
  while done < MetaBudget and metaAt < metaNames.len:
    let path = metaNames[metaAt]
    inc metaAt
    inc done
    var why = ""
    let doc = readJson(Extracted & "/" & path, why)
    if why.len > 0: continue
    # The strip's length is not in the `.mcmeta`; it is in the picture, and a
    # picture cannot be opened here. `frames=` is filled in the first time the
    # texture is actually spawned, by `noteAnimation`.
    let a = readAnimation(doc, 0)
    var name = ""
    var i = 0
    while i < path.len:
      name.add path[i]
      inc i
    addToCatalog(Animations, name,
      "frames=?;steps=" & $stepCount(a) & ";frametime=" & $a.frametime &
      ";interpolate=" & (if a.interpolate: "true" else: "false"))
  if metaAt == metaNames.len and metaNames.len > 0:
    inc metaAt
    note($metaNames.len & " animated textures described in " & Animations)

# ---------------------------------------------------------------------------
# Resource packs
#
# A second plan, after the first: the packs the player enabled, each one's
# `assets/` copied into a folder of its own so the layer stack can hold them
# apart. Reading `options.txt` is what makes this the player's selection rather
# than every pack they have ever downloaded.

var packPlanRunning = false

proc queuePacks(): bool =
  if chosenSaid:
    # The player has been to the resource pack screen. Their choice outlives a
    # re-read of the jar; `options.txt` is where this *started*, not where it
    # is kept.
    packNames = chosenPacks
  elif not importHas(OptionsFile):
    return false
  else:
    let body = importRead(OptionsFile)
    if body.len == 0: return false
    packNames = enabledPacks(body)
  if packNames.len == 0:
    note("no resource pack is enabled; the jar is the whole of it")
    return false
  planClear()
  var i = 0
  while i < packNames.len:
    let name = packNames[i]
    inc i
    planExtract(name, root, "resourcepacks/" & name, PackIn,
      packFolder(Extracted, name))
    # And the pack's own `pack.mcmeta`, which `PackIn` does not reach: it is
    # beside `assets/`, not inside it, and it is the only place a pack says
    # which versions it was made for.
    planExtract(name & " metadata", root, "resourcepacks/" & name,
      "pack.mcmeta", packFolder(Extracted, name))
    # And its picture, beside its metadata and for the same reason. A pack that
    # redraws the game is entitled to say what the game looks like in a taskbar;
    # `packRole` counts every pack step and indexes none, so this is safe to add.
    planExtract(name & " picture", root, "resourcepacks/" & name,
      IconFile, packFolder(Extracted, name))
  writeIndex(PackIndex, packNames)
  note($packNames.len & " resource pack(s) over the jar: " & packNames[0])
  restartPlan("minecraft.packs")
  packPlanRunning = true
  true

## The pack screen chose a different set. Only the pack half of the import is
## re-run - the jar is already out and does not change - so this costs seconds
## rather than minutes, and it is still long enough that the menu goes to the
## loading screen for it, which is what the player asked for and what is
## honest.
##
## Turning every pack off is a real choice and is the one that costs nothing:
## there is nothing to extract, so the layers are rebuilt and the pictures
## re-offered on the spot.
proc startPackChange() =
  packChangeWanted = false
  packNames = chosenPacks
  writeIndex(PackIndex, packNames)
  # A pack turned on or off may be the one that was answering for the font
  # sheet, so the remembered measurement is no longer about this layer stack.
  fontMeasured = ""
  save("font", "")
  if packNames.len == 0:
    rebuildLayers()
    fitChecked = false
    guiPublished = false
    publishGui()
    publishSky()
    note("every resource pack turned off; the jar is the whole of it")
    return
  planClear()
  var i = 0
  while i < packNames.len:
    let name = packNames[i]
    inc i
    planExtract(name, root, "resourcepacks/" & name, PackIn,
      packFolder(Extracted, name))
    planExtract(name & " metadata", root, "resourcepacks/" & name,
      "pack.mcmeta", packFolder(Extracted, name))
    # And its picture, beside its metadata and for the same reason. A pack that
    # redraws the game is entitled to say what the game looks like in a taskbar;
    # `packRole` counts every pack step and indexes none, so this is safe to add.
    planExtract(name & " picture", root, "resourcepacks/" & name,
      IconFile, packFolder(Extracted, name))
  note($packNames.len & " resource pack(s) chosen: " & packNames[0])
  restartPlan("minecraft.packs")
  packPlanRunning = true
  running = true

proc start() =
  provideScheme(Scheme)
  provideService(GuiService)
  if not importAvailable():
    note("this host does not let mods import anything")
    return
  if not importOpens(".jar"):
    note("this host cannot open a .jar; it opens " & importContainers())
  root = findSource(Fingerprint)
  if root.len == 0:
    note("grant a Minecraft folder in " & importPolicyFile() & ", for example")
    note("  minecraft = " & importKnown("appdata") & "\\.minecraft")
  else:
    note("Minecraft at " & root)
  names = readIndex(BlockIndex)
  stateNames = readIndex(StateIndex)
  itemNames = readIndex(ItemIndex)
  recipeNames = readIndex(RecipeIndex)
  metaNames = readIndex(MetaIndex)
  packNames = readIndex(PackIndex)
  rebuildLayers()
  if stateNames.len > 0 or names.len > 0:
    note("an earlier import is still here: " & $stateNames.len & " blocks, " &
      $itemNames.len & " items")
    jarPath = remember("jar", "")
    jarVersion = remember("version", "")
    jarSearched = jarPath.len > 0
    # Which Minecraft this is, said on every boot and not only on the boot that
    # chose it. An import that is already done never reaches the picker, and a
    # fact that is only ever stated once is a fact nothing can be asked about
    # afterwards - which is how "it imported 26.2" went unnoticed for a day.
    log("[assert] minecraft.version=" & jarVersion)
    log("[assert] minecraft.target=" & remember("target", TargetVersion))
    publish()
    if (jarPath.len == 0 or guiCount == 0 or packPicture().len == 0) and root.len > 0:
      # An import from before this mod knew about the interface, or from before
      # it knew about the picture. The extractor skips a file already there at
      # the same size, so bringing it up to date costs the new globs and nothing
      # else.
      note("that import predates the interface or the picture; topping it up")
      beginImport(true)
  elif root.len > 0:
    # **Granting is not importing.** The grant is permission to read; nothing
    # had ever read. A player who has put the line in `imports.txt` has said
    # yes, and making them then find an undocumented keypress before anything
    # happens is how somebody ends up staring at a placeholder. M still forces
    # a re-read; it is no longer the only way in.
    note("reading your Minecraft now - this happens once")
    beginImport(false)
  else:
    note("grant a Minecraft above, or press M once you have")

## Whether the panel is worth drawing this frame. `mcpanel.wanted` is the rule
## and this is the clock it takes.
proc panelUp(): bool = wanted(running, gameTime() - saidAt, ask)

proc update() =
  stepLanguageAssets(root, jarPath)
  # How long the frame that just went by took, and therefore how much of this
  # one the language table may have. A mod cannot time its own work - the host
  # samples `jester_time` before the callback and it does not move while
  # the callback runs - so the frame that already happened is the only honest
  # signal there is. `aoughwl.spawner`'s `sources.pacePump` paces its
  # catalog reader off the same one.
  let frameMs = int(deltaTime() * 1000.0)
  paceLang(frameMs)
  pacePacks(frameMs)
  stepLang()
  if pressed("B"): ask = toggled(panelUp())
  if pressed("M") and not running: beginImport(false)
  if pressed("R"): beginImport(true)
  if pressed("K"):
    let gone = importForget(Extracted)
    note("removed " & $gone & " imported files; reload the pack to clear the catalog")
  if finding != 0: settleFinding(startingOver)
  listPacks()
  # A choice made on the resource pack screen, paid for here rather than inside
  # the service call that made it: an import started inside a service call would
  # start inside the caller's frame.
  if packChangeWanted and not running and finding == 0: startPackChange()

  # Measured against `fontRowReady`, not `published`: the font sheet is ready
  # to read the same frame the catalogs start filling, and a jar with enough
  # blocks and items to keep `published` false for a while must not hold the
  # loading screen's own text hostage to that count.
  stepFont()
  if published:
    fillVoxel()
    fillHud()
    stepRecipes()
    stepStates()
    stepMeta()
    stepIcons()
    checkFit()

  # A fresh install may have all of its index files already on disk when the
  # host starts. Keep finishing the catalog publication in later frames too;
  # `start()` and the import-complete callback can only do the first batch.
  if publishInitialized and not published:
    publish()

  if not running: return
  let status = tickPlan()
  if status == PlanStepDone:
    let job = planJob()
    # The cursor has already moved past the step that just answered, and the
    # pack plan numbers its own steps from zero. Both of those are `mcplan`'s
    # business now; neither is a subtraction written at this call site again.
    let at = finishedStep(planIndex())
    # The receipt moves with the cursor, on the same frame, so that the folder
    # and the saved state can never disagree about a step that really happened.
    if not packPlanRunning: writeReceipt()
    let role = if packPlanRunning: packRole(at) else: jarRole(at)
    if role == RoleListing:
      note("the jar lists " & $importCount(job) & " block models")
    elif role == RoleBlockModels:
      names = collect(job)
      writeIndex(BlockIndex, names)
      note("wrote " & $names.len & " block models")
    elif role == RoleBlockstates:
      stateNames = collect(job)
      writeIndex(StateIndex, stateNames)
      note("wrote " & $stateNames.len & " blockstates")
    elif role == RoleItemModels:
      itemNames = collect(job)
      writeIndex(ItemIndex, itemNames)
      note("wrote " & $itemNames.len & " item models")
    elif role == RoleItemDefinitions:
      # The fuller list when the jar has one, and silence when it does not.
      # An old jar leaves the item models step's answer standing rather than
      # replacing it with nothing, which is the whole point of choosing by
      # what is there.
      let defs = collect(job)
      if defs.len > 0:
        itemNames = defs
        writeIndex(ItemIndex, itemNames)
        note("wrote " & $itemNames.len & " item definitions")
      else:
        note("this jar keeps its items in models/item/ - " &
             $itemNames.len & " of them")
    elif role == RoleRecipes:
      recipeNames = collect(job)
      writeIndex(RecipeIndex, recipeNames)
      note("wrote " & $recipeNames.len & " recipes")
    elif role == RoleMeta:
      metaNames = collectPaths(job)
      writeIndex(MetaIndex, metaNames)
      note("wrote " & $metaNames.len & " texture metadata files")
    else:
      note("wrote " & $importCount(job) & " files")
  elif status == PlanFailed:
    running = false
    note("failed: " & planFailure())
  elif status == PlanDone:
    if packPlanRunning:
      packPlanRunning = false
      running = false
      rebuildLayers()
      note("resource packs are in place")
      save("jar", jarPath)
      save("version", jarVersion)
      fitChecked = false
      publish()
      # `publish()` answers only once, and a top-up import - one that ran
      # because an earlier import predated the interface - reaches this line
      # with `published` already true. The pictures still have to be offered
      # again, because the files they name have only just arrived.
      guiPublished = false
      publishGui()
      publishSky()
      # And the font sheet, here rather than a frame later. Measuring a 64x
      # pack's 512x512 sheet is a whole frame, and nothing repaints while a mod
      # is running, so the only question is which picture is frozen on the
      # screen while it happens. This frame's is the loading screen the player
      # has been watching for a minute; the next frame's is the title, which
      # would look like the game had hung the moment it arrived.
      measureFont()
    elif queuePacks():
      discard
    else:
      running = false
      rebuildLayers()
      save("jar", jarPath)
      save("version", jarVersion)
      fitChecked = false
      publish()
      # `publish()` answers only once, and a top-up import - one that ran
      # because an earlier import predated the interface - reaches this line
      # with `published` already true. The pictures still have to be offered
      # again, because the files they name have only just arrived.
      guiPublished = false
      publishGui()
      publishSky()
      # And the font sheet, here rather than a frame later. Measuring a 64x
      # pack's 512x512 sheet is a whole frame, and nothing repaints while a mod
      # is running, so the only question is which picture is frozen on the
      # screen while it happens. This frame's is the loading screen the player
      # has been watching for a minute; the next frame's is the title, which
      # would look like the game had hung the moment it arrived.
      measureFont()

proc drawGui() =
  if not panelUp(): return
  # Anchored to the right edge, not to the 1280-wide window somebody happened to
  # have open: x = 760 with a width of 560 wants 1320 px and ran off the side of
  # a shipped player.
  let wide = 560.0
  var x = screenWidth() - wide - 20.0
  if x < 20.0: x = 20.0
  beginPanel(x, 20.0, wide, 130.0 + 24.0 * float64(lines.len))
  heading("Minecraft")
  if running:
    label($planPercent() & "%  " & planNote())
  else:
    label("M import   R start over   K take it back   B hide")
    if root.len == 0:
      label("grant a folder in " & importPolicyFile() & " and press M")
  var i = 0
  while i < lines.len:
    label(lines[i])
    inc i
  endPanel()
