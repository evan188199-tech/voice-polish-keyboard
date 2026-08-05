#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
echo "关闭粤英语音输入法 / 恢复正常输入..."
./scripts/disable_ime.sh --stop-companion "$@"
echo
read -r "?按回车关闭窗口..."
