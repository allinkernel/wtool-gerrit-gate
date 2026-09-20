#!/bin/sh
# install.sh —— 把 gerrit-gate 挂到用户的 PATH 和 shell 里（幂等）
#
# 用户级目录（~/.local/bin、~/.zshrc）只有装机时写一次；跑在沙箱里的 agent
# 通常写不了 $HOME，所以这一步由你（人）跑，或者让 agent 申请提权跑。
#
#   sh ~/.local/share/gerrit-gate/install.sh
#
# 做三件事：
#   1. ~/.local/bin/gerrit-gate -> 这份目录的 gerrit-gate.sh
#   2. ~/.zshrc 里加一段受管块，source gerrit.zsh（ggcp/gchk/gq/gpush）
#   3. 修一下权限
set -eu

here=$(cd -- "$(dirname -- "$0")" && pwd)
changed=0

# 1) 入口
mkdir -p "$HOME/.local/bin"
target="$HOME/.local/bin/gerrit-gate"
if [ -L "$target" ] && [ "$(readlink -f "$target")" = "$here/gerrit-gate.sh" ]; then
    echo "==> $target 已经指向这里"
else
    ln -sfn "$here/gerrit-gate.sh" "$target"
    echo "==> 建了 $target -> $here/gerrit-gate.sh"
    changed=1
fi

# 2) zsh 块
ZSHRC=${ZDOTDIR:-$HOME}/.zshrc
block_begin="# >>> gerrit-gate（检视闸门：ggcp / gchk / gq / gpush）>>>"
if [ -f "$ZSHRC" ] && grep -qF "$block_begin" "$ZSHRC"; then
    echo "==> $ZSHRC 里已经有 gerrit-gate 块"
else
    cat >> "$ZSHRC" <<EOF

$block_begin
[ -r "$here/gerrit.zsh" ] && . "$here/gerrit.zsh"
# <<< gerrit-gate <<<
EOF
    echo "==> 往 $ZSHRC 加了 gerrit-gate 块（想撤就把这块删掉）"
    changed=1
fi

# 3) 权限
chmod 755 "$here" "$here/tests" 2>/dev/null || true
chmod 755 "$here"/gerrit-gate.sh "$here"/install.sh "$here"/lib.sh "$here"/gerrit.zsh \
          "$here"/my_repo.py "$here"/gerrit_query.py "$here"/tests/*.sh 2>/dev/null || true
chmod 644 "$here"/README.md 2>/dev/null || true

case :$PATH: in
    *:$HOME/.local/bin:*) ;;
    *) echo "!! $HOME/.local/bin 不在 PATH 里，自己加一下" ;;
esac

if [ "$changed" = 1 ]; then
    echo "==> 装好了。新开一个 shell（或 source ~/.zshrc）之后：gerrit-gate help"
else
    echo "==> 本来就是好的，没动任何东西"
fi

echo
echo "下一步：站在任意 repo 工作区里跑"
echo "    gerrit-gate status        # 看有没有闸门"
echo "    gerrit-gate all           # 没有就装一台（起 Gerrit、导入、建 ds_dev）"
