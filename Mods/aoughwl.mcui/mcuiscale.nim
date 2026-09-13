## The GUI scale, which is why Minecraft's interface looks like Minecraft.
##
## Everything Minecraft draws on a screen is laid out in a coordinate space of
## whole pixels and then blown up by a whole number. A button is 200 by 20 and
## it is drawn at 1x, 2x, 3x or 4x - never at 2.37x. That is the entire reason
## the art stays crisp: every source pixel lands on exactly `scale` by `scale`
## screen pixels, with no filtering across a boundary and no half-pixel seam
## anywhere. A clone that lays the same art out in floating point over the real
## window size gets every proportion right and still looks wrong, because the
## edges shimmer.
##
## So this module answers two questions and the rest of the mod asks nothing
## else about size: how big is one interface pixel, and how big is the
## interface in those pixels.
##
## The rule itself is Minecraft's `Window.calculateScale`, which is a loop and
## not a formula:
##
##     int i = 1;
##     while (i != guiScale
##            && i < width && i < height
##            && width / (i + 1) >= 320
##            && height / (i + 1) >= 240) ++i;
##
## `guiScale` of 0 means "auto" and never equals `i`, so auto runs the loop out
## and lands on the largest scale that still leaves 320 by 240 interface pixels
## to lay out in. A chosen scale stops the loop early - and is still clamped by
## the same two conditions, which is why picking 4 on a small window quietly
## gives you 2 in the real game rather than a menu with its buttons off the
## side.

const
  MinGuiWidth* = 320
    ## The narrowest interface Minecraft will lay out in. Below this it drops a
    ## scale rather than letting a 200-wide button leave the window.
  MinGuiHeight* = 240
  MaxGuiScale* = 4
    ## What the options screen offers. Nothing here enforces it - the loop's own
    ## conditions do - but a chosen value above this is not a Minecraft one.
  AutoGuiScale* = 0

## The scale for a window this big, honouring a chosen setting when it fits.
## `setting` is 0 for auto, or 1..4.
proc guiScale*(width, height: int; setting = AutoGuiScale): int =
  var i = 1
  while i != setting and i < width and i < height and
        width div (i + 1) >= MinGuiWidth and
        height div (i + 1) >= MinGuiHeight:
    inc i
  i

## How wide the interface is, in interface pixels, on that window at that scale.
## Integer division, so the leftover strip on the right of the window is outside
## the interface - which is exactly where Minecraft leaves it.
proc guiWidth*(width, scale: int): int =
  if scale <= 0: width else: width div scale
proc guiHeight*(height, scale: int): int =
  if scale <= 0: height else: height div scale

## A point on the screen, in interface pixels. Not rounded: the caller wants to
## know where the pointer is between two interface pixels when it is hit-testing
## a one-pixel border.
proc toGui*(px: float; scale: int): float =
  if scale <= 0: px else: px / float(scale)

## The other way: an interface pixel's top-left corner on the screen. Whole
## numbers in, whole numbers out, which is the property the whole module is for.
proc toScreen*(gui: float; scale: int): float = gui * float(scale)

## Whether a laid-out rectangle really is on whole screen pixels. Nothing in
## the mod branches on this; it is the property the test asserts, spelled once
## here so that the assertion and the layout cannot drift apart.
proc snapped*(guiValue: float; scale: int): bool =
  let px = guiValue * float(scale)
  px == float(int(px))
