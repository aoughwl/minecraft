## Which screen you are on, and how you got there.
##
## Nine screens is where a menu stops being five buttons and starts being a
## thing with a shape. The shape is a stack: every screen you open goes on top
## of the one you were on, and Cancel takes it off again - so Options opened
## from the title goes back to the title, and Resource Packs opened from Options
## goes back to Options, without either screen having to know which.
##
## `mcuimenu` has a two-value `Screen` for the title and its options page. This
## does not replace it and does not touch it - that enum is another agent's
## surface this week - it is the wider thing the whole stack is expressed in.
##
## ## The loading screen is a *place*, not a moment
##
## The interesting rule in this module, and the one the user asked for:
##
##     *"when we change resource pack we should have it go to that screen for
##     that change of resource pack loading"*
##
## So the loading screen is not something that happens before the menu, it is a
## screen the stack can be **sent to** and can come back from. `arrive` below is
## the whole of it: whenever the importer says it is reading, the stack goes to
## the loading screen and remembers where it was; when the importer stops
## saying so, the stack goes back there. That one rule covers three cases that
## would otherwise be three pieces of code:
##
##   * the first read at boot, which lands on the title;
##   * `R` to read it all again, from wherever you were;
##   * and a resource pack changed on the pack screen, which is the one the
##     complaint was about.
##
## It also means the loading screen cannot be got wrong by forgetting to leave
## it: leaving is a consequence of the importer's own state and not of anybody
## remembering to call something.
##
## ## Where a pack change comes back to
##
## The title, redrawn in the new pack's art - not the pack screen. That is
## deliberate and it is the user's own words: *"return to the title redrawn in
## the new pack's art"*. The point of changing a pack is to see it, and the pack
## screen is the one screen that hides most of it.

import mcuigrant
import mcuiload

type
  Page* = enum
    TitlePage,      ## the one with the logo on it
    WorldsPage,     ## Singleplayer
    CreatePage,     ## Create New World
    ServersPage,    ## Multiplayer
    AddServerPage,  ## Add Server, and Direct Connect, which is the same screen
    OptionsPage,
    # The options family. Minecraft's options screen is a hub and not a screen:
    # eight of its ten controls open another screen, and every one of those goes
    # back to it and not to whatever opened it. That is the stack doing its job
    # rather than nine screens each remembering where they came from - Options
    # from the title goes back to the title, and Options from the pause screen
    # goes back to the pause screen, without Video Settings knowing either
    # happened.
    VideoPage,
    ControlsPage,
    MousePage,      ## Mouse Settings, which Controls opens over itself
    LanguagePage,
    SoundPage,
    ChatPage,
    SkinPage,
    AccessPage,
    PacksPage,
    LoadingPage,    ## a place, per the above
    WorldPage,      ## no menu at all; the world has the screen
    PausePage       ## Escape, over the world. `mcuipause` owns everything
                    ## about it; the stack only has to know that it stands on
                    ## the world and that Options may stand on it.

  Stack* = object
    pages*: seq[Page]
    returnTo*: Page      ## where the loading screen puts you down
    reason*: LoadReason
    wasImporting*: bool
    awaiting*: int
      ## How many more frames the loading screen will wait for an import that
      ## has been *asked for* but has not started yet.
      ##
      ## This is the one piece of state that is not obvious and the one whose
      ## absence is a real bug. Choosing a resource pack tells the importer over
      ## a service, and the importer starts the work on *its* next frame - so on
      ## the frame the pack screen sends the stack here, nothing is being read
      ## yet, and a loading screen that closed the moment nothing was being read
      ## would flash and vanish before the thing it is waiting for began.
      ##
      ## So it waits. And it does not wait for ever: an importer that never
      ## starts - because the grant went away between the click and the frame -
      ## must still put the player back on a screen. `WaitFrames` is the budget
      ## and running out of it is not an error, it is landing.

const WaitFrames* = 240
  ## How long the loading screen waits for an import it has been promised. At
  ## the rate the menu polls while it is up this is a few seconds - long enough
  ## for an importer that is going to start, short enough that one which never
  ## does is not a screen nobody can leave.

## The stack a session starts with. The loading screen is what Minecraft opens
## on, so it is what this opens on, and `arrive` takes it away the moment the
## importer says there is nothing being read.
proc atBoot*(): Stack =
  Stack(pages: @[LoadingPage], returnTo: TitlePage, reason: FirstRead,
        wasImporting: false, awaiting: 0)

proc here*(s: Stack): Page =
  if s.pages.len == 0: TitlePage else: s.pages[s.pages.len - 1]

proc depth*(s: Stack): int = s.pages.len

## Open a screen over this one.
proc go*(s: var Stack; p: Page) =
  s.pages.add p

## Close this one. Never empties: the title is the floor, and a Cancel on the
## title is not a way out of the game.
proc back*(s: var Stack) =
  if s.pages.len <= 1: return
  var kept: seq[Page] = @[]
  var i = 0
  while i + 1 < s.pages.len:
    kept.add s.pages[i]
    inc i
  s.pages = kept

## Replace this screen rather than stacking on it - what Create New World does
## when it succeeds, because going "back" from the world it made should not
## return you to the form that made it.
proc swapTo*(s: var Stack; p: Page) =
  if s.pages.len == 0:
    s.pages = @[p]
    return
  s.pages[s.pages.len - 1] = p

## Throw the whole stack away and stand on one screen. Taking Singleplayer into
## a world does this: there is nothing behind the world to go back to, and a
## stack that still had four screens on it would come back inside out.
proc resetTo*(s: var Stack; p: Page) =
  s.pages = @[p]

proc showing*(s: Stack; p: Page): bool = here(s) == p

## Whether a menu is on the screen at all. The world takes the whole screen and
## the menu draws nothing over it.
proc menuUp*(s: Stack): bool = here(s) != WorldPage

# ---------------------------------------------------------------------------
# The importer's state, arriving

## Send the stack to the loading screen on purpose, saying why and where to come
## back to. The pack screen calls this; nothing else needs to, because `arrive`
## catches every other case on its own.
proc sendToLoading*(s: var Stack; why: LoadReason; comeBackTo: Page) =
  s.reason = why
  s.returnTo = comeBackTo
  s.awaiting = WaitFrames
  if here(s) != LoadingPage: s.go LoadingPage

## What the importer said this frame. Called every frame with the grant state
## and nothing else, and it is the only thing that opens or closes the loading
## screen.
##
## Two edges and not a level, which matters: the screen opens when the importer
## *starts* reading and closes when it *stops*, so a player who walked into the
## loading screen from the pack screen is not thrown out of it a frame later by
## a stale state, and a player sitting on the title while a background re-read
## finishes is not thrown anywhere at all.
proc arrive*(s: var Stack; state: GrantState) =
  let importing = state == Importing
  if importing and not s.wasImporting and here(s) != LoadingPage:
    # Something started reading and we were not expecting it - `R`, or the
    # first read finding a jar late. Come back to wherever we are now.
    s.returnTo = here(s)
    s.go LoadingPage
  if importing: s.awaiting = 0
  elif s.awaiting > 0 and here(s) == LoadingPage:
    # Promised, not started. Wait, and count.
    s.awaiting = s.awaiting - 1
    s.wasImporting = importing
    return
  if (not importing) and here(s) == LoadingPage:
    # It stopped. The loading screen is over whatever the outcome was: a grant
    # that turned out to be missing lands on the title with the notice on it,
    # which is the screen that can say so.
    s.resetTo s.returnTo
  s.wasImporting = importing

## Whether the loading screen should still be up at boot even though nothing is
## being read yet - the frame or two before the importer has answered anything
## at all. Without this the title flashes up and is replaced, which is exactly
## the thing a loading screen is for.
proc settling*(s: Stack; heard: bool): bool =
  here(s) == LoadingPage and not heard

## Which screen a page's Cancel or Done goes to when the stack is asked rather
## than popped - used only by the test, which walks every page and asserts that
## every one of them has a way out that is not itself. A screen you cannot leave
## is the failure this catches, and it is a failure that is invisible until
## somebody is standing on it.
proc parentOf*(p: Page): Page =
  if p == WorldsPage: TitlePage
  elif p == CreatePage: WorldsPage
  elif p == ServersPage: TitlePage
  elif p == AddServerPage: ServersPage
  elif p == OptionsPage: TitlePage
  elif p == VideoPage: OptionsPage
  elif p == ControlsPage: OptionsPage
  elif p == MousePage: ControlsPage
  elif p == LanguagePage: OptionsPage
  elif p == SoundPage: OptionsPage
  elif p == ChatPage: OptionsPage
  elif p == SkinPage: OptionsPage
  elif p == AccessPage: OptionsPage
  elif p == PacksPage: OptionsPage
  elif p == LoadingPage: TitlePage
  elif p == PausePage: WorldPage
  else: TitlePage
