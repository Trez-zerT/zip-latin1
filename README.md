# Zip Latin-1

A small macOS app that packs several folders (recursively) into **one** `.zip`
whose entry names are stored as **ISO-8859-1 (Latin-1)**, **CP850** (Windows/DOS
OEM) or **UTF-8**. The encoding is chosen in the window. The archive is written
next to the dropped folders.

## Usage

1. Open `~/Applications/ZipLatin1.app`.
2. Drop folders into the window (or drag them onto the app icon, or use
   **Add Folders…**).
3. Press **Create ZIP** (or Return).

The archive is saved in the parent folder of the dropped folders:

| Dropped | Archive |
| --- | --- |
| `~/Work/Photos` | `~/Work/Photos.zip` |
| `~/Work/Photos` + `~/Work/Scans` | `~/Work/Photos and 1 more.zip` |
| `~/Work/Photos` + `~/Desktop/Scans` | save panel (defaults to `~/Desktop/Scans and 1 more.zip`) |

If the name already exists, ` 2`, ` 3`, … is appended.

## Where the archive goes

- **All dropped folders share a parent** → saved next to them, named after the
  first folder (`Photos.zip`) or `Photos and 1 more.zip`. If the name exists,
  ` 2`, ` 3`, … is appended.
- **Folders come from different parents** → a save panel asks where to put the
  archive. It defaults to the parent of the alphabetically first folder.
- **The default destination is read-only** (read-only volume, mount, or no
  write permission) → a save panel asks for a writable location, defaulting to
  the Desktop.
- Existing archives are only replaced once the new one is fully written, so a
  failed or cancelled run never damages the old file.

## Name encoding

Pick **Names:** in the top-right corner:

| Setting | Bytes stored | Use when |
| --- | --- | --- |
| **CP850 (Windows/DOS)** (default) | OEM code page 850, no UTF-8 flag | Legacy Windows/DOS zip readers. Fixes `Ø` showing up as `Ï`. |
| **ISO-8859-1 (Latin-1)** | Latin-1, no UTF-8 flag | The receiving system explicitly expects Latin-1. |
| **UTF-8** | UTF-8, general-purpose bit 11 set | Modern readers (macOS, Windows 10+, 7-Zip, Java, Python). |

A quick way to diagnose a mangled `Ø` on the receiving side:

| What it shows | It decoded our bytes as | Choose |
| --- | --- | --- |
| `Ø` | correctly | — |
| `Ï` | CP850, from Latin-1 bytes | **CP850** |
| `├ÿ` | CP850, from UTF-8 bytes | **CP850** (or UTF-8 if the flag is honoured) |
| `Ã˜` | Latin-1/Windows-1252, from UTF-8 | **UTF-8** |
| `?` | character not representable | **UTF-8** |

In CP850 and Latin-1 mode, names are NFC-normalised first, characters outside
the code page are transliterated with ICU (`Any-Latin; Latin-ASCII`), and
anything still unrepresentable becomes `?` (the app reports how many names were
transliterated). UTF-8 preserves every character. If transliteration makes two
names collide, `~2`, `~3`, … is appended.

## What is stored

- Full directory tree, including empty directories and hidden files.
- Unix permissions in the external attributes.
- Symlinks are stored as symlinks (not followed).
- Modification times (clamped to the ZIP range 1980–2107).
- Deflate compression (level 6), ZIP64 for large entries/archives.

Not preserved: resource forks / Finder metadata (the classic `.zip` format has
no place for them unless stored as AppleDouble `._*` files).

## Build

Requires the Xcode Command Line Tools (Swift) and Python 3.9+ at runtime.

```sh
./build.sh            # installs to ~/Applications/ZipLatin1.app
./build.sh /path/to/ZipLatin1.app
```

The archive engine can also be used from the terminal:

```sh
python3 zip_latin1.py --json ~/Work/Photos ~/Work/Scans
python3 zip_latin1.py --encoding cp850 --output ~/Desktop/bundle.zip ~/Work/Photos
python3 zip_latin1.py --encoding utf8 ~/Work/Photos
```

## Files

- `main.swift` — native AppKit window, drag & drop, progress, engine runner.
  Build with `-D SELFTEST` to enable the automated UI/engine test hooks
  (`ZIPLATIN1_TEST_FOLDERS`, `ZIPLATIN1_ENCODING`, `ZIPLATIN1_AUTOSTART`,
  `ZIPLATIN1_TEST_OUTPUT`, `ZIPLATIN1_SNAPSHOT`, `ZIPLATIN1_TEST_RESULT`).
- `zip_latin1.py` — archive engine (`zipfile` + CoreFoundation ICU
  transliteration, no third-party packages).
- `Info.plist` — app bundle metadata (also registers folders for
  drag-onto-icon).
- `AppIcon.icns` — app icon (`make_icon.swift` regenerates it).
- `build.sh` — compiles and assembles the `.app`.
