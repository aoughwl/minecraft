## A Minecraft-shaped player: a hotbar, ten hearts, ten haunches, armour, a
## level, an inventory screen with a bench in it, and the survival state that
## makes any of it mean anything.
##
## ## Where the work is
##
## Almost none of it is here. `main.nim` is the host seam - the keys, the
## character, the frame - and everything that can be wrong lives next door in
## files that call no host at all and are proved by `Tests/hud_test.exe` in
## under a second:
##
##   `hudcore.nim`    stacks, the forty slots, what a mouse button does to one,
##                    armour, hunger, regeneration, falling, and the experience
##                    curve
##   `hudrecipe.nim`  recipes as text, shaped and shapeless matching, the
##                    bench, and the player as one value
##   `huditems.nim`   the catalogs: five item facets and one recipe kind
##   `hudscreen.nim`  the drawing and the pointing
##
## ## What is a catalog and what is not
##
## Nothing in this mod knows what a stone is. Items come from
## `aoughwl.inventory`'s item catalogs, which this mod extends with the
## five facets a survival HUD needs - an icon, a food value, a saturation
## value, armour points and which armour slot - and recipes come from a kind
## this mod declares, `aoughwl.hud.recipe`, one recipe per row. A voxel
## mod that publishes a block and a recipe for it turns up in this inventory
## and on this bench without either mod naming the other, which is the whole
## point of the arrangement.
##
## The starter kit below is this mod's own content, published like anybody
## else's under `aoughwl.hud.starter`, and it exists so the modpack is
## playable with nothing else loaded. A game with real blocks in it publishes
## its own and both appear.
##
## Keys: 1-9 and the wheel pick a hotbar slot, E opens the inventory, F eats
## what is held, Q drops one of it, R respawns.

import jester
import vec
import color
import input
import entities
import catalogs
import character
import aoughwl_ui/ui
import aoughwl_handoff/handoff
import hudcore
import hudrecipe
import huditems
import hudscreen

const
  Starter = "aoughwl.hud.starter"
  StarterRecipes = "aoughwl.hud.starter.recipes"
  Ground = 1.0
  SpawnHeight = 2.0
    ## The plane and the height this mod puts a player on when it is the only
    ## thing in the modpack that has a world. When something else does - a
    ## voxel world, say - it says so on the handoff queue before the first
    ## frame and neither of these is used.

var
  hud = newHud(2, 2)
  registry = newRegistry()
  recipes: seq[Recipe] = @[]
  player = newCharacter()
  ready = false
  wasAt = vec3(0.0, 0.0, 0.0)
  showing = true

  ## ---- the seam with whoever has the world ---------------------------------
  ##
  ## This mod has a body, a floor and a spawn point of its own so that a modpack
  ## of nothing but the HUD is playable. In a modpack with a real world in it,
  ## that world places and drives the character, and a second body and a second
  ## camera beside it would be nonsense. The world says so on the handoff queue
  ## during its start(); this is read on the first frame, by which time every
  ## mod's start() has run - so neither mod has to load first.
  ourWorld = true

  ## Whether there is a world in front of the player at all.
  ##
  ## **The bug this exists for**: the hearts, the hunger and the experience bar
  ## were drawn over the main menu. The mod knew - it had already said
  ## `hud.ourworld=false` - and painted anyway, because `drawGui` asked whether
  ## it was ready and whether it was hidden and never whether there was a world.
  ##
  ## `ourWorld` is the wrong question to gate on and gating on it would have
  ## traded one bug for a worse one: in this modpack the world is
  ## `aoughwl.voxel`'s, so `ourWorld` is false for the whole session and
  ## the HUD would then never draw at all. The question is not *whose* world it
  ## is, it is whether one is up.
  ##
  ## Nor is it "who has the mouse", which was the other near miss. The pause
  ## screen has the mouse and has a world behind it, and Minecraft draws the
  ## HUD there; a mod that read the `pointer` verb would have hidden it.
  ##
  ## So whoever runs the menu says which of the two the player is looking at,
  ## on the handoff queue, in the same three places it already says who has the
  ## mouse. It starts true, so a modpack with no menu mod in it - every example
  ## pack, and the HUD on its own - is a world from the first frame and draws
  ## exactly as it did before.
  inWorld = true

  ## -1 until `drawGui` has decided once, so the first decision is always said.
  toldDrawn = -1
  begun = false
  handoffSeen = 0
  toldHold = ""
  pickups = 0

# ---------------------------------------------------------------------------
# This mod's own content
# ---------------------------------------------------------------------------

proc publishStarterKit() =
  let kit = hudItemCatalog(Starter, "Placeholder things to carry")
  defineHudItem(kit, "hud.stone", "Stone", stack = 64, icon = "0",
    tags = "block")
  defineHudItem(kit, "hud.plank", "Planks", stack = 64, icon = "1",
    tags = "block wood")
  defineHudItem(kit, "hud.stick", "Stick", stack = 64, icon = "2",
    tags = "wood")
  defineHudItem(kit, "hud.apple", "Apple", stack = 16, icon = "3", food = 4,
    saturation = 2.4, tags = "food")
  defineHudItem(kit, "hud.bread", "Bread", stack = 16, icon = "4", food = 5,
    saturation = 6.0, tags = "food")
  defineHudItem(kit, "hud.pickaxe", "Pickaxe", stack = 1, icon = "5",
    tags = "tool")
  defineHudItem(kit, "hud.sword", "Sword", stack = 1, icon = "6",
    tags = "tool")
  defineHudItem(kit, "hud.helmet", "Helmet", stack = 1, icon = "7",
    armour = 2, part = Head, tags = "armour")
  defineHudItem(kit, "hud.plate", "Chestplate", stack = 1, icon = "8",
    armour = 6, part = Chest, tags = "armour")
  defineHudItem(kit, "hud.greaves", "Greaves", stack = 1, icon = "9",
    armour = 5, part = Legs, tags = "armour")
  defineHudItem(kit, "hud.boots", "Boots", stack = 1, icon = "10",
    armour = 2, part = Feet, tags = "armour")
  defineHudItem(kit, "hud.coal", "Coal", stack = 64, icon = "11")
  defineHudItem(kit, "hud.iron", "Iron", stack = 64, icon = "12")
  defineHudItem(kit, "hud.log", "Log", stack = 64, icon = "13", tags = "wood")
  defineHudItem(kit, "hud.table", "Crafting table", stack = 64, icon = "14",
    tags = "block")
  defineHudItem(kit, "hud.torch", "Torch", stack = 64, icon = "15")

  let book = hudRecipeCatalog(StarterRecipes, "Placeholder recipes")
  defineShapeless(book, "hud.planks", @["hud.log"], "hud.plank", 4)
  defineShapeless(book, "hud.sticks", @["hud.plank", "hud.plank"],
    "hud.stick", 4)
  defineShaped(book, "hud.table", @["pp", "pp"], "p=hud.plank", "hud.table", 1)
  defineShaped(book, "hud.torch", @[".c.", ".s."],
    "c=hud.coal,s=hud.stick", "hud.torch", 4)
  defineShaped(book, "hud.pickaxe", @["iii", ".s.", ".s."],
    "i=hud.iron,s=hud.stick", "hud.pickaxe", 1)
  defineShaped(book, "hud.sword", @[".i.", ".i.", ".s."],
    "i=hud.iron,s=hud.stick", "hud.sword", 1)
  defineShaped(book, "hud.helmet", @["iii", "i.i"], "i=hud.iron",
    "hud.helmet", 1)
  defineShaped(book, "hud.plate", @["i.i", "iii", "iii"], "i=hud.iron",
    "hud.plate", 1)
  defineShaped(book, "hud.greaves", @["iii", "i.i", "i.i"], "i=hud.iron",
    "hud.greaves", 1)
  defineShaped(book, "hud.boots", @["i.i", "i.i"], "i=hud.iron",
    "hud.boots", 1)

## One of everything, so a person who loaded the modpack has something to
## carry before they have anything to break. Given once per save rather than
## once per session, so a hot swap does not refill the bag.
proc giveStarterKit() =
  if remember("hud.kit.given", false): return
  save("hud.kit.given", true)
  discard give(hud.inv, registry, "hud.stone", 64)
  discard give(hud.inv, registry, "hud.log", 12)
  discard give(hud.inv, registry, "hud.iron", 24)
  discard give(hud.inv, registry, "hud.coal", 16)
  discard give(hud.inv, registry, "hud.apple", 6)
  discard give(hud.inv, registry, "hud.bread", 3)

# ---------------------------------------------------------------------------
# What another mod hands the player
# ---------------------------------------------------------------------------

## Everything a world mod said since the last frame. Four verbs, and the rules
## behind all four are this mod's: a world reports that a block was picked up,
## that a body landed after so many decimetres, that so many metres were
## walked, and what it spent - and what a safe fall is, how much a stack holds
## and how much walking costs are answered here, from `hudcore`.
##
## Each of these is one line because each of them becomes a proc on this mod's
## side of a service call when there is one to make.
proc takeHandoffs() =
  for one in handed(handoffSeen):
    case one.verb
    of "give":
      let over = give(hud.inv, registry, one.subject, one.amount)
      if over > 0:
        say("no room for " & $over & " " & definitionOf(registry, one.subject).display)
      let took = one.amount - over
      if took > 0:
        pickups = pickups + took
        var slot = 0
        var found = -1
        while slot < FirstArmour:
          let s = hud.inv.at(slot)
          if (not isEmpty(s)) and s.item == one.subject and found < 0: found = slot
          slot = slot + 1
        log("[assert] hud.pickups=" & $pickups)
        log("[assert] hud." & one.subject & "=" & $countOf(hud.inv, one.subject))
        log("[assert] hud.newslot=" & $found)
        say("picked up " & definitionOf(registry, one.subject).display)
    of "spend":
      let gone = takeOut(hud.inv, one.subject, one.amount)
      log("[assert] hud." & one.subject & "=" & $countOf(hud.inv, one.subject))
      log("[assert] hud.spent=" & $gone)
    of "fell":
      # The world measured the drop; this decides what it cost.
      let hurtBy = fallDamage(float64(one.amount) / 10.0)
      if hurtBy > 0:
        hurt(hud.life, hurtBy)
        say("that was a long way down")
      log("[assert] hud.health=" & $hud.life.health)
    of "walked":
      walked(hud.life, float64(one.amount), false)
    of "world":
      # A menu mod says which of the two is in front of the player. Nothing
      # here knows which mod said it, and a modpack without one never says it
      # at all, which is why the default is a world and not a menu.
      inWorld = one.subject == "playing"
    else: discard

## What is in the player's hand, said out loud whenever it changes, so a world
## mod knows which block a right click puts down and whether there is one left.
## Said on change and not every frame: the queue is append-only.
proc tellHold() =
  let s = held(hud)
  var line = ""
  if not isEmpty(s): line = s.item & "|" & $s.count
  if line == toldHold: return
  toldHold = line
  if isEmpty(s): handOver("hold", "", 0)
  else: handOver("hold", s.item, s.count)

# ---------------------------------------------------------------------------
# The frame
# ---------------------------------------------------------------------------

proc reload() =
  registry = loadRegistry()
  recipes = loadRecipes()
  settle(hud.bench, recipes)
  refreshArmour(hud, registry)

proc openScreen() =
  hud.open = true
  freePointer()
  # Whoever has the world must stop digging through this screen.
  handOver("pointer", "free")
  # And say where everything on it came out, at this window and this scale, so
  # a headless run can assert the slots are where the arithmetic says rather
  # than photograph them. `hudscreen.proveLayout` is the check; the numbers it
  # logs are the ones `Tests/mcui_test.exe` derives independently.
  proveLayout()

proc shutScreen() =
  let over = closeScreen(hud, registry, recipes)
  if over > 0: say("no room for " & $over & " of it; still on the bench")
  lockPointer()
  handOver("pointer", "held")

proc keysForScreen() =
  if pressed(E):
    if hud.open: shutScreen() else: openScreen()
  elif pressed(Escape) and hud.open:
    shutScreen()

proc keysForHotbar() =
  if hud.open: return
  const Digits = [Digit1, Digit2, Digit3, Digit4, Digit5, Digit6, Digit7,
    Digit8, Digit9]
  var i = 0
  while i < Digits.len:
    if pressed(Digits[i]): hud.selected = i
    i = i + 1
  let turn = wheel()
  if turn != 0.0: hud.selected = scrolledSlot(hud.selected, turn)

proc keysForHands() =
  if hud.open: return
  if pressed(F):
    if eatHeld(hud, registry):
      say("eaten")
    else:
      say("nothing to eat")
  if pressed(Q) and not isEmpty(held(hud)):
    let name0 = definitionOf(registry, held(hud).item).display
    spendHeld(hud)
    say("dropped one " & name0)
    exhaust(hud.life, 0.005)

## Everything that happens to a player who is simply standing there: the
## hunger they spend on having walked, the fall they are in the middle of, the
## regeneration or the starvation that follows from both.
proc stepSurvival() =
  if player.body.isNothing():
    # Somebody else's world is carrying the body. The clock is still this
    # mod's - hunger, regeneration, starvation - and the walking and the
    # falling arrive as handoffs from the mod that can see the body.
    step(hud.life, deltaTime())
    if hud.life.dead and not hud.open: freePointer()
    return
  let at = player.position()
  let onGround = player.body.grounded()
  let moved = vec3(at.x - wasAt.x, 0.0, at.z - wasAt.z)
  wasAt = at
  if onGround:
    let sprinting = held(LeftShift) and canSprint(hud.life)
    walked(hud.life, len(moved), sprinting)
  let hurtBy = fell(hud.life, at.y, onGround)
  if hurtBy > 0:
    hurt(hud.life, hurtBy)
    say("that was a long way down")
  step(hud.life, deltaTime())
  if hud.life.dead and not hud.open:
    freePointer()

proc respawnPlayer() =
  respawn(hud.life)
  if ourWorld:
    player.teleport(vec3(0.0, SpawnHeight, 0.0))
    groundAt(hud.life, SpawnHeight)
    wasAt = player.position()
  refreshArmour(hud, registry)
  say("")
  if not hud.open: lockPointer()

## Everything that does not depend on what else is in the modpack. The floor,
## the body and the pointer wait for the first frame, because whether this mod
## has a world of its own is a question about the other mods and their start()
## has not necessarily run yet when this one does.
proc start() =
  publishStarterKit()
  reload()
  # Tell any world mod that there is a bag here, so it stops keeping its own.
  # Said now and read by the other mod on its first frame.
  handOver("keeps", "player")
  ready = true
  log("aoughwl.hud: " & $count(registry) & " kinds of thing, " &
    $recipes.len & " recipes from " & $recipeCatalogCount() & " catalogs")

## The first frame, by which time every mod in the pack has published whatever
## it publishes: whose world this is, what is in the catalogs, and therefore
## whether to build a floor and a player at all.
proc beginWorld() =
  begun = true
  ourWorld = not anybodySaid("owns")
  # Anything a mod published in its own start() after this one ran.
  reload()
  if ourWorld:
    if Ground > 0.0:
      let floor0 = shape(Plane, "Ground")
      floor0.scale(vec3(12.0, 1.0, 12.0))
      floor0.color(rgb(0.34, 0.46, 0.28, 1.0))
    player.configure("character.controls", "character.movement")
    player.place("Player", vec3(0.0, SpawnHeight, 0.0))
    groundAt(hud.life, SpawnHeight)
    wasAt = player.position()
  # The kit is a stand-in for content, and a modpack with a real world in it has
  # content. You start a survival world with nothing, which is also what makes
  # the first thing you dig the first thing in the bag.
  if ourWorld: giveStarterKit()
  refreshArmour(hud, registry)
  lockPointer()
  log("[assert] hud.ourworld=" & $ourWorld)
  log("[assert] hud.kinds=" & $count(registry))
  log("aoughwl.hud: the world is " &
    (if ourWorld: "this mod's" else: "another mod's") & ", " &
    $count(registry) & " kinds of thing")

proc update() =
  if not ready: return
  if not begun: beginWorld()
  # The importer's sizes and reason - here rather than in drawGui(), because
  # asking is a service call and a frame is sixteen milliseconds. The words are
  # a separate and far more expensive question, so they are asked for only on
  # the frames there is a word to say: the inventory screen's title and the
  # death screen's two lines are the whole of it. See `hudscreen.warmSkin`.
  warmSkin()
  takeHandoffs()
  keysForScreen()
  keysForHotbar()
  keysForHands()
  if hud.life.dead:
    warmWords()
    if pressed(R): respawnPlayer()
    return
  if ourWorld: player.step(turning = not hud.open)
  stepSurvival()
  tellHold()
  # Asked after the keys, not before them, so the frame E was pressed on is
  # already the frame the words are there for. `warmWords` latches, so this is
  # one comparison a frame afterwards.
  if hud.open: warmWords()

## Whether anything was painted, said whenever that changes.
##
## The state a test needs is not "does this mod think there is a world" - the
## mod already said `hud.ourworld=false` on the frame it drew hearts over the
## title screen, and a flag that agrees with the complaint while the pixels
## disagree is exactly the check that cannot fire. This is the pixels: it moves
## only when `drawGui` starts or stops painting, so it costs two lines a session
## and it goes red the moment the gate below is taken away.
proc sayDrawn(now: int) =
  if toldDrawn == now: return
  toldDrawn = now
  log("[assert] hud.drawn=" & $now)

proc drawGui() =
  if not ready or not showing:
    sayDrawn(0)
    return
  # No world in front of the player, no HUD over it. A screen that opens OVER
  # a world does not count and must not: this mod's own inventory, and the
  # pause screen, both leave the hearts and the hotbar where the game leaves
  # them, which is behind the screen.
  if not inWorld:
    sayDrawn(0)
    return
  sayDrawn(1)
  beginFrame()
  drawHud(hud, registry)
  if hud.open: drawInventory(hud, registry, recipes)
  drawHand(hud, registry)
  settleHudDrag()
  endFrame()

proc stop() =
  discard

# ---------------------------------------------------------------------------
# Things a headless run can ask for, so the mod answers in words rather than
# in pixels. `tools/run_mod.exe` calls these by name.
# ---------------------------------------------------------------------------

proc sayState() =
  log("hud: health " & $hud.life.health & "/20, hunger " & $hud.life.hunger &
    "/20, armour " & $hud.life.armour & ", level " &
    $levelOf(hud.life.experience) & ", slot " & $hud.selected)
  var line = ""
  var i = 0
  while i < PlayerSlots:
    let s = hud.inv.at(i)
    if not isEmpty(s):
      if line.len > 0: line = line & ", "
      line = line & $i & ":" & s.item & "x" & $s.count
    i = i + 1
  log("hud slots: " & line)

proc sayCatalogs() =
  log("hud: " & $count(registry) & " kinds of thing, " & $recipes.len &
    " recipes from " & $recipeCatalogCount() & " catalogs")
  var i = 0
  while i < recipes.len:
    log("  recipe " & recipes[i].id & " -> " & recipes[i].made & " x" &
      $recipes[i].count)
    i = i + 1

## Take up anything a mod published after this one started. A voxel mod that
## registers its blocks in its own `start()` is not necessarily earlier than
## this one, so this is the call that closes that gap - and it is a callback
## rather than a per-frame walk because a catalog read is a host call and this
## one is thirty of them per item.
proc adoptContent() =
  # An import that published content has usually just finished, so this is also
  # the moment the interface sizes and the language file are worth asking for
  # again. `warmSkin` does the asking, next update().
  forgetSkin()
  reload()
  log("hud: adopted " & $count(registry) & " kinds of thing and " &
    $recipes.len & " recipes")

## Run one real recipe through the real catalogs, and say what came out. The
## matching itself is proved in `Tests/hud_test.exe` against literals; this is
## the other half - that the text a catalog actually holds is the text the
## parser actually reads - and it is a callback so a headless run can ask.
proc proveBench() =
  var one = 0
  while one < hud.bench.cells.len:
    hud.bench.cells[one] = nothingStack()
    one = one + 1
  hud.bench.cells[0] = stack("hud.log", 1)
  settle(hud.bench, recipes)
  log("bench: a log makes " & hud.bench.made.item & " x" &
    $hud.bench.made.count)
  discard takeMade(hud, registry, recipes)
  log("bench: in hand, " & hud.carried.item & " x" & $hud.carried.count)
  hud.bench.cells[0] = stack("hud.plank", 1)
  hud.bench.cells[3] = stack("hud.plank", 1)
  settle(hud.bench, recipes)
  log("bench: two planks on a diagonal make " & hud.bench.made.item & " x" &
    $hud.bench.made.count)
  hud.bench.cells[3] = nothingStack()
  hud.bench.cells[1] = stack("hud.plank", 1)
  hud.bench.cells[2] = stack("hud.plank", 1)
  hud.bench.cells[3] = stack("hud.plank", 1)
  settle(hud.bench, recipes)
  log("bench: four planks in a square make " & hud.bench.made.item & " x" &
    $hud.bench.made.count)
  discard clearBench(hud.bench, hud.inv, registry, recipes)

## Wear everything wearable that is in the bag, and say what the armour bar
## came to - the other end of the facet pipeline, through real catalog rows.
proc proveArmour() =
  discard give(hud.inv, registry, "hud.helmet", 1)
  discard give(hud.inv, registry, "hud.plate", 1)
  discard give(hud.inv, registry, "hud.greaves", 1)
  discard give(hud.inv, registry, "hud.boots", 1)
  var slot = 0
  while slot < FirstArmour:
    if not isEmpty(hud.inv.at(slot)):
      discard quickMove(hud.inv, registry, slot)
    slot = slot + 1
  refreshArmour(hud, registry)
  log("armour: " & $hud.life.armour & " points from " &
    hud.inv.at(36).item & ", " & hud.inv.at(37).item & ", " &
    hud.inv.at(38).item & ", " & hud.inv.at(39).item)

proc showHud() = showing = true
proc hideHud() = showing = false

## Open and shut the screen from outside a key press, so a headless run can
## draw the half of the interface a person only sees with E held down.
proc openInventory() = openScreen()
proc closeInventory() = shutScreen()

## Take some damage and some falling, and say what it came to. The rules are
## proved against literals in `Tests/hud_test.exe`; this is here so a headless
## run of the real mod can show the same numbers moving.
proc proveSurvival() =
  hurt(hud.life, 6)
  log("hurt 6 through " & $hud.life.armour & " armour: health " &
    $hud.life.health & "/20")
  hud.life.hunger = 20
  hud.life.saturation = 0.0
  step(hud.life, 4.0)
  log("four seconds fed: health " & $hud.life.health & "/20, hunger " &
    $hud.life.hunger & "/20")
  groundAt(hud.life, 40.0)
  discard fell(hud.life, 40.0, false)
  let hurtBy = fell(hud.life, 20.0, true)
  hurt(hud.life, hurtBy)
  log("twenty metres down: " & $hurtBy & " half hearts before armour, health " &
    $hud.life.health & "/20")
  addExperience(hud.life, 400)
  log("four hundred points: level " & $levelOf(hud.life.experience))
