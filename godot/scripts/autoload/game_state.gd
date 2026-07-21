# game_state.gd — Godot Autoload 单例（GameState）
# 持有全局游戏状态：玩家库存、NPC 记忆、能力清单、对话历史。
# P1 的 world/npc["memory"]/npcs.json 全部迁移到这里。
extends Node

signal npc_updated(npc_id: String)
signal trade_settled(npc_id: String, msg: String)
signal conflict_entered(npc_id: String)
signal inventory_changed()

var capabilities: Dictionary = {}
var npc_configs: Dictionary = {}
var npc_memories: Dictionary = {}   # npc_id -> {trust, needs, trade_history, ...}
var npc_inventories: Dictionary = {} # npc_id -> {item: qty}
var player_inventory: Dictionary = {"水": 3, "氧气滤芯": 1}
var current_npc: String = ""         # 正在对话的 NPC
var dialog_history: Array = []       # [{role, content}, ...]
var pending_offer: Array = []   # 桌面待成交报价 [{gives, wants}]

func _ready():
	_load_capabilities()
	_load_npc_configs()
	_init_npc_state()

func _load_capabilities():
	var f = FileAccess.open("res://capabilities.json", FileAccess.READ)
	if f:
		var text = f.get_as_text()
		var json = JSON.new()
		if json.parse(text) == OK:
			capabilities = json.data
		else:
			printerr("capabilities.json parse error: ", json.get_error_message())

func _load_npc_configs():
	var f = FileAccess.open("res://npcs.json", FileAccess.READ)
	if f:
		var text = f.get_as_text()
		var json = JSON.new()
		if json.parse(text) == OK:
			npc_configs = json.data

func _init_npc_state():
	for key in npc_configs:
		if key.begins_with("_"):
			continue
		var cfg = npc_configs[key]
		var mem = cfg.get("memory", {}).duplicate(true)
		mem["conflict_mode"] = false
		mem["has_betrayed"] = false
		npc_memories[key] = mem
		npc_inventories[key] = cfg.get("inventory", {}).duplicate(true)

func get_npc_name(key: String) -> String:
	return npc_configs.get(key, {}).get("name", key)

func get_npc_archetype(key: String) -> String:
	return npc_configs.get(key, {}).get("archetype", "")

func get_npc_prompt_file(key: String) -> String:
	return npc_configs.get(key, {}).get("prompt_file", "")

func get_trust(key: String) -> int:
	return npc_memories.get(key, {}).get("trust", 0)

func set_trust(key: String, val: int):
	npc_memories[key]["trust"] = clamp(val, -10, 10)

func get_needs(key: String) -> Array:
	return npc_memories.get(key, {}).get("needs", [])

func add_trade_history(key: String, entry: String):
	var th = npc_memories[key].get("trade_history", [])
	th.append(entry)

func increment_broke_promise(key: String):
	var m = npc_memories[key]
	m["player_broke_promise"] = m.get("player_broke_promise", 0) + 1

func has_item(npc_id: String, item: String, qty: int) -> bool:
	return npc_inventories.get(npc_id, {}).get(item, 0) >= qty

func player_has(item: String, qty: int) -> bool:
	return player_inventory.get(item, 0) >= qty

func move_items(from_inv: Dictionary, to_inv: Dictionary, items: Array):
	for it in items:
		var name = it.get("item", "")
		var qty = it.get("qty", 1)
		from_inv[name] = from_inv.get(name, 0) - qty
		if from_inv.get(name, 0) <= 0:
			from_inv.erase(name)
		to_inv[name] = to_inv.get(name, 0) + qty

func settle_trade(npc_id: String, gives: Array, wants: Array) -> Dictionary:
	"""结算一笔交易。NPC 给出 gives、得到 wants。返回 {ok, msg}。"""
	var npc_inv = npc_inventories[npc_id]
	# 可行性校验
	var issues = []
	for it in gives:
		if not has_item(npc_id, it.get("item", ""), it.get("qty", 1)):
			issues.append("对方拿不出%s" % it.get("item", ""))
	for it in wants:
		if not player_has(it.get("item", ""), it.get("qty", 1)):
			issues.append("你没有%s" % it.get("item", ""))
	if issues:
		return {"ok": false, "msg": "交易无法达成: " + "；".join(issues)}
	move_items(npc_inv, player_inventory, gives)
	move_items(player_inventory, npc_inv, wants)
	var give_str = _fmt_items(gives)
	var want_str = _fmt_items(wants)
	add_trade_history(npc_id, "给玩家%s换得%s" % [give_str, want_str])
	for w in wants:
		var needed = get_needs(npc_id)
		if w.get("item", "") in needed:
			needed.erase(w.get("item", ""))
	trade_settled.emit(npc_id, "交易达成: %s给出%s，得到%s" % [get_npc_name(npc_id), give_str, want_str])
	inventory_changed.emit()
	return {"ok": true, "msg": "交易达成"}

func settle_betray(npc_id: String, takes: Array) -> Dictionary:
	"""背叛结算：把 take 从玩家转到 NPC。"""
	if takes.is_empty():
		return {"ok": false, "msg": "背叛落空: 没锁定物品"}
	var issues = []
	for it in takes:
		if not player_has(it.get("item", ""), it.get("qty", 1)):
			issues.append("你没有%s" % it.get("item", ""))
	if issues:
		return {"ok": false, "msg": "背叛落空: " + "；".join(issues)}
	move_items(player_inventory, npc_inventories[npc_id], takes)
	npc_memories[npc_id]["has_betrayed"] = true
	npc_memories[npc_id]["trade_history"].append("(已背叛)")
	conflict_entered.emit(npc_id)
	inventory_changed.emit()
	return {"ok": true, "msg": "%s抢走了 %s" % [get_npc_name(npc_id), _fmt_items(takes)]}

func _fmt_items(items: Array) -> String:
	if items.is_empty():
		return "（无）"
	var parts = []
	for it in items:
		parts.append("%sx%d" % [it.get("item", "?"), it.get("qty", 1)])
	return ", ".join(parts)
