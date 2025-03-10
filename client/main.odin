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

MIN_PIECE_COUNT :: 2
MAX_PIECE_COUNT :: 6

debug := false

Screen_State :: enum {
	MainMenu,
	GameModes,
	LocalGameMode,
	GamePlay,
}

Piece :: struct {
	at_start: bool,
	finished: bool,
	cell:     Cell_ID,
}

Player_State :: struct {
	color:  rl.Color,
	pieces: [MAX_PIECE_COUNT]Piece,
}

Game_State :: struct {
	screen_state:         Screen_State,
	player_count:         i32,
	piece_count:          i32,
	is_paused:            bool,
	cell_positions:       [Cell_ID]Vec2,
	players:              [dynamic]Player_State,
	player_turn_index:    u32,
	player_won_index:     i32,
	rolls:                [dynamic]i32,
	can_roll:             bool,
	selected_piece_index: i32,
}

init_game :: proc(allocator := context.allocator) -> ^Game_State {
	gs := new(Game_State, allocator)
	gs.screen_state = .MainMenu
	reset_game_state(gs)
	return gs
}

deinit_game :: proc(gs: ^Game_State) {
	delete(gs.rolls)
	delete(gs.players)
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
	game_state.player_count = MIN_PIECE_COUNT
	game_state.piece_count = MIN_PIECE_COUNT
	game_state.player_turn_index = 0
	game_state.player_won_index = -1
	resize(&game_state.players, MAX_PLAYER_COUNT)
	for i in 0 ..< MAX_PLAYER_COUNT {
		p := &game_state.players[i]
		p.color = PLAYER_COLORS[i]
		for j in 0 ..< MAX_PIECE_COUNT {
			piece := Piece {
				at_start = true,
				finished = false,
				cell     = .BottomRightCorner,
			}
			if i % 2 == 0 {
				piece.at_start = false
				piece.finished = false
				piece.cell = .MainDiagonal3
			}
			p.pieces[j] = piece
		}
	}
	resize(&game_state.rolls, 0)
	game_state.is_paused = false
	game_state.selected_piece_index = -1
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
			pieces_id := push_widget(&layout, "PIECES", padding)
			pieces_spinner_id := push_widget(&layout, "", screen_size * Vec2{0.1, 0.05})
			start_id := push_widget(&layout, "START", padding)
			back_id := push_widget(&layout, "BACK", padding)
			end_vertical_layout(&layout, ui_points.center)

			{
				w := get_widget(layout, players_id)
				rl.GuiLabel(w.rect, w.text)
			}

			{
				w := get_widget(layout, players_spinner_id)
				rl.GuiSpinner(
					w.rect,
					nil,
					&game_state.player_count,
					MIN_PLAYER_COUNT,
					MAX_PLAYER_COUNT,
					false,
				)
			}

			{
				w := get_widget(layout, pieces_id)
				rl.GuiLabel(w.rect, w.text)
			}

			{
				w := get_widget(layout, pieces_spinner_id)
				rl.GuiSpinner(
					w.rect,
					nil,
					&game_state.piece_count,
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
				margin_y := screen_size.y * 0.05
				r := Rect{screen_size.x * 0.5 - size.x * 0.5, margin_y, size.x, size.y}

				if !game_state.can_roll || game_state.is_paused {
					rl.GuiDisable()
				}

				player := game_state.players[game_state.player_turn_index]

				if rl.GuiButton(r, text) {
					n := rand.int31_max(7) - 1
					if n != 4 && n != 5 {
						game_state.can_roll = false
					}
					should_append := true
					all_pieces_at_start := true
					for piece in player.pieces {
						if !piece.at_start {
							all_pieces_at_start = false
							break
						}
					}
					if n == 0 {
						should_append = false
						resize(&game_state.rolls, 0)
					}
					if n == -1 && all_pieces_at_start && len(game_state.rolls) == 0 {
						should_append = false
					}
					if should_append {
						append(&game_state.rolls, n)
					}
				}

				rl.GuiEnable()

				offset_y += size.y + margin_y

				total_width := f32(0)
				height := f32(0)
				spacing := 0.025 * screen_size.x
				for i := 0; i < len(game_state.rolls); i += 1 {
					text := fmt.ctprintf("%d", game_state.rolls[i])
					size := rl.MeasureTextEx(
						default_style.font,
						text,
						default_style.font_size,
						default_style.font_spacing,
					)
					total_width += size.x
					height = max(height, size.y)
				}

				total_width += f32(len(game_state.rolls) - 1) * spacing
				offset_y += screen_size.y * 0.02
				offset_x := screen_size.x * 0.5 - total_width * 0.5

				for i := 0; i < len(game_state.rolls); i += 1 {
					text := fmt.ctprintf("%d", game_state.rolls[i])
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

				// Debug
				if debug {
					selected_cell := -1
					for cell in Cell_ID {
						pos := game_state.cell_positions[cell]
						radius := select_cell_radius(cell, small_circle_radius, big_circle_radius)
						if rl.CheckCollisionPointCircle(mouse, pos, radius) {
							selected_cell = int(cell)
							break
						}
					}
					if selected_cell != -1 &&
					   !game_state.is_paused &&
					   game_state.player_won_index == -1 {
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
							radius := select_cell_radius(
								item,
								small_circle_radius,
								big_circle_radius,
							)
							pos := game_state.cell_positions[item]
							rl.DrawCircleV(pos, radius, rl.BLUE)
						}

						prev0, prev1 := get_prev_cell(start_cell)

						{
							radius := select_cell_radius(
								prev0,
								small_circle_radius,
								big_circle_radius,
							)
							pos := game_state.cell_positions[prev0]
							rl.DrawCircleV(pos, radius, rl.RED)
						}

						{
							radius := select_cell_radius(
								prev1,
								small_circle_radius,
								big_circle_radius,
							)
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
				}

				Move :: struct {
					roll:   i32,
					cell:   Cell_ID,
					finish: bool,
				}

				moves := make([dynamic]Move, context.temp_allocator)

				if len(game_state.rolls) != 0 &&
				   game_state.selected_piece_index != -1 &&
				   !game_state.can_roll {
					player := &game_state.players[game_state.player_turn_index]
					for i := 0; i < len(game_state.rolls); i += 1 {
						piece_to_move := player.pieces[game_state.selected_piece_index]
						roll := game_state.rolls[i]
						if roll == -1 {
							if !piece_to_move.at_start {
								back0, back1 := get_prev_cell(piece_to_move.cell)
								append(&moves, Move{roll, back0, false})
								if back1 != back0 {
									append(&moves, Move{roll, back1, false})
								}
							}
						} else {
							path, end := get_move_sequance(
								piece_to_move.cell,
								u32(roll),
								piece_to_move.at_start,
							)
							append(&moves, Move{roll, path[len(path) - 1], end})
						}
						should_move := false
						target_move := Move{}
						if !game_state.is_paused && game_state.player_won_index == -1 {
							finish_count := 0
							for move in moves {
								if move.finish do finish_count += 1
							}
							finish_offset := f32(0)
							for move in moves {
								pos := game_state.cell_positions[move.cell]
								if move.finish {
									pos += Vec2{piece_size, piece_size} * 0.5
									pos.x += finish_offset
									finish_offset += piece_size * 0.1
								} else {
									pos -= Vec2{piece_size, piece_size} * 0.5
								}
								r := Rect{pos.x, pos.y, piece_size, piece_size}
								if rl.CheckCollisionPointRec(mouse, r) &&
								   rl.IsMouseButtonPressed(.LEFT) {
									should_move = true
									target_move = move
									break
								}
							}
						}
						if should_move {
							for player_idx in 0 ..< game_state.player_count {
								player_state := &game_state.players[player_idx]
								for piece_idx in 0 ..< game_state.piece_count {
									piece := player_state.pieces[piece_idx]
									if piece.finished do continue
									if piece.cell == target_move.cell &&
									   !piece.finished &&
									   !piece.at_start &&
									   player_idx != i32(game_state.player_turn_index) {
										piece.at_start = true
										piece.cell = .BottomRightCorner
										game_state.can_roll = true
									}
									player_state.pieces[piece_idx] = piece
								}
							}

							if piece_to_move.at_start {
								piece_to_move.at_start = false
								piece_to_move.finished = target_move.finish
								piece_to_move.cell = target_move.cell
								player.pieces[game_state.selected_piece_index] = piece_to_move
							} else {
								for player_idx in 0 ..< game_state.player_count {
									player_state := &game_state.players[player_idx]
									for piece_idx in 0 ..< game_state.piece_count {
										piece := player_state.pieces[piece_idx]
										if piece.finished do continue
										if piece.cell == piece_to_move.cell &&
										   player_idx == i32(game_state.player_turn_index) {
											piece.at_start = false
											piece.cell = target_move.cell
											piece.finished = target_move.finish
										}
										player_state.pieces[piece_idx] = piece
									}
								}
							}

							game_state.selected_piece_index = -1
							ordered_remove(&game_state.rolls, i)

							finished_pieces_count := i32(0)
							for piece_idx in 0 ..< game_state.piece_count {
								piece :=
									game_state.players[game_state.player_turn_index].pieces[piece_idx]
								if piece.finished {
									finished_pieces_count += 1
								}
							}
							if finished_pieces_count == game_state.player_count {
								game_state.player_won_index =
								auto_cast game_state.player_turn_index
							}
							break
						}
					}
				}

				if len(game_state.rolls) == 0 &&
				   game_state.can_roll == false &&
				   game_state.player_won_index == -1 {
					game_state.player_turn_index += 1
					game_state.player_turn_index %= u32(game_state.player_count)
					game_state.can_roll = true
				}

				piece_spacing := screen_size.x * 0.005
				total_width :=
					piece_size * f32(game_state.piece_count) +
					(f32(game_state.piece_count) - 1) * piece_spacing

				// Drawing Players
				{
					left_side_player_count := game_state.player_count / 2
					right_side_player_count := game_state.player_count / 2
					if game_state.player_count % 2 == 1 {
						left_side_player_count += 1
					}

					player_area_size :=
						f32(default_style.font.baseSize) + screen_size.y * 0.005 + piece_size

					left_offset := Vec2 {
						screen_size.x * 0.25 * 0.5 - total_width * 0.5,
						(screen_size.y / f32(left_side_player_count)) * 0.5 -
						player_area_size * 0.5,
					}

					right_offset := Vec2 {
						screen_size.x * 0.75 + screen_size.x * 0.25 * 0.5 - total_width * 0.5,
						(screen_size.y / f32(right_side_player_count)) * 0.5 -
						player_area_size * 0.5,
					}

					for i := i32(0); i < game_state.player_count; i += 1 {
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

						offset: ^Vec2

						if i % 2 == 0 {
							offset = &left_offset
						} else {
							offset = &right_offset
						}

						pos := Vec2{offset.x, offset.y}
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
						for j in 0 ..< game_state.piece_count {
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
							if piece.finished || !piece.at_start {
								pos := Vec2{f32(j) * (piece_size + piece_spacing), 0}
								r := Rect {
									offset.x + pos.x,
									offset.y + pos.y,
									piece_size,
									piece_size,
								}
								rl.DrawRectangleLinesEx(
									r,
									min(0.05 * r.width, 0.05 * r.height),
									player.color,
								)
							}
							if piece.finished do continue
							hovered := rl.CheckCollisionPointRec(mouse, r)
							if hovered &&
							   belongs_to_player &&
							   rl.IsMouseButtonPressed(.LEFT) &&
							   !game_state.can_roll {
								game_state.selected_piece_index = i32(j)
							}
							is_selected := game_state.selected_piece_index == i32(j)
							if hovered &&
							   belongs_to_player &&
							   len(game_state.rolls) != 0 &&
							   !is_selected &&
							   !game_state.is_paused &&
							   game_state.player_won_index == -1 {
								padding := min(r.width, r.height) * 0.1
								r = expand_rect(r, Vec2{padding, padding})
							}

							rl.DrawRectangleRec(r, color)

							if !piece.finished {
								mount_count := 0
								for k in 0 ..< game_state.piece_count {
									if k == j do continue
									other := player.pieces[k]
									if !piece.at_start &&
									   !other.at_start &&
									   !other.finished &&
									   other.cell == piece.cell {
										mount_count += 1
									}
								}

								if mount_count != 0 {
									text := fmt.ctprintf("%d", mount_count + 1)
									size := rl.MeasureTextEx(
										default_style.font,
										text,
										default_style.font_size * 0.75,
										default_style.font_spacing,
									)
									pos :=
										Vec2{r.x + r.width * 0.5, r.y + r.height * 0.5} -
										size * 0.5
									rl.DrawTextEx(
										default_style.font,
										text,
										pos,
										default_style.font_size * 0.75,
										default_style.font_spacing,
										rl.WHITE,
									)
								}
							}

							if is_selected && belongs_to_player && len(game_state.rolls) != 0 {
								rl.DrawRectangleLinesEx(
									r,
									min(0.05 * r.width, 0.05 * r.height),
									rl.GOLD,
								)
							}
						}

						if i % 2 == 0 {
							offset.y += screen_size.y / f32(left_side_player_count) * 0.5
						} else {
							offset.y += screen_size.y / f32(right_side_player_count) * 0.5
						}
					}
				}

				finish_count := 0
				for move in moves {
					if move.finish do finish_count += 1
				}

				finish_offset := f32(0)

				for move in moves {
					player := game_state.players[game_state.player_turn_index]
					pos := game_state.cell_positions[move.cell]
					if move.finish {
						pos += Vec2{piece_size, piece_size} * 0.5
						pos.x += finish_offset
						finish_offset += piece_size * 1.1
					} else {
						pos -= Vec2{piece_size, piece_size} * 0.5
					}
					r := Rect{pos.x, pos.y, piece_size, piece_size}
					color := player.color
					color.a = 128
					hovered := rl.CheckCollisionPointRec(mouse, r)
					if hovered && !game_state.is_paused && game_state.player_won_index == -1 {
						r = expand_rect(r, Vec2{piece_size, piece_size} * 0.1)
					}
					rl.DrawRectangleRec(r, color)

					if finish_count > 1 {
						text := fmt.ctprintf("%v", move.roll)
						size := rl.MeasureTextEx(
							default_style.font,
							text,
							default_style.font_size * 0.75,
							default_style.font_spacing,
						)
						center := Vec2{r.x + r.width * 0.5, r.y + r.height * 0.5} - size * 0.5
						rl.DrawTextEx(
							default_style.font,
							text,
							center,
							default_style.font_size * 0.75,
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

			if game_state.player_won_index != -1 {
				rl.DrawRectangleRec(screen_rect, {0, 0, 0, 128})

				spacing := 0.005 * screen_size.y
				layout := begin_vertical_layout(spacing)
				layout.style = default_style

				padding := Vec2{0.01, 0.01} * screen_size
				player_won_id := push_widget(
					&layout,
					fmt.ctprintf("P%d WON", game_state.player_won_index + 1),
					padding,
				)
				main_menu_id := push_widget(&layout, "MAIN MENU", padding)
				end_vertical_layout(&layout, ui_points.center)

				{
					w := get_widget(layout, player_won_id)
					rl.GuiLabel(w.rect, w.text)
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
