## The models this mod ships, as data.
##
## They live here rather than as literals in `main.nim` for the reason
## `vxdefaults.nim` gives for the blocks: **`Tests/entity_test.exe` can read
## this file and cannot read that one.** A box whose rectangle runs off the
## edge of its picture, a limb hung off a box that does not exist, a cow twice
## as tall as a cow - every one of those is a thing you would find out by
## walking round it in a play session, and every one of them is now a failing
## check that takes a millisecond.
##
## Nothing here is privileged. These are exactly the rows any other mod or any
## modpack would ship in its own `entities.conf`; this mod's set is just the
## one that arrives first, and a later file is layered over it field by field
## (`vxmodel.parseModels`). The repository ships **no** `entities.conf` for
## that reason: there would then be two spellings of the same rows and one of
## them would go stale.
##
## ## What is in here and what is not
##
## **Geometry, and nothing else.** A box is a size and a pivot in sixteenths of
## a block - the shape of a thing, which is the sort of fact a ruler answers -
## and a `uv` is which corner of the picture that box reads from. **There is no
## picture here and there never will be.** Every texture comes from the
## player's own copy of the game at run time, through the same catalog row the
## skin does; a model whose texture nobody has granted is drawn in the flat
## `rgb` colours below, which is what the box player already does with its
## declared-but-empty skin catalog. No byte of Mojang's is in this repository.
##
## ## The handedness
##
## This engine faces +Z with the right hand at +X, which is the mirror of
## Minecraft's. So the numbers below are the mirror of the ones in the wiki:
## mirroring the **geometry** and leaving the rectangles alone is what keeps a
## face the right way round, exactly as `vxskin` says for the player. Mirroring
## the rectangles instead would give you a cow whose markings are backwards.
##
## ## The scale
##
## The player and the other humanoids are drawn at 15/16, because a 32-pixel
## model is two blocks and a player is 1.8 - Minecraft's own shrink. The
## animals are not: a cow model is 22 pixels and a cow is 1.4, which is 22/16
## to within a centimetre, so they say `scale=1.0`. `Tests/entity_test.exe`
## holds every model's picture to its stated height and that is the check that
## catches a scale somebody copied from the wrong mob.

const Models* = """
# The grammar is `screen.conf`'s: `# ...` is a comment and every other line is
# an id followed by `field=value` pairs. An id with a DOT in it is a box of the
# model named before the dot; an id without one is the model itself. See
# `vxmodel.nim` for what every field means.

# --------------------------------------------------------------------------
# The player, and everybody shaped like one.
#
# These six boxes are the ones `vxskin.nim` used to hold as literals. It reads
# them from here now, so there is one spelling: `Tests/view_test.exe` proves
# the unwrap of exactly these rows and did not change a line when they moved.

player                  tex=64,64 scale=0.9375 height=1.8 plate=1
player.head             at=-4,24,-4,4,32,4   pivot=0,24,0  uv=0,0   role=head   rgb=#c79978
player.trunk            at=-4,12,-2,4,24,2   pivot=0,24,0  uv=16,16             rgb=#00abb5
player.rightArm         at=4,12,-2,8,24,2    pivot=5,22,0  uv=40,16 role=armR   turn=45 rgb=#c79978
player.leftArm          at=-8,12,-2,-4,24,2  pivot=-5,22,0 uv=32,48 role=armL   turn=45 rgb=#c79978
player.rightLeg         at=0,0,-2,4,12,2     pivot=2,12,0  uv=0,16  role=legR   turn=45 rgb=#3d4587
player.leftLeg          at=-4,0,-2,0,12,2    pivot=-2,12,0 uv=16,48 role=legL   turn=45 rgb=#3d4587

# A zombie is a player with its arms held out in front of it. Same six boxes,
# same rectangles, one field different - which is the whole argument for the
# models being data rather than code.
zombie                  tex=64,64 scale=0.9375 height=1.95 plate=1
zombie.head             at=-4,24,-4,4,32,4   pivot=0,24,0  uv=0,0   role=head   rgb=#00afaf
zombie.trunk            at=-4,12,-2,4,24,2   pivot=0,24,0  uv=16,16             rgb=#00a8a8
zombie.rightArm         at=4,12,-2,8,24,2    pivot=5,22,0  uv=40,16 role=armR   turn=18 hold=-90 rgb=#00afaf
zombie.leftArm          at=-8,12,-2,-4,24,2  pivot=-5,22,0 uv=32,48 role=armL   turn=18 hold=-90 rgb=#00afaf
zombie.rightLeg         at=0,0,-2,4,12,2     pivot=2,12,0  uv=0,16  role=legR   turn=45 rgb=#2d4a8a
zombie.leftLeg          at=-4,0,-2,0,12,2    pivot=-2,12,0 uv=16,48 role=legL   turn=45 rgb=#2d4a8a

# A skeleton is the same layout with two-pixel limbs, on a 64x32 picture where
# the two arms read one rectangle and the two legs read another. That is what a
# pre-1.8 layout is, and it is not a special case here: the rectangle a box
# reads is a field, so two boxes reading one rectangle is two rows with the
# same `uv`.
skeleton                tex=64,32 scale=0.9375 height=1.99 plate=1
skeleton.head           at=-4,24,-4,4,32,4   pivot=0,24,0  uv=0,0   role=head   rgb=#c1c1c1
skeleton.trunk          at=-4,12,-2,4,24,2   pivot=0,24,0  uv=16,16             rgb=#b4b4b4
skeleton.rightArm       at=4,12,-1,6,24,1    pivot=5,23,0  uv=40,16 role=armR   turn=45 rgb=#c1c1c1
skeleton.leftArm        at=-6,12,-1,-4,24,1  pivot=-5,23,0 uv=40,16 role=armL   turn=45 rgb=#c1c1c1
skeleton.rightLeg       at=1,0,-1,3,12,1     pivot=2,12,0  uv=0,16  role=legR   turn=45 rgb=#b4b4b4
skeleton.leftLeg        at=-3,0,-1,-1,12,1   pivot=-2,12,0 uv=0,16  role=legL   turn=45 rgb=#b4b4b4

# --------------------------------------------------------------------------
# A creeper: a body on four short legs, and no arms at all.
#
# The four legs are two pairs and not four independents - front-right walks
# with back-left, which is how anything on four legs walks - so the diagonals
# share a role and the roles do the rest.

creeper                 tex=64,32 scale=1.0 height=1.7 plate=1
creeper.head            at=-4,18,-4,4,26,4   pivot=0,18,0  uv=0,0   role=head   rgb=#4f9c3c
creeper.trunk           at=-4,6,-2,4,18,2    pivot=0,18,0  uv=16,16             rgb=#4f9c3c
creeper.frontRightLeg   at=0,0,-6,4,6,-2     pivot=2,6,-4  uv=0,16  role=legR   turn=45 rgb=#3f8330
creeper.frontLeftLeg    at=-4,0,-6,0,6,-2    pivot=-2,6,-4 uv=0,16  role=legL   turn=45 rgb=#3f8330
creeper.backRightLeg    at=0,0,2,4,6,6       pivot=2,6,4   uv=0,16  role=legL   turn=45 rgb=#3f8330
creeper.backLeftLeg     at=-4,0,2,0,6,6      pivot=-2,6,4  uv=0,16  role=legR   turn=45 rgb=#3f8330

# --------------------------------------------------------------------------
# A spider: a head, a thorax, an abdomen and eight legs in a ring.
#
# `turn` on a `crawl` box is not an angle - it is which of the eight that leg
# is, and `vxanim.crawlYaw` turns a place in the ring into two angles. Eight
# legs each with their own sine is what Minecraft does; eight legs each with
# their own place in one ring is the same picture with no trigonometry in it.
#
# A spider's body does not reach the ground and is not meant to: the legs are
# horizontal sticks and the gait swings them down. That is why the standing
# check in `Tests/entity_test.exe` asks whether a model FLOATS rather than
# whether it touches.

spider                  tex=64,32 scale=1.0 height=0.9 plate=1
spider.thorax           at=-3,6,-3,3,12,3    pivot=0,9,0   uv=0,0               rgb=#2c2c38
spider.head             at=-4,5,-11,4,13,-3  pivot=0,9,-3  uv=32,4  role=head   rgb=#32323f
spider.abdomen          at=-5,5,3,5,13,15    pivot=0,9,3   uv=0,12              rgb=#26262f
spider.rightLegOne      at=3,8,-5,19,10,-3   pivot=3,9,-4  uv=18,0  role=crawl turn=0 rgb=#26262f
spider.rightLegTwo      at=3,8,-2,19,10,0    pivot=3,9,-1  uv=18,0  role=crawl turn=1 rgb=#26262f
spider.rightLegThree    at=3,8,1,19,10,3     pivot=3,9,2   uv=18,0  role=crawl turn=2 rgb=#26262f
spider.rightLegFour     at=3,8,4,19,10,6     pivot=3,9,5   uv=18,0  role=crawl turn=3 rgb=#26262f
spider.leftLegOne       at=-19,8,-5,-3,10,-3 pivot=-3,9,-4 uv=18,0  role=crawl turn=4 rgb=#26262f
spider.leftLegTwo       at=-19,8,-2,-3,10,0  pivot=-3,9,-1 uv=18,0  role=crawl turn=5 rgb=#26262f
spider.leftLegThree     at=-19,8,1,-3,10,3   pivot=-3,9,2  uv=18,0  role=crawl turn=6 rgb=#26262f
spider.leftLegFour      at=-19,8,4,-3,10,6   pivot=-3,9,5  uv=18,0  role=crawl turn=7 rgb=#26262f

# --------------------------------------------------------------------------
# The animals.
#
# **Read the `spin` note in `vxmodel.nim` before changing a body here.** A
# quadruped's barrel is authored STANDING UP and laid on its side by `spin=90`,
# because the picture is unwrapped from the box as authored: a cow's body is a
# box twelve wide, eighteen tall and ten deep, whose strip is forty-four pixels
# and fits, and the eighteen-deep box it looks like would want sixty and would
# run off the edge of a sixty-four pixel sheet. That is not a detail - it is
# why these rows and a real resource pack's picture can ever line up, and it is
# checked.
#
# `scale=1.0` and not the player's 15/16: a quadruped model is already the
# height of the animal.

pig                     tex=64,32 scale=1.0 height=0.9 plate=1
pig.trunk               at=-5,2,-4,5,18,4    pivot=0,10,0  uv=28,8  spin=90     rgb=#d98c8c
pig.head                at=-4,6,-14,4,14,-6  pivot=0,12,-6 uv=0,0   role=head   rgb=#dd9797
pig.snout               at=-2,8,-15,2,11,-14 pivot=0,12,-6 uv=16,16 of=head     rgb=#c97c7c
pig.frontRightLeg       at=1,0,-7,5,6,-3     pivot=3,6,-5  uv=0,16  role=legR   turn=40 rgb=#c97c7c
pig.frontLeftLeg        at=-5,0,-7,-1,6,-3   pivot=-3,6,-5 uv=0,16  role=legL   turn=40 rgb=#c97c7c
pig.backRightLeg        at=1,0,3,5,6,7       pivot=3,6,5   uv=0,16  role=legL   turn=40 rgb=#c97c7c
pig.backLeftLeg         at=-5,0,3,-1,6,7     pivot=-3,6,5  uv=0,16  role=legR   turn=40 rgb=#c97c7c

cow                     tex=64,32 scale=1.0 height=1.4 plate=1
cow.trunk               at=-6,8,-5,6,26,5    pivot=0,17,0  uv=18,4  spin=90     rgb=#4a3526
cow.head                at=-4,16,-15,4,24,-9 pivot=0,20,-9 uv=0,0   role=head   rgb=#4a3526
cow.rightHorn           at=4,23,-14,5,24,-13 pivot=0,20,-9 uv=22,0  of=head     rgb=#d0d0d0
cow.leftHorn            at=-5,23,-14,-4,24,-13 pivot=0,20,-9 uv=22,0 of=head    rgb=#d0d0d0
cow.frontRightLeg       at=2,0,-7,6,12,-3    pivot=4,12,-5 uv=0,16  role=legR   turn=40 rgb=#3d2b1f
cow.frontLeftLeg        at=-6,0,-7,-2,12,-3  pivot=-4,12,-5 uv=0,16 role=legL   turn=40 rgb=#3d2b1f
cow.backRightLeg        at=2,0,3,6,12,7      pivot=4,12,5  uv=0,16  role=legL   turn=40 rgb=#3d2b1f
cow.backLeftLeg         at=-6,0,3,-2,12,7    pivot=-4,12,5 uv=0,16  role=legR   turn=40 rgb=#3d2b1f

# A sheep is a cow's layout on a smaller body. Its wool is the same boxes grown
# by a pixel - `grow` is what a hat layer is, and a sheep is the reason it is a
# field rather than a second set of boxes - and the wool boxes are not here
# because a second layer needs a second picture and nobody has granted one. See
# the note at the top of this file about what is and is not in this repository.
sheep                   tex=64,32 scale=1.0 height=1.3 plate=1
sheep.trunk             at=-4,7,-3,4,23,3    pivot=0,15,0  uv=28,8  spin=90     rgb=#e8e8e8
sheep.head              at=-3,15,-16,3,21,-8 pivot=0,18,-8 uv=0,0   role=head   rgb=#d6c4b0
sheep.frontRightLeg     at=1,0,-7,5,12,-3    pivot=3,12,-5 uv=0,16  role=legR   turn=40 rgb=#d6c4b0
sheep.frontLeftLeg      at=-5,0,-7,-1,12,-3  pivot=-3,12,-5 uv=0,16 role=legL   turn=40 rgb=#d6c4b0
sheep.backRightLeg      at=1,0,3,5,12,7      pivot=3,12,5  uv=0,16  role=legL   turn=40 rgb=#d6c4b0
sheep.backLeftLeg       at=-5,0,3,-1,12,7    pivot=-3,12,5 uv=0,16  role=legR   turn=40 rgb=#d6c4b0

# A chicken: two thin legs, a beak and a wattle hung off the head, and two
# wings that flap rather than swing. The beak and the wattle hang off the head
# so that turning the head takes them with it - which is the whole reason a box
# may name a parent.
chicken                 tex=64,32 scale=1.0 height=0.8 plate=1
chicken.trunk           at=-3,4,-4,3,12,4    pivot=0,8,0   uv=0,9   spin=90     rgb=#e8e8e8
chicken.head            at=-2,8,-5,2,14,-2   pivot=0,9,-2  uv=0,0   role=head   rgb=#e8e8e8
chicken.beak            at=-2,10,-7,2,12,-5  pivot=0,9,-2  uv=14,0  of=head     rgb=#e0a040
chicken.wattle          at=-1,8,-7,1,10,-5   pivot=0,9,-2  uv=14,4  of=head     rgb=#c02020
chicken.rightLeg        at=0,0,-2,3,5,1      pivot=1,5,-1  uv=26,0  role=legR   turn=40 rgb=#e0a040
chicken.leftLeg         at=-3,0,-2,0,5,1     pivot=-1,5,-1 uv=26,0  role=legL   turn=40 rgb=#e0a040
chicken.rightWing       at=3,6,-3,4,10,3     pivot=3,10,0  uv=24,13 role=wingR  turn=60 rgb=#d8d8d8
chicken.leftWing        at=-4,6,-3,-3,10,3   pivot=-3,10,0 uv=24,13 role=wingL  turn=60 rgb=#d8d8d8

# --------------------------------------------------------------------------
# The flat ones.
#
# A dropped item and a thrown thing are not boxes - they are one square of a
# picture that turns to face you, which is what `flat` says and is what the
# chip particles already are. They carry no boxes at all and they are drawn in
# ONE batched mesh for all of them rather than as a part each: the same
# decision, for the same reason, as `vxfeel.meshFrameCost`.

item                    flat=0.45,0.45 height=0.25
arrow                   flat=0.5,0.16  height=0.16
snowball                flat=0.3,0.3   height=0.25
fireball                flat=0.6,0.6   height=0.6
"""
