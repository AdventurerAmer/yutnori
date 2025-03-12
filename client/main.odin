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

Screen_State :: enum {
	MainMenu,
	GameModes,
	LocalGameMode,
	GamePlay,
}

Piece :: struct {
	finished: bool,
	cell:     Cell_ID,
}

is_piece_at_start :: proc(p: Piece) -> bool {
	return p.cell == .BottomRightCorner && !p.finished
}

Player_State :: struct {
	color:  rl.Color,
	pieces: [MAX_PIECE_COUNT]Piece,
}

Move :: struct {
	roll:   i32,
	cell:   Cell_ID,
	finish: bool,
}

Draw_State :: struct {
	screen_size:        Vec2,
	piece_size:         Vec2,
	cell_positions:     [Cell_ID]Vec2,
	top_rect:           Rect,
	board_rect:         Rect,
	left_players_rect:  Rect,
	right_players_rect: Rect,
	bottom_rect:        Rect,
}

Game_State :: struct {
	screen_state:         Screen_State,
	is_paused:            bool,
	draw_state:           Draw_State,
	piece_count:          i32,
	player_count:         i32,
	players:              [dynamic]Player_State,
	player_turn_index:    u32,
	player_won_index:     i32,
	rolls:                [dynamic]i32,
	moves:                [dynamic]Move,
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
	game_state.player_count = MIN_PLAYER_COUNT
	game_state.piece_count = MIN_PIECE_COUNT
	game_state.player_turn_index = 0
	game_state.player_won_index = -1
	resize(&game_state.players, MAX_PLAYER_COUNT)
	for i in 0 ..< MAX_PLAYER_COUNT {
		p := &game_state.players[i]
		p.color = PLAYER_COLORS[i]
		for j in 0 ..< MAX_PIECE_COUNT {
			piece := Piece {
				finished = false,
				cell     = .BottomRightCorner,
			}
			p.pieces[j] = piece
		}
	}
	resize(&game_state.rolls, 0)
	game_state.is_paused = false
	game_state.selected_piece_index = -1
	game_state.can_roll = true
}

roll :: proc(game_state: ^Game_State) {
	if !game_state.can_roll do return
	player := game_state.players[game_state.player_turn_index]
	n := rand.int31_max(7) - 1
	if n != 4 && n != 5 {
		game_state.can_roll = false
	}
	should_append := true
	all_pieces_at_start := true
	for piece in player.pieces {
		if !is_piece_at_start(piece) {
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

			update_draw_state(game_state)
			draw_state := game_state.draw_state
			piece_size := draw_state.piece_size

			game_state.moves = make([dynamic]Move, context.temp_allocator)
			if len(game_state.rolls) != 0 &&
			   game_state.selected_piece_index != -1 &&
			   !game_state.can_roll {
				player := &game_state.players[game_state.player_turn_index]
				for roll, roll_idx in game_state.rolls {
					piece_to_move := player.pieces[game_state.selected_piece_index]
					if roll == -1 {
						if !is_piece_at_start(piece_to_move) {
							back0, back1 := get_prev_cell(piece_to_move.cell)
							append(&game_state.moves, Move{roll, back0, false})
							if back1 != back0 {
								append(&game_state.moves, Move{roll, back1, false})
							}
						}
					} else {
						path, end := get_move_sequance(
							piece_to_move.cell,
							u32(roll),
							is_piece_at_start(piece_to_move),
						)
						append(&game_state.moves, Move{roll, path[len(path) - 1], end})
					}
					should_move := false
					target_move := Move{}
					if !game_state.is_paused && game_state.player_won_index == -1 {
						finish_count := 0
						for move in game_state.moves {
							if move.finish do finish_count += 1
						}
						finish_offset := f32(0)
						for move in game_state.moves {
							pos := draw_state.cell_positions[move.cell]
							if move.finish {
								pos += piece_size * 0.5
								pos.x += finish_offset
								finish_offset += piece_size.x * 0.1
							} else {
								pos -= piece_size * 0.5
							}
							r := Rect{pos.x, pos.y, piece_size.x, piece_size.y}
							if rl.CheckCollisionPointRec(rl.GetMousePosition(), r) &&
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
								   !is_piece_at_start(piece) &&
								   player_idx != i32(game_state.player_turn_index) {
									piece.cell = .BottomRightCorner
									game_state.can_roll = true
								}
								player_state.pieces[piece_idx] = piece
							}
						}

						if is_piece_at_start(piece_to_move) {
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
										piece.cell = target_move.cell
										piece.finished = target_move.finish
									}
									player_state.pieces[piece_idx] = piece
								}
							}
						}

						game_state.selected_piece_index = -1
						ordered_remove(&game_state.rolls, roll_idx)

						finished_pieces_count := i32(0)
						for piece_idx in 0 ..< game_state.piece_count {
							piece :=
								game_state.players[game_state.player_turn_index].pieces[piece_idx]
							if piece.finished {
								finished_pieces_count += 1
							}
						}
						if finished_pieces_count == game_state.player_count {
							game_state.player_won_index = auto_cast game_state.player_turn_index
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

			draw(game_state, default_style)

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

update_draw_state :: proc(game_state: ^Game_State) {
	screen_size := Vec2{f32(rl.GetRenderWidth()), f32(rl.GetRenderHeight())}

	draw_state := &game_state.draw_state
	draw_state.screen_size = screen_size

	piece_size := min(screen_size.x, screen_size.y) * 0.05
	draw_state.piece_size = Vec2{piece_size, piece_size}

	draw_state.top_rect = Rect{0, 0, screen_size.x, screen_size.y * 0.1}

	{
		padding := min(screen_size.x * 0.1, screen_size.y * 0.1)
		size := Vec2{screen_size.x * 0.5, screen_size.y * 0.9}
		board_rect := Rect{screen_size.x * 0.5 - size.x * 0.5, screen_size.y * 0.1, size.x, size.y}
		board_rect = shrink_rect(board_rect, padding)
		draw_state.board_rect = board_rect
	}

	draw_state.bottom_rect = Rect{screen_size.y * 0.9, 0, screen_size.x, screen_size.y * 0.1}

	draw_state.left_players_rect = Rect {
		0,
		screen_size.y * 0.1,
		screen_size.x * 0.25,
		screen_size.y * 0.9,
	}
	draw_state.right_players_rect = Rect {
		screen_size.x * 0.75,
		screen_size.y * 0.1,
		screen_size.x * 0.25,
		screen_size.y * 0.9,
	}


	// calculate game board positions
	{
		points := get_anchors_from_rect(draw_state.board_rect)
		draw_state.cell_positions[.BottomRightCorner] = points.bottom_right
		draw_state.cell_positions[.TopRightCorner] = points.top_right
		draw_state.cell_positions[.TopLeftCorner] = points.top_left
		draw_state.cell_positions[.BottomLeftCorner] = points.bottom_left
		draw_state.cell_positions[.Center] = points.center

		// Vertical
		{
			step := draw_state.board_rect.height / (SIDE_CELL_COUNT + 1)
			for i in 0 ..< SIDE_CELL_COUNT {
				p := points.bottom_right
				p.y -= f32(i + 1) * step
				draw_state.cell_positions[Cell_ID.Right0 + Cell_ID(i)] = p
			}
			for i in 0 ..< SIDE_CELL_COUNT {
				p := points.top_left
				p.y += f32(i + 1) * step
				draw_state.cell_positions[Cell_ID.Left0 + Cell_ID(i)] = p
			}
		}

		// Horizontal
		{
			step := draw_state.board_rect.width / (SIDE_CELL_COUNT + 1)
			for i in 0 ..< SIDE_CELL_COUNT {
				p := points.top_right
				p.x -= f32(i + 1) * step
				draw_state.cell_positions[Cell_ID.Top0 + Cell_ID(i)] = p
			}
			for i in 0 ..< SIDE_CELL_COUNT {
				p := points.bottom_left
				p.x += f32(i + 1) * step
				draw_state.cell_positions[Cell_ID.Bottom0 + Cell_ID(i)] = p
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
				draw_state.cell_positions[.MainDiagonal0 + Cell_ID(i)] =
					p0 + dir * f32(i + 1) * step0

			}

			center_to_p1 := p1 - points.center
			step1 := linalg.length(center_to_p1) / 3
			for i := 0; i < SIDE_CELL_COUNT / 2; i += 1 {
				draw_state.cell_positions[.MainDiagonal2 + Cell_ID(i)] =
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
				draw_state.cell_positions[.AntiDiagonal0 + Cell_ID(i)] =
					p0 + dir * f32(i + 1) * step0

			}

			center_to_p1 := p1 - points.center
			step1 := linalg.length(center_to_p1) / 3
			for i := 0; i < SIDE_CELL_COUNT / 2; i += 1 {
				draw_state.cell_positions[.AntiDiagonal2 + Cell_ID(i)] =
					points.center + dir * f32(i + 1) * step0

			}
		}
	}
}

draw :: proc(game_state: ^Game_State, style: UI_Style) {
	mouse := rl.GetMousePosition()

	draw_state := game_state.draw_state
	screen_size := draw_state.screen_size
	piece_size := draw_state.piece_size

	// draw top section
	{
		cursor := Vec2{draw_state.top_rect.x, draw_state.top_rect.y}

		{
			text := cstring("ROLL")
			size := rl.MeasureTextEx(style.font, text, style.font_size, style.font_spacing)
			size += screen_size * Vec2{0.01, 0.01}

			cursor.y += screen_size.y * 0.01
			r := Rect{screen_size.x * 0.5 - size.x * 0.5, cursor.y, size.x, size.y}

			if !game_state.can_roll || game_state.is_paused {
				rl.GuiDisable()
			}

			if rl.GuiButton(r, text) {
				roll(game_state)
			}
			rl.GuiEnable()

			cursor.y += size.y
		}

		{
			total_width := f32(0)
			total_height := f32(0)
			font_size := style.font_size * 0.75

			for roll in game_state.rolls {
				text := fmt.ctprintf("%d", roll)
				size := rl.MeasureTextEx(style.font, text, font_size, style.font_spacing)
				total_width += size.x
				total_height = max(total_height, size.y)
			}

			spacing := 0.025 * screen_size.x
			total_width += f32(len(game_state.rolls) - 1) * spacing

			cursor.x += draw_state.top_rect.width * 0.5 - total_width * 0.5
			cursor.y += screen_size.y * 0.02

			for roll in game_state.rolls {
				text := fmt.ctprintf("%d", roll)
				size := rl.MeasureTextEx(style.font, text, font_size, style.font_spacing)

				r := Rect{cursor.x, cursor.y, size.x, total_height}
				r = expand_rect(r, Vec2{0.01, 0.01} * screen_size)

				rl.DrawRectangleRec(r, rl.Color{0, 0, 0, 128})
				rl.DrawTextEx(
					style.font,
					text,
					{cursor.x, cursor.y},
					font_size,
					style.font_spacing,
					rl.WHITE,
				)

				cursor.x += size.x + spacing
			}
		}
	}

	small_circle_radius := draw_state.screen_size.x * 0.02
	big_circle_radius := 1.2 * small_circle_radius

	// draw board
	{
		color := rl.DARKGREEN
		line_thickness := min(screen_size.x, screen_size.y) * 0.01

		r := expand_rect(draw_state.board_rect, Vec2{line_thickness * 0.5, line_thickness * 0.5})
		rl.DrawRectangleLinesEx(r, line_thickness, color)

		points := get_anchors_from_rect(draw_state.board_rect)
		rl.DrawLineEx(points.top_left, points.bottom_right, line_thickness, color)
		rl.DrawLineEx(points.top_right, points.bottom_left, line_thickness, color)

		for cell in Cell_ID {
			radius := select_cell_radius(cell, small_circle_radius, big_circle_radius)
			rl.DrawCircleV(draw_state.cell_positions[cell], radius, color)
		}
	}

	// draw players
	{
		piece_count := game_state.piece_count
		piece_spacing := screen_size.x * 0.005
		total_width := piece_size.x * f32(piece_count) + (f32(piece_count) - 1) * piece_spacing

		left_side_player_count := game_state.player_count / 2
		right_side_player_count := game_state.player_count / 2
		if game_state.player_count % 2 == 1 {
			left_side_player_count += 1
		}

		player_area_height := f32(style.font.baseSize) + screen_size.y * 0.005 + piece_size.y

		left_cursor := Vec2 {
			draw_state.left_players_rect.x +
			draw_state.left_players_rect.width * 0.5 -
			total_width * 0.5,
			draw_state.left_players_rect.y +
			(draw_state.left_players_rect.height / f32(left_side_player_count)) * 0.5 -
			player_area_height * 0.5,
		}

		right_cursor := Vec2 {
			draw_state.right_players_rect.x +
			draw_state.right_players_rect.width * 0.5 -
			total_width * 0.5,
			draw_state.right_players_rect.y +
			(draw_state.right_players_rect.height / f32(right_side_player_count)) * 0.5 -
			player_area_height * 0.5,
		}

		for i in 0 ..< game_state.player_count {
			player := game_state.players[i]
			belongs_to_player := game_state.player_turn_index == auto_cast i
			color := player.color

			if !belongs_to_player {
				color.a = 128
			}

			text := fmt.ctprintf("P%v", i + 1)
			size := rl.MeasureTextEx(style.font, text, style.font_size, style.font_spacing)

			offset: ^Vec2

			if i % 2 == 0 {
				offset = &left_cursor
			} else {
				offset = &right_cursor
			}

			pos := Vec2{offset.x, offset.y}
			pos.x += total_width * 0.5 - size.x * 0.5

			rl.DrawTextEx(style.font, text, pos, style.font_size, style.font_spacing, color)

			offset.y += size.y + screen_size.y * 0.005
			for j in 0 ..< game_state.piece_count {
				piece := &player.pieces[j]
				r := Rect{}
				if is_piece_at_start(piece^) {
					pos := Vec2{f32(j) * (piece_size.x + piece_spacing), 0}
					r = Rect{offset.x + pos.x, offset.y + pos.y, piece_size.x, piece_size.y}
				} else {
					pos := game_state.draw_state.cell_positions[piece.cell]
					pos -= piece_size * 0.5
					r = Rect{pos.x, pos.y, piece_size.x, piece_size.y}
				}
				if piece.finished || !is_piece_at_start(piece^) {
					pos := Vec2{f32(j) * (piece_size.x + piece_spacing), 0}
					r := Rect{offset.x + pos.x, offset.y + pos.y, piece_size.x, piece_size.y}
					rl.DrawRectangleLinesEx(r, min(r.width, r.height) * 0.05, player.color)
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
					piece_union_count := 0
					for k in 0 ..< game_state.piece_count {
						if k == j do continue
						other := player.pieces[k]
						if !is_piece_at_start(piece^) &&
						   !is_piece_at_start(other) &&
						   !other.finished &&
						   other.cell == piece.cell {
							piece_union_count += 1
						}
					}

					if piece_union_count != 0 {
						font_size := style.font_size * 0.75
						text := fmt.ctprintf("%d", piece_union_count + 1)
						size := rl.MeasureTextEx(style.font, text, font_size, style.font_spacing)
						pos := Vec2{r.x + r.width * 0.5, r.y + r.height * 0.5} - size * 0.5
						rl.DrawTextEx(
							style.font,
							text,
							pos,
							font_size,
							style.font_spacing,
							rl.WHITE,
						)
					}
				}

				if is_selected && belongs_to_player && len(game_state.rolls) != 0 {
					rl.DrawRectangleLinesEx(r, min(r.width, r.height) * 0.05, rl.GOLD)
				}
			}

			if i % 2 == 0 {
				offset.y += screen_size.y / f32(left_side_player_count) * 0.5
			} else {
				offset.y += screen_size.y / f32(right_side_player_count) * 0.5
			}
		}
	}

	// draw moves
	{
		finisher_move_count := 0
		for move in game_state.moves {
			if move.finish do finisher_move_count += 1
		}

		player := game_state.players[game_state.player_turn_index]
		font_size := style.font_size * 0.75

		cursor := Vec2{}
		for move, move_idx in game_state.moves {
			pos := game_state.draw_state.cell_positions[move.cell]
			if move.finish {
				pos += cursor + piece_size * 0.5
				cursor.x += piece_size.x * 1.1
				if cursor.x >= screen_size.x {
					cursor.x = 0
					cursor.y += piece_size.y
				}
			} else {
				pos -= piece_size * 0.5
			}
			r := Rect{pos.x, pos.y, piece_size.x, piece_size.y}
			color := player.color
			color.a = 128

			hovered := rl.CheckCollisionPointRec(mouse, r)
			if hovered && !game_state.is_paused && game_state.player_won_index == -1 {
				r = expand_rect(r, piece_size * 0.1)
				radius := select_cell_radius(move.cell, small_circle_radius, big_circle_radius)
				circle_pos := draw_state.cell_positions[move.cell]
				rl.DrawCircleLinesV(circle_pos, radius, rl.GOLD)
			}

			rl.DrawRectangleRec(r, color)
			if finisher_move_count > 1 {
				text := fmt.ctprintf("%v", move.roll)
				size := rl.MeasureTextEx(style.font, text, font_size, style.font_spacing)
				center := Vec2{r.x + r.width * 0.5, r.y + r.height * 0.5} - size * 0.5
				rl.DrawTextEx(style.font, text, center, font_size, style.font_spacing, rl.WHITE)
			}
		}
	}
}
