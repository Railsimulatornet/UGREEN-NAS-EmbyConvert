"""Media guards tested with synthetic clips and a stubbed encoder; no QSV or NAS."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]


def run_ffmpeg(*args):
    subprocess.run(["ffmpeg", "-v", "error", "-nostdin", *map(str, args)], check=True, capture_output=True, timeout=30)


class OutputIntegrityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not shutil.which("ffmpeg") or not shutil.which("ffprobe"):
            raise RuntimeError("These regression tests require ffmpeg and ffprobe.")
        cls.temporary = tempfile.TemporaryDirectory(prefix="synthetic-media-fixtures-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.fixtures = Path(cls.temporary.name)
        cls.source = cls.fixtures / "source.mp4"
        run_ffmpeg("-f", "lavfi", "-i", "testsrc2=size=64x64:rate=10", "-t", "3",
                   "-c:v", "libx264", "-threads", "1", cls.source)
        packets = json.loads(subprocess.check_output([
            "ffprobe", "-v", "error", "-show_packets", "-select_streams", "v:0", "-of", "json", str(cls.source),
        ], text=True, timeout=10))["packets"]
        # Damage a late encoded slice while preserving its container and NAL header.
        # A packet-copy scan can read it; a decoder reports the broken payload.
        damaged = bytearray(cls.source.read_bytes())
        packet = packets[-3]
        start, size = int(packet["pos"]), int(packet["size"])
        if size <= 10:
            raise RuntimeError("Fixture packet is unexpectedly small.")
        damaged[start + 10:start + size] = bytes([255]) * (size - 10)
        damaged_mp4 = cls.fixtures / "damaged.mp4"
        damaged_mp4.write_bytes(damaged)
        run_ffmpeg("-i", damaged_mp4, "-c", "copy", cls.fixtures / "damaged.mkv")
        run_ffmpeg("-i", cls.source, "-t", "0.5", "-c", "copy", cls.fixtures / "short.mkv")
        run_ffmpeg("-i", cls.source, "-c", "copy", cls.fixtures / "valid.mkv")

        cls.multiaudio = cls.fixtures / "multiaudio.mp4"
        run_ffmpeg(
            "-f", "lavfi", "-i", "testsrc2=size=64x64:rate=10:duration=3",
            "-f", "lavfi", "-i", "sine=frequency=1000:duration=3",
            "-f", "lavfi", "-i", "sine=frequency=600:duration=6",
            "-map", "0:v:0", "-map", "1:a:0", "-map", "2:a:0",
            "-c:v", "libx264", "-threads", "1", "-c:a", "aac",
            "-metadata:s:a:0", "language=deu", "-metadata:s:a:1", "language=eng", cls.multiaudio,
        )
        run_ffmpeg("-i", cls.multiaudio, "-map", "0", "-c", "copy", cls.fixtures / "multiaudio.mkv")
        # Keep both complete audio streams, but truncate only the video.
        # Container duration therefore cannot reveal this missing video tail.
        run_ffmpeg("-i", cls.multiaudio, "-map", "0:v:0", "-map", "0:a",
                   "-vf", "trim=duration=0.5", "-c:v", "libx264", "-threads", "1", "-c:a", "copy",
                   cls.fixtures / "short-video-with-audio.mkv")

    def check_process(self, language, mode, fixture, accepted, source_fixture=None):
        default = REPO / language / "EmbyConvert/ffmpeg/scripts/hevc_batch.sh"
        source_path = Path(os.environ.get("EMBY_SCRIPT_" + language.upper(), default))
        source = source_path.read_text()
        marker = "# ---------------------------\n# Args\n# ---------------------------"
        self.assertIn(marker, source)
        definitions = source.split(marker, 1)[0]
        with tempfile.TemporaryDirectory(prefix="output guard test ") as temporary:
            root = Path(temporary)
            input_root, output_root = root / "input", root / "output"
            input_root.mkdir()
            output_root.mkdir()
            original = input_root / "video.mp4"
            shutil.copyfile(self.fixtures / source_fixture if source_fixture else self.source, original)
            original_bytes = original.read_bytes()
            output = output_root / "video.mkv"
            output.write_bytes(b"PREVIOUS OUTPUT MUST SURVIVE FAILED CONVERSION")
            previous = output.read_bytes()
            fixture_path = self.fixtures / fixture
            env = dict(
                os.environ, IN_ROOT=str(input_root), OUT_ROOT=str(output_root),
                FIXTURE_OUTPUT=str(fixture_path), TEST_SOURCE=str(original),
                DRY_RUN="0", OVERWRITE="1", STRICT_INPUT="1", VERIFY_OUTPUT="1",
                SKIP_4K="0", SKIP_HDR="0", SKIP_DOLBY_VISION="0",
                SIZE_GUARD="0", HYBRID_ENCODE="0", RATE_MODE="quality",
                REMUX_HEVC="1" if mode == "remux" else "0",
                REENCODE_HEVC="1" if mode == "reencode" else "0",
                HEVC_MIN_SIZE_GB="0", HEVC_MIN_SAVINGS_PCT="0",
                HEVC_REENCODE_GQ_START="20", HEVC_REENCODE_GQ_MAX="20",
                VMAF_CHECK="0", EXCLUDE_DIRS="@eaDir", AUDIO_GERMAN_ONLY="0",
            )
            stub = """
encode_hevc_qsv_to_tmp() { cp -- "$FIXTURE_OUTPUT" "$2"; }
run_cmd() { cp -- "$FIXTURE_OUTPUT" "${@: -1}"; }
min_savings_ok() { return 0; }
"""
            if mode in ("remux", "reencode"):
                stub += 'get_vcodec() { printf hevc; }\n'
            result = subprocess.run(
                ["bash", "-c", definitions + stub + '\nprocess_one "$TEST_SOURCE"'],
                env=env, capture_output=True, text=True, timeout=30,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(original.read_bytes(), original_bytes)
            self.assertEqual(output.read_bytes(), fixture_path.read_bytes() if accepted else previous,
                             result.stdout + result.stderr)
            self.assertFalse((output_root / "video.mkv.tmp.mkv").exists())
            if not accepted:
                self.assertIn("VERIFY_OUTPUT failed", result.stdout)

    def test_valid_output_is_promoted(self):
        for language in ("de", "en"):
            for mode in ("encode", "remux", "reencode"):
                with self.subTest(language=language, mode=mode):
                    self.check_process(language, mode, "valid.mkv", True)

    def test_decoder_corruption_preserves_existing_media(self):
        for language in ("de", "en"):
            for mode in ("encode", "remux", "reencode"):
                with self.subTest(language=language, mode=mode):
                    self.check_process(language, mode, "damaged.mkv", False)

    def test_truncated_output_preserves_existing_media(self):
        for language in ("de", "en"):
            for mode in ("encode", "remux", "reencode"):
                with self.subTest(language=language, mode=mode):
                    self.check_process(language, mode, "short.mkv", False)

    def test_complete_audio_does_not_hide_truncated_video(self):
        for language in ("de", "en"):
            for mode in ("encode", "remux", "reencode"):
                with self.subTest(language=language, mode=mode):
                    self.check_process(language, mode, "short-video-with-audio.mkv", False, "multiaudio.mp4")

    def test_german_audio_selection_preserves_complete_video(self):
        for language in ("de", "en"):
            for extension in ("mp4", "mkv"):
                with self.subTest(language=language, extension=extension), tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    input_root, output_root = root / "input", root / "output"
                    input_root.mkdir()
                    output_root.mkdir()
                    original = input_root / ("video." + extension)
                    shutil.copyfile(self.fixtures / ("multiaudio." + extension), original)
                    original_bytes = original.read_bytes()
                    output = output_root / "video.mkv"
                    previous = b"EXISTING OUTPUT"
                    output.write_bytes(previous)
                    script = REPO / language / "EmbyConvert/ffmpeg/scripts/hevc_batch.sh"
                    script = Path(os.environ.get("EMBY_SCRIPT_" + language.upper(), script))
                    marker = "# ---------------------------\n# Args\n# ---------------------------"
                    definitions = script.read_text().split(marker, 1)[0]
                    env = dict(os.environ, IN_ROOT=str(input_root), OUT_ROOT=str(output_root), TEST_SOURCE=str(original),
                               DRY_RUN="0", OVERWRITE="1", STRICT_INPUT="1", VERIFY_OUTPUT="1", SIZE_GUARD="0",
                               HYBRID_ENCODE="0", RATE_MODE="quality", AUDIO_GERMAN_ONLY="1", KEEP_ALL_VIDEO_STREAMS="0",
                               REENCODE_HEVC="0", REMUX_HEVC="0", VMAF_CHECK="0")
                    # Exercise the real audio selector; copy synthetic streams instead of using QSV.
                    code = definitions + """
encode_hevc_qsv_to_tmp() {
  build_map_args "$1" "$6" "$KEEP_ALL_VIDEO_STREAMS" || return 2
  ffmpeg -v error -nostdin -i "$1" "${MAP_ARGS[@]}" -c copy "$2"
}
process_one "$TEST_SOURCE"
"""
                    result = subprocess.run(["bash", "-c", code], env=env, capture_output=True, text=True, timeout=30)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(original.read_bytes(), original_bytes)
                    self.assertNotEqual(output.read_bytes(), previous, result.stdout + result.stderr)
                    streams = json.loads(subprocess.check_output([
                        "ffprobe", "-v", "error", "-show_streams", "-count_frames", "-of", "json", str(output),
                    ], text=True, timeout=10))["streams"]
                    video = [stream for stream in streams if stream["codec_type"] == "video"]
                    audio = [stream for stream in streams if stream["codec_type"] == "audio"]
                    self.assertEqual(len(video), 1)
                    self.assertEqual(int(video[0]["nb_read_frames"]), 30)
                    self.assertEqual(len(audio), 1)
                    self.assertEqual(audio[0].get("tags", {}).get("language"), "deu")


if __name__ == "__main__":
    unittest.main(verbosity=2)
