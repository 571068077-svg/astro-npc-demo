# validator.gd — Godot Autoload（Validator）
# 移植自 P1 validator.py。职责：解析 LLM JSON → schema 校验 → grounding → 参数校验。
# 保持与 Python 版同等语义。
extends Node

const REQUIRED_FIELDS = ["reasoning", "dialogue", "intent", "trust_delta", "emotion"]

func extract_json(text: String) -> Dictionary:
	"""从模型输出里抠出 JSON 对象。返回 {obj: Dictionary|null, ok: bool}。"""
	if text.is_empty():
		return {"obj": null, "ok": false}
	text = text.strip_edges()
	if text.begins_with("```"):
		var re = RegEx.new()
		re.compile("^```[a-zA-Z]*\\n?")
		text = re.sub(text, "")
		re.compile("\\n?```$")
		text = re.sub(text, "").strip_edges()
	var json = JSON.new()
	if json.parse(text) == OK:
		if json.data is Dictionary:
			return {"obj": json.data, "ok": true}
	var l = text.find("{")
	var r = text.rfind("}")
	if l != -1 and r != -1 and r > l:
		var sub = text.substr(l, r - l + 1)
		var j2 = JSON.new()
		if j2.parse(sub) == OK and j2.data is Dictionary:
			return {"obj": j2.data, "ok": true}
	return {"obj": null, "ok": false}

func check_schema(obj: Dictionary) -> Array:
	var issues = []
	for f in REQUIRED_FIELDS:
		if not obj.has(f):
			issues.append("缺字段:" + f)
	var intent = obj.get("intent")
	if intent is Dictionary:
		if not intent.has("raw_action"):
			issues.append("intent缺raw_action")
	else:
		issues.append("intent非对象")
	if obj.has("trust_delta") and not (obj.get("trust_delta") is int or obj.get("trust_delta") is float):
		issues.append("trust_delta非数字")
	return issues

func _kw_hit(text: String, words: Array) -> bool:
	for w in words:
		if w in text:
			return true
	return false

func _kw_negated(text: String, attack_words: Array, negation_words: Array) -> bool:
	if attack_words.is_empty() or negation_words.is_empty():
		return false
	for kw in attack_words:
		var idx = text.find(kw)
		if idx == -1:
			continue
		var before = text.substr(max(0, idx - 6), min(6, idx))
		for n in negation_words:
			if n in before:
				return true
	return false

func ground_action(raw_action: String, dialogue: String, offer: Dictionary, caps: Dictionary) -> Dictionary:
	"""三路信号综合判定动作类型。返回 {action_id, matched}。"""
	offer = offer if offer is Dictionary else {}
	var give: Array = offer.get("give", [])
	var want: Array = offer.get("want", [])
	var take: Array = offer.get("take", [])
	var text = raw_action + " " + dialogue
	var actions = caps.get("actions", [])
	var kw := {}
	for a in actions:
		kw[a["id"]] = a.get("keywords", [])

	# 1) 公开战斗（有否定排除）
	if _kw_hit(text, kw.get("attack_player", [])):
		if _kw_negated(text, kw["attack_player"], caps.get("attack_negation_words", [])):
			return {"action_id": "threaten", "matched": true}
		return {"action_id": "attack_player", "matched": true}
	# 2) 背信偷袭
	if not take.is_empty() or _kw_hit(text, kw.get("betray", [])):
		return {"action_id": "betray", "matched": true}
	# 3) 逃跑
	if _kw_hit(text, kw.get("flee", [])):
		return {"action_id": "flee", "matched": true}
	# 4) 口头威慑
	if _kw_hit(text, kw.get("threaten", [])):
		return {"action_id": "threaten", "matched": true}
	# 5) 结盟
	if _kw_hit(text, kw.get("propose_alliance", [])):
		return {"action_id": "propose_alliance", "matched": true}
	# 6) 交易优先：want 有货（单向赠予/换取）→ 先判交易，别被 ask_help 抢走
	if not want.is_empty() and give.is_empty():
		return {"action_id": "propose_trade", "matched":true}
	# 7) 求助：只想要、不给，且有求助语气
	if not want.is_empty() and give.is_empty() and _kw_hit(text, kw.get("ask_help", [])):
		return {"action_id": "ask_help", "matched": true}
	# 8) 拒绝
	if _kw_hit(text, kw.get("refuse", [])):
		return {"action_id": "refuse", "matched": true}
	# 9) 交易
	if not give.is_empty() or _kw_hit(text, kw.get("propose_trade", [])):
		return {"action_id": "propose_trade", "matched": true}
	return {"action_id": "small_talk", "matched": false}

func _clean_items(lst, world_items: Array) -> Dictionary:
	var clean = []
	var bad = []
	if lst is Array:
		for x in lst:
			if x is Dictionary and x.has("item"):
				if x["item"] in world_items:
					clean.append({"item": x["item"], "qty": int(x.get("qty", 1))})
				else:
					bad.append(x["item"])
	return {"clean": clean, "bad": bad}

func find_items(text: String, world_items: Array) -> Array:
	var found = []
	for item in world_items:
		if item in text:
			found.append({"item": item, "qty": 1})
	return found

func build_params(action_id: String, offer: Dictionary, raw_action: String, world_items: Array) -> Dictionary:
	offer = offer if offer is Dictionary else {}
	var text = raw_action
	var gi = _clean_items(offer.get("give"), world_items)
	var wi = _clean_items(offer.get("want"), world_items)
	var ti = _clean_items(offer.get("take"), world_items)
	var bad = gi["bad"] + wi["bad"] + ti["bad"]
	var deposit = offer.get("deposit", false) or ("定金" in text) or ("预付" in text)
	var flee = ("逃" in text) or ("跑路" in text) or ("狂奔" in text)
	var regex_items = find_items(text, world_items) if gi["clean"].is_empty() and wi["clean"].is_empty() and ti["clean"].is_empty() else []

	match action_id:
		"attack_player":
			var mentioned = find_items(text, world_items)
			var weapon = mentioned[0].get("item", "徒手") if not mentioned.is_empty() else "徒手"
			return {"params": {"weapon": weapon, "target_items": ti["clean"]}, "bad": bad}
		"betray":
			return {"params": {"take": ti["clean"] if not ti["clean"].is_empty() else regex_items, "flee": flee}, "bad": bad}
		"ask_help":
			return {"params": {"request": wi["clean"] if not wi["clean"].is_empty() else regex_items}, "bad": bad}
		"propose_trade":
			return {"params": {"give": gi["clean"], "want": wi["clean"] if not wi["clean"].is_empty() else regex_items, "deposit": deposit}, "bad": bad}
		"accept_trade":
			return {"params": {"give": gi["clean"], "want": wi["clean"]}, "bad": bad}
		"propose_alliance":
			return {"params": {"terms": text.left(60)}, "bad": bad}
		"threaten":
			return {"params": {}, "bad": bad}
		_:
			return {"params": {}, "bad": bad}

func validate(decision_text: String, world_state: Dictionary) -> Dictionary:
	"""主入口：解析 → schema → grounding → 参数校验 → 武器校验。返回与 P1 兼容的 result dict。"""
	var caps = GameState.capabilities
	var result := {
		"parse_ok": false, "schema_ok": false, "grounded": false, "degraded": false,
		"action": "small_talk", "params": {}, "issues": [], "decision": null,
	}
	var extracted = extract_json(decision_text)
	result["parse_ok"] = extracted["ok"]
	if not extracted["ok"]:
		result["issues"].append("JSON无法解析")
		return result

	result["decision"] = extracted["obj"]
	var obj: Dictionary = extracted["obj"]

	var schema_issues = check_schema(obj)
	result["schema_ok"] = schema_issues.is_empty()
	result["issues"].append_array(schema_issues)

	var intent = obj.get("intent", {})
	var raw_action = intent.get("raw_action", "") if intent is Dictionary else ""
	var dialogue_str = obj.get("dialogue", "") if obj.get("dialogue") is String else ""
	var offer = obj.get("offer", {}) if obj.get("offer") is Dictionary else {}

	var ground = ground_action(raw_action, dialogue_str, offer, caps)
	var action = ground["action_id"]
	var matched = ground["matched"]
	var bp = build_params(action, offer, raw_action, caps.get("world_items", []))
	result["action"] = action
	result["params"] = bp["params"]
	result["grounded"] = matched
	result["degraded"] = not matched
	if not matched and not raw_action.is_empty():
		result["issues"].append("意图越界→降级small_talk")
	if not bp["bad"].is_empty():
		result["issues"].append("offer含不存在物品:" + ", ".join(bp["bad"]))

	# 武器校验
	_check_weapon(result, world_state)
	return result

func _check_weapon(v: Dictionary, world_state: Dictionary):
	if v["action"] != "attack_player":
		return
	var weapon = v["params"].get("weapon", "")
	if weapon.is_empty() or weapon == "徒手":
		return
	var npc_id = GameState.current_npc
	if npc_id.is_empty():
		return
	var npc_inv = GameState.npc_inventories.get(npc_id, {})
	if weapon not in npc_inv:
		v["issues"].append("武器越界:%s(NPC库存无此物)→降threaten" % weapon)
		v["action"] = "threaten"
		v["params"] = {}
		v["degraded"] = true

# ---- NPC 级性格过滤 ----
const ATTACK_FILTER := {"sara": "refuse", "tun": "flee"}
const THREATEN_FILTER := {"sara": "refuse", "tun": "small_talk"}

func apply_npc_filters(npc_id: String, v: Dictionary):
	var trust = GameState.get_trust(npc_id)
	if v["action"] == "threaten":
		var to = THREATEN_FILTER.get(npc_id, "")
		if not to.is_empty() and trust > -3:
			v["action"] = to
			v["params"] = {}
			v["grounded"] = true
			v["degraded"] = false
			v["issues"].append("threaten性格过滤→%s" % to)
	if v["action"] == "attack_player":
		var to = ATTACK_FILTER.get(npc_id, "")
		if not to.is_empty():
			v["action"] = to
			v["params"] = {}
			v["grounded"] = true
			v["degraded"] = false
			v["issues"].append("attack_player性格过滤→%s" % to)
