@echo off && python -x "%~f0" %* && exit /B || pause && exit /B
### ^ batch part ^ ### v Python part v ###
"""
# Add Chapters - a one-file interactive script to add chapters to your video files as fast and conveniently as possible!

I needed a tool for quickly, easily and accurately adding chapters to my videos, but failed to find one that met my expections.

- **quick**: adding chapters takes seconds
  > note that the initial FFmpeg scene change detection can take a few seconds or minutes depending on file size and computer performance
- **easy**: comes with presets, accepts many timestamp formats
- **accurate**: By default syncs chapters timestamps with scene changes in the video stream

## Technical notes

I really wanted to try to make a file that behaves like a `.bat` file, specifically you can drag-and-drop
files on it and they will be passed as parameters to the script, but whose logic is Python code, for it's
a language that I particularly affectionate for its simplicity and flexibility (among other things).

I adapted the python-in-bat-file fusion technique from LALLOU'LAB article (http://lallouslab.net/2017/06/12/batchography-embedding-python-scripts-in-your-batch-file-script/)
because I wished to clearly separate batch and Python code.

Note: Later I found there was a similar answer from jeb that, as a bonus, is syntactically valid in Python : https://stackoverflow.com/a/17468811

### How It works

Focus on the first line

1. `@echo off`: Batch command to disable printing executed lines
2. `python -x "%~f0" %*`: Call the python interpreter
  a. `-x` to avoid reading the first line, because it is not valid Python syntax
  b. `"%~f0"` run the current file
  c. `%*` pass through the parameters
3. `&& exit /B`: Executed if the python interpreter ends with a "good" error level; exit the script to avoid executing the rest of the file
3. ` || pause && exit /B`: Executed if the python interpreter ends with a "bad" error level, for example if an exception is thrown.
  This command pause the script until the user pressen the ENTER key, then exits the script to avoid executing the rest of the file.
  Without `pause` the script would immediately exit and the user would miss the error message when using the script with drag-and-drop.

All of this ensures the first line is only executed by the Windows command line, and the rest of the file
is only executed by the Python interpreter.

### Why use MKVmerge instead of FFmpeg for merging MKVs ?

MKVmerge is widely recognised as the main and best muxer for the MKV format, also I dislike how FFmpeg strips metadata from MKV files.
For other formats I find that FFmpeg is the best tool for its wide compatibility.


## Usage

The main way is to simply drag-and-drop video files onto this script.

Alternatively you can run it from the command line, passing it video file(s) path(s) as parameters.

Timestamp formats accepted:

- `XXhXXmXXs`: can be shortened if `XX` is `0`; `s` is optional; example `3m47` for 3 minutes 47 seconds
- `XX:XX:XX`: like above but uses `:` separators; example `1:22:05` for 1 hour 22 minutes 5 seconds

### Example - series mode

Let's say you have many episodes of a show as files without intro and outro chapter marks and want to add them.

1. Drag-and-drop the video files onto `add_chapters.bat`
2. For each file you will be asked to choose a mode. Since you want to add chapters for intro and outro, choose `series`
3. For each file, the script will ask you start and end timestamps for the intro and outro. Use a media player to determine them and input them (see above for accepted formats).
  > If an episode doesn't have an intro or outro, you can skip it by leaving the timestamp field blank.
4. For each file, after entering the timestamps, the script will pause (see section below), and after confirmation it will generate the output file with chapters.

### Let's say you made a typo

If you made a typo when entering a timestamp or chapter title, you can either fix the generated `.metadata` file when prompted, or fix it later and re-run the output file generation step using the generated `.merge.bat` script.


## Requirements

  - Run from the windows command line (not PowerShell, wsl or linux shells)
    > Note: You're welcome to edit the first line to make it work with your shell
  - Python `>=3.10`, FFmpeg, MKVmerge (from MKVToolNix is fine) installed
  - The following must be callable from a shell : `python`, `ffmpeg`, `mkvmerge`
  - The Python package `drs.drslib>=0.10.0`


## License

This is released under the MIT License (see LICENSE file).
"""
import argparse
import datetime
import re
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Self

try:
    from drslib.cli_ui import select_action, choose_from_list
    from drslib.execute import execute
    from drslib.path_tools import find_available_path
    from drslib.serialize import JSONSerializable
except ImportError as e:
    raise ImportError("Please install drs.drslib>=0.10.0") from e

TIMESTAMP_PATTERN = re.compile(r"^(?:(?:(\d+)h)?(\d+)m)?(\d+)s?$")
TIMESTAMP_PATTERN_2 = re.compile(r"^(?:(?:(\d+):)?(\d+):)?(\d+)$")
FILE_STEM_IGNORE_CRC_PATTERN = re.compile(r"^(.+?)(?:\s*\[[a-fA-F0-9]{8}\])?$")
FFMPEG_METADATA_HEADER = ";FFMETADATA1"
SEPARATOR = "#" * 20
PRE_INTERACTIVE_PROMPT = "Start of interactive mode. In case of typo you can fix chapter file at a later step when prompted"
METADATA_FILE_READY_PROMPT = "Chapter file written. If you need to edit it to fix a typo, do it now and save the file. When ready to continue press ENTER."

def get_file_paths() -> list[Path]:
    """Parses CLI arguments"""
    parser = argparse.ArgumentParser(description="Interactively add chapters to your videos. Currently in beta")

    parser.add_argument("FILES", nargs="+", help="Video file")
    if not parser.parse_args().FILES:
        parser.print_usage()
        raise ValueError("Missing argument FILES")
    return [Path(p.replace("\\", "/")).resolve() for p in parser.parse_args().FILES if p]

@dataclass
class VideoFileMetadata(JSONSerializable):
    file: Path
    scene_changes: dict[float, float]
    total_video_duration_ms: int

    SCENECHANGE_PATTERN = re.compile(r"frame:\d+\s+pts:\d+\s+pts_time:([\d\.]+).+?lavfi\.scene_score=([\d\.]+)", flags=re.DOTALL)
    DURATION_PATTERN = re.compile(r".+Duration: ([\d\:\.]{8,}).+", flags=re.DOTALL)
    JSON_SERIALIZE_DEFAULT_PARAMS = {"ensure_ascii": False, "indent": 2, "default": Path.as_posix}

    def post_deserialization(self):
        """JSON format only supports string mapping keys, so here we convert it back. Also we neet to deserialize Path"""
        self.scene_changes = {
            float(k): v for k, v in self.scene_changes.items()
        }
        self.file = Path(self.file)

    @classmethod
    def from_ffmpeg_output(cls, file: Path, ffmpeg_out: str) -> Self:
        """Parse FFmpeg output for scene change metadata"""
        scene_changes = {
            float(_match.group(1)): float(_match.group(2))
            for _match in cls.SCENECHANGE_PATTERN.finditer(ffmpeg_out)
        }
        duration = cls.DURATION_PATTERN.match(ffmpeg_out).group(1)
        # parse duration to ms
        timestamp_sec, timestamp_ms = duration.split(".")
        parsed_timestamp_ms = int(f"{timestamp_ms:03}"[0:3]) if timestamp_ms else 0
        parsed_video_duration_ms = parse_timestamp(timestamp_sec) * 1000 + parsed_timestamp_ms
        return VideoFileMetadata(file, scene_changes, parsed_video_duration_ms)

    def nearest_scene_changes(self, timestamp: float, tolerance: float) -> dict[float, float]:
        """Returns subset of scene_changes around given timestamp"""
        return [
            ts
            for ts in self.scene_changes
            if abs(ts - timestamp) < tolerance
        ]


def extract_scenechanges_from_video(video: Path, threshold: float = 0.25) -> VideoFileMetadata:
    cmd = [
        "ffmpeg",
        "-i", video,
        "-filter_complex", f"select='gt(scene, {threshold:0.2f})',metadata=print",
        "-fps_mode", "passthrough",
        "-f", "null", "-"
    ]
    print("Extracting scene information, please wait a few seconds..")
    print(f"{cmd=}")
    output = execute(cmd)['stderr']
    if "muxing overhead" not in output:
        raise ValueError(f"Failed to extract scene info from video file {video}")
    Path("./dump.json").write_text(output, encoding="utf-8")
    return VideoFileMetadata.from_ffmpeg_output(video, output)


@dataclass
class ChapterStartMarker:
    start: float
    title: str

    @property
    def start_ms(self) -> int:
        return int(self.start * 1000)

def parse_timestamp(timestamp: str) -> int | None:
    timestamp = timestamp.strip()
    for pattern in (TIMESTAMP_PATTERN, TIMESTAMP_PATTERN_2):
        _match = pattern.match(timestamp)
        if not _match:
            continue
        # print(f"Match using pattern {pattern}")
        return sum(0 if _match.group(3-i) is None else int(_match.group(3-i)) * (60 ** i) for i in range(3))
    return None


def get_timestamp(message: str, scene_changes: VideoFileMetadata) -> int | None:
    # Parse user input into a timestamp
    while True:
        raw_timestamp = input(message + ": ").strip()
        if not raw_timestamp:
            return None
        if raw_timestamp.startswith('-f'):
            return parse_timestamp(raw_timestamp[2:].strip())
        parsed_timestamp = parse_timestamp(raw_timestamp)
        # Match with scene_changes
        scene_change_candidates = scene_changes.nearest_scene_changes(parsed_timestamp, tolerance=2.0)
        if len(scene_change_candidates) == 0:
            print(f"No scene change within 3s of timestamp {parsed_timestamp}s")
            continue
        if len(scene_change_candidates) == 1:
            return scene_change_candidates[0]
        # Choose among candidates
        return choose_from_list(scene_change_candidates)


def get_series_chapters(scene_changes: VideoFileMetadata) -> list[ChapterStartMarker]:
    """Ask user about intro and outro timestamps"""
    res = []

    print(f"Add '-f' before timestamp to use timestamp without scenechange")
    start_timestamp = get_timestamp("Start timestamp for intro", scene_changes)
    if start_timestamp:
        end_timestamp = get_timestamp("End timestamp for intro", scene_changes)
        if end_timestamp:
            if start_timestamp > 1:
                res.append(ChapterStartMarker(0.0, ""))
            res.append(ChapterStartMarker(start_timestamp, "Intro"))
            res.append(ChapterStartMarker(end_timestamp, "Episode"))

    start_timestamp = get_timestamp("Start timestamp for outro", scene_changes)
    if start_timestamp:
        res.append(ChapterStartMarker(start_timestamp, "Outro"))
        end_timestamp = get_timestamp("End timestamp for outro (if no post credit you can skip)", scene_changes)
        if end_timestamp:
            res.append(ChapterStartMarker(end_timestamp, "Post Credit"))

    return res


def get_manual_chapters(scene_changes: VideoFileMetadata) -> list[ChapterStartMarker]:
    """Ask user about intro and outro timestamps"""
    res = []

    print("Add '-f' before timestamp to use timestamp without scenechange")
    print("CTRL+C to end interactive phase")
    while True:
        try:
            start_timestamp = get_timestamp("Start timestamp for chapter", scene_changes)
            title = input("Chapter title: ")
            res.append(ChapterStartMarker(start_timestamp, title))
        except KeyboardInterrupt:
            break

    return res

def file_stem_without_crc(file_stem: str) -> str:
    """If a CRC checksum is present in file stem (matches `\[[a-fA-F0-9]{8}\]$`), remove it"""
    return FILE_STEM_IGNORE_CRC_PATTERN.match(file_stem).group(1)

def dump_merge_bat(ori_file: Path, cmd: list[Path | str | Any]) -> None:
    """Dump a command file in case the user wants to build the file again"""
    bat_file = ori_file.with_suffix(".merge.bat")
    content = " ".join(f'"{x.as_posix()}"' if isinstance(x, Path) else str(x) for x in cmd)
    bat_file.write_text(content, encoding="utf-8")

def mkvmerge_add_chapters(metadata: VideoFileMetadata, chapters: list[ChapterStartMarker]) -> Path:
    """Use mkvmerge to add given chapters to video file; Returns path of muxed file"""

    # Clean up : sort chapters just in case something went wrong
    chapters = sorted(chapters, key=lambda c: c.start_ms)
    ori_file = metadata.file

    def convert_to_mkvmerge_timestamp(ms: int) -> str:
        """This is a bit of a hack but it should work for durations up to 24h"""
        duration_as_datetime = datetime.datetime.min + datetime.timedelta(milliseconds=ms)
        return duration_as_datetime.strftime("%H:%M:%S.%f")[:-3]

    # Build metadata file
    metadata_file_contents = "\n".join(f"CHAPTER{idx+1:02}={convert_to_mkvmerge_timestamp(c.start_ms)}\nCHAPTER{idx+1:02}NAME={c.title}" for idx, c in enumerate(chapters))
    metadata_file = ori_file.with_suffix(".metadata")
    metadata_file.write_text(metadata_file_contents, encoding="utf-8")
    input(METADATA_FILE_READY_PROMPT)

    # Build merged file
    out_file = find_available_path(ori_file.parent, file_stem_without_crc(ori_file.stem) + "_out", file_ext=ori_file.suffix)
    cmd = [
        "mkvmerge",
        "--chapters", metadata_file,
        "-o", out_file,
        ori_file
    ]
    dump_merge_bat(ori_file, cmd)
    print(f"Merging chapters ..")
    # print(f"{cmd=}")
    execute(cmd)

    return out_file


def ffmpeg_add_chapters(metadata: VideoFileMetadata, chapters: list[ChapterStartMarker]) -> Path:
    """Use Fmpeg to add given chapters to video file; Returns path of muxed file"""

    # Clean up : add marker at end of video for end of last chapter, and sort chapters just in case something went wrong
    if max(c.start_ms for c in chapters) + 1000 < metadata.total_video_duration_ms:
        chapters.append(ChapterStartMarker((metadata.total_video_duration_ms + 1) / 1000, ""))
    chapters = sorted(chapters, key=lambda c: c.start_ms)
    ori_file = metadata.file

    # Build metadata file
    chapter_spans: list[tuple[int, int, str]] = [(_curr.start_ms, _next.start_ms - 1, _curr.title) for _curr, _next in zip(chapters, chapters[1:])]

    metadata_file_contents = FFMPEG_METADATA_HEADER + "\n\n" + "\n".join(f"[CHAPTER]\nTIMEBASE=1/1000\nSTART={span[0]}\nEND={span[1]}\ntitle={span[2]}\n" for span in chapter_spans)
    metadata_file = ori_file.with_suffix(".metadata")
    metadata_file.write_text(metadata_file_contents, encoding="utf-8")
    input(METADATA_FILE_READY_PROMPT)

    # Build merged file
    out_file = find_available_path(ori_file.parent, file_stem_without_crc(ori_file.stem) + "_out", file_ext=ori_file.suffix)
    cmd = [
        "ffmpeg",
        "-i", ori_file,
        "-i", metadata_file,
        "-map_metadata", "1",
        "-codec", "copy",
        out_file
    ]
    dump_merge_bat(ori_file, cmd)
    print(f"Merging chapters ..")
    # print(f"{cmd=}")
    stdx = execute(cmd)

    # test for success
    if "Chapter #1:0" not in stdx["stderr"]:
        raise RuntimeError("FFmpeg apparently failed to merge chapters")

    return out_file

MODES = {
    "series": {
        "explanation": "Add intro and outro chapters to series episodes",
        "action": get_series_chapters
    },
    "manual": {
        "explanation": "Add chapters manually",
        "action": get_manual_chapters
    }
}


def process_file(file_path: Path) -> None:

    if not file_path.exists():
        raise FileNotFoundError(file_path)
    print(f'Processing file "{file_path.name}"\n')

    # Get scene change data
    scenechange_json_file = file_path.with_suffix('.scenechange.json')
    metadata: VideoFileMetadata
    if scenechange_json_file.exists():
        metadata = VideoFileMetadata.from_json(scenechange_json_file.read_text(encoding="utf-8"))
    else:
        metadata = extract_scenechanges_from_video(file_path)
        scenechange_json_file.write_text(metadata.to_json(), encoding="utf-8")

    # Get user-provided chapter markers
    action: Callable[[VideoFileMetadata], list[ChapterStartMarker]] = select_action(MODES)
    print(SEPARATOR)
    print(PRE_INTERACTIVE_PROMPT)
    timestamps = action(metadata)
    print("Chapters:\n  - " + "\n  - ".join(map(str, timestamps)))
    print(SEPARATOR)

    # Add chapters to file
    muxer: Callable[[VideoFileMetadata, list[ChapterStartMarker]], Path] = mkvmerge_add_chapters if file_path.suffix.lower() == '.mkv' else ffmpeg_add_chapters
    new_file = muxer(metadata, timestamps)
    if new_file and new_file.exists():
        print(f"Merged chapters into file '{new_file.as_posix()}'")
    else:
        print(f"Something went wrong while merging the file")


def main() -> None:
    for file_path in get_file_paths():
        print("\n" + SEPARATOR + "\n")
        process_file(file_path)


if __name__ == "__main__":
    main()
    print('END OF PROGRAM')
