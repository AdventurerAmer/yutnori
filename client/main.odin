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
	piece_spacing:      f32,
	cell_positions:     [Cell_ID]Vec2,
	top_rect:           Rect,
	board_rect:         Rect,
	left_players_rect:  Rect,
	right_players_rect: Rect,
	bottom_rect:        Rect,
}

Action :: enum {
	Unready,
	Ready,
	GameStarted,
	GameEnded,
	BeginTurn,
	EndTurn,
	BeginRoll,
	EndRoll,
	BeginMove,
	EndMove,
	Ticking,
}

Game_State :: struct {
	screen_state:            Screen_State,
	is_paused:               bool,
	draw_state:              Draw_State,
	piece_count:             i32,
	player_count:            i32,
	players:                 [dynamic]Player_State,
	player_turn_index:       i32,
	player_won_index:        i32,
	rolls:                   [dynamic]i32,
	selected_piece_index:    i32,
	current_action:          Action,
	should_roll:             bool,
	target_move:             Move,
	target_piece:            i32,
	target_position:         Vec2,
	target_position_percent: f32,
	move_seq_idx:            i32,
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
	game_state.current_action = .Unready
	game_state.should_roll = false
}

roll :: proc(game_state: ^Game_State) -> i32 {
	n := rand.int31_max(7) - 1
	should_append := true
	if n == 0 {
		should_append = false
		resize(&game_state.rolls, 0)
	}
	player := game_state.players[game_state.player_turn_index]
	all_pieces_at_start := true
	for piece in player.pieces {
		if !is_piece_at_start(piece) {
			all_pieces_at_start = false
			break
		}
	}
	if n == -1 && all_pieces_at_start && len(game_state.rolls) == 0 {
		should_append = false
	}
	if should_append {
		append(&game_state.rolls, n)
	}
	return n
}

get_player_moves :: proc(
	game_state: ^Game_State,
	allocator := context.temp_allocator,
) -> [dynamic]Move {
	if game_state.selected_piece_index == -1 do return nil
	player := game_state.players[game_state.player_turn_index]
	piece := player.pieces[game_state.selected_piece_index]
	moves := make([dynamic]Move, allocator)
	for roll, roll_idx in game_state.rolls {
		path0, path1, finish := get_move_sequance(piece, roll)
		if len(path0) != 0 {
			append(&moves, Move{roll, path0[len(path0) - 1], finish})
		}
		if len(path1) != 0 {
			append(&moves, Move{roll, path1[len(path1) - 1], finish})
		}
	}
	return moves
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
			mouse := rl.GetMousePosition()

			if rl.IsKeyPressed(.ESCAPE) {
				game_state.is_paused = !game_state.is_paused
			}

			update_draw_state(game_state)
			draw_state := game_state.draw_state
			piece_size := draw_state.piece_size

			switch game_state.current_action {
			case .Unready:
				fmt.println("players are unready")
				game_state.current_action = .Ready
			case .Ready:
				fmt.println("players are ready")
				game_state.current_action = .GameStarted
			case .GameStarted:
				fmt.println("game started")
				game_state.player_turn_index = rand.int31_max(game_state.player_count)
				game_state.current_action = .BeginTurn
			case .GameEnded:
				fmt.printf("game ended p%d won\n", game_state.player_won_index + 1)
			case .BeginTurn:
				fmt.printf("p%v's turn\n", game_state.player_turn_index + 1)
				game_state.current_action = .BeginRoll
			case .EndTurn:
				fmt.println("end turn")
				game_state.player_turn_index += 1
				game_state.player_turn_index %= game_state.player_count
				game_state.current_action = .BeginTurn
			case .BeginRoll:
				if game_state.should_roll {
					game_state.should_roll = false
					n := roll(game_state)
					fmt.printf("begin roll: %d\n", n)
					game_state.current_action = .EndRoll
				}
			case .EndRoll:
				fmt.println("end roll")
				roll_count := len(game_state.rolls)
				if roll_count == 0 {
					game_state.current_action = .EndTurn
				} else if game_state.rolls[roll_count - 1] == 4 ||
				   game_state.rolls[roll_count - 1] == 5 {
					game_state.current_action = .BeginRoll
				} else {
					game_state.current_action = .Ticking
				}
			case .BeginMove:
				fmt.println("begin move")
				player := &game_state.players[game_state.player_turn_index]
				piece := player.pieces[game_state.target_piece]
				move := game_state.target_move
				seq0, seq1, won := get_move_sequance(piece, move.roll)
				seq := seq0
				if len(seq1) != 0 {
					if move.cell == seq1[len(seq1) - 1] {
						seq = seq1
					}
				}
				if int(game_state.move_seq_idx) >= len(seq) - 1 {
					game_state.current_action = .EndMove
					break
				}
				dt := rl.GetFrameTime()
				from := Vec2{}
				if game_state.move_seq_idx == -1 {
					from = draw_state.cell_positions[piece.cell]
				} else {
					from = draw_state.cell_positions[seq[game_state.move_seq_idx]]
				}
				from -= draw_state.piece_size * 0.5
				to := draw_state.cell_positions[seq[game_state.move_seq_idx + 1]]
				to -= draw_state.piece_size * 0.5
				ease_in_out_quint :: proc(x: f32) -> f32 {
					return x < 0.5 ? 16 * x * x * x * x * x : 1 - math.pow(-2 * x + 2, 5) / 2
				}
				game_state.target_position = math.lerp(
					from,
					to,
					ease_in_out_quint(game_state.target_position_percent),
				)
				game_state.target_position_percent += dt * 5
				game_state.target_position_percent = math.clamp(
					game_state.target_position_percent,
					0.0,
					1.0,
				)
				if game_state.target_position_percent >= 0.99 {
					game_state.target_position_percent = 0.0
					game_state.move_seq_idx += 1
				}
			case .EndMove:
				fmt.println("end move")

				move := game_state.target_move
				current_player := &game_state.players[game_state.player_turn_index]
				piece_to_move := current_player.pieces[game_state.target_piece]

				// moving pieces
				if is_piece_at_start(piece_to_move) {
					piece_to_move.finished = move.finish
					piece_to_move.cell = move.cell
					current_player.pieces[game_state.target_piece] = piece_to_move
				} else {
					for piece_idx in 0 ..< game_state.piece_count {
						piece := current_player.pieces[piece_idx]
						if piece.finished do continue
						if piece.cell == piece_to_move.cell {
							piece.cell = move.cell
							piece.finished = move.finish
						}
						current_player.pieces[piece_idx] = piece
					}
				}

				// stomping an opponent piece
				stomped := false
				for player_idx in 0 ..< game_state.player_count {
					player := &game_state.players[player_idx]
					for piece_idx in 0 ..< game_state.piece_count {
						piece := player.pieces[piece_idx]
						if piece.finished do continue
						if piece.cell == move.cell &&
						   !is_piece_at_start(piece) &&
						   player_idx != i32(game_state.player_turn_index) {
							piece.cell = .BottomRightCorner
							stomped = true
						}
						player.pieces[piece_idx] = piece
					}
				}


				roll_index := -1
				for roll, idx in game_state.rolls {
					if roll == move.roll {
						roll_index = idx
						break
					}
				}

				ordered_remove(&game_state.rolls, roll_index)

				finished_pieces_count := i32(0)
				for piece_idx in 0 ..< game_state.piece_count {
					piece := current_player.pieces[piece_idx]
					if piece.finished {
						finished_pieces_count += 1
					}
				}

				if finished_pieces_count == game_state.player_count {
					game_state.player_won_index = game_state.player_turn_index
					game_state.current_action = .GameEnded
				} else if stomped {
					game_state.current_action = .BeginRoll
				} else {
					game_state.current_action = .Ticking
				}
			case .Ticking:
				// fmt.println("ticking")

				if rl.IsKeyPressed(.Q) {
					game_state.selected_piece_index = -1
				}

				if len(game_state.rolls) == 0 {
					game_state.current_action = .EndTurn
					break
				}

				moved_this_frame := false

				// pick a move
				{
					moves := get_player_moves(game_state)
					finish_offset := f32(0)
					for move in moves {
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
							current_player := game_state.players[game_state.player_turn_index]
							piece := current_player.pieces[game_state.selected_piece_index]
							game_state.target_piece = game_state.selected_piece_index
							game_state.selected_piece_index = -1
							game_state.target_move = move
							game_state.move_seq_idx = -1
							game_state.target_position_percent = 0
							game_state.current_action = .BeginMove
							moved_this_frame = true
							break
						}
					}
				}

				if moved_this_frame {
					break
				}

				// select piece
				{
					piece_count := game_state.piece_count
					total_width :=
						piece_size.x * f32(piece_count) +
						(f32(piece_count) - 1) * draw_state.piece_spacing

					left_side_player_count := game_state.player_count / 2
					right_side_player_count := game_state.player_count / 2
					if game_state.player_count % 2 == 1 {
						left_side_player_count += 1
					}
					player_area_height :=
						f32(default_style.font.baseSize) + screen_size.y * 0.005 + piece_size.y

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
						(draw_state.right_players_rect.height / f32(right_side_player_count)) *
							0.5 -
						player_area_height * 0.5,
					}

					for i in 0 ..< game_state.player_count {
						player := game_state.players[i]
						belongs_to_player := game_state.player_turn_index == auto_cast i

						text := fmt.ctprintf("P%v", i + 1)
						size := rl.MeasureTextEx(
							default_style.font,
							text,
							default_style.font_size,
							default_style.font_spacing,
						)

						offset: ^Vec2

						if i % 2 == 0 {
							offset = &left_cursor
						} else {
							offset = &right_cursor
						}

						pos := Vec2{offset.x, offset.y}
						pos.x += total_width * 0.5 - size.x * 0.5
						offset.y += size.y + screen_size.y * 0.005
						for j in 0 ..< game_state.piece_count {
							piece := player.pieces[j]
							if piece.finished do continue
							piece_rect := get_piece_rect(draw_state, player, j, offset^)
							hovered := rl.CheckCollisionPointRec(mouse, piece_rect)
							if hovered && belongs_to_player && rl.IsMouseButtonPressed(.LEFT) {
								game_state.selected_piece_index = i32(j)
							}
						}

						if i % 2 == 0 {
							offset.y += screen_size.y / f32(left_side_player_count) * 0.5
						} else {
							offset.y += screen_size.y / f32(right_side_player_count) * 0.5
						}
					}
				}
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
	draw_state.piece_spacing = screen_size.x * 0.005

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

get_piece_rect :: proc(
	draw_state: Draw_State,
	player: Player_State,
	piece_idx: i32,
	offset: Vec2,
) -> (
	result: Rect,
) {
	if piece_idx >= MAX_PIECE_COUNT {
		return
	}
	size := draw_state.piece_size
	spacing := draw_state.piece_spacing
	piece := player.pieces[piece_idx]
	if is_piece_at_start(piece) {
		pos := Vec2{f32(piece_idx) * (size.x + spacing), 0}
		result = Rect{offset.x + pos.x, offset.y + pos.y, size.x, size.y}
	} else {
		pos := draw_state.cell_positions[piece.cell]
		pos -= size * 0.5
		result = Rect{pos.x, pos.y, size.x, size.y}
	}
	return result
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

			if game_state.current_action != .BeginRoll || game_state.is_paused {
				rl.GuiDisable()
			}

			if rl.GuiButton(r, text) {
				game_state.should_roll = true
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
		total_width :=
			piece_size.x * f32(piece_count) + (f32(piece_count) - 1) * draw_state.piece_spacing

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

		for player_idx in 0 ..< game_state.player_count {
			player := game_state.players[player_idx]
			belongs_to_current_player := game_state.player_turn_index == player_idx
			color := player.color

			if !belongs_to_current_player {
				color.a = 128
			}

			text := fmt.ctprintf("P%v", player_idx + 1)
			size := rl.MeasureTextEx(style.font, text, style.font_size, style.font_spacing)

			offset: ^Vec2

			if player_idx % 2 == 0 {
				offset = &left_cursor
			} else {
				offset = &right_cursor
			}

			pos := Vec2{offset.x, offset.y}
			pos.x += total_width * 0.5 - size.x * 0.5

			rl.DrawTextEx(style.font, text, pos, style.font_size, style.font_spacing, color)

			offset.y += size.y + screen_size.y * 0.005
			for piece_idx in 0 ..< game_state.piece_count {
				piece := player.pieces[piece_idx]
				piece_rect := get_piece_rect(draw_state, player, piece_idx, offset^)
				if piece.finished || !is_piece_at_start(piece) {
					pos := Vec2{f32(piece_idx) * (piece_size.x + draw_state.piece_spacing), 0}
					r := Rect{offset.x + pos.x, offset.y + pos.y, piece_size.x, piece_size.y}
					rl.DrawRectangleLinesEx(r, min(r.width, r.height) * 0.05, player.color)
				}
				if piece.finished do continue
				hovered := rl.CheckCollisionPointRec(mouse, piece_rect)
				is_selected := game_state.selected_piece_index == piece_idx
				if game_state.current_action == .Ticking &&
				   hovered &&
				   belongs_to_current_player &&
				   len(game_state.rolls) != 0 &&
				   !is_selected &&
				   !game_state.is_paused {
					padding := min(piece_rect.width, piece_rect.height) * 0.1
					piece_rect = expand_rect(piece_rect, Vec2{padding, padding})
				}

				if game_state.current_action == .BeginMove && belongs_to_current_player {
					if piece_idx == game_state.target_piece ||
					   (piece.cell == player.pieces[game_state.target_piece].cell &&
							   piece.cell != .BottomRightCorner) {
						pos := game_state.target_position
						piece_rect.x = pos.x
						piece_rect.y = pos.y

					}
				}

				rl.DrawRectangleRec(piece_rect, color)

				if !piece.finished {
					piece_union_count := 0
					for k in 0 ..< game_state.piece_count {
						if k == piece_idx do continue
						other := player.pieces[k]
						if !is_piece_at_start(piece) &&
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
						pos :=
							Vec2 {
								piece_rect.x + piece_rect.width * 0.5,
								piece_rect.y + piece_rect.height * 0.5,
							} -
							size * 0.5
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

				if is_selected && belongs_to_current_player && len(game_state.rolls) != 0 {
					rl.DrawRectangleLinesEx(
						piece_rect,
						min(piece_rect.width, piece_rect.height) * 0.05,
						rl.GOLD,
					)
				}
			}

			if player_idx % 2 == 0 {
				offset.y += screen_size.y / f32(left_side_player_count) * 0.5
			} else {
				offset.y += screen_size.y / f32(right_side_player_count) * 0.5
			}
		}
	}

	// draw moves
	{
		moves := get_player_moves(game_state)
		finisher_move_count := 0
		for move in moves {
			if move.finish do finisher_move_count += 1
		}

		player := game_state.players[game_state.player_turn_index]
		font_size := style.font_size * 0.75

		cursor := Vec2{}
		for move, move_idx in moves {
			duplicate_move := false
			for i := 0; i < move_idx; i += 1 {
				if moves[i].cell == move.cell {
					duplicate_move = true
					break
				}
			}
			if duplicate_move do continue
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
