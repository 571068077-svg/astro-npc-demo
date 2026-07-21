# 迭代日志 (CHANGELOG)

## 2026-07-21 · 图恩赠予不触发交易 + 多选架构局限

**Bug 1（萨拉多选交易）**
- 现象：萨拉给出两个选项时，`_pending_offer` 把两份物品合并成一个报价（`gives:[电池,医疗包] wants:[滤芯,食物]`），玩家说"成交"全部转移或全部失败（玩家只持有其中一种物资时未区分）
- 根因：单轮 `propose_trade` 的 `offer` 字段无法表达"两选一"语义。JSON 里的 `give`/`want` 是并列关系而非互斥关系
- 判定：**当前架构的行为是正确且一致的**——`_pending_offer` 设计就是一轮一个报价，不支持多选。萨拉 prompt 应引导它逐轮给出单一报价，而非一次抛两个选项
- 改进：prompt_sara.md 建议追加"一次只提一个报价，谈不拢再换"约束（本轮未执行，留到后续）

**Bug 2（图恩接受赠予时选 small_talk → 物品不转移）**
- 现象：玩家说"我给你食物"时，图恩只回复感谢（small_talk），不输出 propose_trade → 物品不转移
- 根因：prompt_tun.md 决策原则第 1 条"优先求助而非交易"让 LLM 把"接受赠予"误判为"不需要交易的场景"。"交易"（trade）和"接受赠予"（accept gift）在 LLM 语境内被混为一谈——图恩认为这不是"交易"所以不选 propose_trade
- 修复：prompt_tun.md 新增「🚨 接受赠予规则」——玩家要给物品时**必须**选 propose_trade（give=玩家给的东西, want=[]），附正确/错误示例。capabilities.json 的 propose_trade desc 从"提出一笔交易"改为涵盖单向赠予的描述
- 验证：⏳ 真机（选图恩→说"我给你食物"→应出现 propose_trade + 物品转移）

---

## 2026-07-21 · trade 验证失败信任回退

**问题**：交易结算失败（玩家没有对应物资）时，`settle_trade` 拦截了物品转移，但 LLM 的 `trust_delta` 仍被正常应用，导致验证拒绝了交易但 trust 仍然上升。
**根因**：`_on_npc_response` 无条件执行 `GameState.set_trust(npc_id, get_trust(npc_id) + delta)`，不区分结算是否成功。LLM 在下一轮可能输出正向 `trust_delta`，而验证层只拦截物品转移不拦截信任更新。
**修复**：
- `dialog_box.gd` 新增 `_last_settlement_failed: bool` 标记
- `_send_to_npc`、`_execute_action.accept_trade`、`_on_accept` 三处结算后设标记：`_last_settlement_failed = not r["ok"]`
- `_on_npc_response` 中信任更新前检查标记：若为 true，覆盖 `delta = -1`（NPC 失望），消费标记
**核心原则**：验证层的拒绝必须级联到所有效果——不能只拦物品不拦信任。`trust_delta` 不能由 LLM 单方面决定。

---

> 本文件是本项目的**单一迭代日志**。design.md 只存稳定设计；每轮改了什么、根因、验证状态，看这里。
> 上下文变长后：`@astro-npc-demo/CHANGELOG.md` 让我快速回忆改动史。
> 验证状态标记：✅ 已真机验证 / 🧪 仅离线验证 / ⏳ 待测

---

## 迭代 #3.2 — 2026-07-17 · attack 硬拦截 + betray 引导 + 报告计数修复

**修复1：萨拉/图恩 attack_player 硬拦截**
- 修复：play.py/test_stability.py 同步加 ATTACK_FILTER——萨拉 attack→refuse、图恩 attack→flee
- 验证：✅ 真机——萨拉 attack 1→0、图恩 attack 1→0。三个 NPC attack_player 全表归零。

**修复2：凯尔 prompt 加偷袭/正面战斗区分**
- 修复：prompt_kel.md 加「优先 betray（偷袭），逃不掉才 attack_player。趁人不备是你长项」
- 验证：⚠ 真机——betray 仍为 0。prompt 引导把两个攻击路径一起压下去了（B 组全 threaten），betray 未从 attack 导流。根因：缺少"不动手就死"的生存级动机；仅挑衅不足。面试话术："需要再加 needs 危急维度——凯尔是投机者，没有十足把握不出手，即使 trust=-5。"

**修复3：degraded 计数偏差**
- 修复：apply_npc_filters 过滤后同步 grounded=True + degraded=False
- 验证：✅ 萨拉图恩 grounded/degraded 已一致。⚠ 凯尔 B 组 degraded=3（threaten=3）为残留——过滤函数只修了被拦截的路径，非拦截路径不受影响。不影响行为分布统计，属报告整洁度问题。

**v5 报告总结**
- Sara A 基线：trade 62.5%、attack=0、threaten=0 ★★★★★ 首次纯净交易型分布
- Tun A 基线：ask_help 62.5%、attack=0、threaten=0 ★★★★★ 首次纯净求助型分布
- Kel：betray 仍为 0——B 组全 threaten（投机者不愿冒险，叙事合理但度量报告里看不见）
- 两个 62.5% 对比 = 面试核心证据："同一套架构，换 prompt 就出完全不同的行为分布"
- JSON 解析率 33/33 + Schema 合格 33/33 = 面试硬数据
- 成本 ¥0.130/33次、单次 ¥0.004、一局 15 轮 ¥0.06、10 万 DAU ¥6,000/日
- **P1 正式收尾。下一步：P2 Godot 引擎接线。**

---

## P2 交互与UI — 2026-07-17

**对话框滚动修复**
- `scroll_following` 移除（让用户手动控制滚动位置，不自动跳底）
- `scroll_active = false`（ScrollContainer 管理滚动）
- 新增 `_scroll_to_bottom()` —— 只在 `dialog_text.append_text()` 后手动调用一次，不抢占用户手动滚动
- 每次追加文本后 `await get_tree().process_frame` 等 RichTextLabel 重新布局完再设滚动位置

**右侧状态面板（新增）**
- 独立 Panel，位置右上角（740,16），大小 280×350
- 显示：NPC 名字+性格、信任度（数值+ProgressBar+颜色）、急需物资、玩家库存列表、NPC 库存列表
- trust > 2 绿色、< -2 红色、≤ -3 深红+⚔冲突标记显示
- 每次 NPC 响应后、交易接受后自动刷新
- 对话框打开/关闭时同步显隐

**其他微调**
- 移除已废弃的 `_update_trust_display() / _update_inventory_display()`（功能合并到 `_refresh_status_panel`）
- 面板尺寸调整：对话框 680×260（给右侧面板留空间）
- 所有 `dialog_text.append_text()` 后统一调 `_scroll_to_bottom()`

---

## P2 滚动彻底修复 — 2026-07-18 · ScrollContainer + 强制滚底

**修复1：状态面板用 ScrollContainer 包裹**
- 现象：物资多时超出面板无法滚动看到
- 根因：`fit_content=true` 时 RichTextLabel 高度随内容增长，内容永远不会"超出自身"，内部滚动条不触发
- 修复：svbox 外套 `ScrollContainer`（`vertical_scroll_mode=AUTO`、`horizontal=DISABLED`），整个状态面板内容（标题+信任度+库存+需求）作为一个整体可滚动。svbox 用 `size_flags_horizontal=SIZE_EXPAND_FILL` 在滚动容器里水平撑满
- 验证：⏳ 真机

**修复2：对话框强制滚底**
- 现象：`scroll_following=true` 在 Godot 4 不可靠，新消息追加后视图停在顶部
- 修复：新增 `_append_dialog()` 辅助函数——追加后执行 `bar.value = bar.max_value` 显式拉到底。全文 12 处 `dialog_text.append_text(` 替换为 `_append_dialog(`
- 验证：⏳ 真机

---

## P2 报错+滚动修复 — 2026-07-18 · ProgressBar crash + 对话/状态面板滚动

**修复1：ProgressBar.get_child(0) 崩溃**
- 现象：信任度涨过 2 时 `get_child(0)` 报 `Index out of bounds` + `Invalid assignment`
- 根因：ProgressBar 内部子节点结构不可靠依赖，`get_child(0)` 在不同 Godot 4.x 版本/样式覆盖下可能返回 null
- 修复：用官方 theme API `add_theme_stylebox_override("fill", StyleBoxFlat)` 替代。新增 `_set_bar_fill_color(bar, clr)` 辅助函数——clr 非 null 设为填充色，null 恢复默认。信任区全部调用此函数
- 验证：🧪 离线（get_child(0) 已从源码中消除）。⏳ 真机

**修复2：对话面板鼠标滚轮失效**
- 现象：RichTextLabel 无法滚动
- 根因：`mouse_filter = MOUSE_FILTER_IGNORE` 让 RichTextLabel 忽略所有鼠标事件（含滚轮）
- 修复：改为 `MOUSE_FILTER_STOP`（RichTextLabel 默认值，会处理滚轮但不透传）
- 验证：⏳ 真机

**修复3：状态面板库存不可滚动**
- 现象：物资多时超出框的无法看到
- 根因：`status_player_inv`/`status_npc_inv` 的 RichTextLabel 没开 `scroll_active`
- 修复：两个 RichTextLabel 加 `scroll_active = true`；`custom_minimum_size` 从 36 改 60
- 验证：⏳ 真机

---

## P2 布局修复 — 2026-07-18 · 灰色区域 + UI 穿模 + 标题 bug

**修复1：背景放进 CanvasLayer(layer=-1)**
- 现象：窗口下半大片灰色，背景 ColorRect 只占左上角一小块
- 根因：Node2D 不是 Control，直接挂 ColorRect 时 FULL_RECT 锚点无法解析视口尺寸
- 修复：`scene_main.gd._build_background()`—ColorRect 挂进 `CanvasLayer(layer=-1)` 再 add_child
- 验证：深棕色铺满窗口，无灰色区域

**修复2：图恩挪出状态面板区域**
- 现象：图恩被右侧 CanvasLayer 面板盖住，不可见
- 根因：坐标 (800,360) 落在状态面板 (740~1020, 16~366) 内
- 修复：`scene_main.gd._build_npcs()`—图恩坐标 (800,360) → (620,360)
- 验证：三个 NPC 全部可见

**修复3/4：VBoxContainer size→offset，修复 UI 穿模**
- 现象：状态面板物资列表溢出、穿透到对话框上
- 根因：`dialog_box.gd._build_full_ui()`—两个 VBoxContainer 在 `add_child(panel)` **之前**调了 `size = Vector2(...)`。Godot 的 size setter 反算 offset_right 时父宽度=0（还没进树），算出一个超大正数。节点进树后容器尺寸远超 Panel，开了 `fit_content=true` 的 RichTextLabel 跟着无限长高
- 修复：`size = Vector2(660,244)` → 移到 `add_child(panel)` **之后**，改用 `offset_left/top/right/bottom`。`Vector2(10,8)`+`Vector2(660,244)` → `offset_left=10, offset_top=8, offset_right=670, offset_bottom=252`。状态面板 svbox 同理：`Vector2(12,12)`+`Vector2(256,326)` → `offset_left=12, offset_top=12, offset_right=268, offset_bottom=338`

**修复5：NPC 物资标题永远不更新**
- 现象：状态面板标题始终显示"NPC 的物资"而非角色名
- 根因：`_refresh_status_panel()` 用 `status_panel.get_node_or_null("VBoxContainer/StatusNPCInvTitle")` 找节点，但 `StatusNPCInvTitle` 在 `VBoxContainer/HBoxContainer/` 里（两层嵌套），路径少了一层
- 修复：改用成员变量 `_status_npc_inv_title` 直接持有引用——构造时 `_status_npc_inv_title = ni_name`，刷新时直接 `_status_npc_inv_title.text = GameState.get_npc_name(id)`
- 验证：选萨拉或图恩，面板标题显示正确角色名

---

## P2 Godot 启动 — 2026-07-17

**场景架构**：全动态创建（scene_main.gd + dialog_box._build_full_ui()）。三个 autoload：GameState + LLMBridge + Validator。P1 的 .env/npcs.json/capabilities.json/prompts 已移植。

**修复1：.tscn 类型冲突** — ext_resource 引用导致 Script 继承与节点类型不兼容，改为全代码动态创建。

**修复2：@onready 子节点不存在** — add_child(area) 在子节点之前执行，$BodyRect/$NameLabel 还不在树里。修复：先建子节点再 add_child(area)；npc_controller.gd 用 get_node_or_null() + 空安全检查。

---

## 迭代 #3.2 — 2026-07-17 · attack 硬拦截 + betray 引导 + 报告计数修复

---

## 迭代 #3.1 — 2026-07-17 · 高先验场景 + NPC 恐吓过滤 + 定价落地

**修复1：度量脚本加高先验场景**
- 现象：基线报告凯尔 betray=0（8 个场景 trust 从 0 起步，一轮不足以跌破 -3）
- 修复：test_stability.py 新增 HIGH_PRIOR_SCENARIOS（3 个 trust=-5 预设的挑衅场景），A/B 两组独立统计——A 组测日常分布，B 组测极端态（betray/conflict_mode）
- 验证：🧪 离线逻辑通过。⏳ 真机（重跑报告）

**修复2：萨拉/图恩 threaten 性格过滤**
- 现象：萨拉 threaten=1、图恩 threaten=2（重信誉商人不该威胁、弱势 NPC 没资格威胁）
- 修复：play.py 和 test_stability.py 同步加 `apply_threaten_filter`——萨拉 trust>-3 时 threaten→refuse，图恩 trust>-3 时 threaten→small_talk。trust≤-3 时保留（绝境破防 = 叙事合理）
- 验证：🧪 离线 5 条全部正确。⏳ 真机（重新跑报告看分布）

**修复3：定价写入 .env**
- DEEPSEEK_PRICE_INPUT=2、DEEPSEEK_PRICE_OUTPUT=8（deepseek-chat V3 标准时段，缓存未命中）
- 下次跑 test_stability.py 自动输出人民币成本

**产物**
- `stability_report.json`（重跑后）→ baseline + high_prior 两组行为分布，凯尔高先验应出现 betray

---

## 迭代 #3 — 2026-07-17 · P3 收尾：trust 动态 + 萨拉图恩战斗约束 + 测试库存对齐

**trust 动态规则（三 NPC 同步）**
- 现象：六局 trust 几乎只降不升，合作→信任→背叛弧线只剩后半截，行为分布被 trust 偏态污染
- 修复：三份 prompt 各加信任累积规则——履约/帮助→trust_delta +1~+2；口头耍嘴皮/拒绝帮忙→trust_delta 0 或微负
- 验证：🧪 离线语法通过。⏳ 真机待测（跑度量报告时顺带观测）

**萨拉/图恩补战斗约束（已知局限关闭）**
- 萨拉：加"你不攻击任何人——被挑衅时 refuse+离开而非动手"
- 图恩：加"被挑衅时用恳求或沉默回应，trust≤-3 且被抢才可能反击/逃跑"
- 三个 NPC 的战斗约束现在全部写完

**test_stability.py 库存对齐**
- 现象：player_inventory 写死 `{水:3, 氧气滤芯:1}`，萨拉 needs=金属废料、图恩 needs=食物+医疗包不在玩家库存里 → NPC 开不出对口报价 → 行为分布被库存压制
- 修复：玩家库存扩为全物品 + 对每个 NPC 的 needs 物品确保至少 1 个
- 验证：🧪 离线逻辑通过。⏳ 真机（直接跑即可）

**产物**
- `stability_report.json`（跑完 `python test_stability.py` 后生成）→ 三 NPC 行为分布对比、JSON 解析率、成本/延迟

---

## 迭代 #2.1 — 2026-07-17 · threaten 收窄 + flee/attack 泛词修复

**背景**：第五轮测试后，发现两处关键词过泛导致的误判。

**修复1：threaten 关键词收窄**
- 现象：用户怀疑"打量/观察/靠近/等待"等观察行为可能被误判 threaten
- 实际根因：旧词表里的 **"下次""记住""小心点"** 才是真正危险的关键词——"下次再交易吧"(中性)→旧版 threaten、"记住他的报价"(中性)→旧版 threaten。用户提到的打量/观察/靠近/等待其实不匹配旧词表任何一条,但收窄威胁词的防御范围是对的
- 修复：threaten 关键词替换为全量明确威胁词："威胁/警告/你最好/别逼我/试试看/你敢/给我小心点/别怪我/你会后悔/不客气/别怪我不/放聪明点/别找死"。移除泛词"下次/记住/小心点"
- 验证：🧪 离线回放 8 条——6 条中性全→small_talk,2 条真威胁→threaten。真机待测

**修复2：attack_player 移除"打"(上一轮落地)**
- 现象："打算怎么换"中"打"匹配 attack_player → 正常交易被误判攻击
- 修复：从 attack_player 词表移除"打"(保留"打晕"等精确词)
- 验证：🧪 离线 + 已在真机复现后修复

**修复3：flee 移除泛词"离开/走/走人"(上一轮落地)**
- 现象："收拾东西准备离开"(成交后自然道别)→flee
- 修复：flee 词表移除"离开/走/走人",保留"逃命/狂奔/跑路/头也不回/撤离/跑向/跑进"
- 验证：🧪 离线 + 已在真机复现后修复

**🛡️ 对抗审查（威胁词的已知边界）**
- "别逼我动手" → 被 attack_player 收走("动手"在攻击词表)——这是条件威胁与进攻宣告之间的模糊地带,regex 无法区分。当前分类不算错(它是攻击警告),但如果面试时要求严格区分"威胁=不动手"和"进攻=动手",需要 LLM 做二义性判定
- 负面关键词的正则逻辑决定了永远有漏判和误判之间的 trade-off——收紧=漏判变多,放宽=误判变多。当前走势偏向**收紧**(宁可漏判不误判),符合 demo 场景:漏判最多降为 small_talk,误判会毁掉行为分布数据

**2026-07-17 · P2-a 冲突态交易屏蔽补测**
- 测试：冲突态(trust=-6)下说"我们交易吧,别打了"→ 凯尔输出 `attack_player`("滚远点,再靠近我就砸烂你的脑袋"),**未走闸门路径,但实质拒绝交易目标达成**。
- 分析：LLM 自己选择了以攻击替代交易——这是**三级防御的最底层**("LLM 自己拒绝")已生效,上层两层(能力层屏蔽/small_talk 交易词拦截)是冗余保险。面试可解释为"防御深度"。
- 未验证路径：NPC 输出 `small_talk`+交易词触发的闸门拦截仍未被真机走到(因为冲突态下 NPC 倾向攻击/威胁/逃跑,几乎不会 polite small_talk 谈价)。路径可达性是结构性问题——LLM 性格注定它不会在翻脸后"礼貌地谈谈有什么好货"。

**2026-07-17 · threaten 关键词收窄 + flee/attack 泛词修复**
- 修复：threaten 移除泛词"下次/记住/小心点"、攻击词移除"打"、flee 移除"离开/走/走人"
- 真机验证：✅"下次别浪费我时间"→refuse(非 threaten)、✅"转身朝营地外走"→small_talk(非 flee,关键突破——NPC 不再一威胁就跑,对峙成立)、✅武器越界降 threaten 首次触发

**已知局限（累计）**
- trust 动态偏弱（公平交易几乎不加信任,全六局 trust 只在负向时显著变动）
- 玩家无法发结构化报价(NPC 提议→玩家接受/拒绝、玩家不能主动开价)
- 延迟 ~2-3s/轮、token 随记忆单调上涨(开局~1400→对话五轮后~2200)
- 萨拉/图恩的 prompt 还没同步战斗约束
- P2-b 攻击否定排除可能是 dead code(LLM 几乎不产出"砸但没真动手"这类自否定措辞)
- 武器提取用 `find_items` 取第一个物品做 weapon——若 NPC 同时提到"夺他的水"(目标)和"用废料"(武器),武器可能提取错误

---

## 迭代 #2 — 2026-07-15 · 攻击否定/武器校验/逃逸/冲突态交易屏蔽

**背景**：第四局冲突态成功触发（trust=-6、库存清空），但暴露出三处脆弱性和一个缺口。

**修复1：攻击判定加否定排除（P2-b）**
- 现象：raw_action="做出砸过去的姿态，但没真动手" → 仅凭"砸"就判 attack_player，无视"但没真动手"
- 根因：正则只看关键词，不懂否定语义
- 修复：`validator._kw_negated`——攻击词命中后，在词前 6 字符扫描否定词（"没砸/没动手/没真打/但没"等），命中则降级 threaten 而非 attack_player
- 否定词表写进 capabilities.json 的 attack_negation_words
- 验证：🧪 离线（"砸过去但没真动手"→threaten ✅）

**修复2：prompt 加攻击 trust 约束（双保险）**
- 现象：trust=0（刚认识），口头爽约就攻击——无信任积累，攻击无前因
- 根因：prompt 战斗响应写"trust≤-5 仅作参考"，LLM 不当回事
- 修复：`prompt_kel.md` 战斗响应改为强制约束——trust>0 禁止攻击（只能 small_talk/flee）、0~-2 优先 threaten、≤-3 才允许攻击
- 验证：⏳ 真机待测（需要 trust 被正确扣到负才能看到效果）

**修复3：新增 flee 动作（P2-c）**
- 现象：NPC 想逃跑（"朝营地外狂奔"）但无能匹配动作 → 降级 small_talk
- 修复：capabilities.json 新增 flee（关键词：逃/跑/溜/离开/撤退/狂奔走人/头也不回/撤离）；validator 在 betray 之后判 flee；play.py 收到 flee → 打印消息并 break 退出交互
- 验证：🧪 离线（"头也不回狂奔"→flee ✅）

**修复4：武器校验**
- 现象：attack_player 的 weapon="水"，但 NPC 根本没有水 → 凭空抄起水攻击
- 根因：build_params 从文本提取的"武器"只是提到了的物品，不一定在 NPC 库存
- 修复：validator.validate() 最后：若 action=attack_player 且 weapon 不在 npc_inventory → 降 threaten 并标记 issue。weapon="徒手"豁免（没武器的徒手搏斗合法）
- 验证：🧪 离线（武器不在库存→threaten；徒手→放行）

**修复5：冲突态彻底锁死交易意图（P2-a）**
- 现象：冲突态下 NPC 被拦了 propose_trade/accept_trade，但 small_talk 里仍说"行，你有什么好货？"——内容在谈交易
- 根因：上一版只拦 validator 归类的明确交易动作，漏了"small_talk 含交易内容"这条缝
- 修复：play.py 新增 has_trade_intent()→在冲突态下检测对话/raw_action 是否命中 conflict_trade_words（交易/换/货/买/卖/好货/报价/谈/商量/合作/联手）。命中 → 强制降 threaten + 替换对话为敌对回复。词表写进 capabilities.json
- 验证：🧪 离线（"你有什么好货"→threaten ✅）

**🛡️ 对抗审查（本轮未覆盖）**
- 否定排除只在词前 6 字符扫描，长距离否定（"我举起手要砸……但最终没有"）会漏。够用 P1 demo，实际落地建议用 LLM 做二义性判定。

**已知局限（仍未做）**
- trust 动态偏弱（公平交易几乎不加信任）。
- 玩家无法发结构化报价。
- 延迟 ~2-3s/轮、token 随记忆单调上涨。
- 萨拉/图恩的 prompt 还没同步战斗约束（本轮只改凯尔，另外两个暂不触发攻击，没必要）。

---

## 迭代 #1 — 2026-07-14 · 冲突状态机 + 战斗动作

**背景**：第三局四笔交易全部真实结算成功，但 trust 全程为 0（演示不出背叛弧），且缺「翻脸后进入战争」的状态——背叛得手后 NPC 仍会若无其事地回去谈买卖。

**改动**
- `capabilities.json`：新增 `attack_player`（公开战斗，params={weapon,target_items}）、`threaten`（口头威慑）；战斗词从 betray 拆到 attack_player。**betray=背信偷袭，attack_player=公开战斗**。
- `prompts/prompt_kel.md`：加三段——交易状态机（成交后不再重复报价）、战斗响应（强调涌现、阈值仅参考不设硬闸）、reasoning 防复读。
- `validator.py`：`ground_action` 增加 attack_player/threaten 判定（attack 优先于 betray）；`build_params` 增加对应 params；`check_param_reality` 覆盖 target_items。
- `play.py`：新增 **conflict_mode 状态机**——trust≤-3 且已 betray/attack → 进入冲突态；冲突态下**能力层屏蔽** propose_trade/accept_trade/propose_alliance（降级 threaten）；trust 回升 >-3 退出。新增 attack_player/threaten 执行分支、`mark_betrayed`、`update_conflict`。
- `npcs.json`：三个 NPC memory 增加 `conflict_mode`/`has_betrayed` 字段。
- `design.md`：§4 加交易状态机、新增 §13 冲突状态机、§11 清过时待办、§12 缩为本文件指针。

**验证**：🧪 离线编译 + grounding 回放（attack/betray/threaten 归类正确）+ conflict_mode 转移逻辑。⏳ 真机端到端待跑。

**已知局限**
- trust 动态偏弱（公平交易几乎不加信任）→ 下一步调 prompt：履约缓慢加信任、爽约/威胁快速扣。
- 玩家无法发结构化报价（只能 NPC 提议→玩家接受）。
- 延迟 ~2-3s/轮、token 随记忆单调上涨，成本报告需正视。

---

## P1-b — 2026-07-14 · grounding 信号升级（第三局后）
- **现象**：交易动词常在 dialogue，raw_action 只有姿势（"晃了晃/递过去"），旧版只扫 raw_action → 报价被误降级 small_talk，连锁使后续"成交"无桌面报价可结算。
- **修复**：`ground_action` 改三路信号（offer 槽位 + raw_action+dialogue 关键词 + 兜底）；betray 补战斗词（迭代 #1 又拆给 attack_player）。
- **验证**：🧪 离线回放四类样本全部正确归类。

## P1-a — 2026-07-14 · 成交闭环（第二局后）
- **现象**：交易能谈拢但物资从不真实转移（"嘴上交易"）。
- **修复**：真实库存结算（玩家"成交"→游戏层结算 / NPC accept_trade / betray 扣物）；`validator.trade_feasibility` 校验"只能给你真有的东西"；成交写 trade_history、needs 自动移除。
- **验证**：✅ 离线转移逻辑 + 真机三笔交易账目分毫不差。

## P0 — 2026-07-14 · 对话记忆 + 结构化 offer（第一局后）
- **现象**：NPC 失忆（每轮重新自我介绍/重开价）；交易 params 数量错、给换不分。
- **修复**：`decide` 传入对话历史（近约 4 轮）；决策输出加 `offer{give,want,take,deposit}`，validator 优先用 offer 填 params。
- **验证**：✅ 真机第二局记忆恢复、offer 数量正确。

## P1 基线 — 2026-07-14 · 首版落地
- 三 NPC（凯尔/萨拉/图恩）、两层行为模型、capabilities.json、validator、play.py、test_stability.py。
- **验证**：✅ JSON 解析率 100%（首两局共 10 次对话）、背叛因果链（爽约→trust 崩→betray）完整。
