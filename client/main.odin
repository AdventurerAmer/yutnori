package client

import "base:intrinsics"
import "core:container/queue"
import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import "core:mem"
import "core:net"
import "core:reflect"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

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

Piece :: struct {
	at_start: bool,
	finished: bool,
	cell:     Cell_ID,
}

Player_State :: struct {
	name:      string,
	client_id: string,
	is_ready:  bool,
	color:     rl.Color,
	pieces:    [MAX_PIECE_COUNT]Piece,
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
	None,
	GameStarted,
	GameEnded,
	BeginTurn,
	EndTurn,
	CanRoll,
	BeginRoll,
	EndRoll,
	BeginMove,
	EndMove,
	SelectingMove,
}

Game_Mode :: enum {
	Local,
	Online,
}

Game_State :: struct {
	running:                         bool,
	screen_state:                    Screen_State,
	is_paused:                       bool,
	draw_state:                      Draw_State,
	piece_count:                     i32,
	player_count:                    i32,
	players:                         [dynamic]Player_State,
	player_turn_index:               i32,
	player_won_index:                i32,
	rolls:                           [dynamic]i32,
	selected_piece_index:            i32,
	current_action:                  Action,
	target_move:                     Move,
	target_piece:                    i32,
	target_position:                 Vec2,
	target_position_percent:         f32,
	move_seq_idx:                    i32,
	game_mode:                       Game_Mode,
	net_sender_thread:               ^thread.Thread,
	net_receiver_thread:             ^thread.Thread,
	net_commands_queue:              queue.Queue(Net_Request),
	net_commands_queue_mutex:        sync.Mutex,
	net_commands_semaphore:          sync.Sema,
	net_response_queue:              queue.Queue(Net_Message),
	net_response_queue_mutex:        sync.Mutex,
	connected:                       bool,
	is_trying_to_connect:            bool,
	connection_timer:                f32,
	is_trying_to_create_room:        bool,
	room_id:                         string,
	is_room_master:                  bool,
	is_trying_to_exit_room:          bool,
	room_piece_count:                i32,
	is_trying_to_join_room:          bool,
	room_ready_player_count:         i32,
	is_trying_to_set_piece_count:    bool,
	room_player_count:               i32,
	is_trying_to_change_ready_state: bool,
	is_trying_to_kick_player_set:    bit_set[0 ..< MAX_PLAYER_COUNT;int],
	is_trying_to_start_game:         bool,
	is_trying_to_roll:               bool,
	net_state:                       Net_State,
}

init_game :: proc(allocator := context.allocator) -> ^Game_State {
	game_state := new(Game_State, allocator)
	game_state.running = true
	game_state.screen_state = .MainMenu
	reset_game_state(game_state)
	return game_state
}

deinit_game :: proc(game_state: ^Game_State) {
	reset_net_state(game_state)
	delete(game_state.rolls)
	delete(game_state.players)
	if game_state.net_sender_thread != nil {
		push_net_request(game_state, Quit_Request{})
		thread.join(game_state.net_sender_thread)
		thread.join(game_state.net_receiver_thread)
		thread.destroy(game_state.net_sender_thread)
		thread.destroy(game_state.net_receiver_thread)
		queue.destroy(&game_state.net_commands_queue)
		queue.destroy(&game_state.net_response_queue)
		net_state := &game_state.net_state
		free_all(net_state.allocator)
		delete(net_state.allocator_data)
		free(net_state.allocator.data)
	}
	free(game_state)
}

close_game :: proc(game_state: ^Game_State) {
	game_state.running = false
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
		p.is_ready = false
		for j in 0 ..< MAX_PIECE_COUNT {
			piece := Piece {
				at_start = true,
				finished = false,
				cell     = .BottomRightCorner,
			}
			p.pieces[j] = piece
		}
	}
	resize(&game_state.rolls, 0)
	game_state.is_paused = false
	game_state.selected_piece_index = -1
	game_state.current_action = .None
}

start_game :: proc(game_state: ^Game_State) {
	if game_state.game_mode == .Online {
		net_start_game(game_state)
	} else {
		game_state.player_turn_index = rand.int31_max(game_state.player_count)
		game_state.current_action = .GameStarted
	}
}

end_game :: proc(game_state: ^Game_State) {
	if game_state.current_action == .EndTurn {
		game_state.player_won_index = game_state.player_turn_index
		game_state.current_action = .GameEnded
	}
}

begin_turn :: proc(game_state: ^Game_State) {
	if game_state.game_mode == .Online do return
	if game_state.current_action == .GameStarted || game_state.current_action == .EndTurn {
		game_state.current_action = .BeginTurn
	}
}

end_turn :: proc(game_state: ^Game_State) {
	if game_state.game_mode == .Online do return
	current_player := game_state.players[game_state.player_turn_index]

	finished_piece_count := i32(0)
	for i := i32(0); i < game_state.piece_count; i += 1 {
		piece := current_player.pieces[i]
		if piece.finished {
			finished_piece_count += 1
		}
	}
	if finished_piece_count == game_state.piece_count {
		end_game(game_state)
	} else {
		game_state.player_turn_index += 1
		game_state.player_turn_index %= game_state.player_count
		game_state.current_action = .BeginTurn
	}
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
		if !piece.at_start {
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

can_roll :: proc(game_state: ^Game_State) {
	if game_state.game_mode == .Online do return
	game_state.current_action = .CanRoll
}

begin_roll :: proc(game_state: ^Game_State) {
	if game_state.game_mode == .Online {
		net_roll(game_state)
		return
	}
	game_state.current_action = .BeginRoll
}

end_roll :: proc(game_state: ^Game_State) {
	if game_state.game_mode == .Online do return
	n := roll(game_state)
	fmt.printf("roll: %d\n", n)
	game_state.current_action = .EndRoll
}

begin_move :: proc(game_state: ^Game_State) {
	draw_state := game_state.draw_state
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
		return
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
	game_state.target_position_percent += dt * 3
	game_state.target_position_percent = math.clamp(game_state.target_position_percent, 0.0, 1.0)
	if game_state.target_position_percent >= 0.99 {
		game_state.target_position_percent = 0.0
		game_state.move_seq_idx += 1
	}
}

end_move :: proc(game_state: ^Game_State) {
	move := game_state.target_move
	current_player := &game_state.players[game_state.player_turn_index]
	piece_to_move := current_player.pieces[game_state.target_piece]

	// moving pieces
	if piece_to_move.at_start {
		piece_to_move.finished = move.finish
		piece_to_move.cell = move.cell
		piece_to_move.at_start = false
		current_player.pieces[game_state.target_piece] = piece_to_move
	} else {
		for piece_idx in 0 ..< game_state.piece_count {
			piece := current_player.pieces[piece_idx]
			if piece.finished do continue
			if piece.cell == piece_to_move.cell && !piece.at_start {
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
			   !piece.at_start &&
			   player_idx != i32(game_state.player_turn_index) {
				piece.cell = .BottomRightCorner
				piece.at_start = true
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

	if stomped {
		game_state.current_action = .CanRoll
	} else {
		game_state.current_action = .SelectingMove
	}
}

select_move :: proc(game_state: ^Game_State, style: UI_Style) {
	draw_state := game_state.draw_state
	screen_size := draw_state.screen_size
	piece_size := draw_state.piece_size
	current_player := game_state.players[game_state.player_turn_index]

	finished_pieces_count := i32(0)
	for piece_idx in 0 ..< game_state.piece_count {
		piece := current_player.pieces[piece_idx]
		if piece.finished {
			finished_pieces_count += 1
		}
	}

	if finished_pieces_count == game_state.piece_count || len(game_state.rolls) == 0 {
		game_state.current_action = .EndTurn
		return
	}

	moved_this_frame := false

	// select a move
	{
		moves := get_current_player_moves(game_state)
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
				game_state.target_piece = game_state.selected_piece_index
				game_state.target_move = move
				game_state.move_seq_idx = -1
				game_state.target_position_percent = 0
				game_state.current_action = .BeginMove
				game_state.selected_piece_index = -1
				moved_this_frame = true
				break
			}
		}
	}

	if moved_this_frame {
		return
	}

	// select piece
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

		mouse := rl.GetMousePosition()

		for i in 0 ..< game_state.player_count {
			player := game_state.players[i]
			belongs_to_player := game_state.player_turn_index == auto_cast i

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

get_current_player_moves :: proc(
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

	rl.SetExitKey(.KEY_NULL)
	rl.SetWindowMinSize(320, 240)

	game_state := init_game()
	defer deinit_game(game_state)

	font := rl.GetFontDefault()

	default_style := UI_Style {
		font         = rl.GetFontDefault(),
		font_size    = f32(32),
		font_spacing = f32(2),
	}
	rl.GuiSetStyle(.DEFAULT, i32(rl.GuiDefaultProperty.TEXT_SIZE), i32(default_style.font_size))
	rl.GuiSetStyle(
		.DEFAULT,
		i32(rl.GuiDefaultProperty.TEXT_SPACING),
		i32(default_style.font_spacing),
	)
	for game_state.running {
		free_all(context.temp_allocator)

		handle_net_responses(game_state)

		if rl.WindowShouldClose() {
			close_game(game_state)
		}

		rl.BeginDrawing()
		rl.ClearBackground(rl.SKYBLUE)

		screen_rect := get_screen_rect()
		screen_size := get_screen_size()
		ui_points := get_anchor_points(screen_rect)

		switch game_state.screen_state {
		case .MainMenu:
			draw_main_menu_screen(game_state, default_style)
		case .GameModes:
			draw_game_modes_menu(game_state, default_style)
		case .LocalGameMode:
			draw_local_game_mode_menu(game_state, default_style)
		case .Connecting:
			dt := rl.GetFrameTime()
			if !game_state.is_trying_to_connect {
				game_state.connection_timer += dt
				if game_state.connection_timer >= 0.5 {
					net_connect(game_state)
					game_state.connection_timer = 0.0
				}
			}
			if game_state.connected {
				game_state.game_mode = .Online
				game_state.screen_state = .MultiplayerGameMode
			} else {
				draw_connecting_screen(game_state, default_style)
			}
		case .MultiplayerGameMode:
			draw_multiplayer_game_mode_menu(game_state, default_style)
		case .Room:
			draw_room_screen(game_state, default_style)
		case .GamePlay:
			mouse := rl.GetMousePosition()

			if rl.IsKeyPressed(.ESCAPE) {
				game_state.is_paused = !game_state.is_paused
			}

			update_draw_state(game_state)
			draw_state := game_state.draw_state
			piece_size := draw_state.piece_size

			switch game_state.current_action {
			case .None:
			case .GameStarted:
				fmt.println("game has started")
				begin_turn(game_state)
			case .GameEnded:
				fmt.printf("game has ended P%d won\n", game_state.player_won_index + 1)
			case .BeginTurn:
				can_roll(game_state)
			case .EndTurn:
				end_turn(game_state)
			case .CanRoll:
			case .BeginRoll:
				end_roll(game_state)
			case .EndRoll:
				if game_state.game_mode == .Local {
					fmt.println("end roll")
					roll_count := len(game_state.rolls)
					if roll_count == 0 {
						game_state.current_action = .EndTurn
					} else if game_state.rolls[len(game_state.rolls) - 1] == 4 ||
					   game_state.rolls[len(game_state.rolls) - 1] == 5 {
						game_state.current_action = .CanRoll
					} else {
						game_state.current_action = .SelectingMove
					}
				}
			case .BeginMove:
				fmt.println("begin move")
				begin_move(game_state)
			case .EndMove:
				fmt.println("end move")
				end_move(game_state)
			case .SelectingMove:
				fmt.println("selecting move")
				if rl.IsKeyPressed(.Q) {
					game_state.selected_piece_index = -1
				}
				select_move(game_state, default_style)
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
						push_net_request(game_state, Exit_Room_Request{})
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
		points := get_anchor_points(draw_state.board_rect)
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
	if piece.at_start {
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

			if game_state.current_action != .CanRoll ||
			   game_state.is_paused ||
			   game_state.is_trying_to_roll {
				rl.GuiDisable()
			}

			if rl.GuiButton(r, text) {
				begin_roll(game_state)
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

		points := get_anchor_points(draw_state.board_rect)
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

			if belongs_to_current_player {
				outline_thickness := style.font_size * 0.1
				for i := -outline_thickness; i <= outline_thickness; i += 1 {
					for j := -outline_thickness; j <= outline_thickness; j += 1 {
						if (i == 0 || j == 0) do continue
						p := pos
						p.x += f32(i)
						p.y += f32(j)
						rl.DrawTextEx(
							style.font,
							text,
							p,
							style.font_size,
							style.font_spacing,
							rl.GOLD,
						)
					}
				}
			}
			rl.DrawTextEx(style.font, text, pos, style.font_size, style.font_spacing, color)

			offset.y += size.y + screen_size.y * 0.005
			for piece_idx in 0 ..< game_state.piece_count {
				piece := player.pieces[piece_idx]
				piece_rect := get_piece_rect(draw_state, player, piece_idx, offset^)
				if piece.finished || !piece.at_start {
					pos := Vec2{f32(piece_idx) * (piece_size.x + draw_state.piece_spacing), 0}
					r := Rect{offset.x + pos.x, offset.y + pos.y, piece_size.x, piece_size.y}
					rl.DrawRectangleLinesEx(r, min(r.width, r.height) * 0.05, player.color)
				}
				if piece.finished do continue
				hovered := rl.CheckCollisionPointRec(mouse, piece_rect)
				is_selected := game_state.selected_piece_index == piece_idx
				if game_state.current_action == .SelectingMove &&
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
						if !piece.at_start &&
						   !other.at_start &&
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
		moves := get_current_player_moves(game_state)
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

handle_net_responses :: proc(game_state: ^Game_State) {
	if game_state.net_sender_thread == nil do return
	net_state := &game_state.net_state
	sync.lock(&game_state.net_response_queue_mutex)
	if queue.len(game_state.net_response_queue) == 0 {
		sync.unlock(&game_state.net_response_queue_mutex)
		return
	}
	msg := queue.pop_front(&game_state.net_response_queue)
	sync.unlock(&game_state.net_response_queue_mutex)
	defer {
		sync.lock(&net_state.allocator_mu)
		delete(msg.payload, net_state.allocator)
		sync.unlock(&net_state.allocator_mu)
	}
	switch msg.kind {
	case .Keepalive:
		fmt.println("keepalive response")
	case .Connect:
		fmt.println("connect response")
		game_state.is_trying_to_connect = false
		resp := Connect_Response{}
		parse_msg(msg, &resp)
		if resp.client_id != "" {
			game_state.connected = true
			game_state.players[0].client_id = strings.clone(resp.client_id)
		}
	case .Disconnect:
		fmt.println("disconnect response")
		resp := Disconnect_Response{}
		parse_msg(msg, &resp)
		if game_state.connected {
			game_state.connected = false
			game_state.game_mode = .Local
			reset_net_state(game_state)
			game_state.screen_state = .MainMenu
		}
	case .Quit:
	case .CreateRoom:
		game_state.is_trying_to_create_room = false
		resp := Create_Room_Response{}
		parse_msg(msg, &resp)
		if resp.room_id != "" {
			game_state.is_room_master = true
			game_state.room_piece_count = 2
			game_state.room_player_count = 1
			game_state.room_ready_player_count = 0
			game_state.screen_state = .Room
			game_state.room_id = strings.clone(resp.room_id)
		}
	case .ExitRoom:
		game_state.is_trying_to_exit_room = false
		resp := Exit_Room_Response{}
		parse_msg(msg, &resp)
		if resp.exit {
			reset_room_state(game_state)
			if game_state.screen_state == .Room {
				game_state.screen_state = .MultiplayerGameMode
			}
		}
	case .SetPieceCount:
		game_state.is_trying_to_set_piece_count = false
		resp := Set_Piece_Count_Response{}
		parse_msg(msg, &resp)
		if resp.should_set {
			game_state.room_piece_count = resp.piece_count
		}
	case .PlayerLeft:
		resp := Player_Left_Response{}
		parse_msg(msg, &resp)
		fmt.println(resp, game_state.players[0].client_id)
		game_state.is_room_master = game_state.players[0].client_id == resp.master
		for i in 0 ..< int(game_state.room_player_count) {
			if game_state.players[i].client_id == resp.player {
				if i == 0 {
					reset_room_state(game_state)
					if game_state.screen_state == .Room {
						game_state.screen_state = .MultiplayerGameMode
					}
				} else {
					if resp.kicked {
						game_state.is_trying_to_kick_player_set -= {i}
					}
					delete(game_state.players[i].client_id)
					game_state.players[i].client_id = ""
					game_state.players[i] = game_state.players[game_state.room_player_count - 1]
					game_state.players[i].is_ready = false
					game_state.room_player_count -= 1

					if game_state.screen_state == .GamePlay {
						reset_game_state(game_state)
						game_state.screen_state = .Room
					}
				}
				break
			}
		}
	case .EnterRoom:
		resp := Join_Room_Response{}
		parse_msg(msg, &resp)
		game_state.is_trying_to_join_room = false
		if resp.join {
			game_state.is_room_master = resp.master == game_state.players[0].client_id
			game_state.room_piece_count = i32(resp.piece_count)
			game_state.room_ready_player_count = 0
			game_state.room_player_count = 1
			for p in resp.players {
				if p.is_ready do game_state.room_ready_player_count += 1
				idx := game_state.room_player_count
				game_state.players[idx].client_id = strings.clone(p.client_id)
				game_state.room_player_count += 1
			}
			game_state.screen_state = .Room
			game_state.room_id = strings.clone(resp.room_id)
		}
	case .PlayerJoined:
		resp := Player_Joined_Response{}
		parse_msg(msg, &resp)
		game_state.players[game_state.room_player_count].client_id = strings.clone(resp.client_id)
		game_state.room_player_count += 1
	case .KickPlayer:
	case .Ready:
		resp := Player_Ready_Response{}
		parse_msg(msg, &resp)
		fmt.println("ready", resp, game_state.players[0].client_id)
		for i in 0 ..< MAX_PLAYER_COUNT {
			if game_state.players[i].client_id == resp.player {
				if i == 0 {
					game_state.is_trying_to_change_ready_state = false
				}
				game_state.players[i].is_ready = resp.is_ready
				break
			}
		}
		if resp.is_ready {
			game_state.room_ready_player_count += 1
		} else {
			game_state.room_ready_player_count -= 1
		}
	case .StartGame:
		game_state.is_trying_to_start_game = false
		resp := Start_Game_Response{}
		parse_msg(msg, &resp)
		if resp.should_start {
			game_state.player_count = game_state.room_player_count
			for i in 0 ..< game_state.player_count {
				if game_state.players[i].client_id == resp.starting_player {
					game_state.player_turn_index = i
					break
				}
			}
			game_state.screen_state = .GamePlay
			game_state.current_action = .GameStarted
		}
	case .BeginTurn:
		fmt.println("begin turn")
		game_state.current_action = .BeginTurn
	case .CanRoll:
		fmt.println("can roll")
		game_state.current_action = .CanRoll
	case .BeginRoll:
	case .EndRoll:
		game_state.is_trying_to_roll = false
		resp := End_Roll_Response{}
		parse_msg(msg, &resp)
		fmt.printf("end roll %d\n", resp.roll)
		if resp.should_append {
			append(&game_state.rolls, i32(resp.roll))
		}
	case .EndTurn:
		fmt.println("end turn")
		resp := End_Turn_Response{}
		parse_msg(msg, &resp)
		for idx in 0 ..< game_state.player_count {
			if game_state.players[idx].client_id == resp.next_player {
				game_state.player_turn_index = idx
				break
			}
		}
		resize(&game_state.rolls, 0)
		game_state.current_action = .EndTurn
	case .SelectingMove:
		fmt.println("selecting move")
		resp := Selecting_Move_Response{}
		parse_msg(msg, &resp)
		game_state.current_action = .SelectingMove
	}
}

reset_net_state :: proc(game_state: ^Game_State) {
	delete(game_state.players[0].client_id)
	game_state.players[0].client_id = ""
	game_state.players[0].is_ready = false
	reset_room_state(game_state)
}

reset_room_state :: proc(game_state: ^Game_State) {
	for i in 1 ..< MAX_PLAYER_COUNT {
		if game_state.players[i].client_id == "" do continue
		delete(game_state.players[i].client_id)
		game_state.players[i].client_id = ""
		game_state.players[i].is_ready = false
	}

	delete(game_state.room_id)
	game_state.room_id = ""

	game_state.is_room_master = false
	game_state.room_player_count = 0
	game_state.room_ready_player_count = 0
	game_state.room_piece_count = 2
	game_state.is_trying_to_connect = false
	game_state.is_trying_to_kick_player_set = {}
	game_state.is_trying_to_change_ready_state = false
	game_state.is_trying_to_create_room = false
	game_state.is_trying_to_join_room = false
	game_state.is_trying_to_exit_room = false
	game_state.is_trying_to_set_piece_count = false
	game_state.is_trying_to_start_game = false
	game_state.is_trying_to_roll = false
}
