#!/bin/sh
# env_test.sh —— env.zsh 和 env.bash 必须**行为一致**（不连网）
#
#   sh tests/env_test.sh
#
# 钉三件事：
#   1. ggcp 的参数解析（1234 / 1234/2 / 1234,2 / 两种 URL / 乱输）
#   2. 没有服务器信息时的报错（要清楚，不能静默）
#   3. 两个 shell 给的结果逐字节一样
#
# 没装 zsh 就只测 bash —— env.bash 存在的意义就是"没有 zsh 的机器"。
set -eu

here=$(cd -- "$(dirname -- "$0")" && pwd)
proj=$(cd -- "$here/.." && pwd)

pass=0; fail=0
ok ()  { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
bad () { fail=$((fail + 1)); printf '  FAIL %s\n' "$*"; }
chk () { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 [$3] 实际 [$2]）"; fi; }

T=$(mktemp -d "${TMPDIR:-/tmp}/gerrit-gate-env.XXXXXX")
trap 'rm -rf -- "$T"' EXIT INT TERM

# 不在任何 repo 工作区里跑：_gg_ws 找不到 .repo，_gg_resolve 只能靠环境变量
run_in () {   # <shell> <片段>
    ( cd "$T" && WTOOL_PROJECT_DIR="$proj" HOME="$T" "$1" -c \
        "unset WTOOL_GERRIT_HOST WTOOL_GERRIT_PORT WTOOL_GERRIT_USER WTOOL_GERRIT_SSH_KEY
         . \"$proj/env.$1\"
         $2" ) 2>&1
}

for sh in bash zsh; do
    if ! command -v "$sh" >/dev/null 2>&1; then
        echo "== env.$sh：跳过（没装 $sh）=="
        continue
    fi
    echo "== env.$sh =="

    # --- 参数解析 ---
    for spec in "1234|1234|" "1234/2|1234|2" "1234,2|1234|2" \
                "https://g.example.com/c/p/+/1234/3|1234|3" \
                "https://g.example.com/#/c/1234/2|1234|2"; do
        arg=${spec%%|*}; rest=${spec#*|}; want_ch=${rest%%|*}; want_ps=${rest#*|}
        out=$(run_in "$sh" "_gg_parse_change_arg '$arg' && printf '%s|%s' \"\$_GERRIT_CHANGE\" \"\$_GERRIT_PS\"")
        chk "$sh：$arg -> change/patchset" "$out" "$want_ch|$want_ps"
    done

    out=$(run_in "$sh" "_gg_parse_change_arg abc; echo rc=\$?")
    case $out in
        *rc=2*) ok "$sh：乱输的 change 号退出码 2" ;;
        *) bad "$sh：乱输时退出码不对 [$out]" ;;
    esac
    case $out in
        *patchset*) ok "$sh：报错里给了用法" ;;
        *) bad "$sh：报错里没给用法 [$out]" ;;
    esac

    out=$(run_in "$sh" "_gg_parse_change_arg 1234 x; echo rc=\$?")
    case $out in
        *rc=2*) ok "$sh：patchset 不是数字也拒绝" ;;
        *) bad "$sh：patchset 校验没生效 [$out]" ;;
    esac

    # --- 在一个真的 repo 工作区里：client.conf 要能被找到 ---
    # （这条是防"env.bash 里错用了别的项目的函数"那类 bug 的：
    #   第一次搬过来时 bash 版调了 tools/repo 的 css，于是找不到 .repo）
    mkdir -p "$T/ws/.repo/manifests" "$T/ws/.gerrit"
    cat > "$T/ws/.repo/manifests/default.xml" <<'X'
<?xml version="1.0"?>
<manifest><remote name="r" fetch="ssh://x/"/><default revision="main" remote="r"/></manifest>
X
    ln -sfn manifests/default.xml "$T/ws/.repo/manifest.xml"
    cat > "$T/ws/.gerrit/client.conf" <<'X'
host=127.0.0.1
port=29418
user=dsh-agent
X
    out=$( cd "$T/ws" && WTOOL_PROJECT_DIR="$proj" HOME="$T" "$sh" -c         "unset WTOOL_GERRIT_HOST WTOOL_GERRIT_PORT WTOOL_GERRIT_USER
         . \"$proj/env.$sh\"
         _gg_resolve && printf '%s@%s:%s' \"\$_GERRIT_USER\" \"\$_GERRIT_HOST\" \"\$_GERRIT_PORT\"" 2>&1 )
    chk "$sh：工作区里的 client.conf 能被读到" "$out" "dsh-agent@127.0.0.1:29418"

    # --- 没有服务器信息时要报清楚，而不是静默失败 ---
    out=$(run_in "$sh" "_gg_resolve; echo rc=\$?")
    case $out in
        *rc=1*) ok "$sh：没有服务器信息时退出码 1" ;;
        *) bad "$sh：没有服务器信息时行为不对 [$out]" ;;
    esac
    case $out in
        *gerrit-gate*|*WTOOL_GERRIT_HOST*) ok "$sh：报错里告诉你怎么配" ;;
        *) bad "$sh：报错没给办法 [$out]" ;;
    esac
done

printf '\n%d 通过, %d 失败\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
