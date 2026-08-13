# ffmpeg_getPic

使用 Bash + ffmpeg 定时扫描“所有日期目录（含历史）”中的新 mp4，按配置间隔抽取关键帧，并通过 HTTP API 上传图片。

## 功能

- 持续递归扫描脚本内置的录像总根目录，处理任意通道/码流目录下日期目录中的新 mp4（包含历史目录）
- 按 `FRAME_INTERVAL` 控制抽帧间隔，默认 1800 帧
- 抽出的 jpg 按原始相对路径保存在 `OUTPUT_DIR/<通道>/<码流>/<YYYYMMDD>/` 下
- 每张抽出的图片可自动上传到 `UPLOAD_URL`（`curl -X POST -F "site=cuhk" -F "date=YYYYMMDD" -F "file=@xxx.jpg"`）
- 上传成功后会自动删除本地对应 jpg
- 自动记录已处理视频与已上传图片，避免重复处理/重复上传

## 依赖

运行前请确保系统中已安装：

- ffmpeg
- curl

示例安装命令：

```bash
sudo apt update
sudo apt install -y ffmpeg curl
```

## 文件说明

- extract_keyframes.sh：主脚本，负责抽帧
- config.conf：配置文件，包含抽帧参数和上传参数
- output/：默认图片输出目录
- .state/：默认处理记录目录（自动创建）

## 配置

编辑 config.conf：

```bash
# 输出根目录；jpg 会按录像总根目录下的原始相对路径分类保存
OUTPUT_DIR=./output

# 抽帧间隔：至少间隔多少帧再保存下一张关键帧
FRAME_INTERVAL=1800

# 轮询新视频间隔（秒）
SCAN_INTERVAL=20

# 是否上传
UPLOAD_ENABLED=1

# 上传接口
UPLOAD_URL=http://aisafety.craner.hk/api/upload

# 上传站点参数（接口 form-data: site）
SITE=cuhk

# 可选 Bearer Token
UPLOAD_TOKEN=

# 已处理记录目录
STATE_DIR=./.state
```

配置说明：

- 录像总根目录固定写在 `extract_keyframes.sh` 中，脚本会递归扫描其下所有名为 `YYYYMMDD` 的日期目录
- OUTPUT_DIR：本地输出根目录；图片保留日期目录在录像总根目录下的相对路径
- FRAME_INTERVAL：每隔多少帧保存一次关键帧
- SCAN_INTERVAL：每隔多少秒扫描一次所有日期目录是否有新 mp4
- UPLOAD_ENABLED：是否上传抽出的图片
- UPLOAD_URL：上传接口地址
- SITE：上传站点参数，上传时会以 `site=<SITE>` 发送
- date：脚本会自动从日期目录名识别并上传 `date=<YYYYMMDD>`
- UPLOAD_TOKEN：Bearer 鉴权 token（如果接口需要）
- STATE_DIR：记录状态文件，包含：
  - `<通道>/<码流>/YYYYMMDD.processed`：已抽帧的视频路径
  - `<通道>/<码流>/YYYYMMDD.uploaded`：已成功上传的图片路径

## 使用方法

1. 修改 `config.conf`（重点确认 `UPLOAD_URL`、字段名）
2. 启动脚本
3. 执行脚本：

```bash
chmod +x extract_keyframes.sh
./extract_keyframes.sh
```

脚本会持续运行。你可以用 `Ctrl+C` 停止。

## 处理结果

假设今天日期为 `20260505`，新视频为 `sample.mp4`：

- 生成图片路径示例：`OUTPUT_DIR/通道/Profile_1/20260505/sample_000001.jpg`、`OUTPUT_DIR/通道/Profile_1/20260505/sample_000002.jpg` …
- 抽帧逻辑为：首帧 + 按 `FRAME_INTERVAL` 间隔选取的 I 帧
- 每张图片通过 HTTP POST 上传到 `UPLOAD_URL`，请求格式等价于：`curl -X POST -F "site=cuhk" -F "date=20260503" -F "file=@xxx.jpg" http://aisafety.craner.hk/api/upload`

## 注意事项

- 脚本为常驻监听模式，会一直运行并按 `SCAN_INTERVAL` 轮询
- 若当前没有任何日期目录，脚本会持续轮询等待
- 上传采用固定字段名 `site` 与 `file`，需确保接口与此一致
- 上传时自动携带 `date`（来自目录名），并在本地限制上传文件大小不超过 10MB，仅允许 `.jpg/.jpeg/.png/.gif/.webp`
- 上传成功后会删除本地帧图，避免磁盘持续增长
- 如上传失败，脚本会打印失败日志并继续后续处理