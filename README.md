# Hangar

Your screenshots dock around the edges of the screen like ships in a hangar.

- **Take a screenshot:** a laser scans what you captured, then it launches as a hologram card, banks toward a free port with an exhaust trail and docks with its clamps shut.
- **Open the dock** (⌃⌥H, the menu bar, or rest the pointer in the menu bar): the HUD powers on and every screenshot warps in at once from all four edges. Close it and they warp away.
- Click a card to copy it, drag it into any app or folder, double click to open, hold for Markup, right click for more.

Ports fill round the sides in turn (top, right, bottom, left), from the middle outwards. Each screenshot keeps its port while it is docked.

## Build

    scripts/build-app.sh
    open build/Hangar.app

## Credits

Hangar is a fork of [Tendedero](https://github.com/alejandrobujan/tendedero) by Alejandro Buján, under the MIT License (see LICENSE). The watching, copying, dragging and editing all come from Tendedero; Hangar replaces the clothesline with the dock.
