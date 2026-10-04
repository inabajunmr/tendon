# Tendon

![](assets/tendon_black.png)

Small macOS app for opening apps, windows, and bookmarks quickly.

## Run

```sh
swift run Tendon
```

The app lives in the menu bar as `Tendon`. Press `Option+N` to show or hide it by default.
Open `Preferences...` from the menu bar item to choose the launcher shortcut and whether Chrome
bookmarks are included.

## Package as an app bundle

```sh
make package
open -n dist/Tendon.app
```

`make package` builds a release app bundle. Debug logging is disabled in release builds.

## Package a debug app bundle

Use a debug bundle when investigating launcher behavior, hotkey handling, or window activation:

```sh
make package-debug
open -n dist/Tendon.app
```

Debug builds write JSONL logs to:

```text
logs/YYYYMMDD-HHMMSS.jsonl
```

Run `make package` again when you want to replace `dist/Tendon.app` with the normal release build.

## Build a GitHub release zip

Tendon is currently distributed as an unsigned/not-notarized Apple Silicon build.
To reuse the same local signing identity between builds, create an ignored `local.env`:

```sh
CODESIGN_IDENTITY=Tendon Local Code Signing
```

```sh
make release VERSION=0.1.0
```

This creates:

```text
dist/Tendon-0.1.0-macos-arm64.zip
Casks/tendon.rb
```

Upload that zip to GitHub Releases. If GitHub CLI is installed and authenticated, this can also
create or update the GitHub release:

```sh
make release-github VERSION=0.1.0
```

## Install with Homebrew

After the release zip is uploaded to GitHub Releases, this repository can be tapped directly:

```sh
brew tap inabajunmr/tako https://github.com/inabajunmr/tako
brew install --cask tendon
```

This installs `Tendon.app` into `/Applications` through Homebrew's Caskroom.

To update the cask for an already-built release zip:

```sh
make cask VERSION=0.1.0
```

Tendon is not notarized, so macOS may block the first launch. Right-click `Tendon.app` and choose
Open, or use the "Open Anyway" button in System Settings -> Privacy & Security.

## Controls

- `Option+N` or `Option+Space`: show or hide Tendon, depending on the selected preference
- Type to filter candidates case-insensitively
- `Command+A`: select all text in the search field
- `Up` / `Down`: move selection
- `Control+N` / `Control+P`: move selection while typing
- `Enter`: launch the selected app
- `Esc`: hide Tendon
- Click an item to open it

Applications are scanned from `/Applications`, `/System/Applications`, and `~/Applications`.
Currently running regular apps are also included, even when they are outside those folders.
Windows for running apps are included as separate candidates when macOS exposes a window title.
Selecting a window focuses that window when Accessibility permission is granted.
Google Chrome bookmarks are scanned from local Chrome profiles and are included as candidates once
you start typing when that source is enabled. Selecting a bookmark opens it with the default browser.
Sound input and output devices are included as candidates when you type terms such as `sound input`
or `sound output`. Selecting one switches the macOS default input or output device.
Paired or recently used Bluetooth devices are included as candidates when you type terms such as
`ble` or `bluetooth`. Selecting one connects or disconnects that device.
When the search field is not empty, the last candidate searches Google for the entered text.
On startup, Tendon checks its own Screen Recording and Accessibility status, then only
requests the missing permissions.
macOS may require Accessibility permission for window focusing and Screen Recording permission for
other apps' window titles. Screen Recording changes often require restarting Tendon.
If window titles do not appear, check System Settings -> Privacy & Security and make sure the
allowed item is the same app bundle you are launching. Rebuilding a locally signed app can make
macOS treat it as a new app for privacy permissions.

Matching results are ranked by local launch history: most recent launch first, then launch count,
then application name. History is stored at:

```text
~/Library/Application Support/Tendon/launch-history.json
```
