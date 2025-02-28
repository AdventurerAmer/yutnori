package client

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:reflect"

import rl "vendor:raylib"

Vec2 :: rl.Vector2
Rect :: rl.Rectangle

WINDOW_WIDTH :: 1280
WINDOW_HEIGHT :: 720
WINDOW_TITLE :: "Yutnori"

MIN_PLAYER_COUNT :: 2
MAX_PLAYER_COUNT :: 6

Screen_State :: enum {
	MainMenu,
	GameModes,
	LocalGameMode,
	GamePlay,
}

Game_State :: struct {
	screen_state:   Screen_State,
	player_count:   i32,
	is_paused:      bool,
	cell_positions: [Cell_ID]Vec2,
}

init_game :: proc(allocator := context.allocator) -> ^Game_State {
	gs := new(Game_State, allocator)
	gs.screen_state = .MainMenu
	reset_game_state(gs)
	return gs
}

reset_game_state :: proc(game_state: ^Game_State) {
	game_state.player_count = MIN_PLAYER_COUNT
	game_state.is_paused = false
}

main :: proc() {
	when ODIN_DEBUG {
		tracker: mem.Tracking_Allocator
		mem.tracking_allocator_init(&tracker, context.allocator)
		context.allocator = mem.tracking_allocator(&tracker)
		defer {
			for _, entry in tracker.allocation_map {
				fmt.eprintf(
					"tracking allocator: allocation not freed %v bytes @ %v\n",
					entry.size,
					entry.location,
				)
			}
			for entry in tracker.bad_free_array {
				fmt.eprintf(
					"memory allocator: bad free %v bytes @ %v\n",
					entry.memory,
					entry.location,
				)
			}
		}
	}

	rl.ConfigFlags({.VSYNC_HINT, .WINDOW_RESIZABLE, .MSAA_4X_HINT})
	rl.SetTargetFPS(500)

	rl.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, WINDOW_TITLE)
	defer rl.CloseWindow()

	rl.SetWindowState({.WINDOW_RESIZABLE})
	rl.SetWindowMinSize(320, 240)

	game_state := init_game()
	defer free(game_state, context.allocator)

	default_style := UI_Style {
		font         = rl.GetFontDefault(),
		font_size    = f32(36),
		font_spacing = f32(2),
	}
	rl.GuiSetStyle(.DEFAULT, i32(rl.GuiDefaultProperty.TEXT_SIZE), i32(default_style.font_size))
	rl.GuiSetStyle(
		.DEFAULT,
		i32(rl.GuiDefaultProperty.TEXT_SPACING),
		i32(default_style.font_spacing),
	)

	// @Temprary
	game_state.screen_state = .GamePlay

	running := true

	for running {
		free_all(context.temp_allocator)

		if rl.WindowShouldClose() {
			running = false
		}

		rl.BeginDrawing()
		rl.ClearBackground(rl.SKYBLUE)

		screen_rect := get_screen_rect()
		screen_size := get_screen_size()
		ui_points := get_anchors_from_rect(screen_rect)

		switch game_state.screen_state {
		case .MainMenu:
			spacing := 0.005 * screen_size.y
			layout := begin_vertical_layout(spacing)
			layout.style = default_style

			padding := Vec2{0.01, 0.01} * screen_size
			play_id := push_widget(&layout, "PLAY", padding)
			options_id := push_widget(&layout, "OPTIONS", padding)
			quit_id := push_widget(&layout, "QUIT", padding)

			end_vertical_layout(&layout, ui_points.center)

			{
				w := get_widget(layout, play_id)
				if rl.GuiButton(w.rect, w.text) {
					game_state.screen_state = .GameModes
				}
			}

			{
				w := get_widget(layout, options_id)
				if rl.GuiButton(w.rect, w.text) {
				}
			}

			{
				w := get_widget(layout, quit_id)
				if rl.GuiButton(w.rect, w.text) {
					running = false
				}
			}
		case .GameModes:
			spacing := 0.005 * screen_size.y
			layout := begin_vertical_layout(spacing)
			layout.style = default_style

			padding := Vec2{0.01, 0.01} * screen_size
			local_id := push_widget(&layout, "LOCAL", padding)
			online_id := push_widget(&layout, "ONLINE", padding)
			back_id := push_widget(&layout, "BACK", padding)

			end_vertical_layout(&layout, ui_points.center)

			{
				w := get_widget(layout, local_id)
				if rl.GuiButton(w.rect, w.text) {
					game_state.screen_state = .LocalGameMode
				}
			}

			{
				w := get_widget(layout, online_id)
				if rl.GuiButton(w.rect, w.text) {
				}
			}

			{
				w := get_widget(layout, back_id)
				if rl.GuiButton(w.rect, w.text) {
					game_state.screen_state = .MainMenu
				}
			}
		case .LocalGameMode:
			spacing := 0.005 * screen_size.y
			layout := begin_vertical_layout(spacing)
			layout.style = default_style

			padding := Vec2{0.01, 0.01} * screen_size
			players_id := push_widget(&layout, "PLAYERS", padding)
			players_spinner_id := push_widget(&layout, "", screen_size * Vec2{0.1, 0.05})
			start_id := push_widget(&layout, "START", padding)
			back_id := push_widget(&layout, "BACK", padding)
			end_vertical_layout(&layout, ui_points.center)

			{
				w := get_widget(layout, players_id)
				rl.GuiLabel(w.rect, w.text)
			}

			{
				w := get_widget(layout, players_spinner_id)
				changed := rl.GuiSpinner(
					w.rect,
					nil,
					&game_state.player_count,
					MIN_PLAYER_COUNT,
					MAX_PLAYER_COUNT,
					false,
				)
			}

			{
				w := get_widget(layout, start_id)
				if rl.GuiButton(w.rect, w.text) {
					game_state.screen_state = .GamePlay
				}
			}

			{
				w := get_widget(layout, back_id)
				if rl.GuiButton(w.rect, w.text) {
					reset_game_state(game_state)
					game_state.screen_state = .GameModes
				}
			}
		case .GamePlay:
			if rl.IsKeyPressed(.ESCAPE) {
				game_state.is_paused = !game_state.is_paused
			}

			offset_y := f32(0)

			// draw top section
			{
				if game_state.is_paused {
					rl.GuiDisable()
				}

				text := rl.GuiIconText(.ICON_BURGER_MENU, "")
				size := rl.MeasureTextEx(
					default_style.font,
					text,
					default_style.font_size,
					default_style.font_spacing,
				)

				margin := min(screen_size.x * 0.005, screen_size.y * 0.005)

				if rl.GuiButton(Rect{margin, margin, size.y, size.y}, text) {
					game_state.is_paused = true
				}

				rl.GuiEnable()

				offset_y += size.y + margin
			}

			// draw game board
			{
				height := screen_size.y - offset_y
				padding := min(screen_size.x * 0.1, screen_size.y * 0.1)
				size := Vec2{screen_size.x * 0.5, height}
				board_rect := Rect{screen_size.x * 0.5 - size.x * 0.5, offset_y, size.x, size.y}
				board_rect = shrink_rect(board_rect, padding)
				line_thickness := f32(5)
				color := rl.DARKGREEN

				points := get_anchors_from_rect(board_rect)
				small_circle_radius := screen_size.x * 0.02
				big_circle_radius := 1.2 * small_circle_radius

				rl.DrawRectangleLinesEx(board_rect, line_thickness, color)
				rl.DrawLineEx(points.top_left, points.bottom_right, line_thickness, color)
				rl.DrawLineEx(points.top_right, points.bottom_left, line_thickness, color)

				game_state.cell_positions[.BottomRightCorner] = points.bottom_right
				game_state.cell_positions[.TopRightCorner] = points.top_right
				game_state.cell_positions[.TopLeftCorner] = points.top_left
				game_state.cell_positions[.BottomLeftCorner] = points.bottom_left
				game_state.cell_positions[.Center] = points.center

				// Vertical
				{
					step := board_rect.height / (SIDE_CELL_COUNT + 1)
					for i := 0; i < SIDE_CELL_COUNT; i += 1 {
						p := points.bottom_right
						p.y -= f32(i + 1) * step
						game_state.cell_positions[Cell_ID.Right0 + Cell_ID(i)] = p
					}
					for i := 0; i < SIDE_CELL_COUNT; i += 1 {
						p := points.top_left
						p.y += f32(i + 1) * step
						game_state.cell_positions[Cell_ID.Left0 + Cell_ID(i)] = p
					}
				}

				// Horizontal
				{
					step := board_rect.width / (SIDE_CELL_COUNT + 1)
					for i := 0; i < SIDE_CELL_COUNT; i += 1 {
						p := points.top_right
						p.x -= f32(i + 1) * step
						game_state.cell_positions[Cell_ID.Top0 + Cell_ID(i)] = p
					}
					for i := 0; i < SIDE_CELL_COUNT; i += 1 {
						p := points.bottom_left
						p.x += f32(i + 1) * step
						game_state.cell_positions[Cell_ID.Bottom0 + Cell_ID(i)] = p
					}
				}

				// Main Diag
				{
					p0 := points.top_left
					p1 := points.bottom_right

					p0_to_center := points.center - p0
					step0 := linalg.length(p0_to_center) / 3
					dir := linalg.normalize(p0_to_center)
					for i := 0; i < SIDE_CELL_COUNT / 2; i += 1 {
						game_state.cell_positions[.MainDiagonal0 + Cell_ID(i)] =
							p0 + dir * f32(i + 1) * step0

					}

					center_to_p1 := p1 - points.center
					step1 := linalg.length(center_to_p1) / 3
					for i := 0; i < SIDE_CELL_COUNT / 2; i += 1 {
						game_state.cell_positions[.MainDiagonal2 + Cell_ID(i)] =
							points.center + dir * f32(i + 1) * step0

					}
				}

				// Anti Diag
				{
					p0 := points.top_right
					p1 := points.bottom_left

					p0_to_center := points.center - p0
					step0 := linalg.length(p0_to_center) / 3
					dir := linalg.normalize(p0_to_center)
					for i := 0; i < SIDE_CELL_COUNT / 2; i += 1 {
						game_state.cell_positions[.AntiDiagonal0 + Cell_ID(i)] =
							p0 + dir * f32(i + 1) * step0

					}

					center_to_p1 := p1 - points.center
					step1 := linalg.length(center_to_p1) / 3
					for i := 0; i < SIDE_CELL_COUNT / 2; i += 1 {
						game_state.cell_positions[.AntiDiagonal2 + Cell_ID(i)] =
							points.center + dir * f32(i + 1) * step0

					}
				}

				for id in Cell_ID {
					radius := small_circle_radius
					if id == .Center ||
					   id == .TopLeftCorner ||
					   id == .TopRightCorner ||
					   id == .BottomLeftCorner ||
					   id == .BottomRightCorner {
						radius = big_circle_radius
					}
					rl.DrawCircleV(game_state.cell_positions[id], radius, color)
				}

				mouse := rl.GetMousePosition()
				selected_cell := -1
				for id in Cell_ID {
					pos := game_state.cell_positions[id]
					radius := small_circle_radius
					if id == .Center ||
					   id == .TopLeftCorner ||
					   id == .TopRightCorner ||
					   id == .BottomLeftCorner ||
					   id == .BottomRightCorner {
						radius = big_circle_radius
					}
					if rl.CheckCollisionPointCircle(mouse, pos, radius) {
						selected_cell = int(id)
						break
					}
				}

				if selected_cell != -1 {
					start_cell := Cell_ID(selected_cell)
					rl.DrawCircleV(
						game_state.cell_positions[start_cell],
						select_cell_radius(start_cell, small_circle_radius, big_circle_radius),
						rl.YELLOW,
					)

					starting := true
					move_count := 5
					seq, win := get_move_sequance(start_cell, u32(move_count), starting)
					for item in seq {
						radius := select_cell_radius(item, small_circle_radius, big_circle_radius)
						pos := game_state.cell_positions[item]
						rl.DrawCircleV(pos, radius, rl.BLUE)
					}

					prev0, prev1 := get_prev_cell(start_cell)

					{
						radius := select_cell_radius(prev0, small_circle_radius, big_circle_radius)
						pos := game_state.cell_positions[prev0]
						rl.DrawCircleV(pos, radius, rl.RED)
					}

					{
						radius := select_cell_radius(prev1, small_circle_radius, big_circle_radius)
						pos := game_state.cell_positions[prev1]
						rl.DrawCircleV(pos, radius, rl.RED)
					}

					{
						name, _ := reflect.enum_name_from_value(start_cell)
						text := fmt.ctprintf("name: %v win: %v", name, win)
						pos := mouse
						pos.y += 24
						rl.DrawTextEx(
							default_style.font,
							text,
							pos,
							default_style.font_size * 0.5,
							default_style.font_spacing,
							rl.WHITE,
						)
					}
				}
			}

			if game_state.is_paused {
				rl.DrawRectangleRec(screen_rect, {0, 0, 0, 128})

				spacing := 0.005 * screen_size.y
				layout := begin_vertical_layout(spacing)
				layout.style = default_style

				padding := Vec2{0.01, 0.01} * screen_size
				resume_id := push_widget(&layout, "RESUME", padding)
				options_id := push_widget(&layout, "OPTIONS", padding)
				main_menu_id := push_widget(&layout, "MAIN MENU", padding)
				end_vertical_layout(&layout, ui_points.center)

				{
					w := get_widget(layout, resume_id)
					if rl.GuiButton(w.rect, w.text) {
						game_state.is_paused = false
					}
				}

				{
					w := get_widget(layout, options_id)
					if rl.GuiButton(w.rect, w.text) {
					}
				}

				{
					w := get_widget(layout, main_menu_id)
					if rl.GuiButton(w.rect, w.text) {
						reset_game_state(game_state)
						game_state.screen_state = .MainMenu
					}
				}
			}
		}

		rl.EndDrawing()
	}
}
