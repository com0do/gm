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

- **U1** README 精简 → 从 ~1200 行拆到 ~270 行，把 landing 场景保留、深度内容全部指向 USER_GUIDE，加了系统依赖 apt/dnf 一行命令
- **G4** 重名 `.mk` 静默失败 → project.mk 在 SET_TARGET 前扫描 basename 冲突，$(error) 列出所有涉及路径 + 各自的 type 和 artefact 路径
- **G8** 框架自测 → precheck.sh 追加 5 个 make-层 check：nested-gm 拒绝、重名 `.mk`、坏 `-l`、二次 make 幂等、CDB 生成
- **G2** `-lFOO` 拼错的友好诊断 → 挪进 target.c.mk 的 DRY_RUN 分支（只在 `make deps` 或 .mk 触碰后刷 depend.mk 时打），发出 $(warning) 而非 $(error)；系统 lib 目录预先 snapshot 到 `GM_SYS_LIBS`（project.mk 一次 `$(shell)`），每目标 O(1) 集合比对，不再 wildcard
- **2.3** `depUpdate.py` Go/Java 覆盖 → depgo.sh 之前只读 `.GoFiles` 漏掉了 cgo 项目（`.CgoFiles`/`.CFiles`/`.HFiles`/...）；补齐后 gcgo 这类 cgo 目标能被增量检测捕获
- **cosmetic** `o=` deprecation 警告删除 → env.mk 直接静默别名。之前用 `MAKELEVEL==0 && MAKE_RESTARTS==""` 双 gate 只在顶层首解析打，但在 nested make 场景下依旧漏打；与其半成品不如没有

---

## 下一步排期

**P2**

1. 4.2 ADR + 4.3 架构图（README/USER_GUIDE 拆分已完成）
2. C6 删掉 `container/examples/i1/`、C2/C4 容器侧收尾
3. 2.2 `make refresh` 阶段合并

---

## 明确不做（by design）

- **让 gm 直接构建容器镜像。** 分层是刻意的：gm 只负责自己的依赖图（源码
  → obj → lib → exe → rpm），到 rpm 就停。镜像构建由 sibling 的
  `container/` 工具负责，它通过 hooks 收集自己的依赖，并按需消费 gm 已
  emit 的 `.dep.json`；两侧都用同一份 `pydep` Python 库来合成全局视图。
  gm 不需要看到镜像层；container 是"看得到全部"的那一层。这样 gm 的核心
  代码路径不必知道 Docker 的存在，也不用为了镜像构建拉入 docker CLI /
  registry 认证 / SBOM 之类的外部依赖。
