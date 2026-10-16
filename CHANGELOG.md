# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

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
