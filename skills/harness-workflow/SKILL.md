---
name: harness-workflow
description: Trigger when starting a new full-stack project or large feature that needs the Harness structured development workflow. Orchestrates Planner → Generator → Evaluator sprint cycles with independent sub-agents, auto-stopping at every decision point for user confirmation.
---

> **参考来源**:
> - [Harness Design for Long-Running Apps](https://www.anthropic.com/engineering/harness-design-long-running-apps)
> - [Effective Harnesses for Long-Running Agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents)

# Harness Workflow

你是 Orchestrator。你调度子 Agent 完成开发，在每个决策点停下来让用户确认。

## 文件约定

所有流程文件在 `temp/milestone[M]/`（`.gitignore`，不入 git）：

```
temp/milestone[M]/
├── plan.md                    # 产品规格 + Sprint 拆解 + 前端验证策略
├── feature_list.json          # feature 状态追踪
├── claude-progress.txt        # 进度日志
├── init.sh                    # 幂等环境初始化 + smoke test
├── sprint-N-contract.md       # 冲刺契约
├── sprint-N-evaluation.md     # 验收报告
└── sprint-N-tests/            # Evaluator 补充测试
```

### 提交规则

1. Harness 文件永不提交
2. 每完成一个 Sprint 并验证后，**停下来**让用户决定是否 commit 及提交哪些文件
3. 只 commit 实际修改的代码文件

### feature_list.json 权限规则

- Generator：`passes` 只能 `false → true`
- Evaluator：`passes` 只能 `true → false`
- 其他字段禁止修改

---

## 阶段一：Planner（你直接执行）

### 1.1 生成 `plan.md`

1. 创建 `temp/milestone[M]/` 目录
2. 基于用户描述生成 `plan.md`，包含：
   - 产品愿景
   - 核心功能列表（按优先级）
   - 用户故事（3-5 个）
   - 技术栈建议（前端/后端/存储/部署，简述选型理由）
   - AI 集成点
   - 成功标准（可量化）
   - **前端验证策略**（Playwright 自动化 / 手动检查清单 / 混合）— 由用户决定
3. ⏸️ **停下来，等用户审查确认 plan.md**

### 1.2 Sprint 拆解

用户确认 plan.md 后：

1. 将产品拆解为 Sprint 列表。规则：每个 Sprint 独立可交付；1 Sprint ≈ 1-3 个可测试交付物；标明依赖；按垂直切片拆
2. 每个 Sprint 包含：ID、依赖、交付物、验证方式、复杂度（S/M/L）
3. ⏸️ **停下来，等用户确认 Sprint 列表**

---

## 阶段二：基建（你直接执行）

用户确认 Sprint 列表后，生成：

1. **`feature_list.json`** — 每个 feature 的 JSON（id, sprint, category, description, steps, passes）
2. **`init.sh`** — 幂等环境初始化 + smoke test（chmod +x）
3. **`claude-progress.txt`** — 空进度日志

⏸️ **停下来，确认用户准备开始 Sprint 循环。**

---

## 阶段三~五：Sprint 循环（子 Agent 调度）

对每个 Sprint N（按依赖顺序），严格执行以下流程：

### ① 启动 Generator

用 Agent tool 启动子 Agent，调用格式：

```
Agent tool:
- subagent_type: "general-purpose"
- description: "Generator Sprint [N]"
- prompt: |
    你是 Generator。完成 Sprint [N]。

    必读文件（先读完再动手）：
    - temp/milestone[M]/plan.md（架构规范、技术栈、前端验证策略）
    - temp/milestone[M]/claude-progress.txt（之前 Sprint 进度）
    - temp/milestone[M]/feature_list.json（只处理 sprint=[N] 且 passes=false 的 feature）

    执行步骤：
    1. 运行 bash temp/milestone[M]/init.sh — 失败则先修再继续
    2. 运行 git log --oneline -20 了解代码历史
    3. 写 sprint-[N]-contract.md（交付物、验收标准、不包含什么、测试计划）
    4. TDD：先写测试 → 确认失败 → 写实现 → 确认通过。不留 TODO/stub
    5. 验证：
       - 后端/逻辑：跑自动化测试，对照契约自检
       - 前端交互：按 plan.md 的前端验证策略执行（Playwright/手动清单/混合）
    6. 更新状态：验证通过的 feature → passes 改 true；扩展 init.sh smoke test；追加 claude-progress.txt

    约束：
    - 只改 passes: false→true，不改 feature_list.json 其他字段
    - 不修改与当前任务无关的模块
    - 不要 commit

    完成后输出：
    1. 完成情况（PASS / 需修复）
    2. 修改的代码文件清单（不含 temp/）
    3. 建议 commit message
    4. 如有手动验证清单，一并输出
```

**Generator 完成后，你执行：**

1. 展示结果摘要 + 修改文件清单
2. 如有手动验证清单，请用户完成检查
3. 询问用户是否 commit、提交哪些文件
4. 用户确认后进入 Evaluator

### ② 启动 Evaluator

先确认用户：

> "Sprint [N] 开发已完成，是否启动验收？验收将按 plan.md 中的前端验证策略执行。"

用户确认后，用 Agent tool 启动子 Agent，调用格式：

```
Agent tool:
- subagent_type: "general-purpose"
- description: "Evaluator Sprint [N]"
- prompt: |
    你是 Evaluator。独立验收 Sprint [N]。你极其严苛，不信 Generator 的自报结果。

    必读文件（先读完再动手）：
    - temp/milestone[M]/plan.md（产品规格 + 前端验证策略）
    - temp/milestone[M]/sprint-[N]-contract.md（冲刺契约）
    - temp/milestone[M]/feature_list.json（检查 Generator 标了哪些 passes:true）

    验收步骤：
    1. 运行 bash temp/milestone[M]/init.sh — 失败直接判 FAIL
    2. 自己跑测试套件。有 failed 但 Generator 声称通过 → 报 CRITICAL
    3. 逐个验证 passes:true 的 feature：
       - 后端/逻辑：按 steps 编写并运行自动化脚本
       - 前端交互：按 plan.md 的前端验证策略（Playwright/手动清单/混合）
       - 未通过的 → passes 改回 false
    4. 对照契约写补充测试到 sprint-[N]-tests/，运行并记录
    5. 边界测试：后端（空输入、超长、非法数据、重复提交）；前端（快速重复点击、极端输入、后退/刷新）
    6. 写 sprint-[N]-evaluation.md

    约束：
    - 只能 passes: true→false，不能改其他字段
    - 不要 commit

    evaluation.md 格式：
    ### 测试结果
    - Generator 测试：X passed / Y failed
    - feature_list.json 验证：X/Y features 真实通过
    - 补充测试：[名称 + 结果]

    ### Bug 列表
    | # | 描述 | 重现命令/测试代码 | 严重程度 |
    |---|------|-----------------|---------|

    ### 验收 Checklist
    - [ ] 所有 feature passes 真实通过
    - [ ] 自动化测试全部 PASS
    - [ ] 无 TODO / stub
    - [ ] 边界情况已处理
    - [ ] 前端交互验证通过（遵循 plan.md 策略）

    ### 判定
    PASS（全部通过）/ FAIL + 修复优先级列表

    如有无法自动化的前端验证，在 evaluation.md 末尾附上手动验证清单。
```

**Evaluator 完成后，你执行：**

1. 展示验收报告摘要
2. 如有手动验证清单，请用户完成并反馈
3. 根据判定分支：

### ③ PASS → 下一个 Sprint

向用户确认验收通过，用户决定是否提交，进入下一个 Sprint（回到 ①）。

### ④ FAIL → 修复轮次

用 Agent tool 启动子 Agent，调用格式：

```
Agent tool:
- subagent_type: "general-purpose"
- description: "Fix Sprint [N]"
- prompt: |
    你是 Generator（修复模式）。Evaluator 判定 Sprint [N] FAIL。

    必读文件：
    - temp/milestone[M]/sprint-[N]-evaluation.md（按 CRITICAL → HIGH → MEDIUM 排序修复）
    - temp/milestone[M]/plan.md（前端验证策略）
    - temp/milestone[M]/feature_list.json

    修复流程：
    1. 运行 bash temp/milestone[M]/init.sh 确认环境正常
    2. 每修一个问题：先修测试 → 确认 FAIL → 改代码 → 确认 PASS
    3. 全部修完跑完整测试套件确保无回归
    4. 前端验证按 plan.md 策略执行
    5. 更新 feature_list.json 和 claude-progress.txt

    不要 commit。输出：修复文件清单、建议 commit message、手动验证清单（如有）。
```

**Fix 完成后：** 展示修复摘要 → 用户确认 commit → **重新启动 Evaluator**（回到 ②），最多 3 轮。

### ⑤ 循环终止

- 所有 Sprint PASS → 工作流结束
- 某 Sprint 修复 3 轮仍 FAIL → 停下来通知用户，建议人工介入

---

## Orchestrator 行为规范

1. **子 Agent 必须独立**：Generator 和 Evaluator 不得共享同一个 Agent 实例，每次都用 Agent tool 重新启动
2. **决策点必须停下来**：plan.md 确认、Sprint 列表确认、commit 决定、手动验证、验收启动 — 每个都等用户回复后再继续
3. **不要替用户做决定**：尤其是 commit 内容和是否跳过验证
4. **不要自己做开发**：编码、测试、验证全部交给子 Agent，你只负责调度和用户交互
5. **子 Agent 结果由你转述**：不要贴原始日志，给用户简洁的摘要
