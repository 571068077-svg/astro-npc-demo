# AI-NPC 单模块 Demo

独立交付一个 AI 玩法模块——3 个具有独立性格和行为逻辑的 AI-NPC，在交易→信任→背叛的核心循环中，展示 LLM 自主决策 + 工程校验落地的完整能力。

## 核心架构：两层行为模型

```
玩家行为 + 世界状态
        │
        ▼
① 意图层 (开放·LLM 自由生成)     ← 自主性、性格、涌现
        │
        ▼
② 能力层 (封闭·行为验证器)       ← 工程价值：grounding + 校验 + 拦截
```

NPC 的行为是 LLM 根据处境自主决策的，验证器只做约束和校验——不是 if-else 脚本。

## 三个 NPC

| NPC | 性格 | 主打行为 | 背叛触发 |
|-----|------|---------|---------|
| 凯尔 | 投机型·多疑 | 交易 / 偷袭 | 高：trust≤-3 且 needs 未满足 |
| 萨拉 | 交易型·重信誉 | 交易 | 几乎不（砸招牌 = 自杀） |
| 图恩 | 求助型·弱势 | 求助 / 结盟 | 极低（仅被逼绝境） |

## 核心指标

| 指标 | 数值 |
|------|------|
| JSON 可解析率 | **100%**（33/33） |
| Schema 合格率 | **100%**（33/33） |
| 越界降级率 | 6.1%（2/33） |
| 参数幻觉率 | 0% |
| 单次 LLM 调用成本 | **¥0.004** |
| 一局 15 轮交互 | **¥0.06** |
| 均值延迟 | 2,312ms |

## 目录结构

```
astro-npc-demo/
├── README.md                 ← 你在这里
├── design.md                 ← 稳定架构设计
├── methodology.md            ← 方法论文档（含面试话术）
├── CHANGELOG.md              ← 完整迭代日志
├── stability_report.json     ← 度量数据
├── npc_brain.py              ← P1 决策层（意图层）
├── validator.py              ← P1 验证器（能力层）
├── capabilities.json         ← 能力清单
├── play.py                   ← P1 交互 demo
├── test_stability.py         ← P1 度量脚本
├── npcs.json                 ← NPC 运行时配置
├── prompts/                  ← 三份人设 prompt
├── prompt_library/           ← 提示词库（含索引）
└── .env.example              ← API key 配置模板

astro-npc-demo-godot/         ← P2 Godot 引擎 Demo
├── scripts/                  ← GDScript（game_state / llm_bridge / validator / scene_main / dialog_box）
├── assets/                   ← 美术素材
├── prompts/                  ← P1 同款 prompt
└── project.godot             ← Godot 项目配置
```

## 快速运行

### P1 Python 版
```bash
cd astro-npc-demo
cp .env.example .env          # 填入 DeepSeek API key
python play.py                # 默认凯尔，可选 sara / tun
python test_stability.py      # 生成度量报告
```

### P2 Godot 版
1. 用 Godot 4.x 打开 `astro-npc-demo-godot/project.godot`
2. 确保 `.env` 在项目根目录，包含 `DEEPSEEK_API_KEY=你的key`
3. 按 F5 运行
4. WASD 移动，走到 NPC 旁按 E 对话

## 方法论

详见 [`methodology.md`](methodology.md) —— 含 6 轮迭代经验、面试话术速查、完整对话回放。

---

## 演示视频
[AI-NPC Demo v1.0 - 演示视频](https://github.com/571068077-svg/astro-npc-demo/releases/tag/v1.0)

展示完整流程：正常交易 → 信任下降 → 冲突触发 → 指标展示
