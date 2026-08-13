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

readonly RECORDINGS_ROOT="/home/craner/Downloads/easynvr_docker/r/easynvr_rec"
OUTPUT_DIR="${OUTPUT_DIR:-./output}"
FRAME_INTERVAL="${FRAME_INTERVAL:-1800}"
SCAN_INTERVAL="${SCAN_INTERVAL:-20}"
UPLOAD_ENABLED="${UPLOAD_ENABLED:-1}"
UPLOAD_URL="${UPLOAD_URL:-http://aisafety.craner.hk/api/upload}"
SITE="${SITE:-cuhk}"
UPLOAD_TOKEN="${UPLOAD_TOKEN:-}"
STATE_DIR="${STATE_DIR:-${SCRIPT_DIR}/.state}"

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

  ffmpeg -hide_banner -loglevel error -y \
    -i "${video_path}" \
    -vf "select='eq(n\\,0)+eq(pict_type\\,I)*gte(n-prev_selected_n\\,${FRAME_INTERVAL})'" \
    -vsync vfr \
    "${day_output_dir}/${video_stem}_%06d.jpg"

  shopt -s nullglob
  frames=("${day_output_dir}/${video_stem}_"*.jpg)
  shopt -u nullglob

  extracted_count="${#frames[@]}"
  echo "抽帧完成: ${video_name}，输出 ${extracted_count} 张"
}

upload_unuploaded_frames() {
  local day_output_dir="$1"
  local uploaded_state_file="$2"
  local date_value="$3"
  local frame_path
  local -a frames

  shopt -s nullglob
  frames=("${day_output_dir}/"*.jpg)
  shopt -u nullglob

  if [[ "${#frames[@]}" -eq 0 ]]; then
    return 0
  fi

  for frame_path in "${frames[@]}"; do
    upload_frame "${frame_path}" "${uploaded_state_file}" "${date_value}" || true
  done
}

process_day() {
  local day_dir="$1"
  local day
  local relative_day_dir
  local day_output_dir
  local processed_state_file
  local uploaded_state_file
  local legacy_processed_state_file
  local processed_path
  local video_path
  local -a mp4_files

  day="$(basename "${day_dir}")"
  relative_day_dir="${day_dir#${RECORDINGS_ROOT}/}"
  day_output_dir="${OUTPUT_DIR}/${relative_day_dir}"
  processed_state_file="${STATE_DIR}/${relative_day_dir}.processed"
  uploaded_state_file="${STATE_DIR}/${relative_day_dir}.uploaded"
  legacy_processed_state_file="${STATE_DIR}/${day}.processed"

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
    return 0
  fi

  if grep -Fxq -- "__ALL_PROCESSED__" "${processed_state_file}"; then
    echo "日期目录已标记为全部已处理: ${relative_day_dir}"
    upload_unuploaded_frames "${day_output_dir}" "${uploaded_state_file}" "${day}"
    return 0
  fi

  for video_path in "${mp4_files[@]}"; do
    if grep -Fxq -- "${video_path}" "${processed_state_file}"; then
      continue
    fi

    process_video "${video_path}" "${day_dir}" "${day_output_dir}"
    printf '%s\n' "${video_path}" >> "${processed_state_file}"
  done

  upload_unuploaded_frames "${day_output_dir}" "${uploaded_state_file}" "${day}"
}

process_all_days() {
  local day_dir
  local day
  local found_any=0
  local -a day_dirs

  mapfile -d '' day_dirs < <(
    find "${RECORDINGS_ROOT}" -mindepth 1 -type d -print0 | sort -z
  )

  if [[ "${#day_dirs[@]}" -eq 0 ]]; then
    echo "录像总根目录下暂无任何子目录: ${RECORDINGS_ROOT}"
    return 0
  fi

  for day_dir in "${day_dirs[@]}"; do
    day="$(basename "${day_dir}")"
    if [[ ! "${day}" =~ ^[0-9]{8}$ ]]; then
      continue
    fi
    found_any=1
    process_day "${day_dir}"
  done

  if [[ "${found_any}" -eq 0 ]]; then
    echo "未发现日期目录(YYYYMMDD): ${RECORDINGS_ROOT}"
  fi
}

echo "开始扫描录像总根目录: ${RECORDINGS_ROOT}"
echo "抽帧输出根目录: ${OUTPUT_DIR}"
echo "上传地址: ${UPLOAD_URL}"
echo "轮询间隔: ${SCAN_INTERVAL} 秒"

while true; do
  process_all_days
  sleep "${SCAN_INTERVAL}"
done