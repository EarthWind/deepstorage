#!/usr/bin/env bash
# 批量生成 Tectonic 图解（10 张，中文，sketchnote，16:9）。
# 需要：GIIISP_AUTH_TOKEN（必需），DASHSCOPE_API_KEY（可选；缺失时跳过 VLM 语义复查）
# 用法：bash generate.sh [页面ID前缀...]   例如：bash generate.sh 03 07
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SKILL="$HOME/.claude/skills/giiisp-scientific-image-generation/scripts"
RUNS="$HERE/runs"

: "${GIIISP_AUTH_TOKEN:?请先设置 GIIISP_AUTH_TOKEN（https://giiisp.com/#/mcp/authenticate）}"
VLM_FLAG=()
[[ -z "${DASHSCOPE_API_KEY:-}" ]] && VLM_FLAG=(--skip-vlm) && echo "未设置 DASHSCOPE_API_KEY：跳过 VLM 语义复查"

for spec in "$HERE"/prompts/*.json; do
  id="$(basename "$spec" .json)"
  if [[ $# -gt 0 ]]; then
    match=0; for p in "$@"; do [[ "$id" == "$p"* ]] && match=1; done
    [[ $match -eq 1 ]] || continue
  fi
  neg="$(python3 -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["negativePrompt"])' "$spec")"
  echo "== 生成 $id =="
  python3 "$SKILL/run_scientific_image_workflow.py" "${VLM_FLAG[@]}" -- \
    --input-json "$spec" --aspect-ratio 16:9 --negative-prompt "$neg" \
    --output-dir "$RUNS/$id"
  latest="$(ls -td "$RUNS/$id"/*/ | head -1)"
  img="$(ls "$latest"generated_image.* 2>/dev/null | head -1 || true)"
  if [[ -n "$img" ]]; then
    # 统一为 PNG，便于 Markdown 固定引用 <id>.png
    python3 -I -c 'import sys;from PIL import Image;Image.open(sys.argv[1]).save(sys.argv[2],"PNG")' "$img" "$HERE/$id.png"
    echo "   -> $HERE/$id.png"
  else
    echo "   !! $id 未得到图片，见 $latest"
  fi
done
