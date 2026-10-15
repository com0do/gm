# DRY_RUN 依赖生成机制

`gm` 用 **DRY_RUN 模式**在构建目标之前按需重建三份 build artefact（合称依赖图）：

- `build/depend.mk` —— lib 级依赖锁文件（`tmctl: libtmcore` 这种边）
- `build/pkg_of.mk` —— lib → pkg 反查表（`PKG_OF_libtmstats := pkg-tmd pkg-tm-devel`）
- `build/import_of.mk` —— vendor artefact → 拥有它的 `.import.mk`
  反查表（`IMPORT_OF_libminijson_file := libminijson`）

三份都在 `build/` 下、gitignore，从不需要手工维护。重建规则和顶层的 include 在
[`graph.mk`](../production/make/graph.mk) 里（只由 Makefile include 一次）：

| 文件 | 谁读 | 怎么读 |
|------|------|--------|
| `depend.mk` | 顶层 make（构建顺序） | Makefile 在 project.mk 之后 include graph.mk |
| `pkg_of.mk`、`import_of.mk` | target 子 make（`PKG_HEADERS := yes`、pkg.yaml 里的 vendor artefact） | env.mk 在子 make 里直接 `-include`，只读，子 make 里没有重建它们的规则 |

### 哪些 goal 加载依赖图

GNU make 在处理任何 goal **之前**先重建所有被 include 的 makefile，所以只要
include 了 `depend.mk`，它一过时就会全树扫描，不管 goal 是什么。graph.mk 因此只在
goal 会在本进程里构建目标时 include 它：

- **加载**：目标名、`run-<t>`、`<pkg>-header`、`all`、`test`、`show*`、
  `compile_commands`，以及项目自己 Makefile 里的 goal（默认都加载，永远正确）
- **不加载**：project.mk 的 `_GM_GOALS_ALONE` —— 只读文件（`list`、`help`、
  `changes`、`deps-files`…）、不需要顺序（`clean`、`distclean`），或者自己再起一个
  make 的 goal（`coverage`、`refresh`、`incremental`、`deps`，由里层 make 加载）；
  以及 env.mk `SUB_TARGET_ALONE` 里的子 goal（`make <t> SUB_TARGET=clean`）

新加一个 gm goal 时，登记进 `_GM_GOALS`（防止和目标重名，本来就要登记）的两栏之一即可，
不需要另写 `ifneq ($(MAKECMDGOALS),...)`。漏登记的后果只是多一次扫描。
`make prereq` 就是靠这个在新机器上先装 PyYAML / jsonschema，而不是先去扫 pkg.yaml。

本文只讲**机制**——怎么触发、怎么传递、每一代做什么。用法层面
的「什么时候需要 `make deps`」在 [`1-USER_GUIDE.md`](1-USER_GUIDE.md) §5。

---

## 高层视图：三代 make 嵌套

```
Gen-1 (最外层, 用户敲的 make)
 │  $(DRY_RUN) 未设
 │  include env.mk    → DRY_RUN 仍未设
 │  include project.mk → 找出 TARGET_ALL_MK
 │  include graph.mk   → goal 要构建目标时（不在 _GM_GOALS_ALONE 里）：
 │                       定义 $(TARGET_DEP) 规则，include $(TARGET_DEP)   ← depend.mk
 │  ────────────────────────────────────────────
 │  makefile-remake 触发（GNU make 特性）
 │  ────────────────────────────────────────────
 │  被 include 的文件本身也是 target；depend.mk 缺失或过时时，
 │  make 会先执行它的规则、跑完再从零 parse 一遍主 Makefile
 │
 │  规则命中 graph.mk
 │  $(TARGET_DEP): $(TARGET_ALL_MK)
 │      recipe 是 for-loop：
 │
 │      for t in loadgen libminijson pkg-tmd pkg-tm-devel ... ; do
 │          GM_TREE= $(MAKE) -s DRY_RUN=1 $$t   ← 每个变更 target 一次
 │      done
 │
 ↓  ── 这里 fork 出 Gen-2 (每个变更 target 一次，串行) ──
Gen-2 (每个变更 target 一次) : GM_TREE= make -s DRY_RUN=1 libtmcore
 │  没有 -C / -f → 重新加载顶层 Makefile
 │  DRY_RUN=1 是命令行显式参数 → 自动进入 MAKEFLAGS
 │
 │  include env.mk    → DRY_RUN=1 可见
 │  include project.mk
 │  include graph.mk
 │  │  这次 `ifneq ($(DRY_RUN),1)` 门禁生效：
 │  │  $(TARGET_DEP) 规则不定义，也不 include depend.mk
 │  │  → makefile-remake 不触发，切断「Gen-2 又去 rebuild depend.mk」的死循环风险
 │
 │  goal = libtmcore，命中 Makefile 的 $(TARGET_ALL) 分发规则
 │  recipe: $(MAKE) -C $(SOURCE_DIR) -f env.mk -f libtmcore.mk -f target.c.mk ...
 │
 ↓  ── fork Gen-3 (真正做 DRY_RUN 工作的那一代) ──
Gen-3 (真正做 DRY_RUN 的那一层)
 │  make -C example/core -f env.mk -f libtmcore.mk -f target.c.mk
 │  DRY_RUN=1 通过 MAKEFLAGS 环境**自动继承**（Gen-2 命令行 → MAKEFLAGS → Gen-3 环境）
 │
 │  target.c.mk 顶端：
 │  │  ifeq ($(DRY_RUN),1)
 │  │      include target.dry-run.mk    ← 只 sed 写文件，不编译
 │  │  else
 │  │      # 真正的编译规则
 │  │  endif
 │
 │  target.common.mk 设 .DEFAULT_GOAL := $(TARGET)  → 命中 dry-run.mk 里的 phony:
 │  sed -i 一行 "T: DEPS" 到 depend.mk
 │  (可选) sed 反查表：pkg_of.mk / import_of.mk
 │
 ↓  Gen-3 退出（不编译不链接）
[回到 Gen-1]
 │  for-loop 全部结束
 │  recipe 后半段：sort -u pkg_of.mk / import_of.mk
 │                 把 _DEP_DIGEST := <md5> 写入 depend.mk 首行
 │  makefile-remake 结束
 │
 │  GNU make 重新 parse 顶层 Makefile
 │  include $(TARGET_DEP) 这次成功，depend.mk 里的边全部生效
 │
 ↓
 [正常构建] all → $(TARGET_ALL) → 分发器 → Gen-X 编译
```

---

## Gen-1 详解

顶层 `Makefile` 入口的关键三行：

```
[Makefile]
 │
 │  .DEFAULT_GOAL := all         ← 用户敲 make 时的默认 goal
 │  include env.mk              ← 加载所有默认 + 工具路径 + flags.mk
 │  include project.mk          ← 定义 TARGET_ALL_MK、_GM_GOALS_ALONE
 │  include graph.mk
 │  │  ifneq ($(DRY_RUN),1)       ← DRY_RUN 未设 → 走这一支
 │  │  goal 不全在 _GM_GOALS_ALONE 里 → 定义 $(TARGET_DEP) 规则
 │  │  include $(TARGET_DEP)      ← 尝试 include build/depend.mk
 │  │  endif
 ↓
```

**GNU make 的 makefile-remake 机制**：

```
被 include 的文件 是 target
                │
                ├── 缺失？ ──yes──▶ 先跑它的规则，跑完 re-parse 顶层
                │                    │
                │                    ▼
                └── 存在但过时？─────▶ 同上
                     │
                     └── 都不是 ────▶ 直接 include 内容，进入 build 阶段
```

对应到 depend.mk：**冷 clone 时缺失 → makefile-remake 触发；任何一个
`.mk` 文件被 touch 后 depend.mk 过时 → 同样触发**。

命中的规则在 [`graph.mk`](../production/make/graph.mk)：

```make
$(TARGET_DEP): $(TARGET_ALL_MK)
	@mkdir -p $(@D) && touch $(GM_PKG_OF_FILE) $(GM_IMPORT_OF_FILE)
	@$(call V_DEPS,scanning $(words $(_CHANGED)) target(s))
	@for t in $(_ORDERED) ; do \
	    $(ECHO) "  DEPS    $$t" ; \
	    GM_TREE= $(MAKE) -s DRY_RUN=1 $$t || exit $$? ; \
	 done
```

三个关键点：

```
1. prereq 是 $(TARGET_ALL_MK)（所有 .mk 文件路径）
   └── 任何 .mk 被 touch → depend.mk 立刻过时
   └── $? 只包含变更集 → recipe 通过 _CHANGED 只对变更 target 重扫

2. for 循环是【串行】的，不是 -j
   └── 所有 DRY_RUN 子 make 都在 sed -i 同一份 depend.mk / pkg_of.mk / import_of.mk
   └── 并行 sed 同一个文件会 race，边掉

3. GM_TREE=  ← 清掉 env.mk 里 `export GM_TREE := 1` 的 nesting 守卫
   └── 不清就会撞 $(error gm cannot be nested)
   └── 让 Gen-2 看起来像一个「全新的顶层调用」
```

### _ORDERED —— 为什么要严格顺序

```make
$(TARGET_DEP): _ORDERED = \
    $(filter $(_IMPORT_ALL),$(_CHANGED)) \       ← 1) imports 先
    $(filter $(TARGET_PKG),$(_CHANGED)) \        ← 2) pkgs 中
    $(filter-out $(_IMPORT_ALL) $(TARGET_PKG),$(_CHANGED))  ← 3) 其它最后
```

```
[顺序 1: imports]
 │  libminijson.import.mk 产出 libminijson.so / .a + libminijson_file.so + jsonpp
 │  DRY_RUN 写：
 │      IMPORT_OF_libminijson      := libminijson
 │      IMPORT_OF_libminijson_file := libminijson
 │      IMPORT_OF_jsonpp           := libminijson
 │  到 import_of.mk
 ↓
[顺序 2: pkgs]
 │  pkg-tmd 的 pkg.yaml files: [$GM_LIB_DIR/libminijson_file.so]
 │  → 通过 IMPORT_OF_libminijson_file 反查到 libminijson
 │  同时写 PKG_OF_libtmstats := pkg-tmd 到 pkg_of.mk
 ↓
[顺序 3: 其它]
 │  lib / exe / test / go / java 可能 PKG_HEADERS := pkg-<name>
 │  → 此时 pkg_of.mk 已经就绪，可以按需反查
```

**这个顺序破坏了并行的可能**——每一步都读上一步的产物。想 `-j` 就
得把三份文件的写入完全独立，目前没有这个基础设施。

---

## Gen-2 详解

Gen-2 的 recipe 是：

```
GM_TREE= make -s DRY_RUN=1 libtmcore
        └────────────────┴──────── 关键 3 件事
                │            │
                │            └── goal = libtmcore（要 sed 的那一个 target）
                └── DRY_RUN=1 是命令行显式参数
                    ↓
                    自动进入 MAKEFLAGS （GNU make 特性）
```

**没有 `-C`、没有 `-f`** —— 用当前目录的默认 `Makefile`，等于**重新
fork 一个 make 进程从零加载顶层**。

```
[Gen-2 进程启动]
 │
 │  加载 顶层 Makefile
 │  │
 │  │  include env.mk
 │  │  │  export GM_TREE := 1        ← Gen-2 的 env 里被清了，这次重新设
 │  │  │  DRY_RUN=1 通过 MAKEFLAGS 可见
 │  │  
 │  │  include project.mk
 │  │  include graph.mk
 │  │  │  ifneq ($(DRY_RUN),1)       ← DRY_RUN=1 → 门禁生效
 │  │  │      $(TARGET_DEP) 规则不定义，不 include depend.mk
 │  │  │  endif
 │  │  │  → **切断递归风险**：Gen-2 不会触发 makefile-remake
 │
 │  goal = libtmcore → 命中 $(TARGET_ALL) 分发规则
 │
 │  分发规则 recipe：
 │      $(MAKE) -C example/core \
 │              -f env.mk -f libtmcore.mk -f target.c.mk \
 │              PROJ_TOP=... BUILD_MODE=... TYPE=lib SOURCE_DIR=... 
 │      └── 这里 fork Gen-3
```

**Gen-2 本身不做实质工作**，它的意义是：**在 project.mk 完整跑一遍
`SET_TARGET` 之后**，把 target-scoped 的 `TYPE / SOURCE_DIR / BUILD_DIR /
OUT_DIR` 等值准备好，然后传给 Gen-3。

---

## Gen-3 详解

Gen-3 是分发器 fork 出来的，参数是分发器组装好的：

```
make -C example/core \
     -f env.mk \                     ← 框架默认 + flags.mk
     -f libtmcore.mk \               ← 用户 knobs（CXXSOURCE, LDLIBS, ...）
     -f target.c.mk \                ← 编译规则（含 target.common.mk）
     PROJ_TOP=... BUILD_MODE=... TYPE=lib BUILD_DIR=... ...
```

注意分发器转发的变量清单 `_GM_SUBMAKE_VARS`（env.mk）里**没有 DRY_RUN**：

```make
_GM_SUBMAKE_VARS := PROJ_TOP ADMIN_DIR BUILD_ARCH BUILD_MODE SANITIZE COVERAGE GM_MACHINE C_PATH CC_PATH \
                    GM_OUT DEP_TREE TARGET_DEP TYPE SOURCE_DIR BUILD_DIR OUT_DIR REL_DIR
                    ▲
                    │ 没有 DRY_RUN，为什么？
                    ▼
```

**因为 GNU make 会自动把命令行变量塞进 `MAKEFLAGS`**：

```
Gen-2 启动：  make -s DRY_RUN=1 libtmcore
                        ▲
                        │ 命令行变量
                        ▼
                   MAKEFLAGS = "-s DRY_RUN=1"     (Gen-2 内部)
                        │
                        │ 环境变量，跨进程继承
                        ▼
Gen-3 启动：  make -C ...     (子进程环境里 MAKEFLAGS 存在)
                        │
                        ▼
                   Gen-3 读 MAKEFLAGS，看到 DRY_RUN=1，$(DRY_RUN)=1
```

这是命令行传参优于 `export`：**不需要每层 recipe 都记得转发新加的
开关**。想加个新的 flag，命令行传就行，中间层自动带上。

反过来，这也是**长列表不能走命令行**的原因：命令行变量会进 `MAKEFLAGS`，
也就进了 Gen-3 起每个子进程（包括每次编译器调用）的环境。Gen-3 判断
"`-lfoo` 是不是树内目标"要用到的 `TARGET_ALL`（以及 `LDLIB_CHECK=1` 时的
`GM_SYS_LIBS`，系统库名清单，本机近 10 KB）随目录树增长，所以 Gen-2 在解析
project.mk 时把它们写进 `$(GM_OUT)/.dry-run-vars.mk`，Gen-3 的 env.mk 只在
`DRY_RUN=1` 且自己是子 make 时 `include` 它。

Gen-3 加载完 3 个 makefile 之后：

```
[target.c.mk 加载]
 │
 │  ifeq ($(DRY_RUN),1)               ← 命中
 │      include target.dry-run.mk
 │  else
 │      # 真正的编译/链接规则
 │  endif
 │
 │  target.common.mk (被 target.c.mk 顶部 include)
 │  │  .DEFAULT_GOAL := $(TARGET)     ← 没显式传 goal 时的默认
 ↓
[target.dry-run.mk 里的 $(TARGET) rule]
 │
 │  $(TARGET):
 │  │  # 1. 确保 depend.mk 有一行「种子」，让 sed hold-space 有落脚点
 │  │  [ -s $(TARGET_DEP) ] || echo > $(TARGET_DEP)
 │  │
 │  │  # 2. 把「T: DEPS」写进 depend.mk（存在则替换，否则追加）
 │  │  if [ -n "$(DRY_DEPS)" ]; then
 │  │      sed -i "..."   # replace-or-append
 │  │  else
 │  │      sed -i "/^$(TARGET):/d"    # 无依赖 → 删掉旧行
 │  │  fi
 │  │
 │  │  # 3. (可选) 写反查表 pkg_of.mk / import_of.mk
 │  │  if [[ -n "$(DRY_REVERSE_PREFIX)" ]]; then
 │  │      sed -i "..."   # PKG_OF_<lib> := <pkg> 之类
 │  │  fi
 ↓
Gen-3 退出（不编译不链接不打包）
```

`$(DRY_DEPS)` 每个 `target.<type>.mk` 各自算：

```
target.c.mk    :  $(DRY_DEPS) = 从 LDLIBS -l<X> 里过滤出 in-tree 名字
                                + $(PKG_HEADERS)-header 之类
                
target.go.mk   :  $(DRY_DEPS) = 解析 go.mod / go list -deps，
                                找 in-tree replace 依赖

target.java.mk :  $(DRY_DEPS) = $(JAR_DEPS)（in-tree jar 依赖）

target.pkg.mk  :  $(DRY_DEPS) = pkg-build.py --print-intree-targets
                                从 pkg.yaml files: 里抽 $GM_LIB_DIR/$GM_EXEC_DIR 项
                                + rpm_deps: 里的 in-tree pkg

target.import.mk: 不产 DRY_DEPS 边
                  但写 IMPORT_OF_<artefact> := <import-mk-name>
                  到 import_of.mk
```

---

## Gen-1 阶段收尾

for-loop 结束之后，Gen-1 的 `$(TARGET_DEP)` recipe 还有后半段：

```
[graph.mk，$(TARGET_DEP) recipe 后半段]
 │
 │  sort -u pkg_of.mk         → 去重、排序
 │  sort -u import_of.mk      → 去重、排序
 │  
 │  { echo '_DEP_DIGEST := $(_DEP_DIGEST_NOW)' ; 
 │    grep -Ev '^(_DEP_DIGEST := |[[:space:]]*$$)' depend.mk | sort -u ; 
 │  } > depend.mk.tmp && mv depend.mk.tmp depend.mk
 │  
 │  _DEP_DIGEST_NOW 是当前 TARGET_ALL_MK 列表的 md5
 │  → 写入 depend.mk 首行，用于第二次比对
 ↓
makefile-remake 结束
 ↓
GNU make 从零重新 parse 顶层 Makefile
 ↓
[graph.mk 再次跑]
 │  ifneq ($(DRY_RUN),1)     ← 未设，走这一支
 │  include $(TARGET_DEP)     ← 这次能成功
 │  ifneq ($(_DEP_DIGEST),$(_DEP_DIGEST_NOW))  ← 二次比对 digest
 │      $(shell $(RM) $(TARGET_DEP) $(GM_PKG_OF_FILE) $(GM_IMPORT_OF_FILE))
 │      → 说明 .mk 列表变了（add/delete）但 auto-regen 没跟上
 │      → 干掉 depend.mk，makefile-remake 会再触发一次
 │  endif
 │  endif
 ↓
[正常构建流]
 all → $(TARGET_ALL) → 分发器 → Gen-X 编译
```

---

## 三代速查表

```
┌───────┬────────────────────────────────┬──────────────────────────────┬──────────────────────────────────────────┐
│  代   │ 入口命令                       │ DRY_RUN 从哪来               │ 干什么                                    │
├───────┼────────────────────────────────┼──────────────────────────────┼──────────────────────────────────────────┤
│ Gen-1 │ 用户敲的 make                  │ 未设                         │ include depend.mk 触发 makefile-remake   │
│       │ (或 make deps / make -B)       │                              │ 串行 for-loop fork Gen-2                 │
│       │                                │                              │ 结束后 sort/dedupe/写 _DEP_DIGEST         │
├───────┼────────────────────────────────┼──────────────────────────────┼──────────────────────────────────────────┤
│ Gen-2 │ GM_TREE= make -s               │ 命令行显式设                 │ 重入顶层 Makefile                        │
│       │ DRY_RUN=1 <target>             │ (graph.mk 的 for 循环)       │ graph.mk 的 ifneq 门禁避免死循环          │
│       │ (每个变更 target 一次)         │                              │ 分发器把 target 派给 Gen-3               │
├───────┼────────────────────────────────┼──────────────────────────────┼──────────────────────────────────────────┤
│ Gen-3 │ make -C <src>                  │ MAKEFLAGS 环境**自动继承**   │ target.<type>.mk 里 ifeq ($(DRY_RUN),1)  │
│       │ -f env.mk -f <t>.mk            │ (从 Gen-2 的命令行来)        │ → include target.dry-run.mk              │
│       │ -f target.<type>.mk            │                              │ → sed 一行 T: DEPS 到 depend.mk         │
│       │ (被 Gen-2 的分发器 fork)       │                              │ 不编译不链接                              │
└───────┴────────────────────────────────┴──────────────────────────────┴──────────────────────────────────────────┘
```

---

## 手动强制 rebuild depend.mk

平时不用，但**重命名或删除 `.mk` 时**要手动跑一次——auto-regen
只看 `$?`（变更集），看不到「消失的文件」：

```bash
make deps
```

它就是把上面的完整流程再走一遍：

```
make deps
 │
 ↓
[graph.mk]
 │  @$(RM) $(TARGET_DEP) $(GM_PKG_OF_FILE) $(GM_IMPORT_OF_FILE)
 │  @GM_TREE= $(MAKE) $(TARGET_DEP)
 │             │
 │             ↓
 │        触发 $(TARGET_DEP) 规则 → 三代嵌套流程
```

---

## 常见 pitfall

```
1. DRY_RUN 分支里不要做副作用
   │  target.<type>.mk 的 ifeq ($(DRY_RUN),1) 分支
   │  必须只算 DRY_DEPS + include target.dry-run.mk 做 sed
   │  任何真正的编译/链接/生成头
   └── 都得在 else 分支里做（否则会在依赖生成阶段被跑）

2. DRY_RUN 时不能给子 make 传 -j
   │  project.mk 的 for-loop 是串行的、故意的
   │  所有 Gen-2 的 Gen-3 都在 sed 同一份文件
   └── 若 Gen-2 内部又 -j 派发多个 Gen-3，会撞同样的 race

3. 不要 export DRY_RUN
   │  它是命令行变量，走 MAKEFLAGS 自动传播
   └── 一旦 export，任何非 gm 的子进程（如 pkg-build.py 内起的 Python）
       都会看到，可能被误解成别的 dry-run 语义

4. 不要在 Gen-1 判定「depend.mk 需要重建」时依赖时间戳以外的信号
   │  目前用 _DEP_DIGEST 双重保险：
   │  .mk 列表变化 → digest 变化 → depend.mk 强制重建
   └── 除此之外只依赖 make 自己的 mtime 比对
```

---

## 调试小技巧

```
看 DRY_RUN 到底跑了什么
    ↓
make deps VV=1
    └── VV=1 打开 MAKEFLAGS += --trace （见 env.mk:127-130）
        能看到每个 Gen-2 / Gen-3 的具体命令行

看 depend.mk 是不是完整
    ↓
cat build/depend.mk
    └── 每行 T: DEPS 就是一条 lib-level 边

看 reverse maps
    ↓
cat build/pkg_of.mk build/import_of.mk

看某个 target 的 DRY_DEPS
    ↓
make libtmcore DRY_RUN=1 -s
    └── 单独跑一遍，观察它写到 depend.mk 的哪一行
```
