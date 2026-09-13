## When the inventory library's one screen is worth drawing, as arithmetic.
##
## This mod draws a single panel saying that it loaded and that its arithmetic
## holds, and it exists for a real reason: a modpack of nothing but libraries
## came up as an unbroken black rectangle in a shipped player, and a person
## looking at it had no way to tell that from a mod that had failed to load.
##
## The reason is real and the panel was permanent, which is a different thing.
## `aoughwl.inventory` is in `minecraft` too, where it is a
## library under a game, and there its "self-check 23 of 23 - all pass" sat over
## the world for the whole session. A check that passes is not news after the
## first few seconds; a check that FAILED is news for ever, and stays up.
##
## So: up at the start of a session, where it answers the black-rectangle
## question, then down. Up for good when something failed. `L` summons it back
## either way, which is new - the panel had no key at all before, which is part
## of why it never went away.
##
## Pure, so `Tests/picker_test.exe` can assert it with no host and no clock.

const
  Linger* = 12.0
    ## Long enough to read three lines, and gone before anybody has finished
    ## deciding what to do in the game underneath it.

type
  Ask* = enum
    AskNothing, AskOpen, AskShut

func wanted*(passed, checks: int; since: float; ask = AskNothing;
             linger = Linger): bool =
  ## `since` is how long this mod has been loaded, in seconds. `passed` and
  ## `checks` are the self-check's own two numbers: anything other than all of
  ## them passing keeps the panel up, because that is the case the panel was
  ## written for.
  case ask
  of AskOpen: true
  of AskShut: false
  of AskNothing: passed != checks or since < linger

func toggled*(showing: bool): Ask =
  if showing: AskShut else: AskOpen
