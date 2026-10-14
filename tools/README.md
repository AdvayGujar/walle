# Geometry diagnostics

These are how the tile corridor is inspected without a display. Build them with:

    ./scripts/swift.sh build -c release
    P=.build/scratch/release/walle-picker

    # render the corridor offscreen
    $P --snapshot /tmp/shot.png --width 1512 --height 982

    # print the exact slot rectangles, z and shear
    $P --dump-geometry            # add --collapsed for the collapsed row

    # read a snapshot as text
    xcrun swiftc -O tools/ascii.swift -o .build/ascii
    xcrun swiftc -O tools/asciicolor.swift -o .build/asciicolor
    xcrun swiftc -O tools/probe.swift -o .build/probe
    .build/ascii /tmp/shot.png             # luminance, as ASCII
    $P --snapshot /tmp/dbg.png --debug-tiles
    .build/asciicolor /tmp/dbg.png         # per-slot paint order, as letters
    .build/probe /tmp/dbg.png 1099,345     # exact pixel at a layout coordinate

--debug-tiles fills each slot with a flat colour (R G B Y M ... left to right), which is
how the compositing order inside an overlap is read off objectively rather than by eye.
