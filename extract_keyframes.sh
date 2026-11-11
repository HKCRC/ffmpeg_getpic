#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.conf"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "配置文件不存在: ${CONFIG_FILE}"
  exit 1
fi

# shellcheck disable=SC1090
source "${CONFIG_FILE}"

HIK_ROOT="$(cd "${SCRIPT_DIR}/../hik_download" 2>/dev/null && pwd || true)"

# 配置里的目录不存在时，改用 hik_download 旁边的同名目录。
prefer_local_dir() {
  local configured="$1"
  local name
  if [[ -d "${configured}" ]]; then
    printf '%s' "${configured}"
    return
  fi
  name="$(basename "${configured}")"
  if [[ -n "${HIK_ROOT}" && -d "${HIK_ROOT}/${name}" ]]; then
    printf '%s' "${HIK_ROOT}/${name}"
    return
  fi
  printf '%s' "${configured}"
}

SITE="${SITE:-}"
if [[ -z "${RECORDINGS_ROOT:-}" ]]; then
  if [[ -z "${SITE}" ]]; then
    echo "请在 config.conf 中设置 SITE，或直接设置 RECORDINGS_ROOT。"
    exit 1
  fi
  RECORDINGS_ROOT="/workspace/hik_download/${SITE}Data"
fi
RECORDINGS_ROOT="$(prefer_local_dir "${RECORDINGS_ROOT}")"
readonly RECORDINGS_ROOT

EXTRA_RECORDINGS="${EXTRA_RECORDINGS:-}"
if [[ -n "${EXTRA_RECORDINGS}" ]]; then
  remapped_recordings=""
  for spec in ${EXTRA_RECORDINGS}; do
    root="${spec%%=*}"
    site="${spec#*=}"
    if [[ -z "${root}" || -z "${site}" || "${root}" == "${spec}" ]]; then
      remapped_recordings+="${spec} "
      continue
    fi
    remapped_recordings+="$(prefer_local_dir "${root}")=${site} "
  done
  EXTRA_RECORDINGS="${remapped_recordings% }"
  unset remapped_recordings spec root site
fi
OUTPUT_DIR="${OUTPUT_DIR:-./output}"
FRAME_INTERVAL="${FRAME_INTERVAL:-1800}"
# 解码、滤镜、编码共用的线程上限。0 会被 ffmpeg 当成自动，等于占满全部核心
FFMPEG_THREADS="${FFMPEG_THREADS:-2}"
# cpu：软件解码。cuda：NVDEC 只解关键帧，再按 FRAME_INTERVAL 换算的时间间隔抽帧。
# cuda 失败或这路编码没有对应解码器时，这一段自动改回 cpu。
FFMPEG_HWACCEL="${FFMPEG_HWACCEL:-cuda}"
FFMPEG_HWACCEL_DEVICE="${FFMPEG_HWACCEL_DEVICE:-0}"
SCAN_INTERVAL="${SCAN_INTERVAL:-20}"
UPLOAD_ENABLED="${UPLOAD_ENABLED:-1}"
UPLOAD_URL="${UPLOAD_URL:-http://aisafety.craner.hk/api/upload}"
UPLOAD_TOKEN="${UPLOAD_TOKEN:-}"
# 与上传 API / 下载窗口对齐；文件名中 HHMMSS 落在窗外则跳过上传并清理本地
UPLOAD_TIME_WINDOWS="${UPLOAD_TIME_WINDOWS:-09:00:00-11:00:00 14:00:00-17:45:00}"
STATE_DIR="${STATE_DIR:-${SCRIPT_DIR}/.state}"
DELETE_VIDEO_AFTER_UPLOAD="${DELETE_VIDEO_AFTER_UPLOAD:-1}"
# 每个日期目录最接近这些时刻的各一段：抽帧后走视频分片上传，成功再删本地文件
KEEP_DAILY_TIMES="${KEEP_DAILY_TIMES:-10:00:00 15:00:00}"
MAX_DATA_BYTES="${MAX_DATA_BYTES:-2147483648}"
# 定点录像上传。地址默认从 UPLOAD_URL 取到主机，再拼 /api/videos
VIDEO_UPLOAD_ENABLED="${VIDEO_UPLOAD_ENABLED:-1}"
VIDEO_CHUNK_BYTES="${VIDEO_CHUNK_BYTES:-1048576}"
# 同一视频抽帧连续失败多少次后跳过，避免一个坏文件反复拖垮整轮
VIDEO_MAX_ATTEMPTS="${VIDEO_MAX_ATTEMPTS:-3}"

if [[ "${OUTPUT_DIR}" != /* ]]; then
  OUTPUT_DIR="${SCRIPT_DIR}/${OUTPUT_DIR}"
fi
if [[ "${STATE_DIR}" != /* ]]; then
  STATE_DIR="${SCRIPT_DIR}/${STATE_DIR}"
fi
if [[ -z "${VIDEO_API_BASE:-}" ]]; then
  _video_rest="${UPLOAD_URL#*://}"
  _video_host="${_video_rest%%/*}"
  _video_scheme="${UPLOAD_URL%%://*}"
  VIDEO_API_BASE="${_video_scheme}://${_video_host}"
  unset _video_rest _video_host _video_scheme
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "未找到 ffmpeg，请先安装 ffmpeg。"
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "未找到 curl，请先安装 curl。"
  exit 1
fi

if [[ ! -d "${RECORDINGS_ROOT}" ]]; then
  echo "录像总根目录不存在: ${RECORDINGS_ROOT}"
  exit 1
fi

if ! [[ "${FRAME_INTERVAL}" =~ ^[0-9]+$ ]] || [[ "${FRAME_INTERVAL}" -le 0 ]]; then
  echo "FRAME_INTERVAL 必须是正整数，当前值: ${FRAME_INTERVAL}"
  exit 1
fi
if ! [[ "${FFMPEG_THREADS}" =~ ^[0-9]+$ ]] || [[ "${FFMPEG_THREADS}" -le 0 ]]; then
  echo "FFMPEG_THREADS 必须是正整数，当前值: ${FFMPEG_THREADS}"
  exit 1
fi
case "${FFMPEG_HWACCEL}" in
  cpu|cuda) ;;
  *)
    echo "FFMPEG_HWACCEL 只能是 cpu 或 cuda，当前值: ${FFMPEG_HWACCEL}"
    exit 1
    ;;
esac
if ! [[ "${FFMPEG_HWACCEL_DEVICE}" =~ ^[0-9]+$ ]]; then
  echo "FFMPEG_HWACCEL_DEVICE 必须是非负整数，当前值: ${FFMPEG_HWACCEL_DEVICE}"
  exit 1
fi
if [[ "${FFMPEG_HWACCEL}" == "cuda" ]]; then
  if ! ffmpeg -hide_banner -hwaccels 2>/dev/null | grep -qx 'cuda'; then
    echo "ffmpeg 没有 cuda 硬件解码，抽帧改用 CPU"
    FFMPEG_HWACCEL=cpu
  elif ! nvidia-smi -L >/dev/null 2>&1; then
    echo "未检测到 NVIDIA GPU，抽帧改用 CPU"
    FFMPEG_HWACCEL=cpu
  fi
fi
if ! [[ "${SCAN_INTERVAL}" =~ ^[0-9]+$ ]] || [[ "${SCAN_INTERVAL}" -le 0 ]]; then
  echo "SCAN_INTERVAL 必须是正整数，当前值: ${SCAN_INTERVAL}"
  exit 1
fi
if [[ "${UPLOAD_ENABLED}" == "1" ]] && [[ -z "${SITE}" ]]; then
  echo "UPLOAD_ENABLED=1 时，SITE 不能为空。请在 config.conf 中设置 SITE。"
  exit 1
fi
if [[ -n "${EXTRA_RECORDINGS}" ]]; then
  for _extra_spec in ${EXTRA_RECORDINGS}; do
    _extra_root="${_extra_spec%%=*}"
    _extra_site="${_extra_spec#*=}"
    if [[ -z "${_extra_root}" || -z "${_extra_site}" || "${_extra_root}" == "${_extra_spec}" ]]; then
      echo "EXTRA_RECORDINGS 格式应为 目录=站点，当前: ${_extra_spec}"
      exit 1
    fi
  done
  unset _extra_spec _extra_root _extra_site
fi
if ! [[ "${MAX_DATA_BYTES}" =~ ^[0-9]+$ ]] || [[ "${MAX_DATA_BYTES}" -le 0 ]]; then
  echo "MAX_DATA_BYTES 必须是正整数，当前值: ${MAX_DATA_BYTES}"
  exit 1
fi
if [[ "${VIDEO_UPLOAD_ENABLED}" != "0" && "${VIDEO_UPLOAD_ENABLED}" != "1" ]]; then
  echo "VIDEO_UPLOAD_ENABLED 只能是 0 或 1，当前值: ${VIDEO_UPLOAD_ENABLED}"
  exit 1
fi
if ! [[ "${VIDEO_CHUNK_BYTES}" =~ ^[0-9]+$ ]] || [[ "${VIDEO_CHUNK_BYTES}" -le 0 ]]; then
  echo "VIDEO_CHUNK_BYTES 必须是正整数，当前值: ${VIDEO_CHUNK_BYTES}"
  exit 1
fi
if [[ "${VIDEO_UPLOAD_ENABLED}" == "1" ]]; then
  if ! command -v python3 >/dev/null 2>&1; then
    echo "视频上传需要 python3。"
    exit 1
  fi
  if ! command -v sha256sum >/dev/null 2>&1; then
    echo "视频上传需要 sha256sum。"
    exit 1
  fi
fi

mkdir -p "${OUTPUT_DIR}" "${STATE_DIR}"

# 单实例：重复启动会同时抽帧、重复上传、重复删除。只在真正运行时加锁，source 时不加。
acquire_extract_lock() {
  local lock_file="${SCRIPT_DIR}/logs/extract.lock"
  mkdir -p "$(dirname "${lock_file}")"
  # 用追加方式打开，避免第二个实例在拿锁失败前把正在运行的 pid 清空
  exec 8>>"${lock_file}"
  if ! flock -n 8; then
    echo "已有抽帧进程在运行 (pid=$(cat "${lock_file}" 2>/dev/null || echo unknown))，本次退出"
    exit 0
  fi
  printf '%s\n' "$$" > "${lock_file}"
}

build_video_stem() {
  local video_path="$1"
  local day_dir="$2"
  local rel_path="${video_path#${day_dir}/}"
  local rel_no_ext="${rel_path%.*}"
  local stem="${rel_no_ext//\//__}"
  stem="${stem// /_}"
  printf '%s' "${stem}"
}

# 从文件名解析 HHMMSS；解析失败返回空。
# 帧名形如 20261106100243-901_t101312.jpg，_t 后面是该帧的真实时刻，优先用它；
# 录像文件名只有开头的 YYYYMMDDHHMMSS，取这一组。
parse_name_hhmmss() {
  local base
  base="$(basename "$1")"
  if [[ "${base}" =~ _t([0-9]{2})([0-9]{2})([0-9]{2})(_[0-9]+)?\.[A-Za-z0-9]+$ ]]; then
    printf '%s%s%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    return 0
  fi
  if [[ "${base}" =~ ^[0-9]{8}([0-9]{2})([0-9]{2})([0-9]{2}) ]]; then
    printf '%s%s%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
  fi
}

# HHMMSS 是否落在 UPLOAD_TIME_WINDOWS（格式 HH:MM:SS-HH:MM:SS）内
is_hhmmss_allowed() {
  local hhmmss="$1"
  local window start_hms end_hms start_cmp end_cmp

  if [[ -z "${hhmmss}" ]]; then
    return 0
  fi
  if [[ -z "${UPLOAD_TIME_WINDOWS}" ]]; then
    return 0
  fi

  for window in ${UPLOAD_TIME_WINDOWS}; do
    if [[ "${window}" != *-* ]]; then
      continue
    fi
    start_hms="${window%%-*}"
    end_hms="${window##*-}"
    start_cmp="${start_hms//:/}"
    end_cmp="${end_hms//:/}"
    # 10# 避免 09xxxx 被当成八进制
    if (( 10#${hhmmss} >= 10#${start_cmp} && 10#${hhmmss} <= 10#${end_cmp} )); then
      return 0
    fi
  done
  return 1
}

hhmmss_to_seconds() {
  local hhmmss="$1"
  printf '%s' $(( 10#${hhmmss:0:2} * 3600 + 10#${hhmmss:2:2} * 60 + 10#${hhmmss:4:2} ))
}

# 10:00 属于上午窗口，15:00 属于下午窗口。窗口外的录像不能当定点视频。
window_for_target() {
  local target_hms="$1"
  local target_cmp window start_hms end_hms start_cmp end_cmp
  target_cmp="${target_hms//:/}"
  for window in ${UPLOAD_TIME_WINDOWS}; do
    if [[ "${window}" != *-* ]]; then
      continue
    fi
    start_hms="${window%%-*}"
    end_hms="${window##*-}"
    start_cmp="${start_hms//:/}"
    end_cmp="${end_hms//:/}"
    if (( 10#${target_cmp} >= 10#${start_cmp} && 10#${target_cmp} <= 10#${end_cmp} )); then
      printf '%s' "${window}"
      return 0
    fi
  done
  return 1
}

# 录像时长（秒）。读不到时返回空串，调用方按开始时间判断。
video_duration_seconds() {
  local video_path="$1"
  local duration
  duration="$(ffprobe -v error -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 -- "${video_path}" 2>/dev/null || true)"
  if [[ "${duration}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    awk -v d="${duration}" 'BEGIN { printf "%.0f", d }'
  fi
}

# 录像覆盖的时间段 [开始, 开始+时长) 是否与某段上传窗口有交集。
# 检索 09:00-11:00 时 NVR 会返回 08:49 开始的片段，整段跳过会丢掉 09:00-09:13 的帧。
video_overlaps_window() {
  local video_path="$1"
  local hhmmss duration video_start video_end window start_hms end_hms start_sec end_sec

  hhmmss="$(parse_name_hhmmss "${video_path}")"
  [[ -n "${hhmmss}" ]] || return 0
  duration="$(video_duration_seconds "${video_path}")"
  # 读不到时长时退回只按开始时间判断，至少不改变旧行为
  if [[ -z "${duration}" ]]; then
    is_hhmmss_allowed "${hhmmss}"
    return $?
  fi

  video_start="$(hhmmss_to_seconds "${hhmmss}")"
  video_end=$((video_start + duration))
  for window in ${UPLOAD_TIME_WINDOWS}; do
    if [[ "${window}" != *-* ]]; then
      continue
    fi
    start_hms="${window%%-*}"
    end_hms="${window##*-}"
    start_sec="$(hhmmss_to_seconds "${start_hms//:/}")"
    end_sec="$(hhmmss_to_seconds "${end_hms//:/}")"
    if (( video_start < end_sec && video_end > start_sec )); then
      return 0
    fi
  done
  return 1
}

# 窗口结束前不上传。否则先到的一段会被当成最接近 10:00/15:00 的录像。
slot_window_ended() {
  local ymd="$1"
  local window="$2"
  local end_hms end_epoch now_epoch
  end_hms="${window##*-}"
  end_epoch="$(date -d "${ymd:0:4}-${ymd:4:2}-${ymd:6:2} ${end_hms}" +%s)"
  now_epoch="$(date +%s)"
  [[ "${now_epoch}" -ge "${end_epoch}" ]]
}

# 同一日期目录里，只在目标时刻所在窗口内选最接近的一段。
pick_kept_daily_video() {
  local day_dir="$1"
  local target_hms="$2"
  local target_raw target_sec best_path best_diff window
  local start_cmp end_cmp video_path hhmmss video_sec diff
  local -a videos

  target_raw="${target_hms}"
  window="$(window_for_target "${target_raw}")" || return 0
  start_cmp="${window%%-*}"
  start_cmp="${start_cmp//:/}"
  end_cmp="${window##*-}"
  end_cmp="${end_cmp//:/}"
  target_hms="${target_hms//:/}"
  target_sec="$(hhmmss_to_seconds "${target_hms}")"
  best_path=""
  best_diff=999999

  shopt -s nullglob
  videos=("${day_dir}/"*.mp4 "${day_dir}/"*.MP4)
  shopt -u nullglob

  for video_path in "${videos[@]}"; do
    hhmmss="$(parse_name_hhmmss "${video_path}")"
    [[ -n "${hhmmss}" ]] || continue
    if (( 10#${hhmmss} < 10#${start_cmp} || 10#${hhmmss} > 10#${end_cmp} )); then
      continue
    fi
    video_sec="$(hhmmss_to_seconds "${hhmmss}")"
    if (( video_sec >= target_sec )); then
      diff=$(( video_sec - target_sec ))
    else
      diff=$(( target_sec - video_sec ))
    fi
    if (( diff < best_diff )); then
      best_diff="${diff}"
      best_path="${video_path}"
    fi
  done

  printf '%s' "${best_path}"
}

is_kept_daily_video() {
  local video_path="$1"
  local day_dir target kept
  day_dir="$(dirname "${video_path}")"
  for target in ${KEEP_DAILY_TIMES}; do
    kept="$(pick_kept_daily_video "${day_dir}" "${target}")"
    if [[ -n "${kept}" && "${kept}" == "${video_path}" ]]; then
      return 0
    fi
  done
  return 1
}

video_slot_done() {
  local relative_day_dir="$1"
  local target="$2"
  local done_file="${STATE_DIR}/${relative_day_dir}.video_done"
  [[ -f "${done_file}" ]] || return 1
  awk -v target="${target}" '$1 == target { found = 1 } END { exit !found }' "${done_file}"
}

mark_video_slot() {
  local relative_day_dir="$1"
  local target="$2"
  local file_name="$3"
  local done_file="${STATE_DIR}/${relative_day_dir}.video_done"
  mkdir -p "$(dirname "${done_file}")"
  if ! video_slot_done "${relative_day_dir}" "${target}"; then
    printf '%s %s\n' "${target}" "${file_name}" >> "${done_file}"
  fi
}

json_field() {
  local file="$1"
  local field="$2"
  python3 - "${file}" "${field}" <<'PY'
import json
import sys

path, field = sys.argv[1], sys.argv[2]
try:
    with open(path, encoding="utf-8") as handle:
        data = json.load(handle)
except Exception:
    sys.exit(2)

if field == "missing":
    received = set(data.get("received_chunks") or [])
    missing = data.get("missing_chunks")
    total = data.get("total_chunks")
    if missing is None and total is not None:
        missing = [index for index in range(int(total)) if index not in received]
    if not missing:
        print("")
    else:
        print(" ".join(str(index) for index in missing))
    sys.exit(0)

cur = data
for part in field.split("."):
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        cur = ""
        break
if cur is None:
    print("")
elif isinstance(cur, (list, dict)):
    print(json.dumps(cur, ensure_ascii=False))
else:
    print(cur)
PY
}

video_curl() {
  local method="$1"
  local url="$2"
  local body_out="$3"
  shift 3
  local -a args=(
    -sS
    --retry 2
    --retry-delay 2
    --connect-timeout 20
    --max-time 180
    -X "${method}"
    "${url}"
    -o "${body_out}"
    -w "%{http_code}"
  )
  if [[ -n "${UPLOAD_TOKEN}" ]]; then
    args+=(-H "Authorization: Bearer ${UPLOAD_TOKEN}")
  fi
  curl "${args[@]}" "$@" || true
}

video_init_upload() {
  local site="$1"
  local file_name="$2"
  local file_size="$3"
  local chunk_size="$4"
  local date_value="$5"
  local sha="$6"
  local body_file resp_file http_code
  body_file="$(mktemp)"
  resp_file="$(mktemp)"
  SITE="${site}" FILE_NAME="${file_name}" FILE_SIZE="${file_size}" \
    CHUNK_SIZE="${chunk_size}" DATE_VALUE="${date_value}" SHA256="${sha}" \
    python3 - "${body_file}" <<'PY'
import json
import os
import sys

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(
        {
            "site": os.environ["SITE"],
            "file_name": os.environ["FILE_NAME"],
            "file_size": int(os.environ["FILE_SIZE"]),
            "chunk_size": int(os.environ["CHUNK_SIZE"]),
            "date": os.environ["DATE_VALUE"],
            "sha256": os.environ["SHA256"],
        },
        handle,
    )
PY
  http_code="$(video_curl POST "${VIDEO_API_BASE}/api/videos/init" "${resp_file}" \
    -H "Content-Type: application/json" \
    --data-binary @"${body_file}")"
  rm -f -- "${body_file}"
  VIDEO_HTTP_CODE="${http_code}"
  if [[ "${http_code}" != "200" && "${http_code}" != "201" ]]; then
    echo "视频上传初始化失败 (HTTP ${http_code}): ${file_name}"
    if [[ -s "${resp_file}" ]]; then
      echo "  响应: $(head -c 400 "${resp_file}")"
    fi
    rm -f -- "${resp_file}"
    return 1
  fi
  VIDEO_UPLOAD_ID="$(json_field "${resp_file}" upload_id || true)"
  VIDEO_SERVER_CHUNK="$(json_field "${resp_file}" chunk_size || true)"
  rm -f -- "${resp_file}"
  if [[ -z "${VIDEO_UPLOAD_ID}" ]]; then
    echo "视频上传初始化没有返回 upload_id: ${file_name}"
    return 1
  fi
  if [[ "${VIDEO_SERVER_CHUNK}" =~ ^[0-9]+$ ]] && [[ "${VIDEO_SERVER_CHUNK}" -gt 0 ]]; then
    VIDEO_ACTIVE_CHUNK="${VIDEO_SERVER_CHUNK}"
  fi
  return 0
}

video_query_progress() {
  local upload_id="$1"
  local resp_file http_code
  resp_file="$(mktemp)"
  http_code="$(video_curl GET "${VIDEO_API_BASE}/api/videos/upload/${upload_id}" "${resp_file}")"
  VIDEO_HTTP_CODE="${http_code}"
  VIDEO_STATUS=""
  VIDEO_MISSING=""
  if [[ "${http_code}" == "404" || "${http_code}" == "410" ]]; then
    rm -f -- "${resp_file}"
    return 2
  fi
  if [[ "${http_code}" != "200" ]]; then
    echo "查询视频上传进度失败 (HTTP ${http_code}): ${upload_id}"
    if [[ -s "${resp_file}" ]]; then
      echo "  响应: $(head -c 400 "${resp_file}")"
    fi
    rm -f -- "${resp_file}"
    return 1
  fi
  VIDEO_STATUS="$(json_field "${resp_file}" status || true)"
  VIDEO_MISSING="$(json_field "${resp_file}" missing || true)"
  VIDEO_SERVER_CHUNK="$(json_field "${resp_file}" chunk_size || true)"
  rm -f -- "${resp_file}"
  if [[ "${VIDEO_SERVER_CHUNK}" =~ ^[0-9]+$ ]] && [[ "${VIDEO_SERVER_CHUNK}" -gt 0 ]]; then
    VIDEO_ACTIVE_CHUNK="${VIDEO_SERVER_CHUNK}"
  fi
  return 0
}

video_send_chunk() {
  local video_path="$1"
  local upload_id="$2"
  local index="$3"
  local chunk_size="$4"
  local file_size="$5"
  local offset length tmp_file resp_file http_code
  offset=$((index * chunk_size))
  if (( offset >= file_size )); then
    echo "分片序号越界: ${index}"
    return 1
  fi
  length=$((file_size - offset))
  if (( length > chunk_size )); then
    length="${chunk_size}"
  fi
  tmp_file="$(mktemp)"
  resp_file="$(mktemp)"
  dd if="${video_path}" of="${tmp_file}" bs="${chunk_size}" \
    iflag=skip_bytes,count_bytes skip="${offset}" count="${length}" status=none
  http_code="$(video_curl PUT "${VIDEO_API_BASE}/api/videos/upload/${upload_id}" "${resp_file}" \
    -H "Content-Type: application/octet-stream" \
    -H "X-Chunk-Index: ${index}" \
    -H "X-Chunk-Size: ${length}" \
    --data-binary @"${tmp_file}")"
  rm -f -- "${tmp_file}"
  if [[ "${http_code}" != "200" ]]; then
    echo "分片上传失败 (HTTP ${http_code}) index=${index}: $(basename "${video_path}")"
    if [[ -s "${resp_file}" ]]; then
      echo "  响应: $(head -c 400 "${resp_file}")"
    fi
    rm -f -- "${resp_file}"
    return 1
  fi
  rm -f -- "${resp_file}"
  return 0
}

video_complete_upload() {
  local upload_id="$1"
  local sha="$2"
  local body_file resp_file http_code
  body_file="$(mktemp)"
  resp_file="$(mktemp)"
  SHA256="${sha}" python3 - "${body_file}" <<'PY'
import json
import os
import sys

with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({"sha256": os.environ["SHA256"]}, handle)
PY
  http_code="$(video_curl POST "${VIDEO_API_BASE}/api/videos/complete/${upload_id}" "${resp_file}" \
    -H "Content-Type: application/json" \
    --data-binary @"${body_file}")"
  rm -f -- "${body_file}"
  VIDEO_HTTP_CODE="${http_code}"
  VIDEO_MISSING=""
  if [[ "${http_code}" == "409" ]]; then
    VIDEO_MISSING="$(json_field "${resp_file}" missing || true)"
    rm -f -- "${resp_file}"
    return 2
  fi
  if [[ "${http_code}" != "200" && "${http_code}" != "201" ]]; then
    echo "完成视频上传失败 (HTTP ${http_code}): ${upload_id}"
    if [[ -s "${resp_file}" ]]; then
      echo "  响应: $(head -c 400 "${resp_file}")"
    fi
    rm -f -- "${resp_file}"
    return 1
  fi
  rm -f -- "${resp_file}"
  return 0
}

save_video_session() {
  local session_file="$1"
  local upload_id="$2"
  local sha="$3"
  local file_size="$4"
  local chunk_size="$5"
  local file_name="$6"
  mkdir -p "$(dirname "${session_file}")"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "${upload_id}" "${sha}" "${file_size}" "${chunk_size}" "${file_name}" > "${session_file}"
}

# 上传一个定点录像。成功返回 0，失败返回 1，调用方决定是否删除本地文件。
upload_video_file() {
  local video_path="$1"
  local date_value="$2"
  local site="$3"
  local relative_day_dir="$4"
  local file_name file_size sha session_file upload_id chunk_size
  local saved_id saved_sha saved_size saved_chunk saved_name
  local index total missing_round

  [[ -f "${video_path}" ]] || return 1
  file_name="$(basename "${video_path}")"
  file_size="$(stat -c%s -- "${video_path}")"
  sha="$(sha256sum -- "${video_path}" | awk '{print $1}')"
  session_file="${STATE_DIR}/${relative_day_dir}.video_session"
  chunk_size="${VIDEO_CHUNK_BYTES}"
  upload_id=""
  VIDEO_ACTIVE_CHUNK="${chunk_size}"

  if [[ -f "${session_file}" ]]; then
    IFS=$'\t' read -r saved_id saved_sha saved_size saved_chunk saved_name < "${session_file}" || true
    if [[ "${saved_name}" == "${file_name}" && "${saved_sha}" == "${sha}" && "${saved_size}" == "${file_size}" && "${saved_id}" != "" ]]; then
      upload_id="${saved_id}"
      if [[ "${saved_chunk}" =~ ^[0-9]+$ ]] && [[ "${saved_chunk}" -gt 0 ]]; then
        chunk_size="${saved_chunk}"
        VIDEO_ACTIVE_CHUNK="${chunk_size}"
      fi
    fi
  fi

  if [[ -n "${upload_id}" ]]; then
    echo "恢复定点录像上传: ${file_name} (${upload_id})"
    if ! video_query_progress "${upload_id}"; then
      if [[ "${VIDEO_HTTP_CODE}" == "404" || "${VIDEO_HTTP_CODE}" == "410" ]]; then
        echo "上传会话已失效，重新初始化: ${file_name}"
        upload_id=""
      else
        return 1
      fi
    elif [[ "${VIDEO_STATUS}" == "completed" ]]; then
      rm -f -- "${session_file}"
      return 0
    elif [[ "${VIDEO_STATUS}" == "expired" ]]; then
      local expired_body
      expired_body="$(mktemp)"
      video_curl DELETE "${VIDEO_API_BASE}/api/videos/upload/${upload_id}" "${expired_body}" >/dev/null || true
      rm -f -- "${expired_body}"
      upload_id=""
    fi
  fi

  if [[ -z "${upload_id}" ]]; then
    echo "初始化定点录像上传: ${file_name} (${file_size} 字节)"
    VIDEO_ACTIVE_CHUNK="${VIDEO_CHUNK_BYTES}"
    if ! video_init_upload "${site}" "${file_name}" "${file_size}" "${VIDEO_ACTIVE_CHUNK}" "${date_value}" "${sha}"; then
      return 1
    fi
    upload_id="${VIDEO_UPLOAD_ID}"
    chunk_size="${VIDEO_ACTIVE_CHUNK}"
    save_video_session "${session_file}" "${upload_id}" "${sha}" "${file_size}" "${chunk_size}" "${file_name}"
    if ! video_query_progress "${upload_id}"; then
      return 1
    fi
    if [[ "${VIDEO_STATUS}" == "completed" ]]; then
      rm -f -- "${session_file}"
      return 0
    fi
  fi

  chunk_size="${VIDEO_ACTIVE_CHUNK}"
  save_video_session "${session_file}" "${upload_id}" "${sha}" "${file_size}" "${chunk_size}" "${file_name}"
  total=$(((file_size + chunk_size - 1) / chunk_size))

  for missing_round in 1 2; do
    if [[ "${VIDEO_STATUS}" == "ready_to_complete" || -z "${VIDEO_MISSING}" ]]; then
      break
    fi
    for index in ${VIDEO_MISSING}; do
      if ! [[ "${index}" =~ ^[0-9]+$ ]]; then
        echo "忽略无效分片序号: ${index}"
        continue
      fi
      echo "上传分片 $((index + 1))/${total} ${file_name}"
      if ! video_send_chunk "${video_path}" "${upload_id}" "${index}" "${chunk_size}" "${file_size}"; then
        return 1
      fi
    done
    if ! video_query_progress "${upload_id}"; then
      return 1
    fi
    if [[ "${VIDEO_STATUS}" == "completed" ]]; then
      rm -f -- "${session_file}"
      return 0
    fi
  done

  if ! video_complete_upload "${upload_id}" "${sha}"; then
    if [[ "${VIDEO_HTTP_CODE}" == "409" && -n "${VIDEO_MISSING}" ]]; then
      for index in ${VIDEO_MISSING}; do
        echo "补传缺失分片 ${index} ${file_name}"
        if ! video_send_chunk "${video_path}" "${upload_id}" "${index}" "${chunk_size}" "${file_size}"; then
          return 1
        fi
      done
      if ! video_complete_upload "${upload_id}" "${sha}"; then
        return 1
      fi
    else
      return 1
    fi
  fi
  rm -f -- "${session_file}"
  return 0
}

# 定点录像上传成功后删除。该时段已经传过的后续文件只删本地，不再上传。
upload_and_remove_kept_video() {
  local video_path="$1"
  local day_dir="$2"
  local site="$3"
  local relative_day_dir="$4"
  local date_value target kept file_name
  local -a pending=()

  date_value="$(basename "${day_dir}")"
  file_name="$(basename "${video_path}")"
  local waiting=0 window
  for target in ${KEEP_DAILY_TIMES}; do
    kept="$(pick_kept_daily_video "${day_dir}" "${target}")"
    if [[ -z "${kept}" || "${kept}" != "${video_path}" ]]; then
      continue
    fi
    if video_slot_done "${relative_day_dir}" "${target}"; then
      continue
    fi
    window="$(window_for_target "${target}" || true)"
    if [[ -z "${window}" ]] || ! slot_window_ended "${date_value}" "${window}"; then
      echo "时间窗口未结束，暂不上传定点录像: ${file_name} ${target}"
      waiting=1
      continue
    fi
    pending+=("${target}")
  done

  if [[ "${#pending[@]}" -eq 0 ]]; then
    if [[ "${waiting}" -eq 1 ]]; then
      return 0
    fi
    if rm -f -- "${video_path}"; then
      echo "该时段定点录像已上传，删除本地文件: ${video_path}"
    fi
    return 0
  fi

  echo "开始上传定点录像: ${file_name} site=${site} date=${date_value}"
  if ! upload_video_file "${video_path}" "${date_value}" "${site}" "${relative_day_dir}"; then
    echo "定点录像上传失败，保留本地文件，下轮重试: ${video_path}"
    return 0
  fi
  for target in "${pending[@]}"; do
    mark_video_slot "${relative_day_dir}" "${target}" "${file_name}"
  done
  if rm -f -- "${video_path}"; then
    echo "定点录像已上传并删除: ${video_path}"
  else
    echo "定点录像已上传，但删除本地文件失败: ${video_path}"
  fi
  return 0
}

mark_uploaded_and_remove() {
  local frame_path="$1"
  local uploaded_state_file="$2"
  if ! grep -Fxq -- "${frame_path}" "${uploaded_state_file}"; then
    printf '%s\n' "${frame_path}" >> "${uploaded_state_file}"
  fi
  rm -f -- "${frame_path}" || true
}

upload_frame() {
  local frame_path="$1"
  local uploaded_state_file="$2"
  local date_value="$3"
  local site="${4:-${SITE}}"
  local ext_lower
  local file_size
  local hhmmss
  local http_code
  local resp_body
  local resp_file

  if [[ "${UPLOAD_ENABLED}" != "1" ]]; then
    return 0
  fi

  # 已成功上传过但本地又出现同路径文件（重复抽帧）时，直接清掉残留
  if grep -Fxq -- "${frame_path}" "${uploaded_state_file}"; then
    if [[ -f "${frame_path}" ]]; then
      rm -f -- "${frame_path}" || true
      echo "已上传记录存在，清理本地残留: $(basename "${frame_path}")"
    fi
    return 0
  fi

  ext_lower="${frame_path##*.}"
  ext_lower="${ext_lower,,}"
  case "${ext_lower}" in
    jpg|jpeg|png|gif|webp) ;;
    *)
      echo "跳过不支持的图片格式: ${frame_path}"
      mark_uploaded_and_remove "${frame_path}" "${uploaded_state_file}"
      return 0
      ;;
  esac

  hhmmss="$(parse_name_hhmmss "${frame_path}")"
  if [[ -n "${hhmmss}" ]] && ! is_hhmmss_allowed "${hhmmss}"; then
    echo "跳过上传时间窗外的帧 (${hhmmss}): $(basename "${frame_path}")"
    mark_uploaded_and_remove "${frame_path}" "${uploaded_state_file}"
    return 0
  fi

  if ! file_size="$(stat -c%s -- "${frame_path}")"; then
    echo "读取文件大小失败，跳过: ${frame_path}"
    return 0
  fi
  if [[ "${file_size}" -gt 10485760 ]]; then
    echo "跳过超过 10MB 的文件: ${frame_path}"
    mark_uploaded_and_remove "${frame_path}" "${uploaded_state_file}"
    return 0
  fi

  resp_file="$(mktemp)"
  local -a curl_args=(
    -sS
    --retry 2
    --retry-delay 1
    -X POST
    "${UPLOAD_URL}"
    -F "site=${site}"
    -F "date=${date_value}"
    -F "file=@${frame_path}"
    -o "${resp_file}"
    -w "%{http_code}"
  )

  if [[ -n "${UPLOAD_TOKEN}" ]]; then
    curl_args+=(-H "Authorization: Bearer ${UPLOAD_TOKEN}")
  fi

  http_code="$(curl "${curl_args[@]}" || true)"
  resp_body="$(cat "${resp_file}" 2>/dev/null || true)"
  rm -f -- "${resp_file}"

  if [[ "${http_code}" == "200" || "${http_code}" == "201" ]]; then
    mark_uploaded_and_remove "${frame_path}" "${uploaded_state_file}"
    echo "已上传并删除本地文件: $(basename "${frame_path}")"
  else
    echo "上传失败 (HTTP ${http_code}): ${frame_path}"
    if [[ -n "${resp_body}" ]]; then
      echo "  响应: ${resp_body}"
    fi
    # 永久拒绝：时间窗外，记入已处理并删本地，避免反复重试
    if [[ "${resp_body}" == *"UPLOAD_TIME_NOT_ALLOWED"* ]]; then
      echo "  判定为时间窗外，清理本地残留"
      mark_uploaded_and_remove "${frame_path}" "${uploaded_state_file}"
      return 0
    fi
    return 1
  fi
}

# 第一行编码名，第二行帧率（如 25/1）。读不到时两行都可能为空。
video_stream_info() {
  local video_path="$1"
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name,avg_frame_rate \
    -of default=noprint_wrappers=1:nokey=1 -- "${video_path}" 2>/dev/null || true
}

cuvid_decoder_for() {
  case "$1" in
    hevc|h265) printf '%s' hevc_cuvid ;;
    h264) printf '%s' h264_cuvid ;;
    mpeg2video) printf '%s' mpeg2_cuvid ;;
    mpeg4) printf '%s' mpeg4_cuvid ;;
    mjpeg) printf '%s' mjpeg_cuvid ;;
    vp8) printf '%s' vp8_cuvid ;;
    vp9) printf '%s' vp9_cuvid ;;
    av1) printf '%s' av1_cuvid ;;
    *) return 1 ;;
  esac
}

# FRAME_INTERVAL 是帧数。GPU 只输出关键帧，n 不再是原始帧号，所以改用时间间隔。
frame_interval_seconds() {
  local rate="$1"
  awk -v n="${FRAME_INTERVAL}" -v r="${rate}" 'BEGIN {
    split(r, a, "/")
    den = (a[2] == "" || a[2] + 0 == 0) ? 1 : a[2]
    fps = a[1] / den
    if (fps <= 0) fps = 25
    printf "%.6f", n / fps
  }'
}

extract_frames_cpu() {
  local video_path="$1"
  local tmp_dir="$2"
  local log_file="$3"
  ffmpeg -hide_banner -nostdin -loglevel info -y \
    -threads "${FFMPEG_THREADS}" \
    -filter_threads "${FFMPEG_THREADS}" \
    -i "${video_path}" \
    -vf "select='eq(n\\,0)+eq(pict_type\\,I)*gte(n-prev_selected_n\\,${FRAME_INTERVAL})',showinfo" \
    -threads "${FFMPEG_THREADS}" \
    -vsync vfr \
    "${tmp_dir}/frame_%06d.jpg" 2>"${log_file}"
}

# NVDEC 解关键帧。hevc_cuvid 不会填写 pict_type，也不能用 key 标志，所以用 -skip_frame nokey。
extract_frames_gpu() {
  local video_path="$1"
  local tmp_dir="$2"
  local log_file="$3"
  local decoder="$4"
  local interval="$5"
  ffmpeg -hide_banner -nostdin -loglevel info -y \
    -hwaccel cuda \
    -hwaccel_device "${FFMPEG_HWACCEL_DEVICE}" \
    -hwaccel_output_format cuda \
    -c:v "${decoder}" \
    -skip_frame nokey \
    -threads "${FFMPEG_THREADS}" \
    -i "${video_path}" \
    -vf "hwdownload,format=nv12,select='eq(n\\,0)+gte(t-prev_selected_t\\,${interval})',showinfo" \
    -filter_threads "${FFMPEG_THREADS}" \
    -threads "${FFMPEG_THREADS}" \
    -vsync vfr \
    "${tmp_dir}/frame_%06d.jpg" 2>"${log_file}"
}

process_video() {
  local video_path="$1"
  local day_dir="$2"
  local day_output_dir="$3"

  local video_name video_stem extracted_count
  local -a frames
  local -a pts_list
  local hhmmss duration start_sec
  local tmp_dir log_file jpg rel_sec frame_hms target idx=0

  video_name="$(basename "${video_path}")"
  hhmmss="$(parse_name_hhmmss "${video_name}")"
  duration="$(video_duration_seconds "${video_path}")"

  # 整段都在窗外才跳过。与窗口有交集的片段照样抽帧，
  # 由 upload_frame 按每张帧的真实时刻过滤，避免丢掉窗口开头。
  if [[ -n "${hhmmss}" ]] && ! video_overlaps_window "${video_path}"; then
    echo "跳过时间窗外视频 (${hhmmss}${duration:+，时长${duration}s}): ${video_name}"
    return 0
  fi

  video_stem="$(build_video_stem "${video_path}" "${day_dir}")"

  local codec rate decoder interval extracted=0
  local -a stream_info
  mapfile -t stream_info < <(video_stream_info "${video_path}")
  codec="${stream_info[0]:-}"
  rate="${stream_info[1]:-}"
  decoder=""
  if [[ "${FFMPEG_HWACCEL}" == "cuda" ]]; then
    decoder="$(cuvid_decoder_for "${codec}" || true)"
  fi

  if [[ -n "${decoder}" ]]; then
    echo "处理新视频: ${video_name} (cuda:${FFMPEG_HWACCEL_DEVICE} ${decoder})"
  else
    echo "处理新视频: ${video_name} (cpu)"
  fi

  # 先写临时目录，拿到每张帧的 pts_time 后再按真实时刻改名，
  # 否则同一片段内 20 张帧会共用片段开始时间，窗口判定全是错的。
  tmp_dir="$(mktemp -d)"
  log_file="${tmp_dir}/showinfo.log"
  if [[ -n "${decoder}" ]]; then
    interval="$(frame_interval_seconds "${rate}")"
    if extract_frames_gpu "${video_path}" "${tmp_dir}" "${log_file}" "${decoder}" "${interval}"; then
      extracted=1
    else
      echo "GPU 抽帧失败，改用 CPU: ${video_name}"
      rm -f -- "${tmp_dir}"/frame_*.jpg "${log_file}"
    fi
  fi
  if [[ "${extracted}" -eq 0 ]]; then
    if ! extract_frames_cpu "${video_path}" "${tmp_dir}" "${log_file}"; then
      echo "抽帧失败: ${video_name}"
      rm -rf -- "${tmp_dir}"
      return 1
    fi
  fi

  mapfile -t pts_list < <(
    grep -o 'pts_time:[0-9][0-9.]*' "${log_file}" | cut -d: -f2
  )
  start_sec="$(hhmmss_to_seconds "${hhmmss:-000000}")"

  shopt -s nullglob
  frames=("${tmp_dir}/frame_"*.jpg)
  shopt -u nullglob
  if [[ "${#frames[@]}" -eq 0 ]]; then
    echo "抽帧无输出: ${video_name}"
    rm -rf -- "${tmp_dir}"
    return 1
  fi

  for jpg in "${frames[@]}"; do
    rel_sec="${pts_list[${idx}]:-}"
    if [[ "${rel_sec}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      rel_sec="$(awk -v p="${rel_sec}" 'BEGIN { printf "%d", p }')"
    else
      # showinfo 行缺失时退回按帧间距估算
      rel_sec=$((idx * FRAME_INTERVAL))
    fi
    rel_sec=$(((start_sec + rel_sec) % 86400))
    printf -v frame_hms '%02d%02d%02d' \
      $((rel_sec / 3600)) $(((rel_sec % 3600) / 60)) $((rel_sec % 60))
    target="${day_output_dir}/${video_stem}_t${frame_hms}.jpg"
    if [[ -e "${target}" ]]; then
      target="${day_output_dir}/${video_stem}_t${frame_hms}_${idx}.jpg"
    fi
    mv -f -- "${jpg}" "${target}"
    idx=$((idx + 1))
  done
  rm -rf -- "${tmp_dir}"

  shopt -s nullglob
  frames=("${day_output_dir}/${video_stem}_"*.jpg)
  shopt -u nullglob

  extracted_count="${#frames[@]}"
  echo "抽帧完成: ${video_name}，输出 ${extracted_count} 张"
}

# 同一文件失败多次后不再重试，避免反复拖垮整轮扫描。
video_failure_count() {
  local state_file="$1"
  local video_path="$2"
  [[ -f "${state_file}" ]] || return 0
  awk -F'\t' -v p="${video_path}" '$1 == p { print $2 }' "${state_file}" | tail -1
}

record_video_failure() {
  local state_file="$1"
  local video_path="$2"
  local count
  count="$(video_failure_count "${state_file}" "${video_path}")"
  count="${count:-0}"
  count=$((count + 1))
  printf '%s\t%s\n' "${video_path}" "${count}" >> "${state_file}"
  [[ "${count}" -lt "${VIDEO_MAX_ATTEMPTS}" ]]
}

upload_unuploaded_frames() {
  local day_output_dir="$1"
  local uploaded_state_file="$2"
  local date_value="$3"
  local site="${4:-${SITE}}"
  local frame_path
  local -a frames

  shopt -s nullglob
  frames=("${day_output_dir}/"*.jpg)
  shopt -u nullglob

  if [[ "${#frames[@]}" -eq 0 ]]; then
    return 0
  fi

  for frame_path in "${frames[@]}"; do
    upload_frame "${frame_path}" "${uploaded_state_file}" "${date_value}" "${site}" || true
  done
}

# 下载进程写入 logs/active_download_dir：第一行 hikload 子进程 pid，第二行下载脚本 pid，
# 第三行正在落盘的日期目录。父脚本被杀后 hikload 可能还在写，所以两行都要看。
pid_is_hik_download() {
  local pid="$1"
  local cmd
  [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
  [[ -d "/proc/${pid}" ]] || return 1
  cmd="$(tr '\0' ' ' < "/proc/${pid}/cmdline" 2>/dev/null || true)"
  [[ "${cmd}" == *"hikload"* || "${cmd}" == *"hik_download.sh"* ]]
}

active_download_dir() {
  local stamp="${HIK_ROOT}/logs/active_download_dir"
  local child_pid parent_pid dir
  [[ -n "${HIK_ROOT}" && -f "${stamp}" ]] || return 1
  {
    IFS= read -r child_pid || true
    IFS= read -r parent_pid || true
    IFS= read -r dir || true
  } < "${stamp}"
  [[ -n "${dir}" ]] || return 1
  if pid_is_hik_download "${child_pid}" || pid_is_hik_download "${parent_pid}"; then
    printf '%s' "${dir}"
    return 0
  fi
  return 1
}

download_dir_is_active() {
  local path="$1"
  local active
  active="$(active_download_dir)" || return 1
  [[ "${path}" == "${active}" || "${path}" == "${active}/"* ]]
}

# 某视频对应帧全部上传完毕（本地无残留 jpg）时，删除原 mp4。
maybe_delete_video_after_upload() {
  local video_path="$1"
  local day_dir="$2"
  local day_output_dir="$3"
  local site="${4:-${SITE}}"
  local relative_day_dir="${5:-$(basename "${day_dir}")}"
  local video_stem
  local -a remaining_frames

  if [[ "${DELETE_VIDEO_AFTER_UPLOAD}" != "1" ]]; then
    return 0
  fi
  if [[ "${UPLOAD_ENABLED}" != "1" ]]; then
    return 0
  fi
  if [[ ! -f "${video_path}" ]]; then
    return 0
  fi
  if download_dir_is_active "${day_dir}"; then
    echo "日期正在下载，暂不删除: ${video_path}"
    return 0
  fi

  video_stem="$(build_video_stem "${video_path}" "${day_dir}")"
  shopt -s nullglob
  remaining_frames=("${day_output_dir}/${video_stem}_"*.jpg)
  shopt -u nullglob

  if [[ "${#remaining_frames[@]}" -gt 0 ]]; then
    return 0
  fi

  # 定点录像留到本日期目录删完其他视频之后再上传。
  if is_kept_daily_video "${video_path}"; then
    echo "留下定点录像: ${video_path}"
    return 0
  fi

  if rm -f -- "${video_path}"; then
    echo "已上传完毕，删除原视频: ${video_path}"
  else
    echo "删除原视频失败: ${video_path}"
  fi
}

cleanup_processed_videos_for_day() {
  local day_dir="$1"
  local day_output_dir="$2"
  local processed_state_file="$3"
  local site="${4:-${SITE}}"
  local relative_day_dir="${5:-$(basename "${day_dir}")}"
  local video_path

  if [[ "${DELETE_VIDEO_AFTER_UPLOAD}" != "1" ]]; then
    return 0
  fi
  if [[ ! -f "${processed_state_file}" ]]; then
    return 0
  fi

  while IFS= read -r video_path; do
    [[ -z "${video_path}" || "${video_path}" == "__ALL_PROCESSED__" ]] && continue
    [[ -f "${video_path}" ]] || continue
    maybe_delete_video_after_upload "${video_path}" "${day_dir}" "${day_output_dir}" "${site}" "${relative_day_dir}"
  done < "${processed_state_file}"
}

# 图片上传并删掉不保留的原片之后，再上传目录里剩下的定点录像。
upload_remaining_kept_videos() {
  local day_dir="$1"
  local day_output_dir="$2"
  local site="$3"
  local relative_day_dir="$4"
  local video_path video_stem
  local -a mp4_files
  local -a remaining_frames

  if [[ "${VIDEO_UPLOAD_ENABLED}" != "1" || "${UPLOAD_ENABLED}" != "1" || "${DELETE_VIDEO_AFTER_UPLOAD}" != "1" ]]; then
    return 0
  fi
  if [[ ! -d "${day_dir}" ]]; then
    return 0
  fi

  mapfile -d '' mp4_files < <(find "${day_dir}" -type f -iname "*.mp4" -print0)
  for video_path in "${mp4_files[@]+"${mp4_files[@]}"}"; do
    [[ -f "${video_path}" ]] || continue
    if ! is_kept_daily_video "${video_path}"; then
      continue
    fi
    video_stem="$(build_video_stem "${video_path}" "${day_dir}")"
    shopt -s nullglob
    remaining_frames=("${day_output_dir}/${video_stem}_"*.jpg)
    shopt -u nullglob
    if [[ "${#remaining_frames[@]}" -gt 0 ]]; then
      echo "定点录像的图片还在，暂不上传视频: ${video_path}"
      continue
    fi
    upload_and_remove_kept_video "${video_path}" "${day_dir}" "${site}" "${relative_day_dir}"
  done
}

dir_size_bytes() {
  local target="$1"
  local size
  size="$(du -sb -- "${target}" 2>/dev/null | awk '{print $1}')"
  printf '%s' "${size:-0}"
}

# 超限时按 mtime 从旧到新删除已处理的 mp4，并清理空日期目录。
enforce_data_quota() {
  local recordings_root="$1"
  local name_prefix="${2:-}"
  local total_size
  local video_path
  local day_dir
  local relative_day_dir
  local processed_state_file
  local root_name
  local removed=0
  local last_note=0 now_epoch
  local quota_note_file="${STATE_DIR}/quota_note_$(basename "${recordings_root}")"
  local -a candidates

  if [[ ! -d "${recordings_root}" ]]; then
    return 0
  fi

  root_name="$(basename "${recordings_root}")"
  total_size="$(dir_size_bytes "${recordings_root}")"
  if [[ "${total_size}" -le "${MAX_DATA_BYTES}" ]]; then
    return 0
  fi

  mapfile -d '' candidates < <(
    find "${recordings_root}" -type f -iname "*.mp4" -printf '%T@\t%p\0' \
      | sort -z -n \
      | cut -z -f2-
  )

  for video_path in "${candidates[@]}"; do
    total_size="$(dir_size_bytes "${recordings_root}")"
    if [[ "${total_size}" -le "${MAX_DATA_BYTES}" ]]; then
      break
    fi

    day_dir="$(dirname "${video_path}")"
    relative_day_dir="${day_dir#${recordings_root}/}"
    if [[ -n "${name_prefix}" ]]; then
      relative_day_dir="${name_prefix}/${relative_day_dir}"
    fi
    # 仅删除位于 YYYYMMDD 日期目录下的文件
    if [[ ! "$(basename "${day_dir}")" =~ ^[0-9]{8}$ ]]; then
      continue
    fi
    processed_state_file="${STATE_DIR}/${relative_day_dir}.processed"
    if [[ ! -f "${processed_state_file}" ]]; then
      continue
    fi
    if ! grep -Fxq -- "${video_path}" "${processed_state_file}"; then
      continue
    fi
    if is_kept_daily_video "${video_path}"; then
      continue
    fi
    if download_dir_is_active "${day_dir}"; then
      continue
    fi

    if rm -f -- "${video_path}"; then
      removed=$((removed + 1))
      echo "配额清理，删除已处理视频: ${video_path}"
    else
      echo "配额清理失败: ${video_path}"
    fi
  done

  # 清理空日期目录
  local -a empty_day_dirs=()
  local day
  mapfile -d '' empty_day_dirs < <(
    find "${recordings_root}" -mindepth 1 -maxdepth 1 -type d -print0
  )
  for day_dir in "${empty_day_dirs[@]+"${empty_day_dirs[@]}"}"; do
    day="$(basename "${day_dir}")"
    if [[ ! "${day}" =~ ^[0-9]{8}$ ]]; then
      continue
    fi
    if download_dir_is_active "${day_dir}"; then
      continue
    fi
    if [[ -z "$(find "${day_dir}" -type f -print -quit)" ]]; then
      rmdir --ignore-fail-on-non-empty -- "${day_dir}" 2>/dev/null || true
      echo "已清理空日期目录: ${day_dir}"
    fi
  done

  total_size="$(dir_size_bytes "${recordings_root}")"
  # 只剩定点录像时每轮都会超限且无文件可删，日志不要每 20 秒刷一遍。
  if [[ "${removed}" -gt 0 ]]; then
    echo "配额清理后 ${root_name} 用量: ${total_size} 字节"
    rm -f -- "${quota_note_file}"
  else
    now_epoch="$(date +%s)"
    if [[ -f "${quota_note_file}" ]]; then
      last_note="$(cat "${quota_note_file}" 2>/dev/null || echo 0)"
    fi
    if ! [[ "${last_note}" =~ ^[0-9]+$ ]]; then
      last_note=0
    fi
    if (( now_epoch - last_note >= 3600 )); then
      echo "${root_name} 用量 ${total_size} 字节，超过上限 ${MAX_DATA_BYTES}，但没有可删的已处理视频（剩余多为定点录像）"
      printf '%s\n' "${now_epoch}" > "${quota_note_file}"
    fi
  fi
}

process_day() {
  local day_dir="$1"
  local recordings_root="${2:-${RECORDINGS_ROOT}}"
  local site="${3:-${SITE}}"
  local name_prefix="${4:-}"
  local day
  local relative_day_dir
  local day_output_dir
  local processed_state_file
  local uploaded_state_file
  local legacy_processed_state_file
  local processed_path
  local video_path
  local video_failure_file
  local -a mp4_files

  day="$(basename "${day_dir}")"
  if download_dir_is_active "${day_dir}"; then
    echo "该日期正在下载，本轮跳过切帧和删除: ${day_dir}"
    return 0
  fi
  relative_day_dir="${day_dir#${recordings_root}/}"
  if [[ -n "${name_prefix}" ]]; then
    relative_day_dir="${name_prefix}/${relative_day_dir}"
  fi
  day_output_dir="${OUTPUT_DIR}/${relative_day_dir}"
  processed_state_file="${STATE_DIR}/${relative_day_dir}.processed"
  uploaded_state_file="${STATE_DIR}/${relative_day_dir}.uploaded"
  legacy_processed_state_file="${STATE_DIR}/${day}.processed"
  video_failure_file="${STATE_DIR}/${relative_day_dir}.failed"

  mkdir -p "${day_output_dir}" "$(dirname "${processed_state_file}")"

  # 兼容旧版按日期共用的状态文件，只迁移属于当前日期目录的视频记录。
  if [[ ! -e "${processed_state_file}" && -f "${legacy_processed_state_file}" ]]; then
    while IFS= read -r processed_path; do
      if [[ "${processed_path}" == "${day_dir}/"* ]]; then
        printf '%s\n' "${processed_path}" >> "${processed_state_file}"
      fi
    done < "${legacy_processed_state_file}"
  fi

  touch "${processed_state_file}" "${uploaded_state_file}"

  mapfile -d '' mp4_files < <(find "${day_dir}" -type f -iname "*.mp4" -print0)

  if [[ "${#mp4_files[@]}" -eq 0 ]]; then
    echo "日期目录暂无 mp4: ${day_dir}"
    upload_unuploaded_frames "${day_output_dir}" "${uploaded_state_file}" "${day}" "${site}"
    return 0
  fi

  if grep -Fxq -- "__ALL_PROCESSED__" "${processed_state_file}"; then
    echo "日期目录已标记为全部已处理: ${relative_day_dir}"
    upload_unuploaded_frames "${day_output_dir}" "${uploaded_state_file}" "${day}" "${site}"
    cleanup_processed_videos_for_day "${day_dir}" "${day_output_dir}" "${processed_state_file}" "${site}" "${relative_day_dir}"
    upload_remaining_kept_videos "${day_dir}" "${day_output_dir}" "${site}" "${relative_day_dir}"
    return 0
  fi

  for video_path in "${mp4_files[@]}"; do
    if grep -Fxq -- "${video_path}" "${processed_state_file}"; then
      continue
    fi

    if process_video "${video_path}" "${day_dir}" "${day_output_dir}"; then
      printf '%s\n' "${video_path}" >> "${processed_state_file}"
      continue
    fi
    echo "抽帧失败，稍后重试: ${video_path}"
    if ! record_video_failure "${video_failure_file}" "${video_path}"; then
      echo "连续失败 ${VIDEO_MAX_ATTEMPTS} 次，跳过该视频: ${video_path}"
      printf '%s\n' "${video_path}" >> "${processed_state_file}"
    fi
  done

  upload_unuploaded_frames "${day_output_dir}" "${uploaded_state_file}" "${day}" "${site}"
  cleanup_processed_videos_for_day "${day_dir}" "${day_output_dir}" "${processed_state_file}" "${site}" "${relative_day_dir}"
  upload_remaining_kept_videos "${day_dir}" "${day_output_dir}" "${site}" "${relative_day_dir}"
}

process_root() {
  local recordings_root="$1"
  local site="$2"
  local name_prefix="${3:-}"
  local day_dir
  local day
  local found_any=0
  local output_base
  local state_base
  local -a day_dirs
  local -a output_day_dirs
  local day_output_dir
  local uploaded_state_file

  if [[ ! -d "${recordings_root}" ]]; then
    return 0
  fi

  if [[ -n "${name_prefix}" ]]; then
    output_base="${OUTPUT_DIR}/${name_prefix}"
    state_base="${STATE_DIR}/${name_prefix}"
  else
    output_base="${OUTPUT_DIR}"
    state_base="${STATE_DIR}"
  fi

  mapfile -d '' day_dirs < <(
    find "${recordings_root}" -mindepth 1 -type d -print0 | sort -z
  )

  if [[ "${#day_dirs[@]}" -eq 0 ]]; then
    echo "录像目录下暂无任何子目录: ${recordings_root}"
  fi

  for day_dir in "${day_dirs[@]+"${day_dirs[@]}"}"; do
    day="$(basename "${day_dir}")"
    if [[ ! "${day}" =~ ^[0-9]{8}$ ]]; then
      continue
    fi
    found_any=1
    process_day "${day_dir}" "${recordings_root}" "${site}" "${name_prefix}"
  done

  if [[ "${found_any}" -eq 0 ]]; then
    echo "未发现日期目录(YYYYMMDD): ${recordings_root}"
  fi

  # 录像日期目录被配额清理后，仍扫描 output 残留帧并上传/清理
  if [[ -d "${output_base}" ]]; then
    mapfile -d '' output_day_dirs < <(
      find "${output_base}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z
    )
    for day_output_dir in "${output_day_dirs[@]+"${output_day_dirs[@]}"}"; do
      day="$(basename "${day_output_dir}")"
      if [[ ! "${day}" =~ ^[0-9]{8}$ ]]; then
        continue
      fi
      if [[ -d "${recordings_root}/${day}" ]]; then
        continue
      fi
      uploaded_state_file="${state_base}/${day}.uploaded"
      mkdir -p "$(dirname "${uploaded_state_file}")"
      touch "${uploaded_state_file}"
      upload_unuploaded_frames "${day_output_dir}" "${uploaded_state_file}" "${day}" "${site}"
    done
  fi

  enforce_data_quota "${recordings_root}" "${name_prefix}"
}

process_all_days() {
  local spec
  local extra_root
  local extra_site
  local extra_key

  process_root "${RECORDINGS_ROOT}" "${SITE}" ""

  if [[ -z "${EXTRA_RECORDINGS}" ]]; then
    return 0
  fi

  for spec in ${EXTRA_RECORDINGS}; do
    extra_root="${spec%%=*}"
    extra_site="${spec#*=}"
    extra_key="$(basename "${extra_root}")"
    process_root "${extra_root}" "${extra_site}" "${extra_key}"
  done
}

echo "开始扫描录像总根目录: ${RECORDINGS_ROOT} (site=${SITE})"
if [[ -n "${EXTRA_RECORDINGS}" ]]; then
  echo "额外录像: ${EXTRA_RECORDINGS}"
fi
echo "抽帧输出根目录: ${OUTPUT_DIR}"
echo "ffmpeg 线程数: ${FFMPEG_THREADS}"
if [[ "${FFMPEG_HWACCEL}" == "cuda" ]]; then
  echo "ffmpeg 设备: cuda:${FFMPEG_HWACCEL_DEVICE}"
else
  echo "ffmpeg 设备: cpu"
fi
echo "上传地址: ${UPLOAD_URL}"
echo "上传时间窗口: ${UPLOAD_TIME_WINDOWS}"
echo "轮询间隔: ${SCAN_INTERVAL} 秒"
echo "上传后删原视频: ${DELETE_VIDEO_AFTER_UPLOAD}"
echo "定点录像上传: ${VIDEO_UPLOAD_ENABLED} ${VIDEO_API_BASE}/api/videos 分片 ${VIDEO_CHUNK_BYTES} 字节"
echo "Data 上限: ${MAX_DATA_BYTES} 字节"

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  acquire_extract_lock
  while true; do
    process_all_days
    sleep "${SCAN_INTERVAL}"
  done
fi
