## The mod that owns the queue two other mods meet on, and nothing else.
##
## `handoff.nim` beside this file is the whole library; read its head for what
## the queue is and why it is a catalog rather than a call. This file exists for
## two reasons and neither of them is code.
##
## The first is that a library in this engine is a mod: a `.nim` file is only
## importable across mods when some mod exports it, and a mod is a folder with a
## `mod.json` and an entry point. So there is an entry point.
##
## The second is the reason this is not a file inside `aoughwl.inventory`,
## where it started. A dependency is compiled into its dependents, and the
## runtime refuses a mod whose library's *export list* has changed since it was
## built - correctly, because it would otherwise go on running the copy it was
## built with. Adding one file to `aoughwl.inventory`'s exports therefore
## grounded every mod in the tree that depends on it until all of them were
## rebuilt. A new library with nothing depending on it yet costs nobody a
## rebuild, which is the whole difference.
##
## `start()` opens the queue so that it exists before any content mod's start()
## runs. Nothing depends on that - `ensureHandoff` is called by every producer
## and asks rather than assumes - but it means the catalog is owned by the mod
## whose name is on it rather than by whichever content mod happened to speak
## first, which is easier to read in a signature.

import jester
import aoughwl_handoff/handoff

proc start() =
  ensureHandoff()
  log("handoff: the player queue is open")

## There is deliberately no `drawGui` here. `aoughwl.inventory` has one so
## that a modpack of nothing but libraries is not an unbroken black rectangle,
## which is a good reason - but in a modpack with a game in it that panel sits
## in the middle of the game, and two of them sit on top of each other. This
## library says how it is instead through the log and through the count above,
## which `expect state` and the inspector can both read without a camera.
