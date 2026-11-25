# Zstandard decoder

Codex compresses older session logs as `.jsonl.zst`. macOS ships no zstd library or command,
so Tracker builds this small decoder into the app (`TrackerUnzstd`, from `bin/build-desktop`).

- `common/`, `decompress/`, `zstd.h`, `zstd_errors.h` and `LICENSE` are copied unchanged from
  [facebook/zstd](https://github.com/facebook/zstd) at tag `v1.5.7` (BSD license).
- `zstddeclib.c` includes them as one file, like zstd's own single-file decoder.
- `unzstd.c` is Tracker's command: it decompresses one file to standard output.
