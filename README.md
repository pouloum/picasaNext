# PicasaNext

A native macOS replacement for the core of Google Picasa 3.9, written in Swift, built for
large libraries (2 TB+, hundreds of thousands of photos and videos). It imports what Picasa knew
about your photos (stars, captions, named faces, albums, keywords, edits) and never writes to
your photo folders.

> **This folder is the source code.** The index database and thumbnail cache live elsewhere,
> by default in `~/Library/Application Support/PicasaNext Library/` (or `--library DIR`).
> Deleting that library folder is safe (it is rebuilt by rescanning); deleting this one deletes the program.

## What it does

| Area | How |
|---|---|
| Indexing | Incremental scan of one or more roots: only directory listings + `stat`, so a rescan of 2 TB takes seconds-to-minutes. Added/changed/deleted files are detected by size + mtime. |
| Exclusions | Folders named `thumbs`, `thumbnails`, `previews`, `cache`, `caches` are never scanned (Picasa skipped `thumbs` too). `scan --exclude NAME` or `--exclude /abs/path` is remembered; whatever was indexed under it is dropped from the library on the next scan (`excludes`, `unexclude` to manage). |
| Small images | After metadata, images whose longest side is < 200 px, or < 512 px **without** camera EXIF (make/model, capture date, GPS), are set aside as probable thumbnails of other apps: no thumbnail, no analysis, hidden from views, listed under "Small images (ignored)". Small old camera/phone photos (with EXIF) are kept. `index --min-size N --thumb-size N` (0 disables a rule) re-evaluates without rescanning. |
| Metadata | ImageIO / AVFoundation without decoding pixels: dimensions, EXIF date, GPS, camera, video duration. A "quick hash" (SHA-256 of size + first/last 64 KiB) for duplicate detection without reading 2 TB. |
| Thumbnails | 320 px JPEG cache (`thumbs/ab/cd/<id>.jpg`), from embedded EXIF/RAW previews when present; first frame for videos. |
| Picasa import | `.picasa.ini` (per folder, read during scan): stars, captions, faces + names (`[Contacts2]`), local albums (`[.album:…]`), keywords, rotation, `filters=` edit chain. `contacts.xml` (person names). Optional `db3` (`thumbindex.db`, `imagedata_*.pmp`, `albumdata_*.pmp`, `starlist.txt`): captions, faces/people, GPS, stars, thumbnails — paths are matched by trailing components + file size, so the library may have moved disks/OS. |
| Analysis | One Apple Vision pass per image on a single decoded 1600 px copy: faces (+ a print per face), scene labels (~1 300 classes, searchable), cats/dogs, a whole-image print, and on macOS 15+ an aesthetics score with a "utility" flag (screenshots, receipts, documents). |
| Export | `picasa-cli export [--format picasa\|xmp\|all] [--dry-run] [PATH]` (opt-in; nothing else ever writes to the media folders). `picasa`: stars, captions, named faces (with `[Contacts2]`), keywords and albums into each folder's `.picasa.ini` (previous file kept as `.picasa.ini.bak`; `rotate`, `filters` and unknown keys untouched; re-reading it never duplicates faces). `xmp`: one `IMG_0001.xmp` sidecar per photo (RAW+JPEG pairs share one): rating, caption, keywords, people and pets as MWG named regions and `People\|`/`Pets\|`/`Albums\|` hierarchical keywords; sidecars written by other programs are left alone. |
| Faces | Replaces Picasa's Neven engine: unnamed faces are grouped by similarity (name a whole group at once) and suggested names come from cosine similarity to the people already named. Rejected suggestions are remembered. As in Picasa, drag a person onto another to merge them (the merged one stays as an alias for later Picasa re-imports), or an unnamed group onto a person to name it. Faces can be ignored (never suggested, listed under Ignored, restorable). People and Animals share one screen: Groups (cards) or Photos (grid by year), a year filter, and Named / To identify / Ignored filters (unidentified groups hidden by default). |
| Pets | Each detected cat/dog gets a feature print of its crop, so animals are grouped, named and suggested like faces (Animals in the sidebar). Telling two similar-looking animals apart is unreliable; naming corrects it. |
| Discover | **Best photos** (top 10 % aesthetics, documents excluded), **Similar & duplicates** (exact duplicates by quick hash anywhere + near-duplicates within a 10-minute window, best-looking first), **Animals**, **Screenshots & documents**. |
| Viewer | SwiftUI app: All / Starred / Videos / People / Albums / Years / Folders, search (name, folder, caption, tag, person, album, camera), virtualized grid (NSCollectionView), viewer with face boxes (click to name), video playback (Space closes, Return plays/pauses), info panel, star toggle. Every section follows a running scan/index/analysis live — in the app or in `picasa-cli` — by polling the database's change counter, keeping the grid's scroll position and selection. |

Edits made in PicasaNext (stars, names, captions) live in the library database only.

## Build

Requires macOS 14+ and Xcode 16+ (tested with Xcode 26.2 / Swift 6.2).

```bash
swift build -c release          # or: ./build.sh release   (plain swiftc, no SwiftPM caches)
swift run picasa-tests          # or: TESTS=1 ./build.sh debug
```

`swift build` puts binaries in `.build/release/`; `./build.sh` in `build/<config>/` (including `PicasaNext.app`).

## Use

CLI (recommended for the first 2 TB pass, it can run unattended):

```bash
cli=.build/release/picasa-cli
$cli scan /Volumes/Photos --exclude "LightCraft Library"   # index files, read .picasa.ini
$cli import-contacts /path/Picasa2/contacts/contacts.xml   # optional
$cli index                             # metadata + thumbnails
$cli analyze                           # Vision pass: faces, labels, animals, aesthetics, similar photos
$cli stats
$cli import-db3 /path/Picasa2/db3      # optional, if you have it (--no-thumbs to skip its thumbnails)
```

Options: `--library DIR` (default `~/Library/Application Support/PicasaNext Library`; the app honours
`PICASANEXT_LIBRARY=DIR`), `-j N` parallelism (use `-j 2`–`4` for a single spinning disk, higher for
SSD/NAS). Every stage is resumable: stop it any time and rerun, only pending items are processed.

GUI: run `.build/release/PicasaNext` (or open `build/release/PicasaNext.app`), **File ▸ Add Folder to
Library…** (⌘O), optionally **File ▸ Import Picasa Data…** (contacts and/or db3).

Near-duplicate threshold: `$cli similar --threshold 0.95` (cosine of Vision image prints). Calibrate it
on your own photos with `swift Tools/calibrate-similar.swift list.txt` (one image path per line): pick a
value between the "different photos max" and the "same photo min" it prints.

## Sizing for 2 TB

Measured on Apple Silicon, internal SSD, 20 000 JPEGs in 400 folders (release build):
first scan 0.2 s, rescan 0.1 s, metadata 16 s (~1 200 files/s), thumbnails 8 s (~2 400 files/s,
23 KB each); face detection ~30 images/s on 6000 px HEICs. On a USB hard disk the metadata and
thumbnail stages are seek-bound (expect ~100–300 files/s): for ~600k files budget a night, and use
`-j 2`–`4`. Library size ≈ 23 KB per item + ~1 KB of database (+3 KB per face print), i.e.
~10–20 GB for 500k–800k items. Put the library on an SSD.

Safety for external disks: a folder whose listing fails part-way is kept as-is, a root that is
present but empty while the library holds media for it (unmounted `/Volumes/X` stub) aborts the scan
without changes, and files that cannot be read are retried on the next run instead of being
marked done.

## Layout

```
Sources/PicasaFormats   pure parsers: PicasaIni, PicasaContacts, PicasaDB (PMP, thumbindex, thumb caches)
Sources/PicasaCore      Library (SQLite), Scanner, Metadata/Indexer, Thumbnails, Faces, PicasaImport, DB3Import, Browse
Sources/picasa-cli      command line
Sources/PicasaViewer    SwiftUI app
Tests/Runner            test runner (synthetic Picasa files + end-to-end library test)
```


## Known limits

- db3 import is secondary and untested on a real database (only on synthetic files built from the
  decompiled format): album membership (`imagedata_tags`), face rectangles on "virtual" rows and the
  `albumcontactids` format are inferred. `.picasa.ini` files carry the same essentials.
- `import-db3` runs in one transaction; in the app the library is busy until it finishes. Prefer the CLI.
- A `.picasa.ini` change re-imports faces/stars for listed files but does not clear attributes removed
  from it (Picasa no longer edits these files once you migrate).
- The UI was build-tested and launched, not exercised by automated UI tests.

## Not included

Photo editing (Picasa filters are imported and kept but not rendered), collages/movies, printing,
upload to Google services (discontinued), writing back to `.picasa.ini` / XMP.

## macOS permission prompts

Opening a photo reads the original; on a network share macOS asks once for access to network
volumes. It remembers the answer per code signature, and `build.sh` signs ad hoc by default (a new
signature on each build), so the question comes back after every rebuild. To keep the answer:

1. Keychain Access ▸ Certificate Assistant ▸ Create a Certificate… — name `PicasaNext Dev`,
   identity type *Self Signed Root*, certificate type *Code Signing*.
2. Build with it: `SIGN_IDENTITY="PicasaNext Dev" ./build.sh` (or an Apple Development certificate
   from Xcode). Allow once; later builds signed the same way are not asked again.
