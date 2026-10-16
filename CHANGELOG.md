# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Card headers take the main color of the source app's icon instead of a fixed color per type, with dark header text on light colors such as yellow and light green. Cards from an unknown app keep the color of their type. The app icon in the header is larger and tucked into the top-right corner, partly cropped by the card edge, with a soft shadow.
- A glowing cursor ring marks the selected card and slides between cards as the selection moves; the selected card also grows slightly. The ring takes the card's header color. Choose between two styles under "光标样式" in the menu bar menu: 呼吸 (a softly pulsing glow, the default) or 流光 (a gradient border that rotates around the card). With Reduce Motion turned on, the ring stops moving.

- The panel slides up from the bottom of the screen with a slight bounce (about 0.3 s) and slides back down when it closes (about 0.17 s). The first cards rise and fade in one after another. Pressing ⇧⌘V again while the panel is closing sends it back up from where it is. With Reduce Motion turned on in System Settings, the panel only fades in and out. Pasting is as fast as before: the panel gives keyboard focus back to the target app as soon as it starts closing. (#2)

- ⌘Z in the panel restores entries deleted since the panel was opened, most recent first. (#1)

- Menu bar app that records everything you copy — text, links, images and files — into a local SQLite history at `~/Library/Application Support/PasteMe/history.sqlite`, with no item limit.
- Copied image files (PNG, JPEG, HEIC, GIF and other formats ImageIO can read) show a thumbnail of the image on their card instead of a generic file icon. The thumbnail is saved when the file is copied, so it still shows after the file is moved or deleted.
- Copying the same content again moves the existing entry to the top instead of adding a duplicate.
- Content that password managers mark as concealed or transient (`org.nspasteboard.ConcealedType` and related types) is never recorded.
- ⇧⌘V opens a history panel along the bottom of the screen under the mouse, showing one card per entry with its type, source app icon and copy time.
- Panel keyboard controls: type to search, ← → to select, ↩ or double-click to paste into the frontmost app, ⇧↩ to paste as plain text, ⌘1–⌘9 to paste one of the first nine entries, ⌘⌫ to delete, esc to clear the search or close.
- Right-click menu on cards with paste, paste as plain text and delete.
- Menu bar menu with pause recording, launch at login, accessibility permission status and clear history.
- `scripts/bundle.sh` builds and signs `build/PasteMe.app`, using an Apple Development certificate when one is available so the accessibility permission survives rebuilds.
- Architecture decision records `docs/adr/0002`–`0005` (module and target layout, single-threaded store, LIKE search instead of FTS5, hand-written MCP JSON-RPC) and a `GLOSSARY.md` defining the project's domain terms.
- `AGENTS.md` and `docs/agents/` describing where agent skills track issues (GitHub Issues), which triage labels they use, and where domain docs live.
- `docs/architecture.md`, a guide for contributors and agents to the target layout, the paste flow, the seams and their test fakes, and how to run the app against a throwaway history; `AGENTS.md` points to it, and a new `CLAUDE.md` imports `AGENTS.md` so Claude Code sessions load it too. ADR 0006 records why settings are read through `UserDefaults.standard` inside the app bundle.

### Fixed

- Opening and closing the panel no longer stutters. After the card color and cursor changes, about a third of the frames while the panel slid up missed the 120 Hz deadline: every card clipped its enlarged header icon at run time, so each card had to be recomposited on every frame of its entrance animation. The cropped icon with its shadow is now drawn once per app as an image that fits the header. Closing also no longer blocks for 30–50 ms moving the panel's content into a separate window for the slide-out; the panel slides out itself.

- Pressing ⌘⌫ in the panel's search field to delete the typed text no longer deletes the selected clipboard entry. (#1)

### Changed

- The card row has 30 pt margins on both sides and 18 pt between cards. When the selection scrolls the list, the selected card keeps the margin instead of sitting against the panel edge.

- The panel now tracks keyboard focus: the search field when the panel opens, the card list after ↓ or a click on a card. ⌘⌫ and ⌘Z act on the search text while the search field has focus, and delete the selected entry / undo the delete while the card list has focus. ← → move the text cursor when the search field has text, and select cards otherwise. ↑ or typing returns focus to the search field. The selected card's border is brighter when the card list has focus, and the hint line lists the keys for the current focus. (#1)
- `ClipStore.delete(id:)` now returns the deleted entry as a `DeletedClip`, and the new `ClipStore.restore(_:)` puts it back with its original id, time, source and thumbnail. If the same content was copied again in the meantime, the newer entry is kept. Panel key handling moved into `PanelKeymap`, a pure function covered by `PanelKeymapTests`.

- The app code moved out of the `PasteMe` executable target into a new `PasteMeApp` library target, so panel logic can be unit-tested; `PasteMe` now contains only `main.swift`. A new `PasteMeAppTests` target covers moving the selection and which card is selected after a delete.
- `ClipStore.recent(limit:matching:)` is replaced by `ClipStore.items(matching:)`, which takes a `ClipQuery` value. `ClipQuery` currently holds the search text and the result limit; how a query becomes SQL is kept in `ClipQuery.swift`.
- The paste flow moved from `AppDelegate` into `Paster` in `PasteMeCore`. `paste(_:as:into:)` takes `.original` or `.plainText` and a target app, and returns `.pasted` or `.copiedOnly` (no accessibility permission). Writing the pasteboard and sending ⌘V are injected adapters, so tests run against in-memory fakes. The app hides the panel before calling it.
- New `Settings` type in `PasteMeCore`, stored in the `io.github.skjz.PasteMe` defaults domain, with a single switch `showDuringScreenSharing` (off by default) for the upcoming screen-sharing option. Nothing in the app reads it yet.
