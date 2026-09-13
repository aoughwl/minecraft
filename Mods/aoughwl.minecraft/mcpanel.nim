## When the Minecraft importer's panel is worth drawing, as arithmetic.
##
## The importer has something to say exactly twice: while it is importing, and
## for a moment after it says anything. The rest of the time it is a legend of
## four keys drawn over somebody's game - which is what a real 1280x720 capture
## of `minecraft` showed, stacked on two other panels, covering the top
## half of the world.
##
## So this panel is **news rather than state**: it opens when the mod says
## something and closes itself a few seconds after the last thing it said,
## unless an import is actually running, in which case it stays up because a
## progress bar nobody can see is not a progress bar. `B` still summons it, and
## still dismisses it.
##
## Why a timer rather than "hide unless this pack is an importing pack": the
## state of this mod in `minecraft` with no Minecraft granted and the
## state of it in `aoughwl.minecraft.import` with no Minecraft granted are
## the same state, to the byte. Telling them apart would mean branching on the
## modpack's id, which is the one thing this project's house rules forbid, and
## it would be brittle the day somebody makes a fourth importing pack. A timer
## needs to know nothing about which pack it is in: what it shows is what just
## happened, which is true in both.
##
## Pure, so `Tests/picker_test.exe` can assert it with no host and no clock.

const
  Linger* = 12.0
    ## How long after the last note the panel stays up. Long enough to read two
    ## lines about granting a folder, short enough that it is gone before a
    ## player has finished walking to the first tree.

type
  Ask* = enum
    AskNothing, AskOpen, AskShut

func wanted*(running: bool; since: float; ask = AskNothing;
             linger = Linger): bool =
  ## `since` is how many seconds ago the mod last said something. A mod that
  ## has never said anything passes a `since` bigger than `linger`, and the
  ## panel stays down.
  case ask
  of AskOpen: true
  of AskShut: false
  of AskNothing: running or since < linger

func toggled*(showing: bool): Ask =
  if showing: AskShut else: AskOpen
