# Zip Latin-1

A small macOS app that packs any number of folders — with everything inside —
into one `.zip`, using the filename encoding you choose.

It was built for upload portals that garble Scandinavian names (æ, ø, å), but
it is useful whenever the receiving system expects something other than UTF-8.

## How it works

1. Open `~/Applications/ZipLatin1.app`.
2. Drop folders into the window (or drag them onto the app icon, or use
   **Add Folders…**).
3. Choose an encoding under **Encoding**.
4. Press **Create ZIP** (or Return).

The archive is saved next to the folders and named after the first one. Each
dropped folder appears at the top level of the archive. Folders from different
locations bring up a save panel; if the usual location is read-only, the app
asks where to save instead.

## Encodings

| Encoding | Use it for |
| --- | --- |
| **CP850 (Windows/DOS)** — default | Older Windows and DOS zip tools, and upload systems that read zip filenames as an OEM code page. If `Ø` arrives as `Ï` on the other side, this is the one. |
| **ISO-8859-1 (Latin-1)** | Legacy Western European Unix tools and web systems that explicitly ask for Latin-1. Covers é, ü, ñ, ç, ß, æ, ø, å. |
| **UTF-8** | Modern macOS, Windows 10+, Linux, 7-Zip, Java, Python, and current web applications. Handles every character, including emoji and non-Latin scripts. |

In the two single-byte modes, characters the encoding cannot represent are
transliterated to Latin letters and, as a last resort, replaced with `?`. The
app reports when that happens. UTF-8 leaves names unchanged.

The encoding applies to the names stored inside the zip; the archive file on
disk keeps its normal Unicode name.

## Good to know

- Folders are added recursively, including empty folders and hidden files.
- Permissions and symlinks are preserved.
- If the archive name already exists, ` 2`, ` 3`, … is appended.
- A failed or cancelled run never leaves a half-written archive behind.

## Build

Requires the Xcode Command Line Tools (Swift) and Python 3.9+ at runtime.

```sh
./build.sh            # installs to ~/Applications/ZipLatin1.app
./build.sh /path/to/ZipLatin1.app
```

The engine can also be used from the terminal:

```sh
python3 zip_latin1.py --encoding cp850 --output ~/Desktop/bundle.zip ~/Work/Photos
```
