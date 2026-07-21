# dialog_box.gd —— 对话框 + 状态面板 UI
extends Control

# 对话框子节点
var panel: Panel
var npc_name_label: Label
var dialog_text: TextEdit
var player_input: LineEdit
var send_button: Button
var accept_button: Button
var refuse_button: Button
var thinking_indicator: ColorRect
var conflict_badge: Label
var flee_panel: Panel

# 状态面板子节点（右侧独立面板）
var status_panel: Panel
var status_npc_name: Label
var _status_npc_inv_title: Label
var status_trust_value: Label
var status_trust_bar: ProgressBar
var status_player_inv: RichTextLabel
var status_npc_inv: RichTextLabel
var status_needs: Label
var status_archetype: Label
var status_conflict: Label

var _current_npc_id: String = ""
var _pending_offer: Array = []
var _last_settlement_failed := false   # 上笔交易结算失败→覆盖 trust_delta
var _is_thinking := false
var close_callback: Callable

func _build_full_ui():
	mouse_filter = MOUSE_FILTER_IGNORE
	set_anchors_preset(PRESET_FULL_RECT)

	# --- 公共 StyleBox ---
	var ps = StyleBoxFlat.new()
	ps.bg_color = Color(0.08, 0.08, 0.12, 0.95)
	ps.border_width_left = 2; ps.border_width_right = 2
	ps.border_width_top = 2; ps.border_width_bottom = 2
	ps.border_color = Color(0.3, 0.3, 0.4)
	ps.set_corner_radius_all(8)

	# ==================== 对话框面板（底部） ====================
	panel = Panel.new()
	panel.name = "DialogPanel"
	panel.clip_contents = true
	panel.add_theme_stylebox_override("panel", ps)
	panel.position = Vector2(44, 100)
	panel.size = Vector2(680, 540)
	add_child(panel)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 4)
	vbox.set_anchors_preset(PRESET_FULL_RECT)
	panel.add_child(vbox)
	# offset 在 add_child 之后设——避免 Godot 用父宽度=0 算错 offset_right/offset_bottom
	vbox.offset_left = 10
	vbox.offset_top = 8
	vbox.offset_right = 670
	vbox.offset_bottom = 532

	# Top row
	var top = HBoxContainer.new()
	vbox.add_child(top)
	npc_name_label = _mk_label("NPC", Color(0.3, 0.6, 1), 20)
	top.add_child(npc_name_label)
	var sp = Control.new(); sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL; top.add_child(sp)
	conflict_badge = _mk_label("⚔冲突态", Color(1, 0.2, 0.2), 14)
	top.add_child(conflict_badge)
	var close_btn = _mk_button("✕")
	close_btn.custom_minimum_size = Vector2(32, 28)
	close_btn.pressed.connect(close_dialog)
	top.add_child(close_btn)

	# 对话区：TextEdit 自带滚动条，设只读，不需要 ScrollContainer
	dialog_text = TextEdit.new()
	dialog_text.name = "DialogText"
	dialog_text.editable = false
	dialog_text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	dialog_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dialog_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	dialog_text.custom_minimum_size = Vector2(0, 420)
	vbox.add_child(dialog_text)

	# Thinking indicator
	thinking_indicator = ColorRect.new()
	thinking_indicator.color = Color(0.2, 0.3, 0.5, 0.8)
	thinking_indicator.custom_minimum_size = Vector2(0, 18)
	vbox.add_child(thinking_indicator)
	var think_lbl = Label.new()
	think_lbl.text = "NPC 正在思考..."
	think_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	think_lbl.add_theme_color_override("font_color", Color(0.7, 0.8, 1))
	think_lbl.set_anchors_preset(PRESET_FULL_RECT)
	thinking_indicator.add_child(think_lbl)

	# Input row
	var in_row = HBoxContainer.new()
	vbox.add_child(in_row)
	player_input = LineEdit.new()
	player_input.placeholder_text = "输入你想说的话，回车发送..."
	player_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	player_input.focus_entered.connect(_on_input_focus_in)
	player_input.focus_exited.connect(_on_input_focus_out)
	in_row.add_child(player_input)
	var ime_label = Label.new()
	ime_label.text = "💬"
	ime_label.tooltip_text = "输入中文时候选词在系统输入法栏显示"
	ime_label.add_theme_font_size_override("font_size", 10)
	ime_label.add_theme_color_override("font_color", Color(0.4, 0.4, 0.4))
	in_row.add_child(ime_label)
	send_button = _mk_button("发送")
	in_row.add_child(send_button)

	# Accept / Refuse
	var act_row = HBoxContainer.new()
	act_row.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_child(act_row)
	accept_button = _mk_button("接受报价")
	accept_button.add_theme_color_override("font_color", Color(0.3, 1, 0.3))
	act_row.add_child(accept_button)
	refuse_button = _mk_button("拒绝报价")
	refuse_button.add_theme_color_override("font_color", Color(1, 0.3, 0.3))
	act_row.add_child(refuse_button)

	# Flee overlay
	flee_panel = Panel.new()
	flee_panel.add_theme_stylebox_override("panel", ps)
	flee_panel.set_anchors_preset(PRESET_FULL_RECT)
	add_child(flee_panel)
	var flee_lbl = _mk_label("NPC 离开了现场", Color(1, 0.5, 0.2), 24)
	flee_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	flee_lbl.set_anchors_preset(Control.PRESET_CENTER)
	flee_panel.add_child(flee_lbl)

	# ==================== 状态面板（右侧） ====================
	status_panel = Panel.new()
	status_panel.name = "StatusPanel"
	status_panel.clip_contents = true
	var sps = StyleBoxFlat.new()
	sps.bg_color = Color(0.05, 0.05, 0.08, 0.92)
	sps.border_width_left = 2; sps.border_width_right = 2
	sps.border_width_top = 2; sps.border_width_bottom = 2
	sps.border_color = Color(0.25, 0.25, 0.35)
	sps.set_corner_radius_all(8)
	status_panel.add_theme_stylebox_override("panel", sps)
	status_panel.position = Vector2(740, 16)
	status_panel.size = Vector2(280, 350)
	add_child(status_panel)

	# ScrollContainer 包裹整个状态面板内容，内容超出时可滚动
	var status_scroll = ScrollContainer.new()
	status_scroll.name = "StatusScroll"
	status_scroll.set_anchors_preset(PRESET_FULL_RECT)
	status_scroll.offset_left = 12
	status_scroll.offset_top = 12
	status_scroll.offset_right = -12
	status_scroll.offset_bottom = -12
	status_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	status_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	status_panel.add_child(status_scroll)

	var svbox = VBoxContainer.new()
	svbox.add_theme_constant_override("separation", 6)
	svbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_scroll.add_child(svbox)

	# 标题
	var title = _mk_label("📋 NPC 状态", Color(0.5, 0.7, 1), 18)
	svbox.add_child(title)

	var sep1 = HSeparator.new(); svbox.add_child(sep1)

	# NPC 名字 + 性格
	var name_row = HBoxContainer.new(); svbox.add_child(name_row)
	_mk(name_row, "角色: ", Color(0.6, 0.6, 0.6))
	status_npc_name = _mk_label("--", Color(1, 1, 1), 16)
	name_row.add_child(status_npc_name)
	status_archetype = _mk_label("", Color(0.5, 0.5, 0.5), 12)
	svbox.add_child(status_archetype)

	var sep2 = HSeparator.new(); svbox.add_child(sep2)

	# Trust
	var trust_title_row = HBoxContainer.new(); svbox.add_child(trust_title_row)
	_mk(trust_title_row, "信任度: ", Color(0.6, 0.6, 0.6))
	status_trust_value = _mk_label("0", Color.WHITE, 20)
	trust_title_row.add_child(status_trust_value)
	_mk(trust_title_row, " / -10 ~ +10", Color(0.4, 0.4, 0.4))
	status_conflict = _mk_label("⚔ 冲突", Color(1, 0.15, 0.15), 14)
	status_conflict.hide()
	trust_title_row.add_child(status_conflict)

	status_trust_bar = ProgressBar.new()
	status_trust_bar.min_value = 0; status_trust_bar.max_value = 20; status_trust_bar.value = 10
	status_trust_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_trust_bar.custom_minimum_size = Vector2(0, 20)
	svbox.add_child(status_trust_bar)

	# Needs
	status_needs = _mk_label("急需: --", Color(1, 0.6, 0.3), 13)
	svbox.add_child(status_needs)

	var sep3 = HSeparator.new(); svbox.add_child(sep3)

	# 玩家库存
	_mk(svbox, "[你的物资]", Color(0.7, 0.9, 0.7))
	status_player_inv = RichTextLabel.new()
	status_player_inv.bbcode_enabled = true
	status_player_inv.fit_content = true
	status_player_inv.custom_minimum_size = Vector2(0, 60)
	svbox.add_child(status_player_inv)

	# NPC 库存
	var ni_title = HBoxContainer.new(); svbox.add_child(ni_title)
	_mk(ni_title, "[", Color(0.6, 0.6, 0.6))
	var ni_name = _mk_label("NPC", Color(0.8, 0.6, 0.4), 13)
	ni_name.name = "StatusNPCInvTitle"
	_status_npc_inv_title = ni_name
	ni_title.add_child(ni_name)
	_mk(ni_title, " 的物资]", Color(0.6, 0.6, 0.6))
	status_npc_inv = RichTextLabel.new()
	status_npc_inv.bbcode_enabled = true
	status_npc_inv.fit_content = true
	status_npc_inv.custom_minimum_size = Vector2(0, 60)
	svbox.add_child(status_npc_inv)

	# Signals
	send_button.pressed.connect(_on_send)
	player_input.text_submitted.connect(_on_text_submitted)
	accept_button.pressed.connect(_on_accept)
	refuse_button.pressed.connect(_on_refuse)
	LLMBridge.response_ready.connect(_on_npc_response)
	LLMBridge.request_failed.connect(_on_npc_error)

	# 窗口焦点恢复：切回窗口时自动让输入框重新获取焦点
	get_window().focus_entered.connect(_on_window_focus_in)

	# Start hidden
	set_process_unhandled_input(false)
	panel.hide()
	status_panel.hide()
	flee_panel.hide()
	conflict_badge.hide()
	thinking_indicator.hide()

func _mk(parent: Control, txt: String, clr: Color) -> void:
	var l = Label.new(); l.text = txt
	l.add_theme_color_override("font_color", clr)
	l.add_theme_font_size_override("font_size", 13)
	parent.add_child(l)

func _mk_label(txt: String, clr: Color, sz: int) -> Label:
	var l = Label.new(); l.text = txt
	l.add_theme_color_override("font_color", clr)
	l.add_theme_font_size_override("font_size", sz)
	return l

func _mk_button(txt: String) -> Button:
	var b = Button.new(); b.text = txt
	var bs = StyleBoxFlat.new()
	bs.bg_color = Color(0.2, 0.2, 0.3)
	bs.border_width_left = 1; bs.border_width_right = 1
	bs.border_width_top = 1; bs.border_width_bottom = 1
	bs.border_color = Color(0.4, 0.4, 0.5)
	bs.set_corner_radius_all(4)
	b.add_theme_stylebox_override("normal", bs)
	return b


func _append_dialog(p_bbcode: String) -> void:
	dialog_text.insert_text_at_caret(_strip_bbcode(p_bbcode) + "\n")
	await get_tree().process_frame
	dialog_text.scroll_vertical = dialog_text.get_line_count()

func _strip_bbcode(s: String) -> String:
	var r = RegEx.new()
	r.compile("\\[.*?\\]")
	return r.sub(s, "", true)
# ==================== 公开接口 ====================

func open_for_npc(npc_id: String, _caller = null):
	_current_npc_id = npc_id
	GameState.current_npc = npc_id
	GameState.dialog_history.clear()

	_pending_offer.clear()
	npc_name_label.text = GameState.get_npc_name(npc_id)
	dialog_text.text = ""
	_append_dialog("[b]%s[/b] 出现了。你想说什么？" % GameState.get_npc_name(npc_id))
	_refresh_status_panel()
	_update_conflict_badge()
	player_input.text = ""
	player_input.editable = true
	player_input.grab_focus()
	send_button.disabled = false
	accept_button.hide()
	refuse_button.hide()
	set_process_unhandled_input(true)
	panel.show()
	status_panel.show()

func close_dialog():
	set_process_unhandled_input(false)
	panel.hide()
	status_panel.hide()
	GameState.current_npc = ""
	if close_callback.is_valid():
		close_callback.call()

# ==================== 输入 ====================

func _unhandled_input(event: InputEvent):
	if not panel.visible: return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		close_dialog(); get_viewport().set_input_as_handled()

func _on_send():
	if _is_thinking: return
	var text = player_input.text.strip_edges()
	if text.is_empty(): return
	player_input.text = ""
	_send_to_npc(text)

func _on_text_submitted(text: String):
	if _is_thinking: return
	var t = text.strip_edges()
	if t.is_empty(): return
	player_input.text = ""
	_send_to_npc(t)

func _on_input_focus_in():
	get_window().set_ime_active(true)

func _on_input_focus_out():
	get_window().set_ime_active(false)

func _on_window_focus_in():
	if player_input and is_instance_valid(player_input):
		player_input.grab_focus()

func _send_to_npc(text: String):
	_is_thinking = true
	player_input.editable = false; send_button.disabled = true
	thinking_indicator.show()
	_append_dialog("\n[color=gray]你: %s[/color]" % text)
	GameState.dialog_history.append({"role": "user", "content": text})

	# P1 同款逻辑：玩家打字说"成交"→ 游戏层先结算物资 → 再调 LLM
	var event := ""
	if not _pending_offer.is_empty() and _is_accept_text(text):
		var off = _pending_offer.back()
		var r = GameState.settle_trade(_current_npc_id, off["gives"], off["wants"])
		event = "✅ " + r["msg"] if r["ok"] else "✗ " + r["msg"]
		_last_settlement_failed = not r["ok"]
		_append_dialog("\n[color=yellow][系统] %s[/color]" % event)

		_pending_offer.clear()
		accept_button.hide(); refuse_button.hide()
		_refresh_status_panel()

	GameState.pending_offer = _pending_offer
	var mem = GameState.npc_memories.get(_current_npc_id, {})
	var world = {"location": "荒野营地", "conflict_mode": mem.get("conflict_mode", false)}
	LLMBridge.send_to_npc(_current_npc_id, world, text, GameState.dialog_history, event)

func _is_accept_text(t: String) -> bool:
	var n = ["不接受", "不换", "不同意", "不行", "拒绝", "休想", "没门", "算了", "别"]
	for w in n:
		if w in t: return false
	var a = ["成交", "接受", "同意", "就这么定", "换吧", "可以换", "答应", "好", "行", "给你"]
	for w in a:
		if w in t: return true
	return false

# ==================== NPC 响应 ====================

func _on_npc_response(npc_id: String, result: Dictionary):
	_is_thinking = false
	thinking_indicator.hide()
	if npc_id != _current_npc_id: return

	var content = result.get("content", "")
	var world = {"npc_inventory": GameState.npc_inventories.get(npc_id, {}),
				 "player_inventory": GameState.player_inventory}
	var v = Validator.validate(content, world)
	Validator.apply_npc_filters(npc_id, v)
	_handle_conflict_block(v)

	var d: Dictionary = v.get("decision", {})
	var delta = d.get("trust_delta", 0)
	if _last_settlement_failed:
		delta = -1
		_last_settlement_failed = false
	GameState.set_trust(npc_id, GameState.get_trust(npc_id) + int(delta))

	_execute_action(v)

	_append_dialog("\n[color=#4a9eff][b]%s:[/b][/color] %s" % [GameState.get_npc_name(npc_id), d.get("dialogue", "（无回应）")])
	# P1 风格 debug 树 → Godot 编辑器 Output 控制台
	var dbg = "  ├ 盘算：%s\n" % d.get("reasoning", "?")
	var intent = d.get("intent", {})
	if intent is Dictionary:
		dbg += "  ├ 意图：%s\n" % intent.get("raw_action", "?")
	dbg += "  ├ 动作：%s  trust_delta=%s  情绪=%s\n" % [v["action"], delta, d.get("emotion", "?")]
	dbg += "  └ 延迟 %dms  tokens=%d  trust=%d" % [result.get("latency_ms", 0), result.get("usage", {}).get("total_tokens", 0), GameState.get_trust(npc_id)]
	print(dbg)
	_refresh_status_panel()
	_update_conflict_badge()
	_update_offer_buttons(v)
	player_input.editable = true
	send_button.disabled = false
	GameState.dialog_history.append({"role": "assistant", "content": content})

	if v["action"] == "flee":
		_handle_flee()

func _on_npc_error(npc_id: String, error: String):
	if npc_id != _current_npc_id: return
	_is_thinking = false; thinking_indicator.hide()
	_append_dialog("\n[color=red]✗ 调用失败: %s[/color]" % error)
	player_input.editable = true; send_button.disabled = false

# ==================== 动作执行 ====================

func _execute_action(v: Dictionary):
	var act = v["action"]
	var p: Dictionary = v.get("params", {})
	match act:
		"propose_trade":
			var gives: Array = p.get("give", []); var wants: Array = p.get("want", [])
			if not gives.is_empty() or not wants.is_empty():
					_pending_offer = [{"gives": gives, "wants": wants}]

		"ask_help":
				var request: Array = p.get("request", [])

				if not request.is_empty():

					_pending_offer = [{"gives": [], "wants": request}]

		"accept_trade":
			if not _pending_offer.is_empty():
				var off = _pending_offer.back()
				var r = GameState.settle_trade(_current_npc_id, off["gives"], off["wants"])
				_last_settlement_failed = not r["ok"]
				_append_dialog("\n[color=yellow][系统] %s %s[/color]" % ["✅" if r["ok"] else "✗", r["msg"]])

			_pending_offer.clear()
		"betray":
			var takes: Array = p.get("take", [])
			var r = GameState.settle_betray(_current_npc_id, takes)
			_append_dialog("\n[color=yellow][系统] %s %s[/color]" % ["✅" if r["ok"] else "✗", r["msg"]])
		"attack_player":
			var takes: Array = p.get("target_items", [])
			if not takes.is_empty():
				var r = GameState.settle_betray(_current_npc_id, takes)
				_append_dialog("\n[color=yellow][系统] %s 武器:%s[/color]" % [r["msg"], p.get("weapon", "徒手")])
			else:
				GameState.npc_memories[_current_npc_id]["has_betrayed"] = true
		"threaten":
			_append_dialog("\n[color=orange][系统] ⚠ %s发出威胁[/color]" % GameState.get_npc_name(_current_npc_id))

func _handle_conflict_block(v: Dictionary):
	var mem = GameState.npc_memories.get(_current_npc_id, {})
	if not mem.get("conflict_mode", false): return
	if v["action"] in ["propose_trade", "accept_trade", "propose_alliance"]:
		v["action"] = "threaten"; v["params"] = {}
		_append_dialog("\n[color=red][系统] ⚔ 冲突状态: %s拒绝再与你交易[/color]" % GameState.get_npc_name(_current_npc_id))
	var trust = GameState.get_trust(_current_npc_id)
	if mem.get("has_betrayed", false) and trust <= -3: mem["conflict_mode"] = true
	elif trust > -3: mem["conflict_mode"] = false

func _update_offer_buttons(v: Dictionary):
	accept_button.hide(); refuse_button.hide()
	if v["action"] == "propose_trade" and not _pending_offer.is_empty():
		accept_button.show(); refuse_button.show()

func _on_accept():
	accept_button.hide(); refuse_button.hide()
	if _pending_offer.is_empty(): return
	var off = _pending_offer.back()
	var r = GameState.settle_trade(_current_npc_id, off["gives"], off["wants"])
	_last_settlement_failed = not r["ok"]
	_append_dialog("\n[color=yellow][系统] %s %s[/color]" % ["✅" if r["ok"] else "✗", r["msg"]])
	
	_pending_offer.clear()
	_refresh_status_panel()
	var mem = GameState.npc_memories.get(_current_npc_id, {})
	var world = {"location": "荒野营地", "conflict_mode": mem.get("conflict_mode", false)}
	LLMBridge.send_to_npc(_current_npc_id, world, "（交易已达成）", GameState.dialog_history, r["msg"])

func _on_refuse():
	accept_button.hide(); refuse_button.hide()
	
	_pending_offer.clear()
	GameState.increment_broke_promise(_current_npc_id)
	_append_dialog("\n[color=yellow][系统] 你拒绝了报价[/color]")

func _handle_flee():
	_append_dialog("\n[color=orange][系统] 🏃 %s逃离了现场[/color]" % GameState.get_npc_name(_current_npc_id))
	flee_panel.show()
	await get_tree().create_timer(2.0).timeout
	flee_panel.hide()
	close_dialog()


func _set_bar_fill_color(bar: ProgressBar, clr):
	var s = StyleBoxFlat.new()
	if clr != null:
		s.bg_color = clr
	else:
		s.bg_color = Color(0.25, 0.25, 0.35)
	s.set_corner_radius_all(3)
	bar.add_theme_stylebox_override("fill", s)
# ==================== 状态面板 ====================

func _refresh_status_panel():
	if _current_npc_id.is_empty(): return
	var t = GameState.get_trust(_current_npc_id)

	# NPC 名字 + 性格
	status_npc_name.text = GameState.get_npc_name(_current_npc_id)
	status_archetype.text = "性格: %s" % GameState.get_npc_archetype(_current_npc_id)

	# Trust
	status_trust_value.text = str(t)
	status_trust_bar.value = t + 10
	if t > 2:
		status_trust_value.add_theme_color_override("font_color", Color(0.3, 1, 0.3))
		_set_bar_fill_color(status_trust_bar, Color.GREEN)
	elif t < -2:
		status_trust_value.add_theme_color_override("font_color", Color(1, 0.2, 0.2))
		_set_bar_fill_color(status_trust_bar, Color(0.8, 0.1, 0.1))
		if t <= -3:
			status_conflict.show()
		else:
			status_conflict.hide()
	else:
		status_trust_value.add_theme_color_override("font_color", Color.WHITE)
		_set_bar_fill_color(status_trust_bar, null)
		status_conflict.hide()

	# Needs
	var needs_arr = GameState.get_needs(_current_npc_id)
	status_needs.text = "急需: %s" % (", ".join(needs_arr) if not needs_arr.is_empty() else "无")
	status_needs.visible = not needs_arr.is_empty()

	# 玩家库存
	var pi = GameState.player_inventory
	var pi_text = ""
	for k in pi: pi_text += "[color=#7fbf7f]%s[/color] ×%d\n" % [k, pi[k]]
	if pi_text.is_empty(): pi_text = "[color=gray]（空）[/color]"
	status_player_inv.text = pi_text.strip_edges()

	# NPC 库存
	var ni = GameState.npc_inventories.get(_current_npc_id, {})
	var ni_text = ""
	for k in ni: ni_text += "[color=#bf8f5f]%s[/color] ×%d\n" % [k, ni[k]]
	if ni_text.is_empty(): ni_text = "[color=gray]（空）[/color]"
	status_npc_inv.text = ni_text.strip_edges()

	# 更新 NPC 物资标题名字
	if _status_npc_inv_title:
		_status_npc_inv_title.text = GameState.get_npc_name(_current_npc_id)

func _update_conflict_badge():
	var mem = GameState.npc_memories.get(_current_npc_id, {})
	conflict_badge.visible = mem.get("conflict_mode", false)
