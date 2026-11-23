"""Checks for build-pack-previews.py: the order of formats, WebP fallbacks, and the strip index.

Each check builds a checkout of its own in a temporary folder, with a Windows/PackCatalog.tsv
and an empty PackPreviews folder. Run it with the export environment's Python:
    python -I tools/test-build-pack-previews.py
"""
import base64
import contextlib
import csv
import hashlib
import importlib.util
import io
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from PIL import Image, features

# Loading the tool must not leave a __pycache__ folder in the checkout.
sys.dont_write_bytecode = True
TOOL = Path(__file__).resolve().with_name("build-pack-previews.py")
PACK = "Craft-Icons-Artist/Solid"
# From the WebP design's fixtures: A8 is the first 34 bytes of a 16x16 WebP, A10 a PNG signature
# followed by zeros, A11 a 5000x4 WebP, A12 a 32x32 WebP whose image data was zeroed behind a valid
# header, A15 a 32x32 animation of two frames (blue, then red), and A16 a 16x16 blue PNG.
A8 = base64.b64decode("UklGRiwAAABXRUJQVlA4TB8AAAAvD8ADECDStpl/00eF5w==")
A10 = base64.b64decode("iVBORw0KGgoAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
A11 = base64.b64decode("UklGRhgAAABXRUJQVlA4TAwAAAAvh9MAAChAAfrf/wA=")
A12 = base64.b64decode("UklGRioAAABXRUJQVlA4TB0AAAAvH8AHEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=")
A15 = base64.b64decode(
    "UklGRnwAAABXRUJQVlA4WAoAAAASAAAAHwAAHwAAQU5JTQYAAAAAAAAAAABBTk1GJAAAAAAAAAAAAB8AAB8AAGQAAABWUDhMDAAAAC8fwAcAKEAB+t//"
    "AEFOTUYkAAAAAAAAAAAAHwAAHwAAZAAAAFZQOEwMAAAALx/ABwAoQP8L0P8A"
)
A16 = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAHUlEQVR42mNkYPj/n4ECwMRAIRg1YNSAUQMGiwEAVm8CHr3k3X0AAAAASUVORK5CYII="
)
RED, GREEN, BLUE = (255, 0, 0, 255), (0, 255, 0, 255), (0, 0, 255, 255)
RED_SVG = b'<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"><rect width="16" height="16" fill="#f00"/></svg>'


def solid(colour, format, **options):
    """A 16x16 image of one opaque colour in a format Pillow writes."""
    buffer = io.BytesIO()
    Image.new("RGBA", (16, 16), colour).save(buffer, format=format, **options)
    return buffer.getvalue()


def red_webp():
    """A 16x16 lossless WebP of opaque red, like A4."""
    return solid(RED, "WEBP", lossless=True)


def load_tool(root):
    """Load a fresh copy of the tool that works on the checkout at root."""
    spec = importlib.util.spec_from_file_location("build_pack_previews", TOOL)
    tool = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(tool)
    tool.ROOT, tool.OUTPUT = root, root / "PackPreviews"
    return tool


@unittest.skipUnless(features.check("webp"), "Pillow lacks WebP support")
class PackPreviewTests(unittest.TestCase):
    def setUp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        self.root = Path(folder.name)
        self.previews = self.root / "PackPreviews"
        self.previews.mkdir()
        self.tool = load_tool(self.root)
        self.artwork = {}

    def add(self, source, data):
        """Put a file in the checkout and list it in Windows/PackCatalog.tsv. Sources here are canonical names."""
        (self.root / source).parent.mkdir(parents=True, exist_ok=True)
        (self.root / source).write_bytes(data)
        self.artwork[source] = hashlib.sha256(data).hexdigest()
        rows = ["1" * 40] + ["\t".join(("2" * 40, file, file, digest)) for file, digest in self.artwork.items()]
        (self.root / "Windows").mkdir(exist_ok=True)
        (self.root / "Windows/PackCatalog.tsv").write_text("\n".join(rows) + "\n", encoding="utf-8")

    def build(self, *redraw):
        """Run the tool and return its warnings."""
        warnings = io.StringIO()
        with contextlib.redirect_stderr(warnings):
            self.tool.main(redraw)
        return warnings.getvalue()

    def index(self):
        with (self.previews / "catalog.tsv").open(encoding="utf-8", newline="") as stream:
            return list(csv.reader(stream, delimiter="\t"))

    def assertCentre(self, key, colour, tile=0):
        """A tile of a strip, the first unless another is named, shows this colour at its centre."""
        name = next(row[1] for row in self.index() if row[0] == key)
        centre = (tile * (self.tool.CELL + self.tool.GAP) + self.tool.CELL // 2, self.tool.CELL // 2)
        with Image.open(self.previews / name) as strip:
            pixel = strip.convert("RGBA").getpixel(centre)
        self.assertTrue(all(abs(a - b) <= 2 for a, b in zip(pixel, colour)), f"tile {tile} centre {pixel}, expected {colour}")

    def assertGivesWay(self, webp, cause):
        """Alone, this WebP stops the run with its cause. Beside a PNG, it gives way to the PNG with a warning."""
        self.add(f"{PACK}/PhotoCraft.webp", webp)
        with self.assertRaises(ValueError) as caught:
            self.build()
        self.assertEqual(str(caught.exception), f"No usable artwork for PhotoCraft in Artist/Solid: {cause}")
        self.assertFalse((self.previews / "catalog.tsv").exists())
        # None of the WebP fixtures shows green, so a green tile shows that the PNG was drawn.
        self.add(f"{PACK}/PhotoCraft.png", solid(GREEN, "PNG"))
        self.assertEqual(self.build(), f"warning: {PACK}/PhotoCraft.webp: {cause} Using {PACK}/PhotoCraft.png.\n")
        self.assertCentre(PACK, GREEN)

    def test_webp_twin_is_drawn(self):
        self.add(f"{PACK}/PhotoCraft.webp", red_webp())
        self.add(f"{PACK}/PhotoCraft.png", A16)
        self.assertEqual(self.build(), "")
        self.assertCentre(PACK, RED)

    def test_animated_webp_falls_back_to_png(self):
        # The PNG is green, a colour neither frame of A15 has, so the tile shows that the PNG was drawn.
        self.add(f"{PACK}/PhotoCraft.webp", A15)
        self.add(f"{PACK}/PhotoCraft.png", solid(GREEN, "PNG"))
        self.assertEqual(self.build(), f"warning: {PACK}/PhotoCraft.webp: Animated WebP artwork is not supported. Using {PACK}/PhotoCraft.png.\n")
        self.assertCentre(PACK, GREEN)

    def test_damaged_webp_falls_back_to_png(self):
        self.add(f"{PACK}/PhotoCraft.webp", A8)
        self.add(f"{PACK}/PhotoCraft.png", A16)
        self.assertEqual(self.build(), f"warning: {PACK}/PhotoCraft.webp: The WebP file is damaged or incomplete. Using {PACK}/PhotoCraft.png.\n")
        self.assertCentre(PACK, BLUE)

    def test_unusable_webp_alone_fails(self):
        self.add(f"{PACK}/PhotoCraft.webp", A15)
        with self.assertRaises(ValueError) as caught:
            self.build()
        self.assertEqual(str(caught.exception), "No usable artwork for PhotoCraft in Artist/Solid: Animated WebP artwork is not supported.")
        self.assertFalse((self.previews / "catalog.tsv").exists())

    def test_mislabeled_webp_falls_back_to_png(self):
        self.assertGivesWay(A10, "The file is named .webp but is not a WebP image.")

    def test_oversized_webp_falls_back_to_png(self):
        self.assertGivesWay(A11, "WebP artwork must be at most 4096 pixels per side.")

    def test_undecodable_webp_falls_back_to_png(self):
        # A12 passes the byte rule. Pillow finds the damage only when it decodes the image data.
        self.assertGivesWay(A12, "The WebP file is damaged or incomplete.")

    @unittest.skipUnless(importlib.util.find_spec("resvg_py"), "resvg-py is not installed")
    def test_png_beats_svg_and_svg_beats_ico(self):
        # Each icon lists its worse format first, so the order of the inventory cannot decide.
        self.add(f"{PACK}/PhotoCraft.svg", RED_SVG)
        self.add(f"{PACK}/PhotoCraft.png", A16)
        self.add(f"{PACK}/GridCraft.ico", solid(GREEN, "ICO"))
        self.add(f"{PACK}/GridCraft.svg", RED_SVG)
        self.assertEqual(self.build(), "")
        self.assertEqual(self.index()[0][4], "GridCraft,PhotoCraft")
        self.assertCentre(PACK, RED, tile=0)
        self.assertCentre(PACK, BLUE, tile=1)

    def test_changed_webp_beside_png_is_refused(self):
        self.add(f"{PACK}/PhotoCraft.webp", red_webp())
        self.add(f"{PACK}/PhotoCraft.png", A16)
        # The WebP changed after the inventory was written. A PNG beside it does not make that acceptable.
        changed = self.root / PACK / "PhotoCraft.webp"
        changed.write_bytes(solid(GREEN, "WEBP", lossless=True))
        with self.assertRaises(ValueError) as caught:
            self.build()
        self.assertEqual(str(caught.exception), f"Artwork differs from the inventory: {changed}")
        self.assertFalse((self.previews / "catalog.tsv").exists())

    def test_output_is_lossless_and_valid(self):
        for app in ("PhotoCraft", "GridCraft", "FilmCraft", "ArtCraftLauncher"):
            self.add(f"{PACK}/{app}.png", A16)
        self.add(f"{PACK}/PhotoCraft.webp", red_webp())
        self.add(f"{PACK}/FileTypes/pcraft.webp", red_webp())
        self.add(f"{PACK}/FileTypes/pcraft.png", A16)
        # A pack name with no Latin letters still gives a valid file name.
        self.add("Craft-Icons-หมาแดนซ์/PhotoCraft.webp", red_webp())
        self.build()
        rows = self.index()
        self.assertEqual([row[0] for row in rows], [PACK, PACK + "/FileTypes", "Craft-Icons-หมาแดนซ์/Root"])
        self.assertEqual(rows[0][4], "ArtCraftLauncher,FilmCraft,GridCraft")
        for row in rows:
            self.assertEqual(len(row), 5)
            self.assertRegex(row[1], r"^[A-Za-z0-9-]+\.webp$")
            self.assertLessEqual(len(row[4].split(",")), 3)
            data = (self.previews / row[1]).read_bytes()
            self.assertEqual(data[12:16], b"VP8L")
            self.assertLessEqual(len(data), 65536)
            self.assertEqual(row[2:4], [hashlib.sha256(data).hexdigest(), str(len(data))])

    def test_published_strip_kept_when_twins_added(self):
        self.add(f"{PACK}/PhotoCraft.png", A16)
        self.build()
        index = (self.previews / "catalog.tsv").read_bytes()
        strips = {path.name: path.read_bytes() for path in self.previews.glob("*.webp")}
        self.add(f"{PACK}/PhotoCraft.webp", red_webp())
        self.assertEqual(self.build(), "")
        self.assertEqual((self.previews / "catalog.tsv").read_bytes(), index)
        self.assertEqual({path.name: path.read_bytes() for path in self.previews.glob("*.webp")}, strips)
        # Naming the pack draws its strip again, now from the WebP.
        self.build(PACK)
        self.assertNotEqual((self.previews / "catalog.tsv").read_bytes(), index)
        self.assertCentre(PACK, RED)


class PillowWithoutWebPTests(unittest.TestCase):
    def test_stops_without_webp(self):
        folder = tempfile.TemporaryDirectory()
        self.addCleanup(folder.cleanup)
        # The checkout is empty, so a run that did not stop at once would fail to read the inventory instead.
        tool = load_tool(Path(folder.name))
        with mock.patch.object(tool.features, "check", return_value=False) as check:
            with self.assertRaises(SystemExit) as caught:
                tool.main(())
        self.assertEqual(caught.exception.code, "Pillow lacks WebP support.")
        check.assert_called_once_with("webp")


if __name__ == "__main__":
    unittest.main(verbosity=2)
