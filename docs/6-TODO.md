# gm — TODO

未落地的改进，按编号顺序排。历史条目移到 git log。

编号：`G*` = gm 缺陷、`C*` = container、`U*` = 通用、`N.N` = 分节遗留。
状态图例：`⬜` 待办。
优先级：`P1` 高、`P2` 中、`P3` 低。

---

| #   | 优先级 | 问题                                                      | 备注                                                                                                          |
| --- | --- | ------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| G13 | P3  | `_CLASSIFY` 只看文件名 + sibling                             | 扩展性问题，无实际阻塞                                                                                                 |
| C2  | P2  | image key 是 `IMG:hello` 而非 file 路径                       | ——                                                                                                          |
| C4  | P2  | `RpmRuntimeResolver` 在 distroless 上静默返回空                | 静默失败                                                                                                        |
| C6  | P2  | `container/examples/i1/` 是 legacy dead example（同 6.1）   | 仍在树里                                                                                                        |
| C3  | P3  | installer 只支持 RPM                                       | ——                                                                                                          |
| C5  | P3  | `--no-cache=true --rm` 对开发流不友好                          | ——                                                                                                          |
| C7  | P3  | 无签名 / SBOM                                              | ——                                                                                                          |
| C8  | P3  | manifest 无 schema                                       | ——                                                                                                          |
| C9  | P3  | 直接调 docker 二进制、无 push                                   | ——                                                                                                          |
| U4  | P3  | 无 CHANGELOG / 版本号                                       | ——                                                                                                          |
| 2.2 | P2  | `make refresh` 三阶段串行                                    | 现在 gather 无竞争，可考虑合并阶段                                                                                        |
| 2.5 | P3  | 无全局 "dry-run everything" 模式                             | `gm deps` 已部分覆盖                                                                                              |
| 4.2 | P2  | 无 ADR                                                   | 载重决策目前散在注释里                                                                                                 |
| 4.3 | P2  | 无端到端架构图                                                 | ——                                                                                                          |

---

## 已解决（本轮）

- **G14** 目标名与同名目录 / 文件冲突时静默跳过 → 目标名 `.PHONY`；子目录源文件、同名源文件可编；
  `-D` 里带引号 / 撇号的 flag 在 stamp 与 cdb 中保持原样（`_sq`）；`.d` 原子写入 + `.DELETE_ON_ERROR`
- **G15** `make <t> SUB_TARGET=clean` 连依赖一起清 → 只清该目标；缺 `go` / `javac` 时这些目标在目标表
  源头剔除（`_GM_NO_GO` / `_GM_NO_JAVA`，各有一条 `SKIP` 行），pkg 缺 `rpmbuild` 只跳过 rpm 步；`rpmbuild` 失败打印日志末尾；
  `elf-rpath.py` 放不下 RPATH 时失败；`jq` 变成可选（没有就没有 compile_commands.json）
- **G28** 编译期不再用 `find` 找输入：生成头文件由 `.mk` 的 `HEADER_GEN` 列出；java 目标改用
  `<name>.java.mk` 后缀分类，`JAVASOURCE` 必须显式列出（闲置的 `.h.in` / `.java` 不再被编译或改变分类）
- **G16** 框架 flag 里的产品私有内容（`common/inc`、`cmrepo`、`-DRTP_64BIT`…）删除，项目在顶层
  Makefile 用 `PROJECT_CPPFLAGS/_CFLAGS/_CCFLAGS/_LDFLAGS` 设置全局 flag；`-m64` 随 `gcc -dumpmachine`；
  `env.mk` 的 Solaris 时代变量清理；每目标 `CXX_STD := c++20` 现在真的生效
- **G17** 可重现构建跨目录 / 跨主机：`-ffile-prefix-map`、Go `-buildid=`、versionstamp 时间随
  `SOURCE_DATE_EPOCH`、`BUILD_HOST` 统一驱动头文件 / versionstamp / rpm BuildHost（Rocky 8 / 9、
  Ubuntu 24.04 实测逐文件哈希一致）
- **G18** pkg YAML 模式补齐：scriptlet、`provides/conflicts/obsoletes`、作用域 `requires_*`、`epoch/url/vendor/packager`、
  `autoreqprov`、文件 `flags`（config/noreplace/doc/license）、`dirs`、`ghosts`
- **G19** `make coverage` 的 exclude 不再误伤位于 `build` 目录下的仓库，exe 有超时；`make test` 有单测超时；
  `go list` 查不到源文件时给出警告
- **U1** README 精简 → 从 ~1200 行拆到 ~270 行，把 landing 场景保留、深度内容全部指向 USER_GUIDE，加了系统依赖 apt/dnf 一行命令
- **G4** 重名 `.mk` 静默失败 → project.mk 在 SET_TARGET 前扫描 basename 冲突，$(error) 列出所有涉及路径 + 各自的 type 和 artefact 路径
- **G8** 框架自测 → precheck.sh 追加 5 个 make-层 check：nested-gm 拒绝、重名 `.mk`、坏 `-l`、二次 make 幂等、CDB 生成
- **G2** `-lFOO` 拼错的友好诊断 → 挪进 target.c.mk 的 DRY_RUN 分支（只在 `make deps` 或 .mk 触碰后刷 depend.mk 时打），发出 $(warning) 而非 $(error)；系统 lib 目录预先 snapshot 到 `GM_SYS_LIBS`（project.mk 一次 `$(shell)`），每目标 O(1) 集合比对，不再 wildcard
- **2.3** `depUpdate.py` Go/Java 覆盖 → depgo.sh 之前只读 `.GoFiles` 漏掉了 cgo 项目（`.CgoFiles`/`.CFiles`/`.HFiles`/...）；补齐后 gcgo（现在的 example/cgo 的 tmcrc）这类 cgo 目标能被增量检测捕获
- **cosmetic** `o=` deprecation 警告删除 → env.mk 直接静默别名。之前用 `MAKELEVEL==0 && MAKE_RESTARTS==""` 双 gate 只在顶层首解析打，但在 nested make 场景下依旧漏打；与其半成品不如没有

---

## 下一步排期

**P2**

1. 4.2 ADR + 4.3 架构图（README/USER_GUIDE 拆分已完成）
2. C6 删掉 `container/examples/i1/`、C2/C4 容器侧收尾
3. 2.2 `make refresh` 阶段合并

---

## 明确不做（by design）

- **用文件时间戳而不是内容哈希触发重编。** 目标文件依赖全部框架 `.mk`（改 `Makefile` /
  `project.mk` 会全量重编）、新增 / 删除目标会全量重扫依赖图，这是刻意的：简单、保守，
  宁可多编不能少编。大工程靠 ccache 兜底。
- **默认 `-Werror` + 严格告警集。** 这是产品默认策略；放宽用 `WARN_LEVEL=` 或在项目
  Makefile 里 `PROJECT_CCFLAGS += -Wno-error=...`。
- **编译器升级不自动触发重编。** 升级编译器是重大变更，由人手动清理（`make clean` /
  `make distclean`）。
- **不给树加锁。** 同一棵树同一时刻只跑一个 `make`（IDE 自动构建与终端构建不要同时进行）。

- **让 gm 直接构建容器镜像。** 分层是刻意的：gm 只负责自己的依赖图（源码
  → obj → lib → exe → rpm），到 rpm 就停。镜像构建由 sibling 的
  `container/` 工具负责，它通过 hooks 收集自己的依赖，并按需消费 gm 已
  emit 的 `.dep.json`；两侧都用同一份 `pydep` Python 库来合成全局视图。
  gm 不需要看到镜像层；container 是"看得到全部"的那一层。这样 gm 的核心
  代码路径不必知道 Docker 的存在，也不用为了镜像构建拉入 docker CLI /
  registry 认证 / SBOM 之类的外部依赖。
