# Zip Latin-1

A small macOS app that packs any number of folders — with everything inside —
into one `.zip`, using the filename encoding you choose.

It was built for upload portals that garble Scandinavian names (æ, ø, å), but
it is useful whenever the receiving system expects something other than UTF-8.

## Download

Download the latest `ZipLatin1-<version>.zip` from
[Releases](https://github.com/Trez-zerT/zip-latin1/releases), unzip it, and move
`ZipLatin1.app` to `~/Applications` or `/Applications`.

It is a universal build (Apple Silicon and Intel) for macOS 14 or later, and
needs **Python 3.9+** — either the Xcode Command Line Tools or
`brew install python3`.

### First launch (Gatekeeper)

The app is ad-hoc signed, not notarized, so macOS blocks the first launch. To
allow it:

1. Double-click the app and dismiss the warning.
2. Open **System Settings → Privacy & Security**, scroll to **Security**, and
   click **Open Anyway** next to ZipLatin1. Authenticate and confirm.

Alternatively, remove the download quarantine flag from Terminal:

```sh
xattr -dr com.apple.quarantine ~/Applications/ZipLatin1.app
```

Then open the app normally. On some macOS versions, Control-clicking the app
and choosing **Open** also works.

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
./package.sh          # builds dist/ZipLatin1-<version>.zip (universal)
```

The engine can also be used from the terminal:

```sh
python3 zip_latin1.py --encoding cp850 --output ~/Desktop/bundle.zip ~/Work/Photos
```
