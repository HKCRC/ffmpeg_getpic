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

WATCH_ROOT="${WATCH_ROOT:-./videos}"
OUTPUT_DIR="${OUTPUT_DIR:-./output}"
FRAME_INTERVAL="${FRAME_INTERVAL:-1800}"
SCAN_INTERVAL="${SCAN_INTERVAL:-20}"
UPLOAD_ENABLED="${UPLOAD_ENABLED:-1}"
UPLOAD_URL="${UPLOAD_URL:-http://aisafety.craner.hk/api/upload}"
SITE="${SITE:-cuhk}"
UPLOAD_TOKEN="${UPLOAD_TOKEN:-}"
STATE_DIR="${STATE_DIR:-${SCRIPT_DIR}/.state}"

if [[ "${WATCH_ROOT}" != /* ]]; then
  WATCH_ROOT="${SCRIPT_DIR}/${WATCH_ROOT}"
fi
if [[ "${OUTPUT_DIR}" != /* ]]; then
  OUTPUT_DIR="${SCRIPT_DIR}/${OUTPUT_DIR}"
fi
if [[ "${STATE_DIR}" != /* ]]; then
  STATE_DIR="${SCRIPT_DIR}/${STATE_DIR}"
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "未找到 ffmpeg，请先安装 ffmpeg。"
  exit 1
fi
if ! command -v ffprobe >/dev/null 2>&1; then
  echo "未找到 ffprobe，请先安装 ffmpeg（含 ffprobe）。"
  exit 1
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "未找到 curl，请先安装 curl。"
  exit 1
fi

if [[ ! -d "${WATCH_ROOT}" ]]; then
  echo "监听根目录不存在: ${WATCH_ROOT}"
  exit 1
fi

if ! [[ "${FRAME_INTERVAL}" =~ ^[0-9]+$ ]] || [[ "${FRAME_INTERVAL}" -le 0 ]]; then
  echo "FRAME_INTERVAL 必须是正整数，当前值: ${FRAME_INTERVAL}"
  exit 1
fi
if ! [[ "${SCAN_INTERVAL}" =~ ^[0-9]+$ ]] || [[ "${SCAN_INTERVAL}" -le 0 ]]; then
  echo "SCAN_INTERVAL 必须是正整数，当前值: ${SCAN_INTERVAL}"
  exit 1
fi
if [[ "${UPLOAD_ENABLED}" == "1" ]] && [[ -z "${SITE}" ]]; then
  echo "UPLOAD_ENABLED=1 时，SITE 不能为空。请在 config.conf 中设置 SITE。"
  exit 1
fi

mkdir -p "${OUTPUT_DIR}" "${STATE_DIR}"

build_video_stem() {
  local video_path="$1"
  local day_dir="$2"
  local rel_path="${video_path#${day_dir}/}"
  local rel_no_ext="${rel_path%.*}"
  local stem="${rel_no_ext//\//__}"
  stem="${stem// /_}"
  printf '%s' "${stem}"
}

# 文件头全零通常是录制失败产生的占位文件，无法抽帧
video_is_corrupt_placeholder() {
  local video_path="$1"
  local sample_size=4096
  local file_size
  local non_zero_count

  if ! file_size="$(stat -c%s -- "${video_path}" 2>/dev/null)"; then
    return 1
  fi

  if [[ "${file_size}" -eq 0 ]]; then
    return 0
  fi

  if [[ "${file_size}" -lt "${sample_size}" ]]; then
    sample_size="${file_size}"
  fi

  non_zero_count="$(
    head -c "${sample_size}" -- "${video_path}" \
      | tr -d '\0' \
      | wc -c \
      | tr -d '[:space:]'
  )"
  [[ "${non_zero_count}" -eq 0 ]]
}

# ffprobe 能读到首个视频流时，认为视频可处理
video_is_valid() {
  local video_path="$1"
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_type \
    -of csv=p=0 "${video_path}" >/dev/null 2>&1
}

# 按「日期目录/文件名」排序（文件名含 YYYYMMDDHHmmss，多帧含 _000001 等后缀）
sort_paths_by_datetime() {
  local path day base
  while IFS= read -r path; do
    [[ -n "${path}" ]] || continue
    day="$(basename "$(dirname "${path}")")"
    base="$(basename "${path}")"
    printf '%s\t%s\n' "${day}/${base}" "${path}"
  done | LC_ALL=C sort -t $'\t' -k1,1 | cut -f2-
}

list_sorted_days() {
  local day_dir day
  local -a days=()
  local -A day_set=()

  while IFS= read -r day_dir; do
    day="$(basename "${day_dir}")"
    if [[ "${day}" =~ ^[0-9]{8}$ ]] && [[ -z "${day_set[${day}]:-}" ]]; then
      day_set["${day}"]=1
      days+=("${day}")
    fi
  done < <(
    {
      find "${WATCH_ROOT}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null || true
      find "${OUTPUT_DIR}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null || true
    } | sort_paths_by_datetime
  )

  if [[ "${#days[@]}" -eq 0 ]]; then
    return 0
  fi

  printf '%s\n' "$(printf '%s\n' "${days[@]}" | LC_ALL=C sort -u)"
}

day_is_fully_processed() {
  local day="$1"
  local processed_state_file="${STATE_DIR}/${day}.processed"
  [[ -f "${processed_state_file}" ]] && grep -Fxq -- "__ALL_PROCESSED__" "${processed_state_file}"
}

video_is_processed() {
  local video_path="$1"
  local day="$2"
  local processed_state_file="${STATE_DIR}/${day}.processed"
  grep -Fxq -- "${video_path}" "${processed_state_file}" 2>/dev/null
}

mark_video_processed() {
  local video_path="$1"
  local day="$2"
  local processed_state_file="${STATE_DIR}/${day}.processed"
  printf '%s\n' "${video_path}" >> "${processed_state_file}"
}

upload_video_frames() {
  local video_stem="$1"
  local day_output_dir="$2"
  local uploaded_state_file="$3"
  local date_value="$4"
  local frame_path
  local -a frames=()

  shopt -s nullglob
  frames=("${day_output_dir}/${video_stem}_"*.jpg)
  shopt -u nullglob

  if [[ "${#frames[@]}" -eq 0 ]]; then
    return 0
  fi

  mapfile -t frames < <(printf '%s\n' "${frames[@]}" | sort_paths_by_datetime)

  for frame_path in "${frames[@]}"; do
    upload_frame "${frame_path}" "${uploaded_state_file}" "${date_value}" || true
  done
}

upload_frame() {
  local frame_path="$1"
  local uploaded_state_file="$2"
  local date_value="$3"
  local ext_lower
  local file_size

  if [[ "${UPLOAD_ENABLED}" != "1" ]]; then
    return 0
  fi

  if grep -Fxq -- "${frame_path}" "${uploaded_state_file}"; then
    return 0
  fi

  ext_lower="${frame_path##*.}"
  ext_lower="${ext_lower,,}"
  case "${ext_lower}" in
    jpg|jpeg|png|gif|webp) ;;
    *)
      echo "跳过不支持的图片格式: ${frame_path}"
      printf '%s\n' "${frame_path}" >> "${uploaded_state_file}"
      return 0
      ;;
  esac

  if ! file_size="$(stat -c%s -- "${frame_path}")"; then
    echo "读取文件大小失败，跳过: ${frame_path}"
    return 0
  fi
  if [[ "${file_size}" -gt 10485760 ]]; then
    echo "跳过超过 10MB 的文件: ${frame_path}"
    printf '%s\n' "${frame_path}" >> "${uploaded_state_file}"
    return 0
  fi

  local -a curl_args=(
    -fsS
    --retry 2
    --retry-delay 1
    -X POST
    "${UPLOAD_URL}"
    -F "site=${SITE}"
    -F "date=${date_value}"
    -F "file=@${frame_path}"
  )

  if [[ -n "${UPLOAD_TOKEN}" ]]; then
    curl_args+=(-H "Authorization: Bearer ${UPLOAD_TOKEN}")
  fi

  if curl "${curl_args[@]}" >/dev/null; then
    printf '%s\n' "${frame_path}" >> "${uploaded_state_file}"
    if rm -f -- "${frame_path}"; then
      echo "已上传并删除本地文件: $(basename "${frame_path}")"
    else
      echo "已上传，但删除本地文件失败: ${frame_path}"
    fi
  else
    echo "上传失败: ${frame_path}"
    return 1
  fi
}

process_video() {
  local video_path="$1"
  local day_dir="$2"
  local day_output_dir="$3"

  local video_name
  local video_stem
  local extracted_count
  local -a frames

  video_name="$(basename "${video_path}")"
  video_stem="$(build_video_stem "${video_path}" "${day_dir}")"

  echo "处理新视频: ${video_name}"

  if ! ffmpeg -hide_banner -loglevel error -y \
    -i "${video_path}" \
    -vf "select='eq(n\\,0)+eq(pict_type\\,I)*gte(n-prev_selected_n\\,${FRAME_INTERVAL})'" \
    -vsync vfr \
    "${day_output_dir}/${video_stem}_%06d.jpg"; then
    echo "抽帧失败: ${video_name}"
    return 1
  fi

  shopt -s nullglob
  frames=("${day_output_dir}/${video_stem}_"*.jpg)
  shopt -u nullglob

  extracted_count="${#frames[@]}"
  echo "抽帧完成: ${video_name}，输出 ${extracted_count} 张"
}

# 收集所有日期目录下、尚未上传的 jpg，按日期+时间排序
collect_pending_frames() {
  local day day_output_dir uploaded_state_file frame_path
  local -a pending=()
  local -a day_frames=()

  while IFS= read -r day; do
    [[ -n "${day}" ]] || continue

    day_output_dir="${OUTPUT_DIR}/${day}"
    uploaded_state_file="${STATE_DIR}/${day}.uploaded"

    [[ -d "${day_output_dir}" ]] || continue
    touch "${uploaded_state_file}"

    shopt -s nullglob
    day_frames=("${day_output_dir}/"*.jpg)
    shopt -u nullglob

    if [[ "${#day_frames[@]}" -eq 0 ]]; then
      continue
    fi

    mapfile -t day_frames < <(printf '%s\n' "${day_frames[@]}" | sort_paths_by_datetime)

    for frame_path in "${day_frames[@]}"; do
      if grep -Fxq -- "${frame_path}" "${uploaded_state_file}" 2>/dev/null; then
        continue
      fi
      if [[ ! -f "${frame_path}" ]]; then
        continue
      fi
      pending+=("${frame_path}")
    done
  done < <(list_sorted_days)

  if [[ "${#pending[@]}" -gt 0 ]]; then
    printf '%s\n' "${pending[@]}"
  fi
}

upload_pending_frames_globally() {
  local frame_path date_value
  local -a pending=()

  mapfile -t pending < <(collect_pending_frames)

  if [[ "${#pending[@]}" -eq 0 ]]; then
    return 0
  fi

  echo "按时间顺序上传 ${#pending[@]} 张待传图片"

  for frame_path in "${pending[@]}"; do
    date_value="$(basename "$(dirname "${frame_path}")")"
    upload_frame "${frame_path}" "${STATE_DIR}/${date_value}.uploaded" "${date_value}" || true
  done
}

# 收集尚未抽帧的 mp4，按日期目录 + 文件名时间排序
collect_unprocessed_videos() {
  local day day_dir day_output_dir processed_state_file video_path
  local -a mp4_files=()
  local -a videos=()

  while IFS= read -r day; do
    [[ -n "${day}" ]] || continue

    if day_is_fully_processed "${day}"; then
      continue
    fi

    day_dir="${WATCH_ROOT}/${day}"
    day_output_dir="${OUTPUT_DIR}/${day}"
    processed_state_file="${STATE_DIR}/${day}.processed"

    [[ -d "${day_dir}" ]] || continue

    mkdir -p "${day_output_dir}"
    touch "${processed_state_file}" "${STATE_DIR}/${day}.uploaded"

    mapfile -d '' mp4_files < <(find "${day_dir}" -type f -iname "*.mp4" -print0)

    if [[ "${#mp4_files[@]}" -eq 0 ]]; then
      continue
    fi

    mapfile -t mp4_files < <(printf '%s\n' "${mp4_files[@]}" | sort_paths_by_datetime)

    for video_path in "${mp4_files[@]}"; do
      if video_is_processed "${video_path}" "${day}"; then
        continue
      fi
      videos+=("${video_path}")
    done
  done < <(list_sorted_days)

  if [[ "${#videos[@]}" -gt 0 ]]; then
    printf '%s\n' "${videos[@]}"
  fi
}

process_unprocessed_videos_in_order() {
  local video_path day day_dir day_output_dir video_stem uploaded_state_file
  local -a videos=()

  mapfile -t videos < <(collect_unprocessed_videos)

  if [[ "${#videos[@]}" -eq 0 ]]; then
    return 0
  fi

  for video_path in "${videos[@]}"; do
    day="$(basename "$(dirname "${video_path}")")"
    day_dir="${WATCH_ROOT}/${day}"
    day_output_dir="${OUTPUT_DIR}/${day}"
    uploaded_state_file="${STATE_DIR}/${day}.uploaded"

    if video_is_corrupt_placeholder "${video_path}"; then
      echo "跳过全零损坏占位视频: $(basename "${video_path}")"
      mark_video_processed "${video_path}" "${day}"
      continue
    fi

    if ! video_is_valid "${video_path}"; then
      echo "ffprobe 检测视频不可读，跳过本轮: $(basename "${video_path}")"
      continue
    fi

    if ! process_video "${video_path}" "${day_dir}" "${day_output_dir}"; then
      continue
    fi
    mark_video_processed "${video_path}" "${day}"

    video_stem="$(build_video_stem "${video_path}" "${day_dir}")"
    upload_video_frames "${video_stem}" "${day_output_dir}" "${uploaded_state_file}" "${day}"
  done
}

process_all_days() {
  local day
  local found_any=0

  while IFS= read -r day; do
    [[ -n "${day}" ]] || continue
    found_any=1
  done < <(list_sorted_days)

  if [[ "${found_any}" -eq 0 ]]; then
    echo "未发现日期目录(YYYYMMDD): ${WATCH_ROOT}"
    return 0
  fi

  # 1. 先上传所有未传图片（跨日期按时间顺序）
  upload_pending_frames_globally

  # 2. 再按日期+时间顺序抽帧，每段视频抽完立即上传
  process_unprocessed_videos_in_order
}

echo "开始监听根目录: ${WATCH_ROOT}"
echo "抽帧输出根目录: ${OUTPUT_DIR}"
echo "上传地址: ${UPLOAD_URL}"
echo "轮询间隔: ${SCAN_INTERVAL} 秒"

while true; do
  process_all_days
  sleep "${SCAN_INTERVAL}"
done