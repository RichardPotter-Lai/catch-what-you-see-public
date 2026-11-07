<p align="center"><img src="docs/assets/icon.png" width="80" alt="Catch what you see"></p>

# Catch what you see

A modification of [Tendedero](https://github.com/alejandrobujan/tendedero), adding text collection and Markdown notes.

Tendedero hangs screenshots on a clothesline at the top of the screen. I liked that idea and wanted to put selected passages there too. This version keeps the original screenshot interaction and lets text notes hang beside the images.

[Download](https://github.com/RichardPotter-Lai/catch-what-you-see-public/releases/latest) · [Install](docs/INSTALL.md) · [中文](README.md)

## Use it

Select text, then press and release **Option+C**. Catch saves a local Markdown note and hangs a preview on the clothesline. Move the pointer to the middle of the menu bar, or press **Control+Option+T**, to bring it down. Click a text note to copy its excerpt; double-click to open the MD file.

Screenshots use the usual macOS shortcuts. They stay temporary until you choose to collect them. Hiding a card or filling the line does not delete its file.

Some apps allow copying without exposing an Accessibility selection. An optional fallback runs one Copy command after you request collection, reads the new text, and tries to restore the previous clipboard. You can disable it, or copy text yourself and choose the explicit clipboard collection command.

## What changed from Tendedero

The screenshot clothesline, clips and original animation interaction come from Tendedero. This version mainly adds text capture, text cards, Markdown storage, and a local library for search, preview and external editing. Text and images share the deletion/recovery flow.

Each intentional collection creates a separate `.md`; images use relative attachment paths. The default library is:

```text
~/Library/Application Support/CatchWhatYouSee/Library/
```

Edit it with your usual Markdown tools. Back up the entire library, including hidden folders. There is no built-in account, content upload, analytics service or passive clipboard history. Clipboard restoration is best effort; known newer copies are kept. See [privacy](docs/PRIVACY.md).

## Requirements and limits

The build target is macOS 14+. Universal packages contain arm64 and x86_64, but Intel and older systems have not received full device testing. WeChat and commonly used web pages were manually tested on an Apple silicon Mac; this is not a claim that every app or PDF view works. There is no OCR. See [compatibility](docs/COMPATIBILITY.md).

The current UI is in Simplified Chinese. Builds are ad hoc signed, not Apple notarized. Follow the normal opening and Accessibility authorization steps in [INSTALL](docs/INSTALL.md).

## Build

On a Mac with the Swift toolchain:

```sh
cd app
swift run CaptureCoreChecks
swift build -c debug
bash scripts/build-app.sh debug
```

Use an isolated development library. See [development](docs/DEVELOPMENT.md) and [contributing](CONTRIBUTING.md).

## Attribution and license

Based on Tendedero 1.8.1 by Alejandro Buján. Thank you for creating and sharing the original project.

Code is [MIT licensed](LICENSE), retaining upstream notices. Catch uses a different name and an independently drawn icon. Upstream branding and promotional artwork are not included in this public source snapshot or relicensed here. See [third-party notices](THIRD_PARTY_NOTICES.md).
