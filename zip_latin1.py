#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Create a .zip archive whose entry names are stored as ISO-8859-1 (Latin-1).

Folder trees are added recursively with their top-level folder name preserved.
Names that are not representable in Latin-1 are transliterated to Latin via
ICU (Any-Latin; Latin-ASCII) and anything still unrepresentable becomes "?".

Usage:
    zip_latin1.py [--json] FOLDER [FOLDER ...]

With --json, newline-delimited JSON events are written to stdout.
"""

from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import json
import os
import shutil
import stat
import sys
import time
import unicodedata
import zipfile

CHUNK = 1024 * 1024
ZIP_MIN_YEAR = 1980
ZIP_MAX_YEAR = 2107

JSON_MODE = False


def emit(**kw):
    if JSON_MODE:
        sys.stdout.write(json.dumps(kw, ensure_ascii=False) + "\n")
        sys.stdout.flush()


def note(msg):
    if not JSON_MODE:
        print(msg, flush=True)


# --------------------------------------------------------------------------
# Name conversion: everything that reaches the zip must be encodable as
# Latin-1. Latin-1 characters are preserved untouched; other characters are
# transliterated with ICU, then '?' as a last resort.
# --------------------------------------------------------------------------

class _CFRange(ctypes.Structure):
    _fields_ = [("location", ctypes.c_long), ("length", ctypes.c_long)]


class Transliterator:
    """ICU transliteration through the CoreFoundation API (no dependencies)."""

    TRANSFORM = "Any-Latin; Latin-ASCII"

    def __init__(self):
        self._lib = None
        try:
            lib = ctypes.CDLL(ctypes.util.find_library("CoreFoundation"))
            vp, cl, cb = ctypes.c_void_p, ctypes.c_long, ctypes.c_bool
            lib.CFStringCreateWithCharacters.restype = vp
            lib.CFStringCreateWithCharacters.argtypes = [
                vp, ctypes.POINTER(ctypes.c_uint16), cl]
            lib.CFStringCreateMutableCopy.restype = vp
            lib.CFStringCreateMutableCopy.argtypes = [vp, cl, vp]
            lib.CFStringTransform.restype = cb
            lib.CFStringTransform.argtypes = [vp, ctypes.POINTER(_CFRange), vp, cb]
            lib.CFStringGetLength.restype = cl
            lib.CFStringGetLength.argtypes = [vp]
            lib.CFStringGetCharacters.restype = None
            lib.CFStringGetCharacters.argtypes = [
                vp, _CFRange, ctypes.POINTER(ctypes.c_uint16)]
            lib.CFRelease.restype = None
            lib.CFRelease.argtypes = [vp]
            self._lib = lib
            self._transform = self._mk(self.TRANSFORM)
        except Exception:
            self._lib = None

    def _mk(self, text):
        buf = text.encode("utf-16-le")
        n = len(buf) // 2
        arr = (ctypes.c_uint16 * n).from_buffer_copy(buf)
        return self._lib.CFStringCreateWithCharacters(None, arr, n)

    def _text(self, handle):
        n = self._lib.CFStringGetLength(handle)
        buf = (ctypes.c_uint16 * n)()
        self._lib.CFStringGetCharacters(handle, _CFRange(0, n), buf)
        return bytes(buf).decode("utf-16-le", "replace")

    def __call__(self, text):
        if not text:
            return ""
        if self._lib is None:
            return _fallback_transliterate(text)
        src = mutable = None
        try:
            src = self._mk(text)
            mutable = self._lib.CFStringCreateMutableCopy(None, 0, src)
            ok = self._lib.CFStringTransform(
                mutable, None, self._transform, False)
            if not ok:
                return _fallback_transliterate(text)
            return self._text(mutable)
        except Exception:
            return _fallback_transliterate(text)
        finally:
            if mutable:
                self._lib.CFRelease(mutable)
            if src:
                self._lib.CFRelease(src)


_FALLBACK_MAP = {
    "\u2018": "'", "\u2019": "'", "\u201a": ",", "\u201b": "'",
    "\u201c": '"', "\u201d": '"', "\u201e": '"', "\u201f": '"',
    "\u2013": "-", "\u2014": "-", "\u2015": "-", "\u2212": "-",
    "\u2026": "...", "\u2022": "-", "\u00b7": ".",
    "\u2039": "<", "\u203a": ">", "\u00ab": '"', "\u00bb": '"',
    "\u20ac": "EUR", "\u2122": "(TM)", "\u00ae": "(R)", "\u00a9": "(C)",
    "\u00d7": "x", "\u00f7": "/", "\u2044": "/", "\u00b0": "deg",
}


def _fallback_transliterate(text):
    out = []
    for ch in unicodedata.normalize("NFKD", text):
        if ch in _FALLBACK_MAP:
            out.append(_FALLBACK_MAP[ch])
        elif unicodedata.combining(ch):
            continue
        elif ord(ch) < 256:
            out.append(ch)
        else:
            out.append("?")
    return "".join(out)


def _encodable(ch, codec):
    if ch in "\x00\n\r":
        return False
    try:
        ch.encode(codec)
        return True
    except UnicodeEncodeError:
        return False


_TRANSLIT = Transliterator()

NAME_ENCODINGS = {
    "latin1": ("latin-1", 0),
    "cp850": ("cp850", 0),
    "utf8": ("utf-8", 0x0800),   # general purpose bit 11
}


def encode_component(name, codec, utf8=False):
    """Return `name` as a safe string for the target encoding."""
    name = unicodedata.normalize("NFC", name)
    if not name:
        return "?"
    if utf8:
        return name
    if all(_encodable(ch, codec) for ch in name):
        return name

    out = []
    run = []
    run_ok = None

    def flush():
        nonlocal run, run_ok
        if not run:
            return
        chunk = "".join(run)
        out.append(chunk if run_ok else _TRANSLIT(chunk))
        run = []
        run_ok = None

    for ch in name:
        ok = _encodable(ch, codec)
        if run and ok != run_ok:
            flush()
        if not run:
            run_ok = ok
        run.append(ch)
    flush()

    result = "".join(ch if _encodable(ch, codec) else "?"
                     for ch in "".join(out))
    return result or "?"


# --------------------------------------------------------------------------
# Archive writing
# --------------------------------------------------------------------------

class EncodedZipInfo(zipfile.ZipInfo):
    """ZipInfo that stores a pre-encoded name with explicit flag bits."""

    def __init__(self, name, raw_name, flags=0):
        super().__init__(name)
        self._raw_name = raw_name
        self._name_flags = flags

    def _encodeFilenameFlags(self):
        return self._raw_name, self._name_flags


def zip_datetime(mtime):
    try:
        lt = time.localtime(mtime)
    except (ValueError, OSError):
        lt = time.localtime()
    if lt.tm_year < ZIP_MIN_YEAR:
        return (ZIP_MIN_YEAR, 1, 1, 0, 0, 0)
    if lt.tm_year > ZIP_MAX_YEAR:
        return (ZIP_MAX_YEAR, 12, 31, 23, 59, 58)
    return (lt.tm_year, lt.tm_mon, lt.tm_mday,
            lt.tm_hour, lt.tm_min, lt.tm_sec)


def normalize_folders(paths):
    """Resolve paths, reject non-folders, and drop folders nested in others."""
    accepted = []
    for raw in paths:
        path = os.path.abspath(os.path.normpath(os.path.expanduser(raw)))
        if not os.path.isdir(path):
            raise RuntimeError("Not a folder: %s" % raw)
        if any(path == a or path.startswith(a + os.sep) for a in accepted):
            continue
        accepted = [a for a in accepted
                    if not (a.startswith(path + os.sep))]
        accepted.append(path)
    if not accepted:
        raise RuntimeError("No folders to archive.")
    return accepted


def choose_output(folders):
    first = folders[0]
    parent = os.path.dirname(first)

    if len(folders) == 1:
        base = os.path.basename(first) or "Archive"
    else:
        base = "%s and %d more" % (
            os.path.basename(first), len(folders) - 1)

    out = os.path.join(parent, base + ".zip")
    counter = 2
    while os.path.exists(out):
        out = os.path.join(parent, "%s %d.zip" % (base, counter))
        counter += 1
    return out


class Archiver:
    def __init__(self, folders, write_path, out_path=None, encoding="latin1"):
        self.folders = folders
        self.write_path = write_path
        self.out_path = out_path or write_path
        self.encoding = encoding
        self.codec, self.utf8_flag = NAME_ENCODINGS[encoding]
        self.entries = []          # (src, rel, kind, stat)
        self.used = set()          # encoded relative paths already taken
        self.renamed = {}          # original component -> encoded component
        self._skip = {os.path.abspath(write_path),
                      os.path.abspath(self.out_path)}

    # -- scanning ---------------------------------------------------------
    def enc(self, name):
        encoded = encode_component(name, self.codec,
                                   utf8=(self.encoding == "utf8"))
        if encoded != name:
            self.renamed.setdefault(name, encoded)
        return encoded

    def unique(self, rel, is_dir):
        if rel not in self.used:
            self.used.add(rel)
            return rel
        index = 2
        while True:
            if is_dir:
                candidate = "%s~%d" % (rel, index)
            else:
                head, tail = os.path.split(rel)
                stem, ext = os.path.splitext(tail)
                candidate = "%s/%s~%d%s" % (head, stem, index, ext) if head \
                    else "%s~%d%s" % (stem, index, ext)
            if candidate not in self.used:
                self.used.add(candidate)
                return candidate
            index += 1

    def scan(self):
        for folder in self.folders:
            base = self.enc(os.path.basename(folder) or "Archive")
            rel = self.unique(base, True)
            self._walk(folder, rel)

    def _walk(self, src, rel):
        if os.path.abspath(src) in self._skip:
            return
        st = os.lstat(src)
        if stat.S_ISLNK(st.st_mode):
            self.entries.append((src, rel, "link", st))
            return
        if not stat.S_ISDIR(st.st_mode):
            self.entries.append((src, rel, "file", st))
            return

        self.entries.append((src, rel, "dir", st))
        try:
            names = sorted(os.listdir(src))
        except OSError as exc:
            raise RuntimeError("Cannot list %s: %s" % (src, exc))

        for name in names:
            child = os.path.join(src, name)
            try:
                cst = os.lstat(child)
            except OSError as exc:
                raise RuntimeError("Cannot read %s: %s" % (child, exc))
            child_rel = self.unique(
                rel + "/" + self.enc(name),
                stat.S_ISDIR(cst.st_mode) and not stat.S_ISLNK(cst.st_mode))
            self._walk(child, child_rel)

    # -- writing ----------------------------------------------------------
    def info(self, name, is_dir=False):
        display = name + "/" if is_dir else name
        return EncodedZipInfo(display, display.encode(self.codec),
                              self.utf8_flag)

    def write(self):
        total = len(self.entries)
        note("Creating %s" % self.out_path)
        emit(event="start", total=total, archive=self.out_path)

        total_bytes = 0
        with zipfile.ZipFile(
                self.write_path, "w", zipfile.ZIP_DEFLATED,
                allowZip64=True, compresslevel=6) as zf:
            for index, (src, rel, kind, st) in enumerate(self.entries, 1):
                if kind == "dir":
                    zi = self.info(rel, True)
                    zi.create_system = 3
                    zi.date_time = zip_datetime(st.st_mtime)
                    zi.external_attr = (
                        ((st.st_mode & 0o7777) | stat.S_IFDIR) << 16) | 0x10
                    zf.writestr(zi, b"", compress_type=zipfile.ZIP_STORED)

                elif kind == "link":
                    zi = self.info(rel)
                    zi.create_system = 3
                    zi.date_time = zip_datetime(st.st_mtime)
                    zi.external_attr = (
                        (stat.S_IFLNK | 0o777) << 16)
                    target = os.fsencode(os.readlink(src))
                    zf.writestr(zi, target, compress_type=zipfile.ZIP_STORED)

                else:
                    zi = self.info(rel)
                    zi.create_system = 3
                    zi.date_time = zip_datetime(st.st_mtime)
                    zi.external_attr = (st.st_mode & 0xFFFF) << 16
                    zi.compress_type = zipfile.ZIP_DEFLATED
                    with open(src, "rb") as fsrc, \
                            zf.open(zi, "w",
                                    force_zip64=st.st_size >= 0xFFFFFFFF) as fdst:
                        shutil.copyfileobj(fsrc, fdst, CHUNK)
                    total_bytes += st.st_size

                if total <= 200 or index % 20 == 0 or index == total:
                    emit(event="entry", index=index, total=total,
                         name=rel, size=getattr(st, "st_size", 0))

        note("Wrote %d entries to %s" % (total, self.out_path))
        return total, total_bytes


def temp_path_for(out_path):
    directory, name = os.path.split(out_path)
    return os.path.join(directory, ".%s.part-%d" % (name, os.getpid()))


def main(argv):
    global JSON_MODE
    parser = argparse.ArgumentParser(
        description="Create a .zip with ISO-8859-1 encoded entry names.")
    parser.add_argument("--json", action="store_true",
                        help="emit newline-delimited JSON events")
    parser.add_argument("--output", metavar="PATH",
                        help="write the archive to PATH (overwrites)")
    parser.add_argument("--encoding", choices=sorted(NAME_ENCODINGS),
                        default="latin1",
                        help="filename encoding stored in the zip "
                             "(default: latin1)")
    parser.add_argument("folders", nargs="+", help="folders to archive")
    args = parser.parse_args(argv)
    JSON_MODE = args.json

    out_path = None
    write_path = None
    completed = False
    try:
        folders = normalize_folders(args.folders)
        if args.output:
            out_path = os.path.abspath(os.path.expanduser(args.output))
            if os.path.isdir(out_path):
                raise RuntimeError("Output is a folder: %s" % out_path)
        else:
            out_path = choose_output(folders)
        write_path = temp_path_for(out_path)

        emit(event="scanning", total=0)
        archiver = Archiver(folders, write_path, out_path,
                            encoding=args.encoding)
        archiver.scan()
        total, total_bytes = archiver.write()
        os.replace(write_path, out_path)
        completed = True
        emit(event="done", archive=out_path, entries=total,
             bytes=total_bytes,
             renamed=[[k, v] for k, v in list(archiver.renamed.items())[:40]],
             renamed_total=len(archiver.renamed))
        return 0
    except BrokenPipeError:
        if not completed:
            _cleanup(write_path)
        return 0 if completed else 1
    except KeyboardInterrupt:
        if not completed:
            _cleanup(write_path)
        _safe_emit(event="error", message="Cancelled.")
        return 130
    except SystemExit as exc:
        if not completed:
            _cleanup(write_path)
        code = exc.code if isinstance(exc.code, int) else 1
        return code if code else 130
    except BaseException as exc:
        if not completed:
            _cleanup(write_path)
        _safe_emit(event="error",
                   message=str(exc) or exc.__class__.__name__)
        if not JSON_MODE:
            print("Error: %s" % exc, file=sys.stderr)
        return 1


def _safe_emit(**kw):
    try:
        emit(**kw)
    except Exception:
        pass


def _cleanup(path):
    if path and os.path.exists(path):
        try:
            os.remove(path)
        except OSError:
            pass


if __name__ == "__main__":
    import signal

    def _on_term(signum, frame):
        raise SystemExit(143)

    signal.signal(signal.SIGTERM, _on_term)
    sys.setrecursionlimit(20000)
    sys.exit(main(sys.argv[1:]))
