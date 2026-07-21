# scene_main.gd —— WASD 移动 + E 交互（保留 1/2/3 备用模式）
extends Control

# ---- 模式开关：改成 INTERACT_MODE_KEYS 回到按键选择 ----
const INTERACT_MODE_WASD = 0
const INTERACT_MODE_KEYS = 1
const INTERACT_MODE = INTERACT_MODE_WASD

# ---- 常量 ----
const PLAYER_SPEED: float = 300.0
const INTERACT_RANGE: float = 120.0

# ---- 运行时状态 ----
var _player: CharacterBody2D
var _player_sprite: Sprite2D         # 主角静态立绘
var _npc_areas: Dictionary = {}        # "kel" -> Area2D
var _npc_names: Dictionary = {}        # "kel" -> String
var _npcs_colors: Dictionary = {}      # "kel" -> Color
var _interact_hint: Label              # 浮动"按 E 对话"提示
var _nearest_npc: String = ""          # 当前最近的 NPC id
var _target_label: Label
var _dialog_box
var _input_active := true              # false = 对话框打开中

# ==================== 初始化 ====================

func _ready():
	set_anchors_preset(PRESET_FULL_RECT)

	# 游戏世界层——Node2D 子节点隔离 Control 坐标系，保证物理正常工作
	var world = Node2D.new()
	world.name = "World"
	add_child(world)

	_build_background()
	_build_player(world)
	_build_npcs(world)
	_build_ui()
	var mode_str = "WASD+E" if INTERACT_MODE == INTERACT_MODE_WASD else "按键 1/2/3"
	print("营地就绪 —— 移动方式：%s  走到 NPC 附近按 E 对话" % mode_str)
	set_process_unhandled_input(true)

# ==================== 背景 ====================

func _build_background():
	var bg_layer = CanvasLayer.new()
	bg_layer.name = "BackgroundLayer"
	bg_layer.layer = -1
	add_child(bg_layer)

	# 背景图占位 —— 把文件放到 assets/scene_bg.png 自动生效
	var bg_tex = load("res://assets/bg_space_station.png") if ResourceLoader.exists("res://assets/bg_space_station.png") else null
	if bg_tex:
		var bg = TextureRect.new()
		bg.name = "Background"
		bg.texture = bg_tex
		bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		bg.stretch_mode = TextureRect.STRETCH_SCALE
		bg.set_anchors_preset(Control.PRESET_FULL_RECT)
		bg_layer.add_child(bg)

	var overlay = ColorRect.new()
	overlay.color = Color(0, 0, 0, 0.25)
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg_layer.add_child(overlay)

	var lbl = Label.new()
	lbl.text = "🚀 交易空间站"
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_color_override("font_color", Color(1, 0.95, 0.8))
	lbl.add_theme_font_size_override("font_size", 28)
	lbl.position = Vector2(426, 20)
	add_child(lbl)

	_target_label = Label.new()
	_target_label.text = "WASD 移动 | 走到 NPC 附近按 E 对话"
	_target_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_target_label.add_theme_color_override("font_color", Color(0.8, 0.9, 1))
	_target_label.add_theme_font_size_override("font_size", 18)
	_target_label.position = Vector2(360, 60)
	add_child(_target_label)

	# 交互提示（默认隐藏）
	_interact_hint = Label.new()
	_interact_hint.text = "按 E 对话"
	_interact_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_interact_hint.add_theme_color_override("font_color", Color(1, 0.85, 0.3))
	_interact_hint.add_theme_font_size_override("font_size", 18)
	_interact_hint.hide()
	add_child(_interact_hint)

# ==================== 主角 ====================

func _build_player(world: Node2D):
	_player = CharacterBody2D.new()
	_player.name = "Player"
	_player.position = Vector2(640, 400)
	world.add_child(_player)

	_player_sprite = Sprite2D.new()
	_player_sprite.name = "Body"
	_player_sprite.texture = load("res://assets/player.png")
	var screen_h = get_viewport().get_visible_rect().size.y
	var tex_h = _player_sprite.texture.get_height()
	var scale_val = screen_h * 0.09 / tex_h
	_player_sprite.scale = Vector2(scale_val, scale_val)
	print("主角 scale = %.4f (screen=%d, tex=%d)" % [scale_val, screen_h, tex_h])
	_player.add_child(_player_sprite)

	var col = CollisionShape2D.new()
	var cs = CapsuleShape2D.new()
	cs.radius = 14
	cs.height = 30
	col.shape = cs
	col.position = Vector2(0, -10)
	_player.add_child(col)

	var lbl = Label.new()
	lbl.text = "你"
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_color_override("font_color", Color(0.7, 1, 0.7))
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.position = Vector2(-12, 80)
	_player.add_child(lbl)

# ==================== NPC ====================

func _build_npcs(world: Node2D):
	_build_one_npc("kel",  "凯尔", Vector2(350, 250), Color(0.9, 0.3, 0.2), "res://assets/npc_kyle.png", world)
	_build_one_npc("sara", "萨拉", Vector2(640, 300), Color(0.9, 0.75, 0.2), "res://assets/npc_sara.png", world)
	_build_one_npc("tun",  "图恩", Vector2(930, 250), Color(0.3, 0.5, 0.9), "res://assets/npc_tun.png", world)

func _build_one_npc(id: String, nick: String, pos: Vector2, col: Color, tex_path: String, world: Node2D):
	var area = Area2D.new()
	area.name = "NPC_Area_" + id
	area.position = pos
	world.add_child(area)

	var shape = CollisionShape2D.new()
	var cs = CircleShape2D.new()
	cs.radius = INTERACT_RANGE / 2.0
	shape.shape = cs
	area.add_child(shape)

	# 立绘 — 动态缩放到屏幕高度 9%
	var tex = load(tex_path)
	var sprite = Sprite2D.new()
	sprite.name = "BodySprite"
	sprite.texture = tex
	var screen_h = get_viewport().get_visible_rect().size.y
	var tex_h = tex.get_height()
	var scale_val = screen_h * 0.09 / tex_h
	sprite.scale = Vector2(scale_val, scale_val)
	area.add_child(sprite)

	var lbl = Label.new()
	lbl.name = "NameLabel"
	lbl.text = nick
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_color_override("font_color", col.lightened(0.3))
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.position = Vector2(-20, 28)
	area.add_child(lbl)

	var key_hint = Label.new()
	key_hint.text = "[%d]" % (1 + ["kel","sara","tun"].find(id))
	key_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	key_hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	key_hint.add_theme_font_size_override("font_size", 11)
	key_hint.position = Vector2(-14, -32)
	key_hint.visible = (INTERACT_MODE == INTERACT_MODE_KEYS)
	area.add_child(key_hint)

	_npc_areas[id] = area
	_npc_names[id] = nick
	_npcs_colors[id] = col

# ==================== UI ====================

func _build_ui():
	var ui_layer = CanvasLayer.new()
	ui_layer.name = "UI"
	add_child(ui_layer)

	_dialog_box = load("res://scripts/ui/dialog_box.gd").new()
	_dialog_box.name = "DialogBox"
	_dialog_box.add_to_group("dialog_box")
	_dialog_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui_layer.add_child(_dialog_box)
	_dialog_box._build_full_ui()
	_dialog_box.close_callback = _on_dialog_closed

func _on_dialog_closed():
	_input_active = true
	set_process_unhandled_input(true)
	_interact_hint.hide()
	print("对话框关闭 —— 继续移动")

# ==================== 帧循环 ====================

func _physics_process(_delta: float):
	if not _input_active:
		return

	var vel := Vector2.ZERO
	var h := 0
	var v := 0
	if Input.is_key_pressed(KEY_W) or Input.is_key_pressed(KEY_UP):    v = -1
	if Input.is_key_pressed(KEY_S) or Input.is_key_pressed(KEY_DOWN):  v = 1
	if Input.is_key_pressed(KEY_A) or Input.is_key_pressed(KEY_LEFT):  h = -1
	if Input.is_key_pressed(KEY_D) or Input.is_key_pressed(KEY_RIGHT): h = 1
	vel = Vector2(h, v).normalized() * PLAYER_SPEED

	# 方向：左走 flip_h=true，右走 flip_h=false
	if _player_sprite:
		if h < 0:
			_player_sprite.flip_h = true
		elif h > 0:
			_player_sprite.flip_h = false

	_player.velocity = vel
	_player.move_and_slide()

func _process(_delta: float):
	if not _input_active:
		return
	_check_nearby_npc()

func _check_nearby_npc():
	var nearest_id := ""
	var best_dist := INF
	for id in _npc_areas:
		var area = _npc_areas[id] as Area2D
		var bodies = area.get_overlapping_bodies()
		var found := false
		for b in bodies:
			if b == _player:
				found = true
				break
		if not found:
			continue
		var dist = _player.position.distance_to(area.position)
		if dist < best_dist and dist <= INTERACT_RANGE:
			best_dist = dist
			nearest_id = id

	_nearest_npc = nearest_id
	if _nearest_npc.is_empty():
		_interact_hint.hide()
	else:
		var area = _npc_areas[_nearest_npc] as Area2D
		_interact_hint.position = area.position + Vector2(-40, -80)
		_interact_hint.show()

# ==================== 输入 ====================

func _unhandled_input(event: InputEvent):
	if not _input_active:
		return
	if not event is InputEventKey or not event.pressed:
		return

	# 备用模式：按 1/2/3 选 NPC
	if INTERACT_MODE == INTERACT_MODE_KEYS:
		var npc_id := ""
		match event.keycode:
			KEY_1: npc_id = "kel"
			KEY_2: npc_id = "sara"
			KEY_3: npc_id = "tun"
		if not npc_id.is_empty():
			_select_npc(npc_id)
			get_viewport().set_input_as_handled()
		return

	# WASD 模式：E 键交互
	if event.keycode == KEY_E and not _nearest_npc.is_empty():
		_select_npc(_nearest_npc)
		get_viewport().set_input_as_handled()

func _select_npc(id: String):
	# 高亮选中 NPC 立绘（self_modulate 提亮）
	for npc_id in _npc_areas:
		var area = _npc_areas[npc_id] as Area2D
		var sprite = area.get_node_or_null("BodySprite") as Sprite2D
		if sprite:
			sprite.self_modulate = Color(1, 1, 1)
	if _npc_areas.has(id):
		var area = _npc_areas[id] as Area2D
		var sprite = area.get_node_or_null("BodySprite") as Sprite2D
		if sprite:
			sprite.self_modulate = Color(1.4, 1.4, 1.1)

	_target_label.text = "当前对话对象：%s  |  「%s」" % [GameState.get_npc_name(id), GameState.get_npc_archetype(id)]

	_input_active = false
	set_process_unhandled_input(false)
	_interact_hint.hide()
	_dialog_box.open_for_npc(id, self)
