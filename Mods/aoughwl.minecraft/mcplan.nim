## Which step of the import plan just finished, and whose index it fills.
##
## Pure: nothing here calls the host.
##
## This file exists because two separate mistakes here were arithmetic on a step
## number, and arithmetic on a step number is exactly the kind of thing that can
## be settled in a test rather than in a play session.
##
## **The cursor has already moved on.** `tickPlan()` increments its cursor and
## *then* answers `PlanStepDone`, so `planIndex()` read on the frame a step
## finishes names the step about to start, not the one that just did. Filing a
## step's entries under `planIndex()` therefore put every list one place too far
## down: the blockstate index got block *textures*, the item index got
## *blockstates*, the animation index got item textures, and the recipe index got
## `.mcmeta` files. The voxel world then published no blocks at all, because
## `blockstates.txt` was a list of names ending in `.png` and no
## `blockstates/<name>.png.json` exists for any of them. `finishedStep` is that
## subtraction, written down once.
##
## **A second plan reuses the numbers.** The player's resource packs run as
## their own plan after the jar's, and a plan starts again at step 0 - so the
## pack plan's first step landed in the branch that writes the block index, and
## `blocks.txt` came out as the 4,846 files of Faithful 64x instead of the jar's
## 2,657 block models. That is where the panel's "4846 block models" came from.
## A step is named here by its plan *and* its number, so a pack step cannot
## reach a jar index however the pack plan is shaped.

const
  RoleNothing* = 0
    ## Not a step: asked before anything finished, or after the plan ended.
  RoleListing* = 1
    ## The scan that only counts what the jar holds.
  RoleBlockModels* = 2
  RoleBlockstates* = 3
  RoleItemModels* = 4
  RoleItemDefinitions* = 5
    ## `assets/minecraft/items/*.json`, which is where 1.21.4 and later keep the
    ## mapping from an item to its model. See `mcitem.nim`.
  RoleMeta* = 6
  RoleRecipes* = 7
  RoleFiles* = 8
    ## A step whose entries nothing indexes - textures, the interface, the font,
    ## the language files, a resource pack. Counted and reported, not filed.

## The step that just handed its entries over, from the plan cursor as it reads
## on that frame. Never call `jarRole` with a raw `planIndex()`.
proc finishedStep*(cursor: int): int = cursor - 1

## Whose index the jar plan's `finished`-th step fills. The numbers are the
## order `queue()` adds them in and the two must be read together; the roles
## with no number of their own fall through to `RoleFiles`, which is what makes
## appending a step to the end of the plan safe.
proc jarRole*(finished: int): int =
  if finished < 0: RoleNothing
  elif finished == 0: RoleListing
  elif finished == 1: RoleBlockModels
  elif finished == 3: RoleBlockstates
  elif finished == 4: RoleItemModels
  elif finished == 6: RoleMeta
  elif finished == 7: RoleRecipes
  elif finished == 8: RoleItemDefinitions
  else: RoleFiles

## Whose index a resource pack step fills: nobody's. A pack is copied over the
## jar and the jar's own lists still describe what is there, so every pack step
## is only ever a count.
proc packRole*(finished: int): int =
  if finished < 0: RoleNothing else: RoleFiles
