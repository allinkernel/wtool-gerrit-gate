#!/bin/sh
# e2e-wtest.sh —— 用户级 gerrit-gate 的端到端测试
#
# 造一个最小的 repo 工作区 ~/self/wtest（清单 + 两个小仓库 + 本地裸仓当 GitHub），
# 然后**完全走用户级工具**把闸门装起来并验一遍：
#
#   1. gerrit-gate all        → 起一台自己的 Gerrit（gerrit-wtest，端口自动分配）
#   2. 每个仓库有 ds_dev / polygerrit remote / commit-msg hook
#   3. 造一个改动推 refs/for/main → 拿到 change 号
#   4. gchk 说"还没 +2"（退出码 1）
#   5. 助手账号 submit 被拒（闸门真的在服务端）
#   6. ggcp 把那个 change 抓回本地并 cherry-pick 到临时分支
#   7. gerrit-gate status 体检通过
#
# 用法：sh e2e-wtest.sh [--keep]
#   默认跑完把容器停掉（数据留着）；--keep 保持运行
set -eu

here=$(cd -- "$(dirname -- "$0")" && pwd)
TOOL=$here/../gerrit-gate.sh
WS=${GERRIT_GATE_TEST_WS:-$HOME/self/wtest}
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

pass=0; fail=0
ok ()  { pass=$((pass + 1)); printf '  ok   %s\n' "$*"; }
bad () { fail=$((fail + 1)); printf '  FAIL %s\n' "$*"; }
chk () { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1（期望 [$3] 实际 [$2]）"; fi; }

# ---------------------------------------------------------------------------
# 1. 造工作区
# ---------------------------------------------------------------------------
# 提交身份：优先用全局 git 身份（gerrit-gate bootstrap 会把它登记到 agent
# 账号上，推送才不会被 "email not registered" 拒掉）；没有全局身份就退回夹具身份
GIT_NAME=$(git config --global user.name 2>/dev/null || echo wtest)
GIT_EMAIL=$(git config --global user.email 2>/dev/null || echo wtest@example.com)

make_project () {   # <名字>
    name=$1
    mkdir -p "$WS/$name"
    if [ ! -d "$WS/$name/.git" ]; then
        git -C "$WS/$name" init -q -b main
        git -C "$WS/$name" config user.name "$GIT_NAME"
        git -C "$WS/$name" config user.email "$GIT_EMAIL"
        printf '# %s\n\nwtest 的示例仓库。\n' "$name" > "$WS/$name/README.md"
        git -C "$WS/$name" add -A
        git -C "$WS/$name" commit -q -m "init $name"
    fi
    if [ ! -d "$WS/.origins/$name.git" ]; then
        git init -q --bare "$WS/.origins/$name.git"
        git -C "$WS/$name" remote add origin "$WS/.origins/$name.git" 2>/dev/null || true
        git -C "$WS/$name" push -q origin main
    fi
}

if [ ! -d "$WS/.repo" ]; then
    echo "== 造工作区 $WS =="
    mkdir -p "$WS/.repo/manifests" "$WS/.origins"
    make_project hello
    make_project world

    cat > "$WS/.repo/manifests/default.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!-- wtest：gerrit-gate 的端到端测试工作区 -->
<manifest>
    <remote name="local" fetch="file://$WS/.origins/" />
    <default revision="main" remote="local" sync-j="4" />

    <project path="hello" name="hello.git" groups="demo" />
    <project path="world" name="world.git" groups="demo" />
</manifest>
EOF
    ln -sfn manifests/default.xml "$WS/.repo/manifest.xml"

    if [ ! -d "$WS/.repo/manifests/.git" ]; then
        git -C "$WS/.repo/manifests" init -q -b default
        git -C "$WS/.repo/manifests" add -A
        git -C "$WS/.repo/manifests" -c user.name=wtest -c user.email=wtest@example.com \
            commit -q -m "wtest: 清单"
        git init -q --bare "$WS/.origins/wtest-manifests.git"
        git -C "$WS/.repo/manifests" remote add origin "$WS/.origins/wtest-manifests.git"
        git -C "$WS/.repo/manifests" push -q origin default:main
        git -C "$WS/.repo/manifests" fetch -q origin main
        git -C "$WS/.repo/manifests" branch -q --set-upstream-to=origin/main default 2>/dev/null || true
    fi
else
    echo "== 复用已有工作区 $WS =="
fi

# ---------------------------------------------------------------------------
# 2. 用户级工具：一条龙装闸门
# ---------------------------------------------------------------------------
echo "== gerrit-gate all =="
sh "$TOOL" all "$WS" 2>&1 | sed 's/^/  | /'

web=$(sed -n 's/^web_port=//p' "$WS/.gerrit/gate.conf")
ssh_port=$(sed -n 's/^ssh_port=//p' "$WS/.gerrit/gate.conf")
container=$(sed -n 's/^container=//p' "$WS/.gerrit/gate.conf")
echo "== 实例：$container 网页:$web ssh:$ssh_port =="

# ---------------------------------------------------------------------------
# 3. 接线检查
# ---------------------------------------------------------------------------
for p in hello world .repo/manifests; do
    d="$WS/$p"
    [ -d "$d/.git" ] || continue
    if git -C "$d" remote get-url polygerrit >/dev/null 2>&1; then
        ok "$p 有 polygerrit remote"
    else
        bad "$p 缺 polygerrit remote"
    fi
    if git -C "$d" show-ref --verify --quiet refs/heads/ds_dev; then
        ok "$p 有 ds_dev 分支"
    else
        bad "$p 缺 ds_dev 分支"
    fi
done
[ -x "$WS/hello/.git/hooks/commit-msg" ] && ok "commit-msg hook 装好了" || bad "commit-msg hook 没装"

# ---------------------------------------------------------------------------
# 4. 送检 → gchk → 服务端闸门
# ---------------------------------------------------------------------------
export GERRIT_GATE_HOME=$(cd -- "$here/.." && pwd)
ZSH_BIN=${ZSH_BIN:-zsh}
echo "== 在 hello 里造一个改动并送检 =="
cd "$WS/hello"
git checkout -q ds_dev
# 测试夹具可以随便重置：让每次跑都是"从 main 上一个干净的新提交"
git reset -q --hard main
git config user.name "$GIT_NAME"
git config user.email "$GIT_EMAIL"
printf 'change %s\n' "$(date +%s)" > change.txt
git add -A
git commit -q -m "wtest: 送检改动"
push_out=$(GIT_SSH_COMMAND="ssh -i $WS/.gerrit/keys/dsh-agent_rsa -o StrictHostKeyChecking=no -o LogLevel=ERROR -p $ssh_port" \
    git push polygerrit HEAD:refs/for/main 2>&1) || true
change=$(printf '%s' "$push_out" | sed -n 's#.*/+/\([0-9]\+\).*#\1#p' | head -1)
if [ -n "$change" ]; then
    ok "push refs/for/main 拿到 change $change"
else
    bad "没拿到 change 号：$push_out"
fi

if [ -n "$change" ]; then
    cd "$WS"
    if "$ZSH_BIN" -c "source $GERRIT_GATE_HOME/gerrit.zsh; gchk $change" >/dev/null 2>&1; then
        bad "gchk 对没 +2 的 change 不该返回 0"
    else
        ok "gchk 说还没 +2（退出码非 0）"
    fi

    echo "== 助手账号试 submit（应该被服务端拒绝）=="
    if ssh -i "$WS/.gerrit/keys/dsh-agent_rsa" -o StrictHostKeyChecking=no -o LogLevel=ERROR \
        -o BatchMode=yes -p "$ssh_port" dsh-agent@127.0.0.1 gerrit review "$change,1" --submit 2>&1 |
        grep -q "not ready\|not permitted\|submit requirement"; then
        ok "服务端拒绝了：没有 +2 谁都不进去"
    else
        bad "submit 居然没被拒（闸门有问题！）"
    fi

    echo "== ggcp 把 change 抓回本地 =="
    git -C "$WS/hello" checkout -q -B tmp-ggcp main
    if "$ZSH_BIN" -c "source $GERRIT_GATE_HOME/gerrit.zsh; cd $WS; ggcp $change 1" 2>&1 | tail -3; then
        if [ "$(git -C "$WS/hello" rev-parse --abbrev-ref HEAD)" = tmp-ggcp ] &&
           git -C "$WS/hello" log --oneline -1 | grep -q "wtest: 送检改动"; then
            ok "ggcp 抓回来并 cherry-pick 到 tmp-ggcp"
        else
            bad "ggcp 跑了但落点不对（HEAD=$(git -C "$WS/hello" rev-parse --abbrev-ref HEAD) tip=$(git -C "$WS/hello" log --oneline -1)）"
        fi
    else
        bad "ggcp 失败"
    fi
    git -C "$WS/hello" checkout -q ds_dev
fi

# ---------------------------------------------------------------------------
# 5. status
# ---------------------------------------------------------------------------
echo "== gerrit-gate status =="
sh "$TOOL" status "$WS" 2>&1 | sed 's/^/  | /'
if sh "$TOOL" status "$WS" 2>&1 | grep -q "每个仓库都有 polygerrit remote 和 ds_dev"; then
    ok "status 说接线完整"
else
    bad "status 没确认接线"
fi
if sh "$TOOL" list 2>&1 | grep -q "$WS"; then
    ok "gerrit-gate list 列出了这个工作区"
else
    bad "gerrit-gate list 没列出 $WS"
fi

if [ "$KEEP" = 0 ]; then
    echo "== 停掉测试容器（数据留着）=="
    docker stop "$container" >/dev/null
fi

printf '\n%d 通过, %d 失败\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
