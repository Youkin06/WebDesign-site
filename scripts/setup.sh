#!/usr/bin/env bash
# クローンしたあとに一度だけ実行する。main への直接 push を止めるフックを有効にする。
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
git config core.hooksPath .githooks
echo "pre-push フックを有効にしました。"
gh auth status 2>&1 | grep -q "'project'" || echo "gh に project の権限がありません。gh auth refresh -s project を実行してください。"
