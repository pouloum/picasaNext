A native macOS photo library for people who organised their photos in Picasa. A hobby project, shared as is.

## Download

**`PicasaNext-{{VERSION}}-arm64.zip`** below, then drag `PicasaNext.app` to Applications.

- Apple Silicon Macs only (M1 and later), macOS 14 Sonoma or later
- SHA-256: `{{SHA256}}`

## Verify this download

This zip was built by GitHub Actions from the tagged source code, not on the author's machine, and GitHub signed a record of where it came from. To check it:

```bash
gh attestation verify PicasaNext-{{VERSION}}-arm64.zip -R pouloum/picasaNext
```

## First launch

The app is not notarized by Apple (no paid developer account), so macOS blocks it the first time:

1. Open `PicasaNext.app`. macOS says it cannot verify the developer: click **Done**.
2. Open **System Settings ▸ Privacy & Security**, scroll down, click **Open Anyway** next to PicasaNext, and confirm.

This is needed only once. If your photos are on a network share, macOS also asks for access to network volumes: allow it.

## Getting started

1. **File ▸ Add Folder to Library…** (⌘O) and pick your photo folder or NAS share.
2. Optionally, **File ▸ Import Picasa Data…** for Picasa's contacts and database.

## Your photos are safe

- Your photo folders are only read, never modified.
- Everything the app knows lives in `~/Library/Application Support/PicasaNext Library/`. Delete that folder to start over; nothing else is touched.
- Image analysis runs on your Mac (Apple Vision). Only GPS positions reach Apple Maps, never the photos.
- Writing back to `.picasa.ini` or XMP files happens only when you ask for an export.

## Changes

[{{PREV}}...{{TAG}}](https://github.com/pouloum/picasaNext/compare/{{PREV}}...{{TAG}})
