# MacGamingFix

MacGamingFix is a macOS helper for CrossOver/Wine games that use the macOS system cursor as the in-game cursor.

It reduces unwanted cursor reveals caused by macOS hot zones (Dock, menu bar, hot corners) during gameplay, while still allowing intentional in-game cursor shows (for example, pause/menu states).

## What It Solves

Some games hide the cursor with `CGDisplayHideCursor`, but macOS can still force it visible when a hidden "ghost cursor" reaches system trigger zones. This causes disruptive cursor flashes over gameplay.

MacGamingFix runs a high-frequency cursor fence that:

- Detects system-forced cursor reveals quickly
- Re-hides when needed
- Preserves expected game cursor behavior for intentional menu/UI shows
- Restores cursor visibility safely when you switch focus away from the game

## Requirements

- macOS 14 or later
- CrossOver/Wine game running in windowed or fullscreen mode
- Xcode (for building from source)
- Optional: Xcode Command Line Tools (for Game Mode toggle support)

## Build & Run

1. Open `MacGamingFix.xcodeproj` in Xcode.
2. Select the `MacGamingFix` target.
3. Build and run.

## Usage

1. Launch MacGamingFix.
2. Click **Activate**.
3. Start/return to your game.
4. Use your game normally.
5. Click **Deactivate** when done.

## Notes

- Dock hiding is not enforced by this app.
- Behavior adapts to Dock position (bottom/left/right).
- If you hit an edge case, please open a bug report using the repository template.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
