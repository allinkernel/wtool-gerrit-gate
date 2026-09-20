#!/bin/sh
# install.sh —— wtool install 在通用机制（env 块）之后调用这个。
#
# 只做 wtool.xml 表达不了的那件事：把 bin/gerrit-gate 软链进 $WTOOL_PREFIX/bin。
# 那个目录已经在 PATH 上（引擎生成的环境块负责），所以做完这条
# `gerrit-gate` 就是一个普通命令了。
#
# 约定（同 tools/android_repack）：
#   * stdin 是 /dev/null —— 不写交互式提问
#   * 可重入 —— 重复跑不报错、不重复添加
#   * 不做不可逆的事
#
# 注意：**只装命令，不碰 docker**。容器/镜像/卷都是 `gerrit-gate all` 那一步
# 才产生的（而且都在工作区与 docker 自己的地盘里，不占这个仓库）。
set -eu

say() { printf '%s: %s\n' 'tools/gerrit-gate' "$*"; }

link_dir="$HOME/.wtool/links/tools/gerrit-gate"
src="$link_dir/bin/gerrit-gate"
dst="${WTOOL_PREFIX:-$HOME/.wtool/usr}/bin/gerrit-gate"

if [ "${1:-}" = "--uninstall" ]; then
    if [ -L "$dst" ]; then
        rm -f -- "$dst"
        say "已移除 $dst"
    fi
    # 顺手把 zsh/bash 的 gerrit-gate 块也撤掉？不 —— 那是引擎的 env 块，
    # wtool uninstall 会按 journal 逆放，这里别抢它的活。
    exit 0
fi

if [ ! -x "$src" ]; then
    say "警告：找不到 $src（wtool 的稳定链接还没建好？）"
    exit 0
fi

mkdir -p -- "$(dirname -- "$dst")"

if [ -L "$dst" ]; then
    cur=$(readlink -- "$dst" || true)
    if [ "$cur" != "$src" ]; then
        ln -sfn -- "$src" "$dst"
        say "软链已更正: $dst -> $src"
    else
        say "已经装好了: $dst"
    fi
elif [ -e "$dst" ]; then
    say "警告：$dst 已存在且不是软链，跳过（自己决定要不要删）"
else
    ln -s -- "$src" "$dst"
    say "已安装: $dst -> $src"
fi

say "下一步：进任意 repo 工作区跑 gerrit-gate status（没有闸门就 gerrit-gate all）"
