# npc_controller.gd — NPC 控制器
# 挂载到每个 NPC Area2D 节点。处理点击→开对话框。
extends Area2D

@export var npc_id: String = "kel"
@export var npc_color: Color = Color.GRAY

@onready var body_rect: ColorRect = get_node_or_null("BodyRect") as ColorRect
@onready var name_label: Label = get_node_or_null("NameLabel") as Label

func _ready():
	input_event.connect(_on_input_event)
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	if body_rect:
		body_rect.color = npc_color
	if name_label:
		name_label.text = GameState.get_npc_name(npc_id)
		name_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
		name_label.add_theme_constant_override("outline_size", 2)

func _on_input_event(viewport, event, shape_idx):
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_start_dialog()

func _on_mouse_entered():
	body_rect.color = npc_color.lightened(0.3)

func _on_mouse_exited():
	body_rect.color = npc_color

func _start_dialog():
	var dialog_box = get_tree().get_first_node_in_group("dialog_box")
	if dialog_box:
		dialog_box.open_for_npc(npc_id)
