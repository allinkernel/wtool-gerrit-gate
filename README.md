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

## 为什么是独立项目

* **不装它 = 没有 `gerrit-gate` 命令，也没有任何容器/镜像**。
* 仓库里**只有文本**（脚本 + CSS + 文档，约 60KB），**一个二进制都没有**。
* 镜像从 Docker Hub 拉，站点数据在 docker 命名卷里，都不进仓库。

```sh
wtool install tools/gerrit-gate     # -> $WTOOL_PREFIX/bin/gerrit-gate + rc 里的 env 块
wtool uninstall tools/gerrit-gate   # 反过来撤掉（容器/卷是 docker 的东西，见下）
```

不想连源码都下载？清单里这个项目带着 `groups="gerrit"`：

```sh
repo init -g all,-gerrit ...        # 不下载检视闸门这套
```

## 技术细节：这套东西到底由什么组成

| 东西 | 放在哪 | 实测大小 | 谁产生 | 进 git 吗 |
|---|---|---|---|---|
| 工具源码 | 本项目仓库 | ~60KB 文本 | —— | **是** |
| 容器镜像 | Docker Hub `gerritcodereview/gerrit:3.14.3-ubuntu24` | 1.21GB（解包后） | `gerrit-gate up` 时由 docker 拉 | 否 |
| 容器可写层 | docker 自己的存储 | 约 90MB | 同上 | 否 |
| 站点数据 | docker 命名卷 `<实例>-{git,etc,db,index,cache,plugins,static}` | 起手约 9MB，随仓库/评审长大 | `gerrit-gate all` | 否 |
| 客户端状态 | `<工作区>/.gerrit/`（keys、client.conf、gate.conf、admin 密码） | ~30KB | `gerrit-gate setup` | 否（工作区根不是仓库） |

**镜像不是以二进制形式保存的**：`up` 那一步就是 `docker run <镜像标签>`，
仓库里没有 tar、没有离线包、没有 base64。换机器时镜像由 registry 提供。

### 一台实例的构成

```
docker run -d --name gerrit-<工作区名> --restart unless-stopped
  -p 127.0.0.1:<web>:8080  -p 127.0.0.1:<ssh>:29418     # 只绑本机，不暴露
  -v <实例>-git:/var/gerrit/git   ...   共 7 个命名卷（git etc db index cache plugins static）
  -v <工作区>:/workspace:ro                              # 只读挂进去，方便在容器里对着清单干活
  -e CANONICAL_WEB_URL=http://127.0.0.1:<web>/
  gerritcodereview/gerrit:3.14.3-ubuntu24
```

* 端口从 8080/29418 往上找第一对空闲的（`gerrit-gate list` 看所有实例）
* 实例配置在 `<工作区>/.gerrit/gate.conf`（容器名、端口、卷名、skip 列表…），
  可以手改；wtool 那台沿用了当初手起的 `docker24`
* **账号与权限**：账号存在 `All-Users.git`（在 git 卷里）；`admin` 是 init 建的
  引导账号（它的 ssh key 只能停机时直接写 NoteDb 塞进去），`reviewer`
  （默认 `mindul`）进 Administrators 负责 +2，`agent`（默认 `dsh-agent`）
  只能推 `refs/for/*`
* **闸门本体**是 `Code-Review +2` 这个 submit-requirement，不是 submit 权限：
  没有 +2，谁都 submit 不了
* **UI 主题**：Gerrit 只允许用 CSS 变量改外观，所以有一个只装一次的插件
  `plugins/wtooltheme.js` + 一个 `static/wtool-theme.css`（都在卷里）；
  换主题 = 换那个 CSS 文件，刷新浏览器即可

### 客户端

| 命令 | 作用 |
|---|---|
| `gerrit-gate up/bootstrap/import/setup/all/status/open/list/theme` | 服务端 |
| `ggcp <change> [patchset]` | 把 Gerrit 上的提交抓回本地、cd 到对应仓库、cherry-pick |
| `gchk <change>` | +2 了没 / merged 了没（退出码 0 = 可以推 main） |
| `gq [-r] <change>` / `gpush` | 摘要 / 送检 |

后四个是 `env.zsh` / `env.bash` 里的函数（**两个 shell 各一份、内容等价** ——
没装 zsh 的机器也能用）。`my_repo.py` / `gerrit_query.py` 随项目走，
既不依赖 wtool 也不依赖别的项目。

服务器地址从"当前 repo 工作区"的 `.gerrit/client.conf` 读，
也可以用 `WTOOL_GERRIT_HOST` / `_PORT` / `_USER` / `_SSH_KEY` 覆盖。

## 在新机器上复现

```sh
# 1) 引擎（一次性）：见 wtool-base 的 README / guide
# 2) 拿到这个项目并安装
repo sync tools/gerrit-gate          # 或 git clone 到 tools/gerrit-gate
wtool install tools/gerrit-gate      # 命令进 PATH、env 进 rc
# 3) 在任意 repo 工作区里一条龙
cd ~/self/<某个工作区>
gerrit-gate all                      # 拉镜像 → 起容器 → 建账号 → 导入仓库 → 建 ds_dev
gerrit-gate open                     # 打印你的登录链接，浏览器打开就能审
```

依赖：`docker`、`bash`、`python3`、`git`、`ssh`、`curl`。
**不需要 zsh**（这就是 env.bash 存在的理由）。全程只需要能连 Docker Hub。

## 独占性与清理

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

## 测试

```sh
sh tests/e2e-wtest.sh          # 造一个最小 repo 工作区，全流程 13 条断言（会真起容器）
sh tests/e2e-wtest.sh --keep   # 跑完别停容器
sh tests/env_test.sh           # env.zsh / env.bash 同一张用例表（不连网）
```

## 历史

这套东西最早是 wtool 项目内的 `bootstrap/scripts/gerrit/`（只服务 wtool 一个
工作区），后来提到用户级 `~/.local/share/gerrit-gate/`（能服务所有工作区，
但不在任何仓库里、没法复现），现在收编成这个独立项目。
`bootstrap/scripts/gerrit/` 那份是子集，可以删。
