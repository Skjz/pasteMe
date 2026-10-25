<p align="center">
  <img src="docs/media/icon.png" width="128" height="128" alt="PasteMe icon">
</p>

<h1 align="center">PasteMe</h1>

<p align="center">
  Clipboard history for your Mac. Everything you copy is kept. Press ⇧⌘V to find it, ↩︎ to paste it.
</p>

<p align="center">
  <a href="https://github.com/Skjz/pasteMe/releases/latest"><b>Download</b></a>
  &nbsp;·&nbsp; macOS 14 or later &nbsp;·&nbsp; Free and open source &nbsp;·&nbsp; <a href="README.md">中文</a>
</p>

<p align="center">
  <img src="docs/media/hero.jpg" width="900" alt="The PasteMe panel rising from the bottom of the screen, with cards for recently copied links, images, code, files and text">
</p>

## 30-second demo

The captions are in Chinese and English.

https://github.com/user-attachments/assets/3354eec4-f3db-4d77-bcdc-d2529a14f3c0

## What it does

<table>
  <tr>
    <td width="50%" valign="top">
      <img src="docs/media/cards.jpg" alt="A row of cards whose title bars are Safari blue, Xcode blue and WeChat green">
      <h3>Cards wear the color of their app</h3>
      Text, links, images, files and code are all kept, and you can tell at a glance which app each came from.
    </td>
    <td width="50%" valign="top">
      <img src="docs/media/preview.jpg" alt="After pressing space, a sunset image grows out of its card into a preview window">
      <h3>Press space to preview</h3>
      Read long text in full, see images at full size and open links as web pages, without leaving the panel.
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <img src="docs/media/search.jpg" alt="Searching for 报销 (reimbursement) finds a screenshot of a coffee receipt, with every line of text on it recognized">
      <h3>Search the words inside screenshots</h3>
      When you copy an image, PasteMe reads the text in it on your Mac. Search for a word on a receipt and the receipt turns up.
    </td>
    <td width="50%" valign="top">
      <img src="docs/media/pinboard.jpg" alt="A Pinboard holding an email address, a canned reply and a shell command">
      <h3>Keep what you reuse on a Pinboard</h3>
      Pin email addresses, canned replies and commands. ⌘← and ⌘→ switch between your history and each Pinboard.
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <img src="docs/media/delete.jpg" alt="A code card breaking into dust from left to right and drifting up">
      <h3>Deleted the wrong one? ⌘Z</h3>
      ⌘⌫ deletes a card and it drifts away as dust. ⌘Z brings the dust back together.
    </td>
    <td width="50%" valign="top">
      <img src="docs/media/paste.jpg" alt="The panel has closed and the canned reply has been pasted into the draft">
      <h3>Press ↩︎ to paste</h3>
      Pick a card and press Return. The panel closes and the content lands in the app you were using.
    </td>
  </tr>
</table>

Also:

- **Paste Stack**: press ⌃⇧⌘C, copy several things in a row, then press ⌘V once for each to paste them in the order you copied them.
- **Knows code and common formats**: code is colored by language; colors, timestamps, Base64 and hex get their own look, and the Convert menu turns one into another or computes hashes.
- **Filters**: type `@` to filter by type, source app or Pinboard, or filter by date.
- **Drag out**: drag a card into any app. Files stay the original files, and images come with both the image and a PNG file.
- **Updates itself**: when a new version is out, the status bar menu shows Update to…; one click installs it, and only an installer signed by the publisher is accepted.

The [user guide](docs/guide.md) covers every feature in detail (in Chinese).

## Privacy

- Your history stays on your Mac and is never uploaded.
- Content that password managers mark as sensitive is never recorded.
- When you share your screen, record it or take a screenshot, others can't see the panel.
- PasteMe goes online in only three cases: a daily update check (which you can turn off), link previews if you turn them on in settings (off by default), and web pages you preview with space.

## Keys

| Key | Does |
| --- | --- |
| ⇧⌘V | Show the panel |
| ← → | Select a card |
| ↩︎ | Paste into the current app (⇧↩︎ pastes plain text) |
| Type | Search, including text in images |
| Space | Preview |
| ⌘1 … ⌘9 | Paste card 1 … 9 |
| ⌘⌫ / ⌘Z | Delete / undo |
| ⌘P | Pin to a Pinboard |

The full key list is in the [user guide](docs/guide.md#按键). The three global shortcuts (show the panel, pause recording, Paste Stack) can be changed in settings.

## Install

1. Download `PasteMe-<version>.dmg` from [Releases](https://github.com/Skjz/pasteMe/releases/latest), open it and drag PasteMe into Applications.
2. The first time you open it, macOS blocks it because PasteMe isn't notarized by Apple. Go to System Settings → Privacy & Security and click Open Anyway under Security. Or remove the download flag in Terminal:

   ```bash
   xattr -dr com.apple.quarantine /Applications/PasteMe.app
   ```

3. Turn on PasteMe in System Settings → Privacy & Security → Accessibility. Without it PasteMe still works, but you press ⌘V yourself after picking a card.

Later versions install from Update to… in the status bar menu, and the Accessibility permission carries over.

## More

- [User guide](docs/guide.md) (in Chinese): every feature in detail.
- [Development](docs/development.md) (in Chinese): building, testing and how the code is laid out.
- [Changelog](CHANGELOG.md)

Planned: choosing apps to ignore in settings, thumbnails for PDFs, videos and other files, and iCloud sync.

PasteMe's look and interaction are modeled on [Paste](https://pasteapp.io).

PasteMe is released under the [MIT License](LICENSE).
