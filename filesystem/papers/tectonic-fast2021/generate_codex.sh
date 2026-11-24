#!/usr/bin/env bash
# 用 Codex CLI 内置 imagegen 生成图解（不需要 GIIISP_AUTH_TOKEN）。
# 前提：codex 已登录（codex login）。用法：bash generate_codex.sh [页面ID前缀...]，并发数用 JOBS 控制（默认 3）
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$HERE/logs"

gen_one() {
  local spec="$1" id prompt
  id="$(basename "$spec" .json)"
  prompt="$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["prompt"])' "$spec")"
  timeout 900 codex exec --skip-git-repo-check -s workspace-write -C "$HERE" \
"请使用你内置的图像生成工具（imagegen / image_gen）生成一张 16:9 横版图片，严格按照下面的作图说明。生成后把图片文件保存为当前目录下的 ${id}.png（如果工具输出在别处，请复制过来）。不要写任何代码去绘图，不要用 SVG/matplotlib 代替，必须是图像生成模型的输出。完成后只回复保存路径。

作图说明：
${prompt}" > "$HERE/logs/${id}.log" 2>&1
  if [[ -s "$HERE/${id}.png" ]]; then echo "OK   $id"; else echo "FAIL $id (见 logs/${id}.log)"; fi
}
export -f gen_one
export HERE

specs=()
for spec in "$HERE"/prompts/*.json; do
  id="$(basename "$spec" .json)"
  if [[ $# -gt 0 ]]; then
    m=0; for p in "$@"; do [[ "$id" == "$p"* ]] && m=1; done; [[ $m -eq 1 ]] || continue
  fi
  specs+=("$spec")
done
printf '%s\n' "${specs[@]}" | xargs -P "${JOBS:-3}" -I{} bash -c 'gen_one "$1"' _ {}
