## The player, as six boxes and a 64x64 picture.
##
## **This file used to hold those six boxes as literals and no longer does.**
## They are rows in `vxbeasts.nim` now, beside the zombie and the cow, read by
## the general box-model reader in `vxmodel.nim`; what is left here is the
## player's own names for things - `Limb`, `limbs()`, `HeadLimb` - and the
## lookup that gets the player out of the set. `Tests/view_test.exe` did not
## change a line when they moved, which is the check that the generalisation
## did not move the player.
##
## Everything the old comment said is still true and is now said in the two
## files it belongs in:
##
##   * **why boxes and not the skinned pipeline** - `vxmodel.nim`'s header. A
##     box model is not an approximation of Minecraft's player, it *is*
##     Minecraft's player, and that goes for every mob as well.
##   * **what the picture is** - `vxbeasts.nim`'s header. The skin is the
##     player's own, out of the copy of the game they granted; this repository
##     ships no pixel of Mojang's and these files contain none. A player who
##     has granted nothing gets the same six boxes in the flat colours the
##     rows carry.
##   * **the layout** - `vxmodel.nim`'s header. Four sides in a strip, top and
##     bottom above them, and the strip is a real unwrap whose seams
##     `Tests/view_test.exe` and `Tests/entity_test.exe` both check by asking
##     whether two faces sharing a box edge landed in the same texture column.
##
## Nothing here reads a file, and nothing here calls the host.

import vxmodel
import vxbeasts
export vxmodel

const
  PlayerModel* = "player"
    ## Which row of the shipped models the player is. A name and not an index,
    ## because a modpack may add models before this one.
  SkinSide* = DefaultTexSide
    ## A skin is 64x64. The 64x32 skins from before 1.8 have no left arm and no
    ## left leg in them; they are not read here, and a modern skin is what
    ## every copy of the game since 2014 ships.
  ModelScale* = DefaultScale
    ## 15/16. The box model is 32 pixels tall, which is two blocks, and the
    ## player is 1.8; Minecraft draws the model at this scale for exactly that
    ## reason, and 32 * 0.9375 / 16 is 1.875.
  LimbCount* = 6
  HeadLimb* = 0
    ## Which of the six is the head, and therefore which one goes on the
    ## transform that follows where you are looking rather than where you are
    ## walking.

type
  Limb* = Box
    ## The player's word for a box. The same object: a limb of a player and a
    ## leg of a cow are the same kind of thing, which is the whole point.
  SkinRect* = TexRect
  LimbQuad* = BoxQuad

## The shipped models, read once.
##
## A module-level `var` has one instance per mod that imports the module, which
## is what is wanted: the set is parsed the first time anybody asks and never
## again, and a test asking in a different process gets its own.
var cached = noModels()
var cachedAt = -1

proc playerModel*(): Model =
  if cachedAt < 0:
    cached = readModels(Models)
    cachedAt = modelIndex(cached, PlayerModel)
  if cachedAt < 0: return blankModel(PlayerModel)
  cached.model[cachedAt]

## The six boxes, in the order the rows are in: head, trunk, right arm, left
## arm, right leg, left leg.
proc limbs*(): seq[Limb] = playerModel().boxes

## Where a limb hangs from, in metres, with the feet at y 0. One argument,
## because the player is the only model this file knows and does not have to be
## told which.
proc pivotXOf*(l: Limb): float = l.pivotX / PixelsPerBlock * ModelScale
proc pivotYOf*(l: Limb): float = l.pivotY / PixelsPerBlock * ModelScale
proc pivotZOf*(l: Limb): float = l.pivotZ / PixelsPerBlock * ModelScale

## How tall the whole model stands, in metres. The character's own `height` is
## published by `aoughwl.character` and is not this - this is what the
## picture measures, and the two agreeing to a few centimetres is the point.
proc modelHeight*(): float = pictureHeight(playerModel())

## One face of one box, in metres relative to the limb's pivot, with the
## texture coordinates the skin wants. `skinned` false leaves the coordinates
## at the plain 0..1 corners, which is the mesh a flat colour is painted onto.
proc limbQuad*(l: Limb; face: int; skinned = true): LimbQuad =
  boxQuad(playerModel(), l, face, skinned)
