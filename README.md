# AutoRaise Lite

A stripped-down fork of [AutoRaise](https://github.com/sbmpost/AutoRaise) v5.7 by sbmpost. It raises and focuses the window under the mouse once the pointer rests on it. There is no settings screen, config file or command line option: the behaviour is fixed in the code.

## Behaviour

- Checks the mouse every 50ms (`POLL_MILLIS`) and raises the window under it once the pointer has not moved for one check.
- Hold **Control** to temporarily disable it (`DISABLE_KEY`).
- The balloon icon in the menu bar has an **Enabled** toggle. The icon dims while disabled. It always starts enabled.
- Raises the window under the mouse after a space change.
- Leaves windows alone while a mouse button is down (dragging, resizing), while the Dock or Mission Control is active, over menus and the menu bar, for 3 checks after Cmd-Tab, for windows inside the focused window, and for windows that were just closed or are parked offscreen.

Removed from upstream: focus without raise (and the private SkyLight API it needs), mouse warp and cursor scaling, the alternative task switcher, ignore apps and titles, stay focused bundle ids, screen requirements, invert options, mouse delta, the config file, command line options and verbose logging.

## Install

Quit upstream AutoRaise first (and remove it from your login items): two of them running fight over the windows.

```sh
make install
```

This builds `AutoRaiseLite.app`, copies it to `/Applications` and loads a LaunchAgent that starts it at login and restarts it if it quits. Allow **AutoRaise Lite** when macOS asks for Accessibility (System Settings > Privacy & Security > Accessibility).

The app is ad hoc signed, so a rebuild that changes the binary invalidates the Accessibility permission: remove AutoRaise Lite from that list and run `make install` again.

- Stop: `launchctl bootout gui/$(id -u)/io.github.giannoulakis.autoraise-lite`
- Start: `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/io.github.giannoulakis.autoraise-lite.plist`
- Remove: `make uninstall`

## Changing the behaviour

Edit `POLL_MILLIS` or `DISABLE_KEY` at the top of `AutoRaise.mm` and run `make install`.

## Porting upstream fixes

`main` is this fork. `master` and the tags mirror upstream.

```sh
git remote add upstream https://github.com/sbmpost/AutoRaise.git  # once
git fetch upstream --tags
git log --oneline v5.7..upstream/master -- AutoRaise.mm
```

Port fixes to the raise path by hand. Skip changes to focus first (`FOCUS_FIRST`), warp and options, since they are gone here.

## License

GPL, see [LICENSE.md](LICENSE.md). Based on AutoRaise, Copyright (C) 2026 sbmpost.
