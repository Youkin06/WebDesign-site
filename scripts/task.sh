#!/usr/bin/env bash
# issue 単位の作業を始める・出す・片付けるためのスクリプト。使い方は AGENTS.md の「並行開発のルール」を参照。
set -euo pipefail

OWNER="Youkin06"
REPO="Youkin06/WebDesign-site"
PROJECT_NUMBER=6
PROJECT_ID="PVT_kwHOCQlhjM4BrQKb"
STATUS_FIELD_ID="PVTSSF_lAHOCQlhjM4BrQKbzhpjtPU"

ROOT="$(git rev-parse --path-format=absolute --git-common-dir | xargs dirname)"
WORKTREES="$(dirname "$ROOT")/WebDesign-site-worktrees"

usage() {
  cat <<USAGE
使い方:
  $0 find <キーワード>             開いている issue と閉じた issue の両方から探す
  $0 new <種類> <タイトル> <本文ファイル> [誰が]
                                  issue を作り、Project に「未着手」で入れる
                                  種類: 実装 / ネタ / バグ / 人間
                                  誰が: AIがやる / 人間がやる / AIが作って人間が確認（省略時は種類で決まる）
  $0 start <issue番号>           担当を自分にし、worktree を作り、「進行中」にする
  $0 status <issue番号> <状態>    状態を変える（未着手 / 進行中 / 人間判断 / 完了）
  $0 check                        lint・型チェック・ビルドを通す
  $0 pr <issue番号>               push してプルリクエストを作り、「人間判断」にする
  $0 merge <issue番号>            （人間に頼まれたときだけ）チェックを確かめて squash マージし、片付ける
  $0 done <issue番号>           マージ後に worktree とブランチを消し、「完了」にする
USAGE
  exit 1
}

option_id() {
  case "$1" in
    未着手) echo "abbb3734" ;;
    進行中) echo "00bb96e4" ;;
    人間判断) echo "cd1f3c95" ;;
    完了) echo "f0977d98" ;;
    *) echo "状態は 未着手 / 進行中 / 人間判断 / 完了 のどれか: $1" >&2; exit 1 ;;
  esac
}

set_status() {
  local issue="$1" state="$2" url item
  url="$(gh issue view "$issue" -R "$REPO" --json url --jq .url)"
  item="$(gh project item-add "$PROJECT_NUMBER" --owner "$OWNER" --url "$url" --format json --jq .id)"
  gh project item-edit --project-id "$PROJECT_ID" --id "$item" \
    --field-id "$STATUS_FIELD_ID" --single-select-option-id "$(option_id "$state")" >/dev/null
  echo "#$issue → $state"
}

cmd="${1:-}"; [ -n "$cmd" ] || usage

# 初回だけ：main への直接 push を止める pre-push フックを有効にする
if [ "$(git -C "$ROOT" config --get core.hooksPath || true)" != ".githooks" ]; then
  git -C "$ROOT" config core.hooksPath .githooks
  echo "pre-push フックを有効にしました（main への直接 push を止めます）。"
fi

# Project のカードを動かすコマンドは、gh に project の権限が必要
case "$cmd" in
  new|start|status|pr|merge|done)
    if ! gh auth status 2>&1 | grep -q "'project'"; then
      cat >&2 <<MSG
gh に GitHub Project を操作する権限（project）がありません。
次のコマンドを実行し、開いたブラウザで「Authorize」を押してから、もう一度やり直してください。

  gh auth refresh -s project
MSG
      exit 1
    fi
    ;;
esac

case "$cmd" in
  find)
    keyword="${2:?キーワードを指定してください}"
    gh issue list -R "$REPO" --state all --search "$keyword" --limit 50 \
      --json number,title,state,stateReason,labels,assignees \
      --jq '.[] | "#\(.number)\t\(if .state == "OPEN" then "開いている" elif .stateReason == "COMPLETED" then "完了済み" else "閉じた（\(.stateReason // "理由なし")）" end)\t\(.title)\t担当: \([.assignees[].login] | join(",") | if . == "" then "なし" else . end)"'
    ;;
  new)
    kind="${2:?種類を指定してください（実装 / ネタ / バグ / 人間）}"
    title="${3:?タイトルを指定してください}"
    body_file="${4:?本文ファイルを指定してください}"
    case "$kind" in
      実装) prefix="[実装] "; who="${5:-AIが作って人間が確認}" ;;
      ネタ) prefix="[ネタ] "; who="${5:-AIが作って人間が確認}" ;;
      バグ) prefix="[バグ] "; who="${5:-AIが作って人間が確認}" ;;
      人間) prefix="[人間] "; who="人間がやる"; kind="" ;;
      *) echo "種類は 実装 / ネタ / バグ / 人間 のどれか: $kind" >&2; exit 1 ;;
    esac
    labels="$who"
    [ -n "$kind" ] && labels="$kind,$who"
    url="$(gh issue create -R "$REPO" --title "$prefix$title" --body-file "$body_file" --label "$labels")"
    set_status "${url##*/}" 未着手
    echo "$url"
    ;;
  start)
    issue="${2:?issue番号を指定してください}"
    assignees="$(gh issue view "$issue" -R "$REPO" --json assignees --jq '[.assignees[].login] | join(",")')"
    me="$(gh api user --jq .login)"
    if [ -n "$assignees" ] && [ "$assignees" != "$me" ]; then
      echo "#$issue はすでに $assignees が担当しています。別の issue を選んでください。" >&2
      exit 1
    fi
    gh issue edit "$issue" -R "$REPO" --add-assignee @me >/dev/null
    git -C "$ROOT" fetch origin --quiet
    dir="$WORKTREES/issue-$issue"
    if [ -d "$dir" ]; then
      echo "worktree はすでにあります: $dir"
    elif git -C "$ROOT" show-ref --verify --quiet "refs/heads/issue-$issue"; then
      git -C "$ROOT" worktree add "$dir" "issue-$issue"
    else
      git -C "$ROOT" worktree add "$dir" -b "issue-$issue" origin/main
    fi
    set_status "$issue" 進行中
    echo
    echo "作業場所: $dir"
    echo "issue: $(gh issue view "$issue" -R "$REPO" --json url --jq .url)"
    ;;
  status)
    set_status "${2:?issue番号を指定してください}" "${3:?状態を指定してください}"
    ;;
  check)
    if [ ! -f package.json ]; then
      echo "package.json がないので、確認するものはありません。"
      exit 0
    fi
    npm run --if-present lint
    npm run --if-present typecheck
    npm run --if-present build
    ;;
  pr)
    issue="${2:?issue番号を指定してください}"
    branch="$(git rev-parse --abbrev-ref HEAD)"
    if [ "$branch" != "issue-$issue" ]; then
      echo "いまのブランチは $branch です。issue-$issue の worktree の中で実行してください。" >&2
      exit 1
    fi
    if [ -n "$(git status --porcelain)" ]; then
      echo "コミットしていない変更があります。先にコミットしてください。" >&2
      exit 1
    fi
    git fetch origin --quiet
    git rebase origin/main
    git push -u origin "$branch" --force-with-lease
    if ! gh pr view "$branch" -R "$REPO" >/dev/null 2>&1; then
      title="$(gh issue view "$issue" -R "$REPO" --json title --jq .title)"
      body="$(sed "s/#<issue番号>/#$issue/" "$ROOT/.github/pull_request_template.md")"
      gh pr create -R "$REPO" --head "$branch" --base main --title "$title" --body "$body"
      echo "プルリクエストの本文を、テンプレートに沿って埋めてください（gh pr edit $branch --body-file ...）。"
    fi
    set_status "$issue" 人間判断
    ;;
  merge)
    issue="${2:?issue番号を指定してください}"
    branch="issue-$issue"
    mergeable="$(gh pr view "$branch" -R "$REPO" --json mergeable --jq .mergeable)"
    if [ "$mergeable" != "MERGEABLE" ]; then
      echo "$branch のプルリクエストはマージできる状態ではありません（$mergeable）。main を取り込んでコンフリクトを直してください。" >&2
      exit 1
    fi
    # チェックが1つもないときは通ったとみなす。失敗・実行中なら止める
    checks="$(gh pr checks "$branch" -R "$REPO" 2>&1)" || {
      if ! grep -q "no checks reported" <<<"$checks"; then
        echo "チェックが通っていない、またはまだ実行中です。" >&2
        echo "$checks" >&2
        exit 1
      fi
    }
    gh pr merge "$branch" -R "$REPO" --squash
    "$0" done "$issue"
    ;;
  done)
    issue="${2:?issue番号を指定してください}"
    dir="$WORKTREES/issue-$issue"
    state="$(gh pr view "issue-$issue" -R "$REPO" --json state --jq .state 2>/dev/null || echo NONE)"
    if [ "$state" != "MERGED" ]; then
      echo "issue-$issue のプルリクエストはまだマージされていません（状態: $state）。" >&2
      exit 1
    fi
    [ -d "$dir" ] && git -C "$ROOT" worktree remove "$dir"
    git -C "$ROOT" branch -D "issue-$issue" 2>/dev/null || true
    git -C "$ROOT" push origin --delete "issue-$issue" 2>/dev/null || true
    set_status "$issue" 完了
    ;;
  *)
    usage
    ;;
esac
