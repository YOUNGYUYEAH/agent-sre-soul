#!/usr/bin/env bash
# 把 agent-sre-soul 接入本机各 Agent。用法：
#   ./install.sh codex     -> 软链 ~/.codex/AGENTS.md
#   ./install.sh claude    -> 软链 ~/.claude/CLAUDE.md（会先备份原文件）
#   ./install.sh skills    -> 软链 skills/* 到 ~/.claude/skills 和 ~/.codex/skills
#   ./install.sh prompt    -> 合并为单个系统提示词输出到 dist/system-prompt.md（DeepSeek API/网页等）
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
link() { # $1=target
  mkdir -p "$(dirname "$1")"
  if [ -e "$1" ] && [ ! -L "$1" ]; then cp "$1" "$1.bak-$(date +%Y%m%d%H%M%S)"; echo "已备份 $1"; fi
  ln -sfn "$ROOT/AGENTS.md" "$1"; echo "已链接 $1 -> $ROOT/AGENTS.md"
}
case "${1:-}" in
  codex)  link "$HOME/.codex/AGENTS.md" ;;
  claude) link "$HOME/.claude/CLAUDE.md" ;;
  skills)
    for d in "$HOME/.claude/skills" "$HOME/.codex/skills"; do
      mkdir -p "$d"
      for s in "$ROOT"/skills/*/; do n=$(basename "$s")
        if [ -e "$d/$n" ] && [ ! -L "$d/$n" ]; then echo "跳过 $d/$n（已存在且不是软链）"; continue; fi
        ln -sfn "${s%/}" "$d/$n"; echo "已链接 $d/$n"; done
    done ;;
  prompt)
    mkdir -p "$ROOT/dist"; out="$ROOT/dist/system-prompt.md"
    { cat "$ROOT/AGENTS.md"; for f in identity principles troubleshooting change-and-delivery anti-patterns collaboration; do
        printf '\n\n---\n\n'; awk 'NR==1&&/^---$/{fm=1;next} fm&&/^---$/{fm=0;next} !fm' "$ROOT/soul/$f.md"; done; } > "$out"
    echo "已生成 $out（$(wc -c <"$out") 字节）" ;;
  *) sed -n '2,6p' "$0"; exit 1 ;;
esac
