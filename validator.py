"""validator.py —— AI-NPC 能力层（行为验证器）

职责：把意图层【自由生成】的 raw_action，grounding 到 capabilities.json 里
引擎真正能执行的动作。这是「自主性」与「可执行」之间的那一层工程。

分层校验（成本从低到高）：
  ① 确定性检查（0 成本）：JSON 能否解析、schema 是否完整、params 物品是否真实存在
  ② 关键词映射：raw_action → capabilities 里的 action
  ③ 越界降级：映射不上就降级为 small_talk，并记录到 issues（这些越界样本=功能扩展路线图）

注：本文件【不】默认调用第二次 LLM 做语义映射——那会让成本翻倍。留作后续「意图模糊时」的可选兜底。
"""
import os
import re
import json

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
REQUIRED_FIELDS = ["reasoning", "dialogue", "intent", "trust_delta", "emotion"]


def load_capabilities():
    with open(os.path.join(BASE_DIR, "capabilities.json"), "r", encoding="utf-8") as f:
        return json.load(f)


def extract_json(text):
    """稳健地从模型输出里抠出 JSON。返回 (obj, ok)。"""
    if text is None:
        return None, False
    text = text.strip()
    if text.startswith("```"):
        text = re.sub(r"^```[a-zA-Z]*\n?", "", text)
        text = re.sub(r"\n?```$", "", text).strip()
    try:
        return json.loads(text), True
    except Exception:
        pass
    l, r = text.find("{"), text.rfind("}")
    if l != -1 and r != -1 and r > l:
        try:
            return json.loads(text[l:r + 1]), True
        except Exception:
            return None, False
    return None, False


def check_schema(obj):
    issues = []
    for f in REQUIRED_FIELDS:
        if f not in obj:
            issues.append(f"缺字段:{f}")
    if isinstance(obj.get("intent"), dict):
        if "raw_action" not in obj["intent"]:
            issues.append("intent缺raw_action")
    else:
        issues.append("intent非对象")
    if "trust_delta" in obj and not isinstance(obj["trust_delta"], (int, float)):
        issues.append("trust_delta非数字")
    return issues


def find_items(text, world_items):
    """从自由文本里识别真实存在的物资及数量（只认 world_items 里的，天然防幻觉）。"""
    found = []
    for item in world_items:
        if item in text:
            m = re.search(re.escape(item) + r"\s*[x×]?\s*(\d+)", text)
            found.append({"item": item, "qty": int(m.group(1)) if m else 1})
    return found


def _clean_items(lst, world_items):
    """只保留真实存在的物品条目；返回 (clean, bad_names)。bad=引用了不存在的物品（幻觉）。"""
    clean, bad = [], []
    if isinstance(lst, list):
        for x in lst:
            if isinstance(x, dict) and "item" in x:
                if x["item"] in world_items:
                    try:
                        qty = int(x.get("qty", 1))
                    except (TypeError, ValueError):
                        qty = 1
                    clean.append({"item": x["item"], "qty": qty})
                else:
                    bad.append(x["item"])
    return clean, bad


def build_params(action_id, offer, raw_action, world_items):
    """优先用模型给的结构化 offer 填 params；offer 缺失时回退到从 raw_action 正则抽取。
    返回 (params, bad_items)。这里只把【实体】结构化，动作类型仍由 ground_action 读 raw_action 决定。"""
    offer = offer or {}
    text = raw_action or ""
    give, b1 = _clean_items(offer.get("give"), world_items)
    want, b2 = _clean_items(offer.get("want"), world_items)
    take, b3 = _clean_items(offer.get("take"), world_items)
    bad = b1 + b2 + b3
    deposit = bool(offer.get("deposit", False)) or ("定金" in text) or ("预付" in text)
    flee = any(w in text for w in ["逃", "跑", "溜", "走人", "开溜"])
    regex_items = find_items(text, world_items) if not (give or want or take) else []
    if action_id == "attack_player":
        mentioned = find_items(text, world_items)
        weapon = mentioned[0]["item"] if mentioned else "徒手"
        return {"weapon": weapon, "target_items": take}, bad
    if action_id == "betray":
        return {"take": take or regex_items, "flee": flee}, bad
    if action_id == "ask_help":
        return {"request": want or regex_items}, bad
    if action_id == "propose_trade":
        return {"give": give, "want": want or regex_items, "deposit": deposit}, bad
    if action_id == "accept_trade":
        return {"give": give, "want": want}, bad
    if action_id == "propose_alliance":
        return {"terms": text[:60]}, bad
    if action_id == "threaten":
        return {}, bad
    return {}, bad


def _kw_hit(text, words):
    return any(w in text for w in words)


def _kw_negated(text, attack_words, negation_words):
    """检查攻击关键词是否被否定词修饰。返回 True 表示「有攻击词但被否定了」。
    例："做出砸过去的姿态，但没真动手" → attack_words 命中"砸"、"动手"，但"但没真动手"否定了。"""
    if not attack_words or not negation_words:
        return False
    for kw in attack_words:
        idx = text.find(kw)
        if idx == -1:
            continue
        # 在关键词前 5 个字符内找否定词
        before = text[max(0, idx - 6):idx]
        if any(n in before for n in negation_words):
            return True
    return False


def ground_action(raw_action, dialogue, offer, caps):
    """把 NPC 的自由意图 grounding 到能力清单里的一个 action。综合三路信号（比只看 raw_action 关键词稳）：
      1) 结构化 offer 槽位（take=夺取；give/want=交易）——最稳，不依赖措辞；
      2) raw_action + dialogue 的关键词——交易动词常出现在台词里；
      3) 兜底 small_talk。
    动作类型仍由 NPC 自己的表达（自由文本+物品槽）决定——它从没见过动作清单，validator 只做映射。
    返回 (action_id, matched)。"""
    offer = offer or {}
    give = offer.get("give") or []
    want = offer.get("want") or []
    take = offer.get("take") or []
    text = (raw_action or "") + " " + (dialogue or "")
    kw = {a["id"]: a.get("keywords", []) for a in caps["actions"]}

    # 1) 公开战斗:命中战斗词 且 未被否定("没砸/没动手"->不算攻击)
    if _kw_hit(text, kw.get("attack_player", [])):
        if _kw_negated(text, kw.get("attack_player", []), caps.get("attack_negation_words", [])):
            return "threaten", True   # 有攻击意图但没真动手 -> 威胁
        return "attack_player", True
    # 2) 背信偷袭:take 槽有货,或命中背叛词
    if take or _kw_hit(text, kw.get("betray", [])):
        return "betray", True
    # 3) 逃跑/撤退
    if _kw_hit(text, kw.get("flee", [])):
        return "flee", True
    # 4) 口头威慑
    if _kw_hit(text, kw.get("threaten", [])):
        return "threaten", True
    # 5) 结盟
    if _kw_hit(text, kw.get("propose_alliance", [])):
        return "propose_alliance", True
    # 6) 求助:只想要、不给,且有求助语气
    if want and not give and _kw_hit(text, kw.get("ask_help", [])):
        return "ask_help", True
    # 7) 明确拒绝(放在交易前,避免"不换"被当成交易)
    if _kw_hit(text, kw.get("refuse", [])):
        return "refuse", True
    # 8) 交易:有结构化的给/换,或命中交易词
    if give or want or _kw_hit(text, kw.get("propose_trade", [])):
        return "propose_trade", True
    return "small_talk", False


def check_param_reality(params, world_state):
    """校验 params 引用的物品是否出现在当前场景（双方库存）里，抓幻觉/不在场物品。"""
    issues = []
    known = set(world_state.get("npc_inventory", {})) | set(world_state.get("player_inventory", {}))
    for key in ("give", "want", "take", "request", "target_items"):
        for x in params.get(key, []):
            if isinstance(x, dict) and x.get("item") not in known:
                issues.append(f"场景无此物:{x.get('item')}")
    return issues


def trade_feasibility(npc_gives, npc_wants, npc_inv, player_inv):
    """校验一笔交易能否成交：NPC 得真有它要给的，玩家得真有 NPC 想要的。
    这就是「你只能给你真有的东西」——防止用不存在的物资凭空成交。返回 issues（空=可行）。"""
    issues = []
    for it in (npc_gives or []):
        if npc_inv.get(it["item"], 0) < it.get("qty", 1):
            issues.append(f"对方拿不出{it['item']}x{it.get('qty', 1)}(现有{npc_inv.get(it['item'], 0)})")
    for it in (npc_wants or []):
        if player_inv.get(it["item"], 0) < it.get("qty", 1):
            issues.append(f"你没有{it['item']}x{it.get('qty', 1)}(现有{player_inv.get(it['item'], 0)})")
    return issues


def validate(decision_text, world_state, caps=None):
    """主入口：解析 → schema 校验 → grounding → 参数现实性校验。返回结构化结果。"""
    if caps is None:
        caps = load_capabilities()
    result = {
        "parse_ok": False, "schema_ok": False, "grounded": False, "degraded": False,
        "action": None, "params": {}, "issues": [], "decision": None,
    }
    obj, ok = extract_json(decision_text)
    result["parse_ok"] = ok
    if not ok:
        result["issues"].append("JSON无法解析")
        return result
    result["decision"] = obj

    schema_issues = check_schema(obj)
    result["schema_ok"] = (len(schema_issues) == 0)
    result["issues"].extend(schema_issues)

    raw_action = obj.get("intent", {}).get("raw_action", "") if isinstance(obj.get("intent"), dict) else ""
    dialogue = obj.get("dialogue", "") if isinstance(obj.get("dialogue"), str) else ""
    offer = obj.get("offer") if isinstance(obj.get("offer"), dict) else {}
    action, matched = ground_action(raw_action, dialogue, offer, caps)
    params, bad = build_params(action, offer, raw_action, caps["world_items"])
    result["action"], result["params"], result["grounded"], result["degraded"] = action, params, matched, not matched
    if not matched and raw_action:
        result["issues"].append("意图越界→降级small_talk")
    if bad:
        result["issues"].append("offer含不存在物品:" + ",".join(map(str, bad)))
    result["issues"].extend(check_param_reality(params, world_state))

    # 武器校验：attack_player 的 weapon 必须是 NPC 库存里有的物品
    if action == "attack_player":
        weapon = params.get("weapon", "")
        npc_inv = world_state.get("npc_inventory", {})
        if weapon and weapon != "徒手" and weapon not in npc_inv:
            result["issues"].append(f"武器越界:{weapon}(NPC库存无此物)→降threaten")
            result["action"] = "threaten"
            result["params"] = {}
            result["degraded"] = True

    return result
