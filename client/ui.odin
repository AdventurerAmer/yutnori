package client

import rl "vendor:raylib"

expand_rect :: proc(r: Rect, padding: Vec2) -> (result: Rect) {
	result.x = r.x - padding.x
	result.y = r.y - padding.y
	result.width = r.width + padding.x * 2
	result.height = r.height + padding.y * 2
	return result
}

shrink_rect :: proc(r: Rect, padding: Vec2) -> (result: Rect) {
	result.x = r.x + padding.x
	result.y = r.y + padding.y
	result.width = r.width - padding.x * 2
	result.height = r.height - padding.y * 2
	return result
}

Anchors_Points :: struct {
	top_center:    Vec2,
	bottom_center: Vec2,
	left_center:   Vec2,
	right_center:  Vec2,
	center:        Vec2,
	top_left:      Vec2,
	top_right:     Vec2,
	bottom_left:   Vec2,
	bottom_right:  Vec2,
}

get_screen_size :: proc() -> Vec2 {
	return {f32(rl.GetRenderWidth()), f32(rl.GetRenderHeight())}
}

get_screen_rect :: proc() -> Rect {
	return {0, 0, f32(rl.GetRenderWidth()), f32(rl.GetRenderHeight())}
}

get_anchor_points :: proc(rect: Rect) -> Anchors_Points {
	p := Anchors_Points{}
	p.top_center = Vec2{rect.x + rect.width * 0.5, rect.y}
	p.bottom_center = Vec2{rect.x + rect.width * 0.5, rect.y + rect.height}
	p.left_center = Vec2{rect.x, rect.y + rect.height * 0.5}
	p.right_center = Vec2{rect.x + rect.width, rect.y + rect.height * 0.5}
	p.center = Vec2{rect.x + rect.width * 0.5, rect.y + rect.height * 0.5}
	p.top_left = Vec2{rect.x, rect.y}
	p.top_right = Vec2{rect.x + rect.width, rect.y}
	p.bottom_left = Vec2{rect.x, rect.y + rect.height}
	p.bottom_right = Vec2{rect.x + rect.width, rect.y + rect.height}
	return p
}

UI_Style :: struct {
	font:         rl.Font,
	font_size:    f32,
	font_spacing: f32,
}

UI_Widget :: struct {
	text: cstring,
	rect: Rect,
}

UI_Vertical_Layout :: struct {
	_widgets:              [dynamic]UI_Widget,
	_size_without_spacing: Vec2,
	_spacing:              f32,
	_ended:                bool,
	style:                 UI_Style,
}

begin_vertical_layout :: proc(
	spacing := f32(0),
	allocator := context.temp_allocator,
) -> UI_Vertical_Layout {
	layout := UI_Vertical_Layout {
		_widgets = make([dynamic]UI_Widget, allocator),
		_spacing = spacing,
		style = {font = rl.GetFontDefault(), font_size = 35, font_spacing = 2},
	}
	return layout
}

push_widget :: proc(layout: ^UI_Vertical_Layout, text: cstring, padding := Vec2{}) -> int {
	assert(!layout._ended)
	style := layout.style
	widget := UI_Widget {
		text = text,
	}
	size := rl.MeasureTextEx(style.font, text, style.font_size, style.font_spacing) + padding * 2
	if size.x > layout._size_without_spacing.x {
		layout._size_without_spacing.x = size.x
	}
	layout._size_without_spacing.y += size.y
	widget.rect.width = size.x
	widget.rect.height = size.y
	id := len(layout._widgets)
	append(&layout._widgets, widget)
	return id
}

end_vertical_layout :: proc(layout: ^UI_Vertical_Layout, center := Vec2{}) -> Rect {
	assert(!layout._ended)
	assert(len(layout._widgets) != 0)
	layout._ended = true

	size := layout._size_without_spacing
	size.y += f32(len(layout._widgets) - 1) * layout._spacing

	offset := center - size * 0.5
	parent := Rect{offset.x, offset.y, size.x, size.y}

	y := f32(0)
	for &w in layout._widgets {
		w.rect.x = parent.x + parent.width * 0.5 - w.rect.width * 0.5
		w.rect.y = parent.y + y
		y += w.rect.height + layout._spacing
	}

	return parent
}

get_widget :: proc(layout: UI_Vertical_Layout, widget_id: int) -> UI_Widget {
	assert(layout._ended)
	assert(widget_id < len(layout._widgets))
	return layout._widgets[widget_id]
}
