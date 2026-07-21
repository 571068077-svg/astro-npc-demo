# llm_bridge.gd — Godot Autoload（LLMBridge）
# 封装 DeepSeek API 调用。异步 HTTP 请求 → 信号回调。
# 移植自 P1 npc_brain.py，语法调整为 GDScript。
extends Node

signal response_ready(npc_id: String, result: Dictionary)
signal request_failed(npc_id: String, error: String)

var _http: HTTPRequest
var _pending_npc: String = ""           # 正在等待回复的 NPC
var _cfg: Dictionary = {}
var _pending_t0: float = 0.0            # 计时起点
const DESIGN_MARKER := "===DESIGN_NOTES==="

func _ready():
	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_response)
	_load_config()

func _load_config():
	"""从 .env 读 DeepSeek 配置（不依赖 python-dotenv，手动解析）。"""
	var f = FileAccess.open("res://.env", FileAccess.READ)
	if not f:
		return
	while not f.eof_reached():
		var line = f.get_line().strip_edges()
		if line.is_empty() or line.begins_with("#") or "=" not in line:
			continue
		var parts = line.split("=", true, 1)
		_cfg[parts[0].strip_edges()] = parts[1].strip_edges()

func load_system_prompt(prompt_file: String) -> String:
	var f = FileAccess.open("res://" + prompt_file, FileAccess.READ)
	if not f:
		return ""
	var text = f.get_as_text()
	var idx = text.find(DESIGN_MARKER)
	if idx != -1:
		text = text.substr(0, idx).strip_edges()
	return text

func build_user_prompt(npc_id: String, world_state: Dictionary, player_action: String, event: String = "") -> String:
	var mem = GameState.npc_memories.get(npc_id, {})
	var trust = mem.get("trust", 0)
	var needs_arr: Array = mem.get("needs", [])
	var needs_str = ", ".join(needs_arr) if not needs_arr.is_empty() else "（暂无）"
	var th: Array = mem.get("trade_history", [])
	var trade_history_str = "；".join(th) if not th.is_empty() else "（无）"
	var broke = mem.get("player_broke_promise", 0)

	var npc_inv = _inv_str(GameState.npc_inventories.get(npc_id, {}))
	var player_inv = _inv_str(GameState.player_inventory)

	var lines: Array[String] = []
	lines.append("【当前处境】")
	lines.append("- 地点：" + world_state.get("location", "荒野营地"))
	lines.append("- 你现在手上的物资：" + npc_inv)
	lines.append("- 你看到玩家携带：" + player_inv)
	lines.append("- 你对玩家的信任值 trust = " + str(trust))
	lines.append("- 你当前急需：" + needs_str)
	lines.append("- 交易历史：" + trade_history_str)
	lines.append("- 玩家爽约次数：" + str(broke))
	if world_state.get("conflict_mode", false):
		lines.append("- ⚠ 你正与玩家处于敌对/对峙状态：已经和他翻过脸，不再信任他，不会再跟他做交易")
	if not event.is_empty():
		lines.append("- 【刚刚发生】" + event)
	lines.append("")
	lines.append("【玩家刚刚】" + player_action)
	lines.append("")
	lines.append("请以你自己的身份，基于以上处境自主决定这一步做什么。严格按系统要求的 JSON 输出，只输出 JSON。")
	return "\n".join(lines)

func _inv_str(inv: Dictionary) -> String:
	if inv.is_empty():
		return "（几乎一无所有）"
	var parts = []
	for key in inv:
		parts.append("%sx%d" % [key, inv[key]])
	return ", ".join(parts)

func send_to_npc(npc_id: String, world_state: Dictionary, player_action: String, history: Array, event: String = ""):
	"""发送玩家输入给指定 NPC。异步——结果通过 response_ready/failed 信号通知。"""
	if not _pending_npc.is_empty():
		request_failed.emit(npc_id, "上一个请求仍在处理中")
		return

	var prompt_file = GameState.get_npc_prompt_file(npc_id)
	var system_prompt = load_system_prompt(prompt_file)
	if system_prompt.is_empty():
		request_failed.emit(npc_id, "无法加载 prompt: " + prompt_file)
		return

	var messages: Array = [{"role": "system", "content": system_prompt}]
	messages.append_array(history.slice(max(0, history.size() - 8)))
	messages.append({"role": "user", "content": build_user_prompt(npc_id, world_state, player_action, event)})

	var url = _cfg.get("DEEPSEEK_BASE_URL", "https://api.deepseek.com").rstrip("/") + "/chat/completions"
	var body = JSON.stringify({
		"model": _cfg.get("DEEPSEEK_MODEL", "deepseek-chat"),
		"messages": messages,
		"temperature": float(_cfg.get("NPC_TEMPERATURE", "0.8")),
		"response_format": {"type": "json_object"},
		"stream": false,
	})
	var headers = [
		"Content-Type: application/json",
		"Authorization: Bearer " + _cfg.get("DEEPSEEK_API_KEY", ""),
	]
	_pending_npc = npc_id
	_pending_t0 = Time.get_ticks_msec() / 1000.0
	_http.request(url, headers, HTTPClient.Method.METHOD_POST, body)

func _on_response(result: int, response_code: int, headers: PackedStringArray, body: PackedByteArray):
	var latency_ms = (Time.get_ticks_msec() / 1000.0 - _pending_t0) * 1000.0
	var npc_id = _pending_npc
	_pending_npc = ""

	if result != HTTPRequest.RESULT_SUCCESS:
		request_failed.emit(npc_id, "HTTP error: %d (code %d)" % [result, response_code])
		return

	if response_code != 200:
		request_failed.emit(npc_id, "HTTP %d: %s" % [response_code, body.get_string_from_utf8().left(200)])
		return

	var json = JSON.new()
	var err = json.parse(body.get_string_from_utf8())
	if err != OK:
		request_failed.emit(npc_id, "JSON parse error: " + json.get_error_message())
		return

	var data = json.data
	var choices = data.get("choices", [])
	if choices.is_empty():
		request_failed.emit(npc_id, "No choices in response")
		return

	var usage = data.get("usage", {})
	response_ready.emit(npc_id, {
		"content": choices[0].get("message", {}).get("content", ""),
		"usage": usage,
		"latency_ms": latency_ms,
		"error": null,
	})
