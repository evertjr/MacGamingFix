<p align="center">
  <img src="assets/icon.png" width="128" height="128" alt="MacGamingFix icon">
</p>

<h1 align="center">MacGamingFix</h1>

<p align="center">
  Fix the ghost cursor problem in CrossOver/Wine games on macOS.
</p>

<p align="center">
  <img src="assets/screenshot.png" width="400" alt="MacGamingFix screenshot">
</p>

## The Problem

The cursor appearing during gameplay is a well-known problem on most games running through translation layers on macOS. It happens because Windows games don't request the correct presentation mode, so the game renders above the system UI instead of replacing it. While this sounds simple to fix, it's a comically hard problem — the macOS system cursor lives as an invisible "ghost" that keeps drifting with mouse movement even after the game hides it. When this ghost cursor reaches a hot zone (Dock, menu bar, hot corners), macOS forces the cursor visible, causing a disruptive flash over your game.

The fact that CrossOver and Wine have left this unsolved for so many years suggests there isn't much they can do on their side — it's the game process that should request the correct presentation mode, and a translation layer can't easily fake that.

### Common workarounds

- **Running macOS at a larger scale than the game** — the game maps its area to coordinates that don't touch the hot zones. Works, but forces you into a non-native resolution.
- **Playing with a gamepad** — avoids mouse movement entirely, so the ghost cursor never drifts into hot zones. Not an option for games that need mouse input.
- **Apps that fully hide the cursor** — these hide the system cursor entirely, which also hides the in-game cursor when the game intentionally shows it (pause menus, inventory screens), leaving users reliant on keyboard shortcuts to navigate.

## How MacGamingFix Works

MacGamingFix monitors both what the game requested and where the cursor is positioned, and attempts to determine whether a cursor appearance is a false positive (ghost cursor hitting a hot zone) or a legitimate reason to show the cursor (the game intentionally revealed it). When it's a false positive, the cursor gets re-hidden before the next frame — fast enough that the user never sees it. When it's intentional, MacGamingFix steps aside.

It uses private macOS APIs to track cursor visibility state over time and applies multiple hiding strategies to handle games that resist standard cursor control.

### Cursor Toggle Shortcut

MacGamingFix includes a configurable global shortcut for manually showing or hiding the cursor while Cursor Fix is active. The default is `⌃⌥⌘H`, and it can be changed from the app.

The shortcut works out of the box in windowed games. **True-fullscreen** games (the kind that captures the display directly) bypass the standard macOS hot-key system, so the shortcut won't fire in them unless MacGamingFix is allowed to listen at a lower layer. To make that possible, the app can optionally install a HID-level keyboard event tap, which macOS gates behind the **Accessibility** permission. Granting it lets the shortcut recover the cursor inside any game, including fullscreen ones; declining keeps the rest of the app fully functional and the shortcut still fires in windowed games. You can enable it any time from the Cursor Toggle popover.

### Game Mode

MacGamingFix can optionally enable macOS Game Mode, which reduces Bluetooth audio/input latency and prioritizes CPU/GPU scheduling for your game. This requires Xcode Command Line Tools to be installed.

### Standard F-Keys

Apple keyboards default F1–F12 to media controls (brightness, volume, etc.). MacGamingFix can temporarily switch them to standard function keys for gaming, and automatically reverts to your original setting when you toggle it off or quit the app.

## Requirements

- macOS 26 or later
- CrossOver or Wine game
- Optional: Xcode Command Line Tools (for Game Mode)

## Installation

1. Download the latest `.zip` from the [Releases](../../releases/latest) page.
2. Unzip and drag **MacGamingFix.app** to your Applications folder.
3. Launch the app — it's signed and notarized, so macOS will let it run without any extra steps.

## Usage

1. Launch MacGamingFix.
2. Tap **Cursor Fix** to activate.
3. Switch to your game and play.
4. Tap **Cursor Fix** again to deactivate when done.

## Build from Source

If you'd rather build it yourself:

1. Clone the repository.
2. Open `MacGamingFix.xcodeproj` in Xcode 26+.
3. Build and run (Cmd+R).

## Limitations

- Uses private macOS APIs that may change between OS versions.
- The heuristic approach is not perfect. Edge cases exist where the cursor may briefly appear or fail to appear in rare situations.
- App Sandbox is disabled (required for `dlsym` access to private frameworks and `gamepolicyctl`).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

See [LICENSE](LICENSE).
