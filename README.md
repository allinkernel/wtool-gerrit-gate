# tools/gerrit-gate —— 检视闸门（docker 里的 Gerrit）

一句话：**给任意 repo 工作区装一台本机 Gerrit**（web UI 就是 PolyGerrit），
改动先推 `refs/for/main`，人 +2 并 submit 之后才允许推回 GitHub。

```
ds_dev 分支 --git push polygerrit HEAD:refs/for/main--> Gerrit change
                                                            │ 人在网页上 Code-Review +2
                                                            ▼
                                              submit（合并进 Gerrit 的 main）
                                                            │  gchk <change> == 0
                                                            ▼
                                                推回 GitHub 的 main
```

每个 repo 工作区一台自己的 Gerrit，状态全在 `<工作区>/.gerrit/` 里。

## 安装

一句话：`wtool install tools/gerrit-gate`。

下载与安装的**唯一入口**在 GitHub 上：

> **[wtool-base/README.md](https://github.com/allinkernel/wtool/blob/main/README.md)**

（URL 由清单 `.repo/manifests/default.xml` 里的 remote `ssh://git@github.com/`
+ 项目名 `allinkernel/wtool.git` + 默认 revision `main` 拼出，不是猜的。）

* **不要手工跑 `scripts/install.sh`** —— 它是给 wtool 调用的：`wtool install` 在通用机制
  （rc 里的 env 块）之后调它，只做 `wtool.xml` 表达不了的那件事 —— 把 `bin/gerrit-gate`
  软链进 `$WTOOL_PREFIX/bin`（那个目录已在 `PATH` 上）。`wtool uninstall` 会用
  `--uninstall` 反向调一次。
* 装完只是**有命令了**：容器、镜像、卷一个都不会产生 —— 那些是 `gerrit-gate all`
  那一步的事（见下）。
* 不想连源码都下载？清单里这个项目带着 `groups="gerrit"`：
  `repo init -g all,-gerrit ...` 就不会下载它。

## 功能说明

### 一、它提供什么

| 东西 | 是什么 | 谁产生 | 进 git 吗 |
|---|---|---|---|
| `gerrit-gate` 命令 | 服务端编排（起容器、建账号、导仓库、接线） | `wtool install` 软链 | **是**（源码） |
| `ggcp` / `gchk` / `gq` / `gpush` | 日常送检 / 检查的 shell 函数（zsh + bash 各一份） | rc 里的 env 块 source | **是** |
| 容器 | `gerrit-<工作区名>`，跑 Gerrit | `gerrit-gate up`（`docker run`，镜像从 Docker Hub 拉） | 否 |
| 站点数据 | 7 个 docker 命名卷 | 同上 | 否 |
| 客户端状态 | `<工作区>/.gerrit/`（~30KB） | `gerrit-gate setup` | 否（工作区根不是仓库） |

仓库里**只有文本**（脚本 + CSS + 文档），**一个二进制都没有**；没有 tar、没有离线包、
没有 base64。换机器时镜像由 registry 提供。

### 二、命令

工作区参数 `[工作区]` 可以省略 —— 不给就**从当前目录往上找 `.repo`**。
任何子命令都可以加 `--dry-run` 先看要做什么。

#### 会动手的子命令

| 命令 | 做什么 |
|---|---|
| `gerrit-gate all [工作区]` | 一条龙：`up` → `bootstrap` → `import` → `setup`，最后再 `open` 一次打印链接（幂等） |
| `gerrit-gate up [工作区]` | 起/建容器。加 `--recreate` 删了重建（**数据在卷里，不丢**）。已有容器则 `docker start`；建完等就绪，**90 秒**起不来就报错并让你看 `docker logs` |
| `gerrit-gate bootstrap [工作区]` | 建账号、发密钥、配权限（幂等）。见「账号与权限」 |
| `gerrit-gate import [工作区]` | 给清单里每个仓库建 Gerrit 项目 + 把 `main` 导进去（幂等）。浅克隆的仓库会**跳过**（git 不允许从浅克隆推）；清单仓自己是浅克隆时会先试补历史、补不全就临时克隆一份完整的来推；`gate.conf` 的 `skip` 列表里的路径跳过 |
| `gerrit-gate setup [工作区]` | 把工作区接到 Gerrit：每个仓库加 `polygerrit` remote、建 `ds_dev` 分支（从当前 HEAD 拉，建完切过去 —— 用 `--no-checkout` 可以不切）、装 `commit-msg` hook（从 Gerrit 的 `/tools/hooks/commit-msg` 下，**已经有了就不动**）、写 `.gerrit/client.conf` |
| `gerrit-gate theme [工作区] [主题]` | 换 UI 主题；**不带主题名 = 列出可选的**。⚠️ 位置参数顺序是「**主题名** [工作区]**」**，和别的子命令相反；可以组合：`gerrit-gate theme compact+dark`。换完要刷浏览器（Ctrl-Shift-R） |

#### 只读的子命令（不会写脏别的 agent 的工作区）

| 命令 | 做什么 |
|---|---|
| `gerrit-gate status [工作区]` | 体检：工作区 / 实例 / 端口 / 卷 / 容器状态 / 账号 / 项目数 / 接线 / 主题，并打印登录与待检视链接 |
| `gerrit-gate open [工作区]` | 只打印登录链接、待检视链接、全部 open 的列表 |
| `gerrit-gate list` | 列出 `~/self/*` 和 `~/*/self/*` 下**装了闸门**的工作区（容器名 + 状态 + 网页地址）。不需要工作区参数 |
| `gerrit-gate help` | 用法 |

> `status` / `open` 是只读的 —— 别的 agent 的工作区不该被写脏，
> 所以它俩**不会**生成 `.gerrit/gate.conf`。

#### 全局选项

| 选项 | 作用 |
|---|---|
| `--dry-run` | 只说要做什么，不动手 |
| `--recreate` | 删了容器重建（只对 `up` 有意义） |
| `--no-checkout` | `setup` 时**不**把各仓库切到 `ds_dev`（分支照样建，只是不改你当前所在的分支） |
| `-h` / `--help` | 用法 |

### 三、一台实例长什么样

```
docker run -d --name gerrit-<工作区名> --restart unless-stopped
  --label gerrit-gate.workspace=<工作区绝对路径>
  -p 127.0.0.1:<web>:8080  -p 127.0.0.1:<ssh>:29418     # 只绑本机，不暴露
  -v <实例>-git:/var/gerrit/git  ... 共 7 个命名卷
  -v <工作区>:/workspace:ro                              # 只读挂进去
  -e CANONICAL_WEB_URL=http://127.0.0.1:<web>/
  -e HTTPD_LISTEN_URL=http://0.0.0.0:8080/
  gerritcodereview/gerrit:3.14.3-ubuntu24
```

* 7 个卷的名字是 `<实例>-{git,etc,db,index,cache,plugins,static}`，
  分别挂到容器里的 `/var/gerrit/<同名>`。
* 端口从 `8080` / `29418` 往上找第一对空闲的（`gerrit-gate list` 看所有实例）。
* 实例配置在 `<工作区>/.gerrit/gate.conf`，**可以手改**（改完再跑 `gerrit-gate up`）：

  | 键 | 含义 |
  |---|---|
  | `container` | 容器名（数据在卷里，容器删了不丢） |
  | `web_port` / `ssh_port` | 网页端口 / ssh 端口 |
  | `volumes` | 卷名前缀 |
  | `image` | 镜像 |
  | `reviewer` | 人（+2 的那个）的账号名 |
  | `agent` | 助手账号名 |
  | `skip` | 不导入 gerrit 的项目路径（空格分隔） |

### 四、账号与权限

* 账号存在 `All-Users.git`（在 git 卷里）。
* `admin` —— Gerrit init 建的**引导账号**。它的 ssh key 不能走正常流程加，
  只能**停机时直接写 NoteDb** 塞进去（`bootstrap` 就是这么干的：往
  `All-Users.git` 的 `refs/users` 写 `authorized_keys`，然后重启）。
* `reviewer`（默认 `mindul`）—— 进 `Administrators` 组，负责在网页上 +2。
* `agent`（默认 `dsh-agent`）—— 只能推 `refs/for/*`；它的私钥在
  `<工作区>/.gerrit/keys/<agent>_rsa`，`ggcp` / `gpush` 用它连 Gerrit。
* `bootstrap` 会把助手和工作区里各仓库自己的 git 身份邮箱登记到 agent 名下。
* ACL 是这么改的：`refs/heads/*` 上 **push = Administrators**、
  **submit = Registered Users**。
* **闸门本体**是 `Code-Review +2` 这个 **submit-requirement**，不是 submit 权限：
  没有 +2，谁都 submit 不了（`tests/e2e-wtest.sh` 里有一条断言专门验这个）。

### 五、UI 主题

Gerrit 只允许用 **CSS 变量**改外观。所以 `theme` 装两样东西到卷里：

* `plugins/wtooltheme.js` —— 只装一次的插件（内容变了会重装并重启 Gerrit）；
* `static/wtool-theme.css` —— 主题本体，换主题 = 换这个文件。

内置主题在 `themes/`：`compact`（只动密度，不动颜色）、`dark`（Gerrit 自带深色配色，
文件头的 `/*wtool:force-dark*/` 是给插件看的标记）、`high-contrast`（黑白高对比）。
可以组合（`compact+dark`，按顺序拼）。细节和"dark.css 怎么重新生成"见 `themes/README.md`。

### 六、客户端命令（rc 里的 shell 函数）

`env.zsh` 和 `env.bash` **内容等价**（没装 zsh 的机器用 bash 那份）。

| 命令 | 用法 / 行为 |
|---|---|
| `ggcp <change> [patchset]` | 把 Gerrit 上的提交**抓回本地**：查 change → 从清单找到它属于哪个本地仓库 → `git fetch` 那个 ref → 校验抓到的 commit 和 Gerrit 报的一致 → `git cherry-pick`，最后停在对应仓库里。冲突会告诉你 `git cherry-pick --continue` / `--abort`；本地有未提交改动也会提示 |
| `gchk <change>` | **退出码 0 = 已经 +2 且已 merged**（也就是可以推回 GitHub 的 main 了）。没到就非 0 |
| `gq [-r] <change>` | 打 change 摘要；`-r` / `--raw` 打原始 JSON |
| `gpush [remote]` | 送检：`git push <remote> HEAD:refs/for/<分支>`，`remote` 默认 `polygerrit`。分支名优先按清单算（`my_repo.py branch_from_path`），算不出来才用当前分支 |

`<change>` 这几种写法都认：`1234`、`1234/2`、`1234,2`、`https://<host>/c/<项目>/+/1234/3`、
`https://<host>/#/c/1234/2`。

`my_repo.py` / `gerrit_query.py` 随项目走，**既不依赖 wtool 也不依赖别的项目**。

### 七、环境变量

服务器地址优先从**当前 repo 工作区**的 `.gerrit/client.conf` 读，环境变量可以覆盖：

| 变量 | 默认 | 作用 |
|---|---|---|
| `GERRIT_GATE_HOME` | 入口脚本所在目录（= 项目根） | 主题 / 插件 / python 小工具的相对根 |
| `GERRIT_GATE_IMAGE` | `gerritcodereview/gerrit:3.14.3-ubuntu24` | 用的镜像 |
| `GERRIT_GATE_WEB_BASE` | `8080` | 网页端口起点 |
| `GERRIT_GATE_SSH_BASE` | `29418` | ssh 端口起点 |
| `GERRIT_GATE_REVIEWER` | `mindul` | +2 的人（`reviewer`） |
| `GERRIT_GATE_AGENT` | `dsh-agent` | 助手账号（`agent`） |
| `WTOOL_GERRIT_HOST` / `_PORT` / `_USER` / `_SSH_KEY` | 空（读 `client.conf`） | 覆盖服务器地址 / 用户 / 私钥 |
| `WTOOL_GERRIT_CONF` | 空 | 直接指定 `client.conf` 的路径 |
| `WTOOL_PROJECT_DIR` | `$HOME/.wtool/wtool-work-dir/links/tools/gerrit-gate` | env 文件里 `GERRIT_GATE_DIR` 的来源 |

### 八、独占性与清理

| 你想 | 怎么做 |
|---|---|
| 只是不想用它 | 什么都不用做：不跑 `gerrit-gate all` 就没有容器/镜像 |
| 停掉但留着数据 | `docker stop <实例>` |
| 删容器（数据留着） | `docker rm -f <实例>` |
| 连站点数据一起删 | `docker volume rm <实例>-{git,etc,db,index,cache,plugins,static}` |
| 连镜像一起删 | `docker rmi gerritcodereview/gerrit:3.14.3-ubuntu24` |
| 只撤命令和 rc 块 | `wtool uninstall tools/gerrit-gate` |

`wtool uninstall` **只管命令和 rc 块，不碰 docker** —— 那是 docker 的地盘，
删容器/卷/镜像得你说了算。

### 九、依赖

`docker`、`bash`、`python3`、`git`、`ssh`（含 `ssh-keygen`）、`curl`。
**不需要 zsh**（这就是 `env.bash` 存在的理由）。全程只需要能连 Docker Hub。

## 在新机器上复现

```sh
# 1) 引擎（一次性）：见上面的「安装」里那个入口
# 2) 拿到这个项目并安装
repo sync tools/gerrit-gate          # 或 git clone 到 tools/gerrit-gate
wtool install tools/gerrit-gate      # 命令进 PATH、env 进 rc
# 3) 在任意 repo 工作区里一条龙
cd ~/self/<某个工作区>
gerrit-gate all                      # 拉镜像 → 起容器 → 建账号 → 导入仓库 → 建 ds_dev
gerrit-gate open                     # 打印你的登录链接，浏览器打开就能审
```

## 测试

```sh
sh tests/env_test.sh           # 22 条：env.zsh / env.bash 同一张用例表（不连网、不起容器）
sh tests/e2e-wtest.sh          # 造一个最小 repo 工作区跑全流程（会真起容器、拉镜像）
sh tests/e2e-wtest.sh --keep   # 跑完别停容器
```

`tests/e2e-wtest.sh` 的断言条数：**13 条**（3 个项目 × 2 条接线断言「有 polygerrit remote」
「有 ds_dev 分支」+ 7 条流程断言：commit-msg hook、push 拿到 change 号、gchk 对没 +2 的
change 返回非 0、服务端拒绝未 +2 的 submit、ggcp 落点、status、list）。

## 历史

这套东西最早是 wtool 项目内的 `bootstrap/scripts/gerrit/`（只服务 wtool 一个
工作区），后来提到用户级 `~/.local/share/gerrit-gate/`（能服务所有工作区，
但不在任何仓库里、没法复现），现在收编成这个独立项目。
`bootstrap/scripts/gerrit/` 那份是子集，可以删。
