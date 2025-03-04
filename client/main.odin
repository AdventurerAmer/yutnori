package client

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
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
PIECE_COUNT :: 4

Screen_State :: enum {
	MainMenu,
	GameModes,
	LocalGameMode,
	GamePlay,
}

Piece :: struct {
	at_start: bool,
	cell:     Cell_ID,
}

Player_State :: struct {
	color:  rl.Color,
	pieces: [PIECE_COUNT]Piece,
}

debug: bool

Game_State :: struct {
	screen_state:      Screen_State,
	player_count:      i32,
	is_paused:         bool,
	cell_positions:    [Cell_ID]Vec2,
	players:           [MAX_PLAYER_COUNT]Player_State,
	player_turn_index: u32,
	moves:             [dynamic]i32,
	can_roll:          bool,
	selected_piece:    ^Piece,
}

init_game :: proc(allocator := context.allocator) -> ^Game_State {
	gs := new(Game_State, allocator)
	gs.screen_state = .MainMenu
	reset_game_state(gs)
	return gs
}

deinit_game :: proc(gs: ^Game_State) {
	delete(gs.moves)
	free(gs, context.allocator)
}

PLAYER_COLORS := [MAX_PLAYER_COUNT]rl.Color {
	rl.RED,
	rl.BLUE,
	rl.MAGENTA,
	rl.DARKBROWN,
	rl.ORANGE,
	rl.PURPLE,
}

reset_game_state :: proc(game_state: ^Game_State) {
	game_state.player_count = MIN_PLAYER_COUNT
	game_state.player_turn_index = 0
	for i in 0 ..< MAX_PLAYER_COUNT {
		p := &game_state.players[i]
		p.color = PLAYER_COLORS[i]
		for j in 0 ..< PIECE_COUNT {
			p.pieces[j].at_start = true
			p.pieces[j].cell = .BottomRightCorner
		}
	}
	resize(&game_state.moves, 0)
	game_state.is_paused = false
	game_state.selected_piece = nil
	game_state.can_roll = true
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


	rl.SetConfigFlags({.VSYNC_HINT, .WINDOW_RESIZABLE, .MSAA_4X_HINT})
	rl.SetTargetFPS(500)

	rl.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, WINDOW_TITLE)
	defer rl.CloseWindow()

	rl.SetWindowMinSize(320, 240)

	game_state := init_game()
	defer deinit_game(game_state)

	font := rl.GetFontDefault()
	// rl.SetTextureFilter(font.texture, .BILINEAR)

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
				text := cstring("ROLL")
				size := rl.MeasureTextEx(
					default_style.font,
					text,
					default_style.font_size,
					default_style.font_spacing,
				)
				padding := Vec2{screen_size.x * 0.01, screen_size.y * 0.01}
				size += padding
				margin_y := screen_size.y * 0.005
				r := Rect{screen_size.x * 0.5 - size.x * 0.5, margin_y, size.x, size.y}

				if !game_state.can_roll {
					rl.GuiDisable()
				}

				player := game_state.players[game_state.player_turn_index]

				if rl.GuiButton(r, text) {
					n := rand.int31_max(7) - 1
					if n != 4 || n != 5 {
						game_state.can_roll = false
					}
					if n != 0 {
						append(&game_state.moves, n)
					}
				}

				rl.GuiEnable()

				offset_y += size.y + margin_y

				total_width := f32(0)
				height := f32(0)
				spacing := 0.025 * screen_size.x
				for i := 0; i < len(game_state.moves); i += 1 {
					text := fmt.ctprintf("%d", game_state.moves[i])
					size := rl.MeasureTextEx(
						default_style.font,
						text,
						default_style.font_size,
						default_style.font_spacing,
					)
					total_width += size.x
					height = max(height, size.y)
				}

				total_width += f32(len(game_state.moves) - 1) * spacing
				offset_y += screen_size.y * 0.02
				offset_x := screen_size.x * 0.5 - total_width * 0.5

				for i := 0; i < len(game_state.moves); i += 1 {
					text := fmt.ctprintf("%d", game_state.moves[i])
					size := rl.MeasureTextEx(
						default_style.font,
						text,
						default_style.font_size,
						default_style.font_spacing,
					)
					r := Rect{offset_x, offset_y, size.x, height}
					r = expand_rect(r, Vec2{0.01, 0.01} * screen_size)
					rl.DrawRectangleRec(r, rl.Color{0, 0, 0, 128})
					rl.DrawTextEx(
						default_style.font,
						text,
						{offset_x, offset_y},
						default_style.font_size,
						default_style.font_spacing,
						rl.WHITE,
					)
					offset_x += size.x + spacing
				}

				offset_y += r.height
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

				piece_size := min(screen_size.x * 0.05, screen_size.y * 0.05)

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

				for cell in Cell_ID {
					radius := select_cell_radius(cell, small_circle_radius, big_circle_radius)
					rl.DrawCircleV(game_state.cell_positions[cell], radius, color)
				}

				mouse := rl.GetMousePosition()
				selected_cell := -1
				for cell in Cell_ID {
					pos := game_state.cell_positions[cell]
					radius := select_cell_radius(cell, small_circle_radius, big_circle_radius)
					if rl.CheckCollisionPointCircle(mouse, pos, radius) {
						selected_cell = int(cell)
						break
					}
				}

				if selected_cell != -1 && !game_state.is_paused && debug {
					start_cell := Cell_ID(selected_cell)
					rl.DrawCircleV(
						game_state.cell_positions[start_cell],
						select_cell_radius(start_cell, small_circle_radius, big_circle_radius),
						rl.YELLOW,
					)

					starting := true
					move_count := 5
					seq, finish := get_move_sequance(start_cell, u32(move_count), starting)
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
						text := fmt.ctprintf("cell: %v\nfinish: %v", name, finish)
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

				piece_spacing := screen_size.x * 0.005
				total_width := piece_size * PIECE_COUNT + (PIECE_COUNT - 1) * piece_spacing

				// Drawing Left Players
				{
					offset := Vec2 {
						screen_size.x * 0.25 * 0.5 - total_width * 0.5,
						screen_size.y / f32(MAX_PLAYER_COUNT / 2) * 0.5,
					}

					for i := i32(0); i < game_state.player_count; i += 2 {
						player := game_state.players[i]
						belongs_to_player := game_state.player_turn_index == auto_cast i
						color := player.color

						if !belongs_to_player {
							color.a = 128
						}

						text := fmt.ctprintf("P%v", i + 1)
						size := rl.MeasureTextEx(
							default_style.font,
							text,
							default_style.font_size,
							default_style.font_spacing,
						)
						pos := offset
						pos.x += total_width * 0.5 - size.x * 0.5

						rl.DrawTextEx(
							default_style.font,
							text,
							pos,
							default_style.font_size,
							default_style.font_spacing,
							color,
						)

						offset.y += size.y + screen_size.y * 0.005

						for j in 0 ..< PIECE_COUNT {
							piece := &player.pieces[j]
							r := Rect{}
							if piece.at_start {
								pos := Vec2{f32(j) * (piece_size + piece_spacing), 0}
								r = Rect {
									offset.x + pos.x,
									offset.y + pos.y,
									piece_size,
									piece_size,
								}
							} else {
								pos := game_state.cell_positions[piece.cell]
								r = Rect {
									pos.x - piece_size * 0.5,
									pos.y - piece_size * 0.5,
									piece_size,
									piece_size,
								}
							}
							hovered := rl.CheckCollisionPointRec(mouse, r)
							if hovered && rl.IsMouseButtonPressed(.LEFT) {
								game_state.selected_piece = piece
							}
							is_selected := game_state.selected_piece == piece
							if hovered &&
							   belongs_to_player &&
							   len(game_state.moves) != 0 &&
							   !is_selected {
								padding := min(r.width, r.height) * 0.1
								r = expand_rect(r, Vec2{padding, padding})
							}

							rl.DrawRectangleRec(r, color)

							if is_selected && len(game_state.moves) != 0 {
								rl.DrawRectangleLinesEx(
									r,
									min(0.05 * r.width, 0.05 * r.height),
									rl.GOLD,
								)
							}
						}

						offset.y += screen_size.y / f32(MAX_PLAYER_COUNT / 2) * 0.5
					}
				}


				// Drawing Right Players
				{
					offset := Vec2 {
						screen_size.x * 0.75 + screen_size.x * 0.25 * 0.5 - total_width * 0.5,
						screen_size.y / f32(MAX_PLAYER_COUNT / 2) * 0.5,
					}

					for i := i32(1); i < game_state.player_count; i += 2 {
						player := game_state.players[i]
						active := game_state.player_turn_index == auto_cast i
						color := player.color

						if !active {
							color.a = 128
						}

						text := fmt.ctprintf("P%v", i + 1)
						size := rl.MeasureTextEx(
							default_style.font,
							text,
							default_style.font_size,
							default_style.font_spacing,
						)
						pos := offset
						pos.x += total_width * 0.5 - size.x * 0.5
						rl.DrawTextEx(
							default_style.font,
							text,
							pos,
							default_style.font_size,
							default_style.font_spacing,
							color,
						)

						offset.y += size.y + screen_size.y * 0.005

						for j in 0 ..< PIECE_COUNT {
							piece := player.pieces[j]
							r := Rect{}
							if piece.at_start {
								pos := Vec2{f32(j) * (piece_size + piece_spacing), 0}
								r = Rect {
									offset.x + pos.x,
									offset.y + pos.y,
									piece_size,
									piece_size,
								}
							} else {
								pos := game_state.cell_positions[piece.cell]
								r = Rect {
									pos.x - piece_size * 0.5,
									pos.y - piece_size * 0.5,
									piece_size,
									piece_size,
								}
							}
							hovered := rl.CheckCollisionPointRec(mouse, r)
							if hovered && active {
								padding := min(r.width, r.height) * 0.1
								r = expand_rect(r, Vec2{padding, padding})
							}
							rl.DrawRectangleRec(r, color)

							if hovered && active {
								rl.DrawRectangleLinesEx(
									r,
									min(0.05 * r.width, 0.05 * r.height),
									rl.GOLD,
								)
							}
						}

						offset.y += screen_size.y / f32(MAX_PLAYER_COUNT / 2) * 0.5
					}
				}

				if len(game_state.moves) != 0 &&
				   game_state.selected_piece != nil &&
				   !game_state.can_roll {
					piece := game_state.selected_piece
					player := &game_state.players[game_state.player_turn_index]
					for i := 0; i < len(game_state.moves); i += 1 {
						move := game_state.moves[i]
						cells := make([dynamic]Cell_ID, context.temp_allocator)
						if move == -1 {
							back0, back1 := get_prev_cell(piece.cell)
							append(&cells, back0)
							if back1 != back0 {
								append(&cells, back1)
							}
						} else {
							path, end := get_move_sequance(piece.cell, u32(move), piece.at_start)
							append(&cells, path[len(path) - 1])
						}
						should_move := false
						cell: Cell_ID
						for j := 0; j < len(cells); j += 1 {
							pos := game_state.cell_positions[cells[j]]
							pos -= Vec2{piece_size, piece_size} * 0.5
							r := Rect{pos.x, pos.y, piece_size, piece_size}
							color := player.color
							color.a = 128
							hovered := rl.CheckCollisionPointRec(mouse, r)
							if hovered {
								r = expand_rect(r, Vec2{piece_size, piece_size} * 0.1)
							}
							rl.DrawRectangleRec(r, color)
							if hovered && rl.IsMouseButtonPressed(.LEFT) {
								should_move = true
								cell = cells[j]
								break
							}
						}
						if should_move {
							game_state.selected_piece = nil
							piece.at_start = false
							piece.cell = cell
							ordered_remove(&game_state.moves, i)
							i -= 1
						}
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
