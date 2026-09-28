# 来源与本地定制

源自 [poteto/noodle](https://github.com/poteto/noodle) 的 `.agents/skills/adversarial-review`，作者 Lauren Tan（poteto），MIT 许可见同目录 LICENSE。

原导入未记录准确的上游 commit；仓库 Git 历史保留导入与修改过程。本次核对的上游 revision 为 `82d2921c52370f23f29086de81ccfb600939c037`，它是核对点，不宣称是原始 fork 点。

本仓库将原则入口改为随 skill 分发的 `references/reviewer-lenses.md`，使 `brain/principles.md` 成为可选补充，并保留显式 reviewer prompt、输出核实和 lead judgment 规则。因此这是有意维护的定制版，不是上游原样副本。

2026-09-27 的本地修改：删除 Claude Code 不识别的 frontmatter 字段 `schedule`（其中的 cook session 属于上游 noodle 编排器）；`codex exec` 显式传入 `-s read-only`（需要运行测试的 reviewer 用 `-s workspace-write`），因为不传时沿用用户 Codex 配置中的 `sandbox_mode`；命令加 `< /dev/null`，后台运行时不等待 stdin；reviewer 的最终消息即编号结论，由 `-o` 写入文件，reviewer 不自行写结论文件；只含计划或确认的输出记为 reviewer 失败；等待方式改为后台命令的退出通知，因为 Claude Code 2.1.280 不再提供 `TaskOutput`。Codex 历史副本未做这些修改。

Claude 版本供选装；Codex 版本只保留历史定制，当前 Codex 审查选择 Matt 的 code-review。更新本地定制时同步本说明和完整引用资源。
