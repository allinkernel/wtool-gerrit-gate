# gerrit-gate —— 用户级"检视闸门"

**给任何 repo 管理的工作区装一道 Gerrit 检视闸门**：改动先推到本机 Gerrit
（`refs/for/main`），人 +2 并 submit 之后，才允许推回 GitHub。

它不是某个项目的配置，是**用户级**的：

| 在哪 | 是什么 |
|---|---|
| `~/.local/share/gerrit-gate/` | 工具本体（这份目录） |
| `~/.local/bin/gerrit-gate` | 入口（软链到上面） |
| `~/.dsh/AGENTS.md` | **给所有 agent 看的规则**：在 repo 工作区里该怎么做 |
| `~/.zshrc` 里的 `gerrit-gate` 块 | 交互命令 `ggcp` / `gchk` / `gq` / `gpush` |
| `<工作区>/.gerrit/` | **运行期状态**：实例配置、两把 ssh key、客户端配置、admin 密码 |

**运行期状态一律放工作区里**，因为给 agent 用的沙箱通常只允许它写自己的
workspace —— 这样任何 agent 在自己的工作区里就能把闸门装起来，不需要写 `$HOME`。

## 一条命令装好

```sh
cd <任意 repo 工作区>            # 往上能找到 .repo 的那种
gerrit-gate all                 # up + bootstrap + import + setup（幂等，随时可重跑）
```

跑完它会打印你的登录链接。之后：

```sh
gerrit-gate status              # 体检：容器/账号/项目/接线 + 链接
gerrit-gate open                # 只要链接
gerrit-gate list                # ~/self/* 下装了闸门的工作区都列出来
```

## 日常流程

```sh
cd <某个仓库>                    # 每个仓库都有 ds_dev 分支，改动写在它上面
git add -A && git commit         # Change-Id 由 commit-msg hook 补
git push polygerrit HEAD:refs/for/main    # 送检，输出里就有 change 链接
gchk <change>                    # 退出码 0 = 人已 +2 且已 merged
```

`gchk` 返回 0 之后，才把 Gerrit 的 main 推回 GitHub：

```sh
cd <某个仓库>
git fetch polygerrit main
git push origin FETCH_HEAD:main          # remote 名看 git remote -v
```

**清单仓例外**：Gerrit 的 `main` 对应 GitHub 上的清单分支（wtool 是 `wtool`）：

```sh
cd <工作区>/.repo/manifests
git fetch polygerrit main
git push origin FETCH_HEAD:wtool
```

## 每个工作区一台自己的 Gerrit

| 东西 | 默认 | 说明 |
|---|---|---|
| 容器 | `gerrit-<工作区名>` | `--restart unless-stopped`；也可以在一份配置里改成别的名字 |
| 端口 | 8080/29418 起，第一对空闲的 | **只绑 127.0.0.1**，不暴露到局域网 |
| 卷 | `gerrit-<工作区名>-{git,etc,db,index,cache}` | 站点数据；容器删了数据还在 |
| 镜像 | `gerritcodereview/gerrit:3.14.3-ubuntu24` | 官方镜像，自带 JDK21 |
| 挂载 | `<工作区>:/workspace:ro` | 只读挂进去 |

覆盖默认值就改 `<工作区>/.gerrit/gate.conf`（`gerrit-gate all` 第一次会生成它）：

```sh
container=docker24          # wtool 沿用了当年手起的容器
web_port=8080
ssh_port=29418
volumes=docker24
keys_dir=/home/mindul/self/wtool/.gerrit/keys
reviewer=mindul             # 人（+2 的那个）
agent=dsh-agent             # 助手账号
skip=editor/astronvim_v5/nvim shell/oh-my-zsh   # 不导入的项目
```

> 镜像在 Dockerfile 里声明了 `VOLUME /var/gerrit/{git,etc,db,index,cache}`。
> 不显式给命名卷，docker 会给这些子路径各建一个**匿名卷**把它们盖住：
> 站点数据在匿名卷里，你以为挂上的命名卷是空的，下次删容器就找不着了。
> 所以这里五个路径都显式给卷。

## 账号与权限模型

| 账号 | 是谁 | 能干什么 |
|---|---|---|
| `admin` | 引导账号（Gerrit init 建的） | 管服务器、导入历史。日常不用它 |
| `reviewer`（默认 `mindul`） | **人** | Administrators：能 +2、能 submit |
| `agent`（默认 `dsh-agent`） | 助手 | **只能推 `refs/for/*`**，推不了 `refs/heads/*` |

闸门不是"submit 权限"，是 **Code-Review +2 这个 submit-requirement**：

```
[submit-requirement "Code-Review"]
    submittableIf = label:Code-Review=MAX AND -label:Code-Review=MIN
```

默认 ACL 里只有 Administrators 能投 +2。`submit` 权限虽然放给了 Registered Users，
但**没有 +2 谁都 submit 不了**（助手试过，Gerrit 回的是
`Change N is not ready: submit requirement 'Code-Review' is unsatisfied.`）。

登录：`http://127.0.0.1:<web_port>/login/?user_name=<reviewer>`
（dev 模式，账号由 `bootstrap` 建好，点进去就是你自己）

## 命令速查

| 命令 | 作用 |
|---|---|
| `gerrit-gate all [ws]` | 一条龙：起容器 + 账号权限 + 导入 + 接线 |
| `gerrit-gate up [ws]` | 起/建容器（幂等） |
| `gerrit-gate bootstrap [ws]` | 账号、密钥、ACL |
| `gerrit-gate import [ws]` | 每个仓库建项目 + 导入当前分支到 `<branch>` |
| `gerrit-gate setup [ws]` | 每个仓库加 `polygerrit` remote + `ds_dev` + `commit-msg` hook |
| `gerrit-gate status [ws]` | 体检 + 给用户的链接 |
| `gerrit-gate open [ws]` / `list` | 链接 / 所有实例 |
| `ggcp <change> [patchset]` | 把 Gerrit 上的提交抓回本地并 cherry-pick（自动 cd 到对应仓库） |
| `gchk <change>` | +2 了没 / merged 了没（0 = 可以推 main） |
| `gq [-r] <change>` | change 摘要 / 原始 JSON |
| `gpush [remote]` | 推当前 HEAD 到 `refs/for/<清单声明的分支>` |

`ggcp` 认这几种写法：`ggcp 1234`、`ggcp 1234 1`、`ggcp 1234/2`、
`https://host/c/proj/+/1234/2`、老式 `https://host/#/c/1234/2`。
**patchset 不猜**：不给就用 current，指定的不存在就报"现有: 1,2"。

## 测试

```sh
sh ~/.local/share/gerrit-gate/tests/e2e-wtest.sh          # 跑完停容器
sh ~/.local/share/gerrit-gate/tests/e2e-wtest.sh --keep    # 跑完留着
```

它会在 `~/self/wtest` 造一个最小的 repo 工作区（清单 + hello/world 两个仓库 +
本地裸仓当 GitHub），**完全走用户级工具**装一遍闸门，然后验：
接线（remote/ds_dev/hook）→ 送检拿到 change → `gchk` 说没 +2 →
助手 submit 被服务端拒 → `ggcp` 抓回本地 cherry-pick → `status`/`list`。

## 排错

| 现象 | 原因 / 怎么办 |
|---|---|
| `gerrit-gate: 当前目录往上找不到 .repo` | 站错地方了；或者显式给工作区：`gerrit-gate status ~/self/wblog` |
| 容器起不来 | `docker logs gerrit-<ws>`；端口被占的话改 `.gerrit/gate.conf` 里的 `web_port`/`ssh_port` |
| `ggcp` 说"没有 gerrit 服务器信息" | 这个工作区还没 `gerrit-gate setup`，或者不在工作区里 |
| `git push polygerrit` 报 `email not registered` | 你的 git 邮箱没登记到 agent 账号上；`gerrit-gate bootstrap` 会登记 `git config --global user.email` |
| 某个仓库推不进 Gerrit | 看 `import` 的输出：浅克隆（git 不允许从浅克隆推）/ 上游镜像里可能有 JGit 不收的老对象（零填充 filemode）；这类项目写进 `.gerrit/gate.conf` 的 `skip` |
| 切换/新增项目后 | `gerrit-gate import && gerrit-gate setup`（都是幂等的） |

## 和 wtool 仓库里那份的关系

wtool 仓库里还有一份早期的**项目内**版本（`bootstrap/scripts/gerrit/`，
`up.sh` / `bootstrap.sh` / `import.sh` / `local-setup.sh`，已作为 Gerrit change 23 送检）。
它只服务 wtool 一个工作区，容器名/端口/卷名都写死在文档里；
功能是用户级这套的子集。

**以用户级这份（`gerrit-gate`）为准。** 项目内那份留着当"想在自己项目里也带一套"
的参考，将来可以删掉。

## 已知边界

- 只支持 **Gerrit 官方 docker 镜像 + DEVELOPMENT_BECOME_ANY_ACCOUNT**（本机自用）。
  要对外的服务器别用这套。
- 每个工作区一台 Gerrit，一共 N 台容器，每台约 1GB 内存。
- "把 Gerrit 的 main 推回 GitHub" 目前是手动（或 agent 手动）两步，
  没做 replication 插件自动同步。
- 工具本身没有远端仓库（用户级配置），本目录里 `git init` 过一份，
  改动可以 `git log` 看历史。
