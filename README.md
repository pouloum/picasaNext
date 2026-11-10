<p align="center"><img src="docs/logo.png" width="128" alt="PicasaNext logo"></p>

# PicasaNext

A native macOS photo library for people who organised their photos in Picasa and never found a replacement.

It reads what Picasa knew about your photos (named faces, stars, albums, captions, keywords) and keeps them working on a modern Mac, on libraries of hundreds of thousands of files, including on a NAS. Your photo folders are never modified.

<!-- ![PicasaNext](docs/screenshots/cover.png) -->

> **Built by an AI, steered by a human.** Every line of Swift in this repository was written by [Claude Code](https://claude.com/claude-code). I wrote none of it: I set the frame, tried every feature, asked for measurements, and decided what to build. The full story, in French, is told in a LinkedIn series by the author.

## Why

Google stopped Picasa in 2016. It no longer runs on recent Macs (32-bit app, refused by macOS since 2019) and does not read HEIC. Years of face naming, stars and albums sat in undocumented files.

PicasaNext was built for one real library: 207,000 files, 780 GB, photos from 2001 to today, on a home NAS.

## What it does

- **Reads your Picasa data**: `.picasa.ini` files (stars, captions, faces, albums, keywords, rotation), `contacts.xml` (names), and optionally Picasa's internal database.
- **Stays fast on large libraries**: a rescan only lists folders and compares size and date; the grid only builds visible thumbnails; indexing adapts to the disk (SSD, hard disk or NAS) by measuring its own throughput.
- **Faces and animals that learn from you**: suggestions come from the closest face you already named; a rejected face becomes a counter-example. Your decisions are never undone by a re-run.
- **Copies, bursts and similar scenes**: grouped using image likeness and shooting details (same camera, a few seconds apart, same place). Nothing is deleted.
- **Relations**: a graph of who appears with whom, with family and friend circles, a years slider, and the photos people share.
- **Places, labels, search**: Apple Maps, ~1,300 scene labels, multi-criteria search (two people, a label and an album at once).
- **Always up to date**: watches your folders and picks up new photos by itself.
- **Removable disks and NAS**: thumbnails stay on the Mac, so the library stays usable when the disk is unplugged.
- **On your Mac only**: image analysis uses Apple Vision, on device. Only GPS positions reach Apple Maps, never the photos.
- **Export when you choose**: back to `.picasa.ini`, or to XMP sidecars readable by Lightroom, digiKam or Immich.

Not there yet: rendering Picasa's edits, slideshow, creating albums, sharing.

## Download

**[Latest PicasaNext for Apple Silicon Macs](https://github.com/pouloum/picasaNext/releases/latest)** (macOS 14 or later). Unzip, drag `PicasaNext.app` to Applications.

The app is not notarized by Apple: the first time, macOS blocks it. Open **System Settings ▸ Privacy & Security**, click **Open Anyway** next to PicasaNext, and confirm. This is needed only once. The [release notes](https://github.com/pouloum/picasaNext/releases/latest) have the details.

## Requirements to build

- macOS 14 or later (some analysis features need macOS 15)
- Xcode 16 or later to build (tested with Xcode 26.2 / Swift 6.2)
- No external dependency

## Build and run

```bash
./build.sh release
open build/release/PicasaNext.app
```

Then **File ▸ Add Folder to Library…** (⌘O), and optionally **File ▸ Import Picasa Data…**.

Tests:

```bash
TESTS=1 ./build.sh debug
```

A command-line tool, `picasa-cli`, does everything the app does and can run unattended for a first pass on a very large library. See [docs/FEATURES.md](docs/FEATURES.md).

## Where your data lives

The library (database and 320 px thumbnails) lives in `~/Library/Application Support/PicasaNext Library/`, about 7 GB for 207,000 files. It can be deleted at any time and rebuilt by rescanning. Your photos are only read.

## How Picasa's formats were understood

Picasa's formats were never documented. This project started from what the community had published (13 sources), then checked the open questions by static analysis of the original Picasa 3.9 binary, downloaded from archive.org with its Google signature verified, and never run.

This was done for interoperability only, as allowed in the EU (Directive 2009/24/EC, art. 6; French CPI art. L.122-6-1): reading one's own data with an independently written program. **This repository contains no Picasa code, no decompiled code, no extracted strings, and no Picasa binaries**, only the file-format rules needed to read your data, written from scratch.

## Project history

The history has five commits, one per stage of the story. Each is a snapshot of the real development history (73 commits, from 20 October to 7 November 2026), with its original date. Before publication, these were removed:

- the static-analysis notes and anything taken from the Picasa binary
- personal data (folder names, people's names, paths)
- internal working notes

The code itself was not rewritten. Each stage has a tag:

| Tag | What |
|---|---|
| `v0.1` | Picasa file readers and command line |
| `v0.2` | First app |
| `v0.3` | The real library: NAS, benchmark, copies |
| `v1.0` | First version (five days, ~6 hours of AI work) |
| `v1.1` | Continuous indexing, removable disks, better face suggestions |

## Status

A personal project, built for and tested on one real library. Issues are welcome; support is not promised.

## Disclaimer

Picasa is a trademark of Google LLC. This project is not affiliated with, endorsed by, or sponsored by Google.

## License

MIT, see [LICENSE](LICENSE).
