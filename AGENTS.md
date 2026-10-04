# AGENTS.md —— tools/gerrit-gate

> 先读用户级 `~/.dsh/AGENTS.md`（工作区通用规则）和仓库根 `AGENTS.md`（多仓库工作区规则），
> 本文件只讲**这个项目**的事。

## 这个项目是什么

给 repo 工作区装一道检视闸门：docker 里跑一台本机 Gerrit（web UI 就是 PolyGerrit），
改动先推 `refs/for/main`，人 +2 并 submit 之后才允许推回 GitHub。

| 文件 | 是干什么的 |
|---|---|
| `gerrit-gate.sh` | 服务端编排（`all` / `up` / `bootstrap` / `import` / `setup` / `theme` / `status` / `open` / `list`），用法见它的 `usage()` |
| `lib.sh` | 被 `gerrit-gate.sh` source 的公共函数（配置读写、docker/ssh/curl 封装、镜像源表） |
| `bin/gerrit-gate` | 命令入口；`scripts/install.sh` 把它软链进 `$WTOOL_PREFIX/bin` |
| `scripts/install.sh` | **只给 wtool 调用**：装/撤那条软链。不要手工跑 |
| `env.zsh` / `env.bash` | `ggcp` / `gchk` / `gq` / `gpush` 四个客户端函数，两份**内容等价** |
| `my_repo.py` / `gerrit_query.py` | 清单查询 / change 查询；随项目走，不依赖 wtool |
| `themes/*.css` + `theme-plugin.js` | UI 主题（Gerrit 只允许用 CSS 变量改外观） |
| `wtool.xml` | 清单（env 两块 + `publish kind="source"`） |
| `tests/` | `env_test.sh`（不连网）、`e2e-wtest.sh`（真起容器） |

## 铁律

1. **代码一有变化，必须在同一个提交里同步更新 `README.md`。**
   `README.md` 是**给用户的完整功能说明书**（不是开发笔记）。改了什么都对应得上：
   加/改子命令 → 「二、命令」；改 `docker run` 参数、卷名、端口 → 「三、一台实例长什么样」；
   改账号/ACL → 「四、账号与权限」；改 `env.*` 的函数 → 「六、客户端命令」；
   加环境变量 → 「七、环境变量」；改测试 → 「测试」。
   **README 与代码不一致 = 缺陷**，不是"以后补"。
   `gerrit-gate.sh` 的 `usage()` 是给终端用户的唯一用法来源，**它和 README 也要对得上**。

2. **README 里不写"怎么手工跑 `scripts/install.sh`"。** 安装只有一句话
   （`wtool install tools/gerrit-gate`）+ 一个链接到全局唯一下载/安装入口
   （GitHub 上 `wtool-base/README.md`）。`scripts/install.sh` 是 **wtool 调的**，
   它只做 wtool.xml 表达不了的事（软链 `bin/gerrit-gate`）。

3. **`env.zsh` 和 `env.bash` 必须同改。** 两个 shell 各一份、内容等价，
   `tests/env_test.sh` 用同一张用例表测两份。只改一份 = 装了一半。

4. **`status` / `open` 必须保持只读。** 别的 agent 的工作区不该被写脏 ——
   代码里刻意在 `gate_load` 时区分了「会动手的子命令才 `--create`」。

5. **仓库里只放文本。** 镜像从 Docker Hub 拉、站点数据在 docker 命名卷里、
   `<工作区>/.gerrit/` 在工作区根（不是 git 仓库）。**不要把 tar / 镜像 / 二进制提交进来。**

6. **`wtool uninstall` 不碰 docker。** 删容器/卷/镜像永远是用户自己说了算 ——
   别写成"卸载自动清理"。

## README 章节结构（改了对应内容就改对应章节）

| 章节 | 内容 |
|---|---|
| （开头） | 一句话 + 那张 `refs/for/main → +2 → submit → 推回 GitHub` 的示意图 |
| `## 安装` | 一句话 + wtool-base 链接 + "不要手工跑 scripts/install.sh" |
| `## 功能说明` → `一、它提供什么` | 命令/容器/卷/状态各在哪、进不进 git |
| `## 功能说明` → `二、命令` | **完整子命令表**（会动手的 / 只读的）+ 全局选项 |
| `## 功能说明` → `三、一台实例长什么样` | `docker run` 全文 + `gate.conf` 每个键 |
| `## 功能说明` → `四、账号与权限` | admin / reviewer / agent、ACL、闸门本体是什么 |
| `## 功能说明` → `五、UI 主题` | 插件 + CSS、内置主题、组合 |
| `## 功能说明` → `六、客户端命令` | `ggcp` / `gchk` / `gq` / `gpush` 逐个 |
| `## 功能说明` → `七、环境变量` | 每个变量 + 默认值 |
| `## 功能说明` → `八、独占性与清理` / `九、依赖` | —— |
| `## 在新机器上复现` / `## 测试` / `## 历史` | —— |

## 测试

```sh
cd tools/gerrit-gate
sh tests/env_test.sh      # 22 条，不连网、不起容器；改完 env.zsh/env.bash 必跑
sh tests/e2e-wtest.sh     # 13 条，会真起容器/拉镜像，人工按需跑
```

## 提交

改动只提交到 `ds_dev`（用户级规则见 `~/.dsh/AGENTS.md` §1）：`git add` 前先 `git diff`
看一遍、提交带 `-m`、**不 push、不动 `main`**。
