## The importing screen: what this machine can be imported from, and what has
## been imported already.
##
## This mod knows no game. It owns the ledger catalog, so exactly one mod
## creates it and every importer adds to it, and it draws two lists: the
## folders the player granted, and the receipts importers wrote. Which games
## those folders hold, and what came out of them, is entirely the importers'
## business - this mod never asks.
##
## I is the key. Nothing here reads a folder or writes a file.
##
## The screen is not drawn when there is nothing on it. With no folder granted
## and nothing imported this panel had two headings, no rows, and somebody's
## game behind it; the rule is now `importpanel.wanted` - a panel appears when
## it has something to say - and I summons it either way.

import jester
import importing
import importpanel

var
  ask = AskNothing
  open = false
  said = false

proc start() =
  # Whoever loads first owns the ledger; this mod exists so that it is always
  # this one, and an importer that loads alone still works because noteImport
  # creates the catalog itself if nobody has.
  importLedger()
  if not importAvailable():
    log("This host does not let mods import anything.")
  else:
    log("Importing ready. Granted folders are listed in " & importPolicyFile() &
      "; this host opens " & importContainers() & ".")

## Whether the ledger has anything to list, and therefore whether the screen is
## worth drawing. `importpanel.wanted` is the rule; this is the reading of the
## two numbers it takes.
proc showing(): bool =
  let sources = if importAvailable(): importSourceCount() else: 0
  wanted(sources, importedCount(), not importAvailable(), ask)

proc update() =
  if pressed("I"): ask = toggled(showing())
  open = showing()
  if not said and importAvailable() and importSourceCount() == 0:
    said = true
    log("No folder is granted yet. Add one line to " & importPolicyFile() &
      " - for example  minecraft = " & importKnown("appdata") & "\\.minecraft" &
      ". I shows the importing screen; it stays hidden while there is nothing" &
      " on it.")

proc drawGui() =
  if not open: return
  let sources = if importAvailable(): importSourceCount() else: 0
  let receipts = importedCount()
  # The height has to count every row that will be drawn, not only the listed
  # ones: with nothing granted this says two extra lines about where to grant
  # it, and at 150 the last two rows fell out of the bottom of the panel and
  # were drawn dim over whatever the room's background was. Measured in a
  # shipped player, which is where a panel too short for its own text shows.
  let advice = if sources == 0: 2 else: 0
  beginPanel(20.0, 20.0, 720.0,
    170.0 + 24.0 * float64(sources + receipts + advice))
  heading("Importing")
  if not importAvailable():
    label("This host does not let mods read anything outside themselves.")
    endPanel()
    return
  label("Granted folders (" & $sources & ") - the player decides, in " &
    importPolicyFile())
  if sources == 0:
    label("  none yet. One line per folder:  label = C:\\path\\to\\a\\game")
    label("  this machine keeps application data in " & importKnown("appdata"))
  var i = 0
  while i < sources:
    label("  " & importSourceLabel(i) & "  ->  " & importSourcePath(i))
    inc i
  space(8.0)
  label("Imported (" & $receipts & ")")
  var j = 0
  while j < receipts:
    label("  " & importedId(j) & "  by " & importedBy(j) & "  " &
      importedSummary(j))
    inc j
  space(8.0)
  label("Containers this host opens: " & importContainers() & "   -   I hides this")
  if sources == 0 and receipts == 0:
    label("Nothing is granted and nothing is imported, so this stays hidden.")
  endPanel()
