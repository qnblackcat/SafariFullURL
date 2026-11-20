# SafariFullURL

[Safari iOS 27.3's full address bar, backported](https://x.com/galloeldo/status/2121305023812641124). While you edit the address bar, the whole URL wraps onto several lines instead of scrolling along a single one. 

Supports Safari on iPhone in portrait mode. iPad support is experimental and has only been tested on iPadOS 17.

## How it works

- **First tap**: same as stock Safari: the URL is selected and stays on one line.
- **Second tap**: the bar grows to show the full URL: upward with the address bar at the bottom (Tab Bar layout), downward with it at the top (Single Tab layout, the page below moves down with it). The URL stays selected and the Cut / Copy / Paste menu appears.
- **Typing, deleting or moving the caret** grows or shrinks the bar to fit the text.
- **Long URLs**: the bar shows up to 9 lines, and never takes more than a third of the screen (fewer lines with large text). Longer text scrolls inside the bar and follows the caret.
- The voice search button is hidden to give the URL more room, and the clear button sits at the bottom-right corner.

## iPad

The URL field sits in the toolbar at the top, so it behaves like the Single Tab layout: the bar grows downward and the tab bar and the page below it move down with it. This works in full screen, in Split View / Slide Over and in resizable windows, in portrait and landscape.

When the window is narrow, Safari switches to its iPhone-style bar and the iPhone behaviour applies. Closing the suggestions (tapping outside them) folds the bar again; there is no Cancel button on iPad.

## Cancel in the Single Tab layout

While the URL is unfolded in the Single Tab layout (iOS 15 and later), the **Cancel** button is hidden so the URL can use the full width. To cancel editing, tap an **empty space** below the address bar, in the list of suggestions: not a row, a section title or the gap between sections. It does the same as pressing Cancel. On the start page or a web page, tapping anywhere outside the bar cancels as it does in stock Safari.

## Building

<details>
<summary>Build instructions</summary>

Build the package with roothide's fork of Theos. 

```sh
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless
make clean package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide
make package SAFARIFULLURL_DEBUG=1   # debug: logs to <Safari container>/tmp/SafariFullURL.log
```

</details>

## License

SafariFullURL is licensed under the GNU General Public License, version 3 only. See [LICENSE](LICENSE).
