package client

import "core:fmt"
import "core:net"
import "core:strings"
import rl "vendor:raylib"

Screen_State :: enum {
	MainMenu,
	GameModes,
	LocalGameMode,
	Connecting,
	Room,
	MultiplayerGameMode,
	GamePlay,
}

draw_main_menu_screen :: proc(game_state: ^Game_State, style: UI_Style) {
	screen_size := get_screen_size()
	ui_points := get_anchor_points({0, 0, screen_size.x, screen_size.y})

	spacing := 0.005 * screen_size.y

	layout := begin_vertical_layout(spacing)
	layout.style = style

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
			close_game(game_state)
		}
	}
}

draw_game_modes_menu :: proc(game_state: ^Game_State, style: UI_Style) {
	screen_size := get_screen_size()
	ui_points := get_anchor_points({0, 0, screen_size.x, screen_size.y})

	spacing := 0.005 * screen_size.y
	layout := begin_vertical_layout(spacing)
	layout.style = style

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
			if !game_state.connected {
				connect(game_state)
			}
			game_state.screen_state = .Connecting
		}
	}

	{
		w := get_widget(layout, back_id)
		if rl.GuiButton(w.rect, w.text) {
			game_state.screen_state = .MainMenu
		}
	}
}

draw_connecting_screen :: proc(game_state: ^Game_State, style: UI_Style) {
	draw_state := game_state.draw_state
	screen_size := get_screen_size()
	ui_points := get_anchor_points({0, 0, screen_size.x, screen_size.y})

	spacing := 0.005 * screen_size.y
	layout := begin_vertical_layout(spacing)
	layout.style = style

	@(static) dot_count := 1
	@(static) dot_timer := f32(0)

	dt := rl.GetFrameTime()
	dot_timer += dt
	dot_anim_time := f32(0.5)
	max_dot_count := 5
	if dot_timer >= dot_anim_time {
		dot_timer = 0.0
		dot_count += 1
		if dot_count > max_dot_count {
			dot_count = 1
		}
	}

	text := fmt.ctprintf(
		"CONNECTING TO SERVER%v",
		strings.repeat(".", dot_count, context.temp_allocator),
	)

	padding := Vec2{0.01, 0.01} * screen_size
	connect_id := push_widget(&layout, text, padding)
	back_id := push_widget(&layout, "BACK", padding)

	end_vertical_layout(&layout, ui_points.center)

	{
		w := get_widget(layout, connect_id)
		rl.GuiLabel(w.rect, w.text)
	}

	{
		w := get_widget(layout, back_id)
		if rl.GuiButton(w.rect, w.text) {
			game_state.screen_state = .GameModes
		}
	}
}


draw_local_game_mode_menu :: proc(game_state: ^Game_State, style: UI_Style) {
	screen_size := get_screen_size()
	ui_points := get_anchor_points({0, 0, screen_size.x, screen_size.y})

	spacing := 0.005 * screen_size.y
	layout := begin_vertical_layout(spacing)
	layout.style = style

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
}

draw_multiplayer_game_mode_menu :: proc(game_state: ^Game_State, style: UI_Style) {
	screen_size := get_screen_size()
	ui_points := get_anchor_points({0, 0, screen_size.x, screen_size.y})

	spacing := 0.005 * screen_size.y
	layout := begin_vertical_layout(spacing)
	layout.style = style

	padding := Vec2{0.01, 0.01} * screen_size

	push_widget(&layout, "", padding)
	create_room_id := push_widget(&layout, "CREATE ROOM", padding)

	push_widget(&layout, "", padding)

	room_id := push_widget(&layout, "ROOM ID", padding * Vec2{26, 1})
	join_room_id := push_widget(&layout, "JOIN ROOM", padding)

	push_widget(&layout, "", padding)

	back_id := push_widget(&layout, "BACK", padding)

	end_vertical_layout(&layout, ui_points.center)

	{
		if game_state.is_trying_to_create_room {
			rl.GuiDisable()
		}
		w := get_widget(layout, create_room_id)
		if rl.GuiButton(w.rect, w.text) {
			create_room(game_state)
		}
		rl.GuiEnable()
	}

	MAX_INPUT_CHARS :: 64
	@(static) text_buffer: [MAX_INPUT_CHARS + 1]u8

	{
		w := get_widget(layout, room_id)
		ctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
		if ctrl && rl.IsKeyPressed(.V) {
			clipboard := strings.clone_from_cstring(rl.GetClipboardText(), context.temp_allocator)
			copy(text_buffer[:MAX_INPUT_CHARS], transmute([]u8)clipboard)
		}
		c_text := cast(cstring)&text_buffer[0]
		if rl.GuiTextBox(w.rect, c_text, MAX_INPUT_CHARS, true) {
		}
	}

	{
		if game_state.is_trying_to_join_room {
			rl.GuiDisable()
		}

		w := get_widget(layout, join_room_id)
		if rl.GuiButton(w.rect, w.text) {
			c_text := cast(cstring)&text_buffer[0]
			room_id := strings.clone_from_cstring(c_text, context.temp_allocator)
			join_room(game_state, room_id)
		}

		rl.GuiEnable()
	}

	{
		w := get_widget(layout, back_id)
		if rl.GuiButton(w.rect, w.text) {
			disconnect(game_state)
			reset_game_state(game_state)
			game_state.screen_state = .GameModes
		}
	}
}

draw_room_screen :: proc(game_state: ^Game_State, style: UI_Style) {
	screen_size := get_screen_size()
	ui_points := get_anchor_points({0, 0, screen_size.x, screen_size.y})

	spacing := 0.005 * screen_size.y
	layout := begin_vertical_layout(spacing)
	layout.style = style

	padding := Vec2{0.01, 0.01} * screen_size

	room_label_id := push_widget(&layout, "ROOM", padding)
	room_id_text := fmt.ctprintf("%s", game_state.room_id)
	room_id := push_widget(&layout, room_id_text, padding)

	push_widget(&layout, "", padding)

	pieces_id := push_widget(&layout, "PIECES", padding)
	pieces_spinner_id := push_widget(&layout, "", screen_size * Vec2{0.1, 0.05})

	player_ids := make([]int, game_state.room_player_count, context.temp_allocator)

	for i in 0 ..< game_state.room_player_count {
		player := game_state.players[i]
		player_ids[i] = push_widget(&layout, fmt.ctprintf("%s", player.client_id))
	}

	push_widget(&layout, "", padding)

	ready_unready_id: int
	if game_state.is_ready {
		ready_unready_id = push_widget(&layout, "UNREADY", padding)
	} else {
		ready_unready_id = push_widget(&layout, "READY", padding)
	}

	start_id := push_widget(&layout, "START", padding)

	back_id := push_widget(&layout, "BACK", padding)

	end_vertical_layout(&layout, ui_points.center)

	{
		w := get_widget(layout, room_label_id)
		rl.GuiLabel(w.rect, w.text)
	}

	{
		w := get_widget(layout, room_id)
		if rl.GuiLabelButton(w.rect, w.text) {
			rl.SetClipboardText(room_id_text)
		}
	}

	{
		if !game_state.is_room_master {
			rl.GuiDisable()
		}

		{
			w := get_widget(layout, pieces_id)
			rl.GuiLabel(w.rect, w.text)
		}

		{
			if game_state.is_trying_to_set_piece_count {
				rl.GuiDisable()
			}

			w := get_widget(layout, pieces_spinner_id)
			prev_piece_count := game_state.room_piece_count
			rl.GuiSpinner(
				w.rect,
				nil,
				&game_state.room_piece_count,
				MIN_PLAYER_COUNT,
				MAX_PLAYER_COUNT,
				false,
			)
			if prev_piece_count != game_state.room_piece_count {
				game_state.piece_count = prev_piece_count
				set_piece_count(game_state, game_state.room_piece_count)
			}
		}

		if game_state.room_player_count != game_state.room_ready_player_count {
			rl.GuiDisable()
		}

		{
			w := get_widget(layout, start_id)
			if rl.GuiButton(w.rect, w.text) {
			}
		}

		rl.GuiEnable()
	}

	for i in 0 ..< game_state.room_player_count {
		w := get_widget(layout, player_ids[i])
		rl.GuiLabel(w.rect, w.text)
	}

	{
		w := get_widget(layout, ready_unready_id)
		if rl.GuiButton(w.rect, w.text) {
			if game_state.is_ready {
				game_state.is_ready = false
			} else {
				game_state.is_ready = true
			}
		}
	}

	{
		if game_state.is_trying_to_exit_room {
			rl.GuiDisable()
		}
		w := get_widget(layout, back_id)
		if rl.GuiButton(w.rect, w.text) {
			reset_game_state(game_state)
			exit_room(game_state)
		}
		rl.GuiEnable()
	}
}
