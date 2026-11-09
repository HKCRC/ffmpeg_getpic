# ffmpeg_getpic

Scan every `YYYYMMDD` directory under the recordings root, extract keyframes with ffmpeg, upload the frames, then upload the two daily clips that should be kept.

## What it does

- Polls `RECORDINGS_ROOT` every `SCAN_INTERVAL` seconds. When that path is omitted, the script uses `/workspace/hik_download/<SITE>Data`.
- Extracts a clip when its time range overlaps an upload window. A clip that starts at 08:49 and runs past 09:00 is extracted; frames before 09:00 are not uploaded.
- Names each frame `<clip>_tHHMMSS.jpg`, using the frame's own timestamp rather than the clip start time.
- Uploads jpg files to `UPLOAD_URL` as `site`, `date` (`YYYYMMDD`), and `file`. Deletes each jpg after a successful upload.
- After the frames for a day are uploaded, deletes clips that are not the keepers. The keepers are the clip closest to 10:00 inside the morning window and the clip closest to 15:00 inside the afternoon window.
- Uploads those two clips through `/api/videos` in chunks, then deletes the local files. A slot is not uploaded until its window has ended.
- Skips a date directory while `hik_download` is writing it. Other dates are still extracted, deleted, and uploaded.
- Holds `logs/extract.lock` so a second copy exits instead of uploading and deleting in parallel.
- Retries a clip that ffmpeg cannot read. After `VIDEO_MAX_ATTEMPTS` failures (default 3) the clip is marked processed and the loop continues.

## Requirements

- ffmpeg (with ffprobe)
- curl
- python3 and sha256sum when video upload is enabled

```bash
sudo apt update
sudo apt install -y ffmpeg curl
```

## Files

- `extract_keyframes.sh` does the scan, extract, upload, and delete steps
- `config.conf` holds site, paths, windows, and upload settings (gitignored)
- `output/` stores jpg files until they upload
- `.state/` stores processed, uploaded, and video-upload records

## Configuration

```bash
SITE=site_code
RECORDINGS_ROOT=/workspace/hik_download/site_codeData
OUTPUT_DIR=./output
FRAME_INTERVAL=1800
SCAN_INTERVAL=20
UPLOAD_ENABLED=1
UPLOAD_URL=http://aisafety.craner.hk/api/upload
UPLOAD_TOKEN=
UPLOAD_TIME_WINDOWS="09:00:00-11:00:00 14:00:00-17:45:00"
STATE_DIR=./.state
DELETE_VIDEO_AFTER_UPLOAD=1
KEEP_DAILY_TIMES="10:00:00 15:00:00"
MAX_DATA_BYTES=2147483648
VIDEO_UPLOAD_ENABLED=1
VIDEO_CHUNK_BYTES=1048576
```

`UPLOAD_TIME_WINDOWS` should match the download windows in `hik_download`. `MAX_DATA_BYTES` is the local recording-folder cap. It is separate from the 50 GB free-space check in the downloader. Kept clips are not deleted to satisfy that cap; they are deleted after the video upload succeeds.

State files:

- `YYYYMMDD.processed`: clips already extracted
- `YYYYMMDD.uploaded`: frames already uploaded
- `YYYYMMDD.video_done`: daily slots already uploaded
- `YYYYMMDD.video_session`: an unfinished chunked upload, resumed on the next pass
- `YYYYMMDD.failed`: extract failure counts

## Run

```bash
chmod +x extract_keyframes.sh
./extract_keyframes.sh
```

The process loops until stopped. `hik_download/start_daemon.sh` starts it in the background together with the download scheduler.
