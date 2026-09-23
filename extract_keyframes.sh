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

SITE="${SITE:-}"
if [[ -z "${RECORDINGS_ROOT:-}" ]]; then
  if [[ -z "${SITE}" ]]; then
    echo "请在 config.conf 中设置 SITE，或直接设置 RECORDINGS_ROOT。"
    exit 1
  fi
  RECORDINGS_ROOT="/workspace/hik_download/${SITE}Data"
fi
readonly RECORDINGS_ROOT
OUTPUT_DIR="${OUTPUT_DIR:-./output}"
FRAME_INTERVAL="${FRAME_INTERVAL:-1800}"
SCAN_INTERVAL="${SCAN_INTERVAL:-20}"
UPLOAD_ENABLED="${UPLOAD_ENABLED:-1}"
UPLOAD_URL="${UPLOAD_URL:-http://aisafety.craner.hk/api/upload}"
UPLOAD_TOKEN="${UPLOAD_TOKEN:-}"
# 与上传 API / 下载窗口对齐；文件名中 HHMMSS 落在窗外则跳过上传并清理本地
UPLOAD_TIME_WINDOWS="${UPLOAD_TIME_WINDOWS:-09:00:00-11:00:00 14:00:00-17:45:00}"
STATE_DIR="${STATE_DIR:-${SCRIPT_DIR}/.state}"
DELETE_VIDEO_AFTER_UPLOAD="${DELETE_VIDEO_AFTER_UPLOAD:-1}"
MAX_DATA_BYTES="${MAX_DATA_BYTES:-2147483648}"

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
if ! [[ "${MAX_DATA_BYTES}" =~ ^[0-9]+$ ]] || [[ "${MAX_DATA_BYTES}" -le 0 ]]; then
  echo "MAX_DATA_BYTES 必须是正整数，当前值: ${MAX_DATA_BYTES}"
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

# 从 YYYYMMDDHHMMSS-*.jpg / *.mp4 文件名解析 HHMMSS；解析失败返回空
parse_name_hhmmss() {
  local base
  base="$(basename "$1")"
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
    -F "site=${SITE}"
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

process_video() {
  local video_path="$1"
  local day_dir="$2"
  local day_output_dir="$3"

  local video_name
  local video_stem
  local extracted_count
  local -a frames
  local hhmmss

  video_name="$(basename "${video_path}")"
  hhmmss="$(parse_name_hhmmss "${video_name}")"
  if [[ -n "${hhmmss}" ]] && ! is_hhmmss_allowed "${hhmmss}"; then
    echo "跳过时间窗外视频 (${hhmmss}): ${video_name}"
    if [[ "${DELETE_VIDEO_AFTER_UPLOAD}" == "1" ]]; then
      if rm -f -- "${video_path}"; then
        echo "已删除时间窗外原视频: ${video_path}"
      fi
    fi
    return 0
  fi

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

# 某视频对应帧全部上传完毕（本地无残留 jpg）时，删除原 mp4。
maybe_delete_video_after_upload() {
  local video_path="$1"
  local day_dir="$2"
  local day_output_dir="$3"
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

  video_stem="$(build_video_stem "${video_path}" "${day_dir}")"
  shopt -s nullglob
  remaining_frames=("${day_output_dir}/${video_stem}_"*.jpg)
  shopt -u nullglob

  if [[ "${#remaining_frames[@]}" -gt 0 ]]; then
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
    maybe_delete_video_after_upload "${video_path}" "${day_dir}" "${day_output_dir}"
  done < "${processed_state_file}"
}

dir_size_bytes() {
  local target="$1"
  local size
  size="$(du -sb -- "${target}" 2>/dev/null | awk '{print $1}')"
  printf '%s' "${size:-0}"
}

# 超限时按 mtime 从旧到新删除已处理的 mp4，并清理空日期目录。
enforce_data_quota() {
  local total_size
  local video_path
  local day_dir
  local relative_day_dir
  local processed_state_file
  local -a candidates

  if [[ ! -d "${RECORDINGS_ROOT}" ]]; then
    return 0
  fi

  total_size="$(dir_size_bytes "${RECORDINGS_ROOT}")"
  if [[ "${total_size}" -le "${MAX_DATA_BYTES}" ]]; then
    return 0
  fi

  echo "录像目录用量 ${total_size} 字节，超过上限 ${MAX_DATA_BYTES}，开始清理已处理视频..."

  mapfile -d '' candidates < <(
    find "${RECORDINGS_ROOT}" -type f -iname "*.mp4" -printf '%T@\t%p\0' \
      | sort -z -n \
      | cut -z -f2-
  )

  for video_path in "${candidates[@]}"; do
    total_size="$(dir_size_bytes "${RECORDINGS_ROOT}")"
    if [[ "${total_size}" -le "${MAX_DATA_BYTES}" ]]; then
      break
    fi

    day_dir="$(dirname "${video_path}")"
    relative_day_dir="${day_dir#${RECORDINGS_ROOT}/}"
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

    if rm -f -- "${video_path}"; then
      echo "配额清理，删除已处理视频: ${video_path}"
    else
      echo "配额清理失败: ${video_path}"
    fi
  done

  # 清理空日期目录
  local -a empty_day_dirs=()
  local day
  mapfile -d '' empty_day_dirs < <(
    find "${RECORDINGS_ROOT}" -mindepth 1 -maxdepth 1 -type d -print0
  )
  for day_dir in "${empty_day_dirs[@]+"${empty_day_dirs[@]}"}"; do
    day="$(basename "${day_dir}")"
    if [[ ! "${day}" =~ ^[0-9]{8}$ ]]; then
      continue
    fi
    if [[ -z "$(find "${day_dir}" -type f -print -quit)" ]]; then
      rmdir --ignore-fail-on-non-empty -- "${day_dir}" 2>/dev/null || true
      echo "已清理空日期目录: ${day_dir}"
    fi
  done

  total_size="$(dir_size_bytes "${RECORDINGS_ROOT}")"
  echo "配额清理后录像目录用量: ${total_size} 字节"
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
    upload_unuploaded_frames "${day_output_dir}" "${uploaded_state_file}" "${day}"
    return 0
  fi

  if grep -Fxq -- "__ALL_PROCESSED__" "${processed_state_file}"; then
    echo "日期目录已标记为全部已处理: ${relative_day_dir}"
    upload_unuploaded_frames "${day_output_dir}" "${uploaded_state_file}" "${day}"
    cleanup_processed_videos_for_day "${day_dir}" "${day_output_dir}" "${processed_state_file}"
    return 0
  fi

  for video_path in "${mp4_files[@]}"; do
    if grep -Fxq -- "${video_path}" "${processed_state_file}"; then
      continue
    fi

    process_video "${video_path}" "${day_dir}" "${day_output_dir}"
    printf '%s\n' "${video_path}" >> "${processed_state_file}"

    # 立刻上传该视频刚抽出的帧，成功后即可删原片
    upload_unuploaded_frames "${day_output_dir}" "${uploaded_state_file}" "${day}"
    maybe_delete_video_after_upload "${video_path}" "${day_dir}" "${day_output_dir}"
  done

  upload_unuploaded_frames "${day_output_dir}" "${uploaded_state_file}" "${day}"
  cleanup_processed_videos_for_day "${day_dir}" "${day_output_dir}" "${processed_state_file}"
}

process_all_days() {
  local day_dir
  local day
  local found_any=0
  local -a day_dirs
  local -a output_day_dirs
  local day_output_dir
  local uploaded_state_file

  mapfile -d '' day_dirs < <(
    find "${RECORDINGS_ROOT}" -mindepth 1 -type d -print0 | sort -z
  )

  if [[ "${#day_dirs[@]}" -eq 0 ]]; then
    echo "录像总根目录下暂无任何子目录: ${RECORDINGS_ROOT}"
  fi

  for day_dir in "${day_dirs[@]+"${day_dirs[@]}"}"; do
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

  # 录像日期目录被配额清理后，仍扫描 output 残留帧并上传/清理
  mapfile -d '' output_day_dirs < <(
    find "${OUTPUT_DIR}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z
  )
  for day_output_dir in "${output_day_dirs[@]+"${output_day_dirs[@]}"}"; do
    day="$(basename "${day_output_dir}")"
    if [[ ! "${day}" =~ ^[0-9]{8}$ ]]; then
      continue
    fi
    if [[ -d "${RECORDINGS_ROOT}/${day}" ]]; then
      continue
    fi
    uploaded_state_file="${STATE_DIR}/${day}.uploaded"
    touch "${uploaded_state_file}"
    upload_unuploaded_frames "${day_output_dir}" "${uploaded_state_file}" "${day}"
  done

  enforce_data_quota
}

echo "开始扫描录像总根目录: ${RECORDINGS_ROOT}"
echo "抽帧输出根目录: ${OUTPUT_DIR}"
echo "上传地址: ${UPLOAD_URL}"
echo "上传时间窗口: ${UPLOAD_TIME_WINDOWS}"
echo "轮询间隔: ${SCAN_INTERVAL} 秒"
echo "上传后删原视频: ${DELETE_VIDEO_AFTER_UPLOAD}"
echo "Data 上限: ${MAX_DATA_BYTES} 字节"

while true; do
  process_all_days
  sleep "${SCAN_INTERVAL}"
done
