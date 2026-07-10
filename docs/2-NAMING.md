# 为什么 `.mk` basename 必须全局唯一

> 一句话：**gm 把「文件名」直接当作「target 身份」**，这是 gm 换来
> 「零配置 `-l<name>` 链接」的代价。这个代价我们付得心甘情愿——
> 因为**允许重名等于允许两种坏设计流进代码库**。

---

## 1. gm 的约束

任何两个 `.mk` 文件同名，`make` 拒绝启动：

```
gm: libutil must be unique.
```

（错误定义在 [`production/make/project.mk`](../production/make/project.mk#L17-L20)
的 `_TARGET_DUPES` 检查里，`grep -n libutil` 一下能立刻定位到冲突路径。）

「同名」指的是**去掉 `.mk` 后缀之后的 basename**：

```
example/component1/libutil.mk   →  target 名 = libutil
example/component2/libutil.mk   →  target 名 = libutil    ← 撞了
```

---

## 2. 其它构建工具怎么处理这件事

对比几个主流工具：

| 工具 | 唯一性要求 | 唯一 ID 来自哪里 | 文件名 = ID？ |
|------|-----------|----------------|--------------|
| **CMake** | 全局 target 名唯一 | `add_library(foo, src1.cc, src2.cc)` 的第一个参数 | ❌ 名字和源文件解耦 |
| **Bazel** | `//package:name`（路径 scope） | BUILD 文件里 `cc_library(name = "foo")` | ❌ 用路径 + 名字消歧 |
| **Meson** | 子项目内 target 名唯一 | `library('foo', ...)` | ❌ |
| **Cargo** | workspace 内 crate 名唯一 | `Cargo.toml [package] name` | ❌ 文件叫什么都行 |
| **Maven** | `groupId:artifactId:version` 全局唯一 | POM 坐标 | ❌ POM 里显式声明 |
| **Autotools** | 通常没有全局要求（per Makefile.am） | 显式 `libfoo_la_SOURCES` | ❌ |
| **gm** | **全局 `.mk` basename 唯一** | 文件名 | ✅ 强绑定 |

**结论：**

- **「唯一性」本身不奇怪**——CMake / Meson / Cargo 都要求 target 名
  唯一。
- **「文件名 == 唯一 ID」的强绑定确实少见**——大部分工具让你在构建
  描述里显式声明名字，跟文件解耦。
- **Bazel 特殊**——用路径 scope 让 `//a:foo` 和 `//b:foo` 合法共存。
  但这只是把冲突推迟到「链接时如何引用」——见下一节。

---

## 3. gm 的设计权衡：换来了什么

gm 把名字和文件绑一起，直接得到 4 个 UX 简化：

```
                       ┌─────────────────────────────────────┐
                       │  设计选择：filename == target name   │
                       └─────────────────────────────────────┘
                                        │
      ┌─────────────────────────────────┼─────────────────────────────────┐
      │                                 │                                 │
      ▼                                 ▼                                 ▼
┌──────────────┐              ┌──────────────────┐              ┌────────────────┐
│ LDLIBS 零配置 │              │ depend.mk 纯短名 │              │ 打平输出目录合法 │
│              │              │                  │              │                │
│ LDLIBS +=    │              │ t3: libt1 libt2  │              │ ls $GM_LIB_DIR │
│    -lt2      │              │                  │              │ → 一眼所有 .so │
│              │              │ 一行看懂         │              │                │
│ 无需映射表   │              │                  │              │ 无子目录       │
└──────────────┘              └──────────────────┘              └────────────────┘

                                        │
                                        ▼
                              ┌────────────────────┐
                              │ 5 处 contract 一致 │
                              │                    │
                              │ • dispatcher goal  │
                              │ • depend.mk edge   │
                              │ • pkg_of.mk key    │
                              │ • IMPORT_OF key    │
                              │ • dep_query id     │
                              │                    │
                              │ 改一处不用同步 5   │
                              └────────────────────┘
```

对比 CMake：

```make
# gm (LDLIBS += -lt2 就完了)
LDLIBS += -lt2
```

```cmake
# CMake
target_link_libraries(bar PRIVATE t2)
# 框架内部帮你查：t2 这个 target 名对应的 artefact 是什么？
# 在哪个目录？依赖谁？
```

CMake 是把「查名字→文件」的映射放到框架里；gm 是**直接省掉这个映射**：
文件名就是名字。

---

## 4. 允许重名的两种情况：都是坏设计

用户角度真实的问题：**为什么不允许 `component1/libutil.mk` 和
`component2/libutil.mk` 共存**？答案：**共存意味着它俩都要产出
`libutil.so` / `libutil` 这个名字的 artefact**，而这两种情况都是**独立
判定的**坏设计。

### 4.1 两个同名 lib —— 靠 `-L` 顺序解链

假设放行：`component1/libutil.so`、`component2/libutil.so` 同时存在。

```
$(GM_LIB_DIR)/component1/libutil.so
$(GM_LIB_DIR)/component2/libutil.so   ← 逻辑上不同的两个库
```

用户在某处写：

```make
LDLIBS += -lutil
```

链接器怎么办？`-l` 语义是**在 `-L` 路径序列里线性搜索，第一个匹配的赢**。
所以最终链接进去的是 `libutil.so` 中排在 `-L` 前面的那一份。

```
                    ┌─── -L/path/component1 -L/path/component2
                    │
                    ▼
  linker: "find libutil.so"
     → hit component1/libutil.so (先)     ← 赢
     → component2/libutil.so 被静默忽略
```

**问题**：

- **一个 flag 顺序决定整个语义**：`-L` 交换一下顺序，你的可执行文件
  链接进的是另一个 `libutil`。**测试还都能通过**（因为两个 `libutil`
  刚好 API 兼容），**运行时行为诡异**。
- **调试地狱**：`ldd bar` 只显示 `libutil.so`，不告诉你是哪个源码
  编出来的。等你发现 bug，得回去 gcov / strings / readelf 挖 rpath +
  搜索路径 + 目录检索顺序。
- **没有告警**：linker 不认为「两个同名 lib」是错误，它按规则挑一个
  就走了。
- **CI 上和本地行为可能不一样**：`-L` 顺序依赖构建系统对目录的
  discovery 顺序，多线程扫目录时可能不稳定。

这不是 gm 的问题，是 **flat output tree + `-l<short-name>` 的物理约束**。
Bazel 通过强制 `//pkg:name` full path label 绕开了这个 —— 但 Bazel
的用户也不能用 `-lutil`，得用 `//a/component:util`。**gm 选择保留
`-l<name>` 的简洁 UX，代价就是不允许重名。**

### 4.2 两个同名 binary —— 用户认知混淆

假设放行：`component1/mytool` 和 `component2/mytool` 同时存在。

链接层这次不冲突（binary 不参与 `-l` 解析）。但 UX 层出问题：

```
$ which mytool
/opt/gm/bin/mytool          ← 到底哪一个？

$ mytool --help
Usage: mytool [component1 options]   ← 还是
Usage: mytool [component2 options]   ← 用户永远不知道自己在跑哪个
```

**问题**：

- **用户认知模型崩塌**：如果一个项目有两个 `mytool`，那这个 `mytool`
  这个名字**没有单一含义**。用户读日志、看 `ps`、写 systemd unit
  文件时，`mytool` 指代什么？看情况——「情况」是构建时的偶然。
- **打包时 rpm 冲突**：`pkg-p1` 和 `pkg-p2` 都想放 `/opt/gm/bin/mytool`。
  用 rpm-file-diff 一装立刻报错。
- **文档和错误消息互相拆台**：`ERROR in mytool` 用户查 wiki，wiki
  上的 `mytool` 是另一个组件的。

**根源是命名**：如果两个组件都有一个 `mytool`，那它俩的功能重叠了
（起码在用户视角）。**修法不是让构建工具支持重名，而是给它们起
不同的名字**：`comp1-tool` vs `comp2-tool`，或者更好——如果确实是
同一件事，合到一个 `mytool` 里。

---

## 5. 结论

gm 用**构建时**的一个约束（`.mk` basename 唯一），换来两件事：

1. **省掉一层显式声明**（不用像 CMake / Bazel 那样在描述里写名字）
2. **提前拦截两种坏设计**（同名 lib 靠 `-L` 顺序 / 同名 binary 用户
   混淆）

这个约束比大多数工具更强，但**不比它们不合理**——只是把
「不能重名」的判定从「运行时 / 使用时」提前到了「构建时」。
一次报错比十次调试 rpath 便宜。

### 撞名时怎么办

- **error 里已经告诉你 target 名**（`gm: libutil must be unique.`）
- `grep -rn "^libutil.mk\|/libutil.mk" --include='*.mk'` 或
  `find . -name 'libutil.mk'` 一下就能定位所有冲突路径
- 想清楚这两个 `libutil` **应不应该是同一个东西**：
  - 是同一个 → 合并到一个 `libutil.mk`
  - 不是同一个 → 给它们不同的名字

### 推荐的命名惯例

| 场景                             | 命名建议                                     |
|----------------------------------|---------------------------------------------|
| 组件内部的辅助库                 | `<component>_util.mk` → `-lcomponent_util`  |
| 一个产品家族的多个模块           | `libacme_core.mk`、`libacme_ipc.mk`         |
| 同 lib 的多个版本                | `libfoo_v2.mk` 与 `libfoo.mk` 并存          |
| 跨组件共享的工具代码             | 抽到共享目录，只有一份 `libutil.mk`         |
| 二进制工具                       | 描述做什么（`db-migrate`）而不是通用名      |

---

## 6. 什么时候这个约束会被重新审视？

只有当出现**同时满足**下面 3 条的场景时，才考虑放松：

1. 两个真正独立的组件、同一个短名、**不能重命名**（比如上游硬性
   要求 `libssl.so.1` 这种 ABI 名）
2. 使用侧不能改成 full path（`-L/absolute/path -llibssl`）
3. 频繁重复出现，不是一次性 workaround 能解决的

到目前为止 gm 用户没遇到这种场景。如果你遇到了，请更新
[`6-TODO.md`](6-TODO.md) 提出来。
