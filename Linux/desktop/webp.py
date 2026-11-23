"""WebP pack artwork: the byte rule every BetterIcon applies before it decodes a WebP, and the decoder, which is the
system libwebp through ctypes, or a GdkPixbuf WebP loader where libwebp cannot be loaded.

The environment variable BETTERICON_WEBP_DECODER is a test seam, read at every call: "none" behaves as if this computer
had no WebP decoder, and "gdkpixbuf" skips libwebp so the GdkPixbuf loader decodes. It is unset in normal use.
"""
import ctypes
import ctypes.util
import os
import threading
from pathlib import Path

import gi
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf, GLib  # noqa: E402

MAX_SIDE = 4096
MAX_BYTES = 16 * 1024 * 1024
# The causes, worded as on Windows and the Mac.
ANIMATED = "Animated WebP artwork is not supported."
DAMAGED = "The WebP file is damaged or incomplete."
NOT_WEBP = "The file is named .webp but is not a WebP image."
TOO_LARGE = "WebP artwork must be at most 4096 pixels per side."
NO_DECODER = "This computer can't read WebP artwork. Install libwebp or a GdkPixbuf WebP loader."
# Added after ANIMATED where the user chooses artwork.
STILL = " Choose a still image."

_lock = threading.Lock()
_library = []
_loader = []
# Full decodes, by (path, size, mtime in ns, decoder setting): None when the file decoded, or its cause.
_verified = {}


def _u16(data, at):
    return int.from_bytes(data[at:at + 2], "little")


def _u24(data, at):
    return int.from_bytes(data[at:at + 3], "little")


def _u32(data, at):
    return int.from_bytes(data[at:at + 4], "little")


def header(head, length):
    """(cause or None, width, height) from the first 30 bytes of a WebP file and its length, by the shared byte rule."""
    if length < 30 or length > MAX_BYTES or len(head) < 30:
        return DAMAGED, 0, 0
    if head[0:4] != b"RIFF" or head[8:12] != b"WEBP":
        return NOT_WEBP, 0, 0
    if _u32(head, 4) + 8 > length:
        return DAMAGED, 0, 0
    chunk = head[12:16]
    if chunk == b"VP8 ":
        if head[23:26] != b"\x9d\x01\x2a":
            return DAMAGED, 0, 0
        width, height = _u16(head, 26) & 0x3FFF, _u16(head, 28) & 0x3FFF
    elif chunk == b"VP8L":
        if head[20] != 0x2F:
            return DAMAGED, 0, 0
        bits = _u32(head, 21)
        width, height = (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
    elif chunk == b"VP8X":
        if head[20] & 0x02:
            return ANIMATED, 0, 0
        width, height = _u24(head, 24) + 1, _u24(head, 27) + 1
    else:
        return DAMAGED, 0, 0
    if not (1 <= width <= MAX_SIDE and 1 <= height <= MAX_SIDE):
        return TOO_LARGE, width, height
    return None, width, height


def problem(head, length):
    """Why a WebP file cannot be used, by the byte rule alone, or None."""
    return header(head, length)[0]


def _setting():
    return os.environ.get("BETTERICON_WEBP_DECODER", "").strip().lower()


def _libwebp():
    """The system libwebp with the two functions BetterIcon calls, loaded once, or None."""
    with _lock:
        if not _library:
            found = None
            for name in ("libwebp.so.7", "libwebp.so.6", ctypes.util.find_library("webp")):
                if not name:
                    continue
                try:
                    lib = ctypes.CDLL(name)
                    lib.WebPGetInfo.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_int),
                                                ctypes.POINTER(ctypes.c_int)]
                    lib.WebPGetInfo.restype = ctypes.c_int
                    lib.WebPDecodeRGBAInto.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_ubyte),
                                                       ctypes.c_size_t, ctypes.c_int]
                    lib.WebPDecodeRGBAInto.restype = ctypes.c_void_p
                except (OSError, AttributeError):
                    continue
                found = lib
                break
            _library.append(found)
        return _library[0]


def _pixbuf_loader():
    """Whether GdkPixbuf has a WebP loader, as webp-pixbuf-loader or glycin give it."""
    with _lock:
        if not _loader:
            _loader.append(any(f.get_name() == "webp" for f in GdkPixbuf.Pixbuf.get_formats()))
        return _loader[0]


def decoder():
    """'libwebp', 'gdkpixbuf' or None: what decodes WebP on this computer now."""
    setting = _setting()
    if setting == "none":
        return None
    if setting != "gdkpixbuf" and _libwebp() is not None:
        return "libwebp"
    return "gdkpixbuf" if _pixbuf_loader() else None


def available():
    """Whether this computer can decode WebP."""
    return decoder() is not None


def pixbuf(data):
    """The image of a WebP file's bytes as a GdkPixbuf with alpha. Raises ValueError with the cause."""
    data = bytes(data)
    cause, width, height = header(data[:30], len(data))
    if cause:
        raise ValueError(cause)
    way = decoder()
    if way == "libwebp":
        lib = _libwebp()
        w, h = ctypes.c_int(), ctypes.c_int()
        if not lib.WebPGetInfo(data, len(data), ctypes.byref(w), ctypes.byref(h)):
            raise ValueError(DAMAGED)
        width, height = w.value, h.value
        if not (1 <= width <= MAX_SIDE and 1 <= height <= MAX_SIDE):
            raise ValueError(TOO_LARGE)
        size = width * height * 4
        if size > 64 * 1024 * 1024:
            raise ValueError(TOO_LARGE)
        buffer = (ctypes.c_ubyte * size)()
        if not lib.WebPDecodeRGBAInto(data, len(data), buffer, size, width * 4):
            raise ValueError(DAMAGED)
        return GdkPixbuf.Pixbuf.new_from_bytes(GLib.Bytes.new(bytes(buffer)), GdkPixbuf.Colorspace.RGB, True, 8,
                                               width, height, width * 4)
    if way == "gdkpixbuf":
        loader = GdkPixbuf.PixbufLoader.new_with_type("webp")
        try:
            loader.write(data)
            loader.close()
        except GLib.Error as exc:
            raise ValueError(DAMAGED) from exc
        image = loader.get_pixbuf()
        if image is None:
            raise ValueError(DAMAGED)
        if not (1 <= image.get_width() <= MAX_SIDE and 1 <= image.get_height() <= MAX_SIDE):
            raise ValueError(TOO_LARGE)
        return image if image.get_has_alpha() else image.add_alpha(False, 0, 0, 0)
    raise ValueError(NO_DECODER)


def png(data):
    """A WebP file's bytes as PNG bytes. Raises ValueError with the cause."""
    return bytes(pixbuf(data).save_to_bufferv("png", ["compression"], ["3"])[1])


def _key(path, info):
    return str(path), info.st_size, info.st_mtime_ns, _setting()


def verify(path):
    """Decode a WebP file in full, once while it stays the same: None when it can be used, or its cause."""
    path = Path(path)
    try:
        info = path.stat()
    except OSError:
        return DAMAGED
    key = _key(path, info)
    with _lock:
        if key in _verified:
            return _verified[key]
    cause = None
    if path.is_symlink() or not path.is_file() or not 1 <= info.st_size <= MAX_BYTES:
        cause = DAMAGED
    else:
        try:
            pixbuf(path.read_bytes())
        except ValueError as exc:
            cause = str(exc)
        except (OSError, GLib.Error, MemoryError):
            cause = DAMAGED
    with _lock:
        _verified[key] = cause
    return cause


def verdict(path):
    """Whether a pack file can be used: None, or the cause. A file other than WebP always can, as before. A WebP is
    judged by its full decode once verify ran on it, and until then by the byte rule and a decoder being there."""
    path = Path(path)
    if path.suffix.lower() != ".webp":
        return None
    try:
        info = path.stat()
    except OSError:
        return DAMAGED
    with _lock:
        if _key(path, info) in _verified:
            return _verified[_key(path, info)]
    if path.is_symlink() or not path.is_file() or not 1 <= info.st_size <= MAX_BYTES:
        return DAMAGED
    try:
        with path.open("rb") as stream:
            head = stream.read(30)
    except OSError:
        return DAMAGED
    return problem(head, info.st_size) or (None if available() else NO_DECODER)


def chooser_cause(cause):
    """The cause as the user reads it after choosing artwork: a still image is asked for after an animated one."""
    return cause + STILL if cause == ANIMATED else cause
