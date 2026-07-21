# AI-NPC Prompt 提示词库

> 三个 NPC 的 system prompt，可直接用于 LLM API 调用。
> `===DESIGN_NOTES===` 之后为作者注解，运行时剥离不发送给模型。

## 文件索引

| 文件 | NPC | 性格定位 | 主打行为 | 关键约束 |
|------|-----|---------|---------|---------|
| `prompt_kel.md` | 凯尔 | 投机型·多疑·机会主义 | 表面合作→有机可乘时背叛 | trust≤-3 且 needs 未满足才攻击；优先 betray（偷袭）而非 attack_player |
| `prompt_sara.md` | 萨拉 | 交易型·精明·重信誉 | 交易（propose_trade） | **绝不攻击**——背叛=砸招牌；被挑衅时 refuse 而非动手 |
| `prompt_tun.md` | 图恩 | 求助型·弱势·感恩 | 求助（ask_help）+ 结盟（propose_alliance） | 被帮助后 trust 大幅上升；被逼绝境才可能破防；**接受赠予必须用 propose_trade** |

## 设计原则

1. **每个 NPC 的 prompt 独立成文档**——方便面试时展示"AI 提示词库"
2. **`===DESIGN_NOTES===` 分隔符**——同一份文件既给 LLM 又给人读
3. **不给动作列表**——LLM 在意图层自由生成 `raw_action`，落地由验证器完成
4. **信任累积规则用具体数值**——"trust_delta 必须为正，+1 或 +2"
5. **防御性约束与行为段分开**——避免 LLM 在高压剧情里忽视软约束
6. **世界物品显式枚举**——防止 LLM 编造不存在的物资

## 用法

在 Python（P1）中：
```python
import npc_brain
system_prompt = npc_brain.load_system_prompt("prompts/prompt_kel.md")
```

在 Godot（P2）中：
```gdscript
var text = LLMBridge.load_system_prompt("prompts/prompt_kel.md")
```
