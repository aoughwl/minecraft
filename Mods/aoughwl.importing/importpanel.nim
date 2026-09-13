## When the importing screen is worth drawing, as arithmetic.
##
## This mod's panel used to open at boot and stay open, which is right in a pack
## whose whole point is importing and wrong in every other pack that carries
## this mod for the ledger. In a shipped 1280x720 player it read
## "Importing / Granted folders (0)" across the top of a Minecraft world, with
## nothing under either heading, while two more panels stacked on top of it.
##
## The rule is the one a person would state: **a panel appears when it has
## something to say.** Nothing granted and nothing imported is nothing to say -
## it is already a line in the log, which is where a fact with no rows belongs -
## and `I` is still there to summon the screen when somebody wants to read it.
##
## Pure, and called by `main.nim` alone, so `Tests/picker_test.exe` can assert
## it without a host, a screen or a modpack.

type
  Ask* = enum
    ## What the player last said with the key. A toggle has to be a tri-state:
    ## with only "open" and "shut" in it, a panel the rule opened cannot be
    ## dismissed by the same key that opens one the rule left alone.
    AskNothing, AskOpen, AskShut

func wanted*(sources, receipts: int; refused: bool; ask = AskNothing): bool =
  ## `sources` is how many folders the player has granted, `receipts` how many
  ## imports are on the ledger, and `refused` whether this host lets a mod read
  ## anything outside itself at all - which is one sentence worth showing,
  ## because a mod that can import nothing looks exactly like one that found
  ## nothing.
  case ask
  of AskOpen: true
  of AskShut: false
  of AskNothing: refused or sources > 0 or receipts > 0

func toggled*(showing: bool): Ask =
  ## What the key says next. Whichever way the rule had it, the key says the
  ## other, and goes on saying it until the key is pressed again.
  if showing: AskShut else: AskOpen
