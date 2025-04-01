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
			game_state.game_mode = .Local
			game_state.screen_state = .LocalGameMode
		}
	}

	{
		w := get_widget(layout, online_id)
		if rl.GuiButton(w.rect, w.text) {
			net_connect(game_state)
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
			start_game(game_state)
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
			net_create_room(game_state)
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
		rl.GuiTextBox(w.rect, c_text, MAX_INPUT_CHARS, true)
	}

	{
		if game_state.is_trying_to_join_room {
			rl.GuiDisable()
		}

		w := get_widget(layout, join_room_id)
		if rl.GuiButton(w.rect, w.text) {
			c_text := cast(cstring)&text_buffer[0]
			room_id := strings.clone_from_cstring(c_text, context.temp_allocator)
			net_join_room(game_state, room_id)
		}

		rl.GuiEnable()
	}

	{
		w := get_widget(layout, back_id)
		if rl.GuiButton(w.rect, w.text) {
			net_disconnect(game_state)
			reset_game_state(game_state)
			game_state.screen_state = .GameModes
		}
	}
}

draw_room_screen :: proc(game_state: ^Game_State, style: UI_Style) {
	screen_size := get_screen_size()
	ui_points := get_anchor_points({0, 0, screen_size.x, screen_size.y})
	spacing := 0.005 * screen_size.y
	padding := Vec2{0.01, 0.01} * screen_size

	{
		layout := begin_vertical_layout(spacing)
		layout.style = style

		room_label_id := push_widget(&layout, "ROOM", padding)
		room_id_text := fmt.ctprintf("%s", game_state.room_id)
		room_id := push_widget(&layout, room_id_text, padding)

		push_widget(&layout, "", padding)

		pieces_id: int
		pieces_text := cstring("")
		pieces_text_size: Vec2

		if game_state.is_room_master {
			pieces_text = "PIECES "
			pieces_text_size = rl.MeasureTextEx(
				style.font,
				pieces_text,
				style.font_size,
				style.font_spacing,
			)
			size := pieces_text_size
			size.x += screen_size.x * 0.01
			pieces_id = push_widget(&layout, "", size)
		} else {
			pieces_text = fmt.ctprintf("PIECES: %d", game_state.room_piece_count)
			pieces_id = push_widget(&layout, pieces_text, padding)
		}

		push_widget(&layout, "")

		change_name_label := push_widget(&layout, "CHANGE YOUR NAME", padding)

		change_name_id := push_widget(
			&layout,
			"",
			{screen_size.x * 0.15, f32(style.font.baseSize) * 2.0},
		)

		end_vertical_layout(&layout, {ui_points.center.x, screen_size.y / 2 * 0.5})

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
			w := get_widget(layout, pieces_id)
			if game_state.is_room_master {
				if game_state.is_trying_to_set_piece_count {
					rl.GuiDisable()
				}
				prev_piece_count := game_state.room_piece_count

				r := w.rect
				r.width -= pieces_text_size.x
				r.x += pieces_text_size.x

				rl.GuiSpinner(
					r,
					pieces_text,
					&game_state.room_piece_count,
					MIN_PLAYER_COUNT,
					MAX_PLAYER_COUNT,
					false,
				)

				if prev_piece_count != game_state.room_piece_count {
					game_state.piece_count = prev_piece_count
					net_set_piece_count(game_state, game_state.room_piece_count)
				}
			} else {
				rl.GuiLabel(w.rect, w.text)
			}
		}

		{
			w := get_widget(layout, change_name_label)
			rl.GuiLabel(w.rect, w.text)
		}

		{
			w := get_widget(layout, change_name_id)
			MAX_INPUT_CHARS :: 20
			@(static) text_buffer: [MAX_INPUT_CHARS + 1]u8

			c_text := cast(cstring)&text_buffer[0]

			if string(c_text) != game_state.players[0].name {
				copy(text_buffer[:MAX_INPUT_CHARS], transmute([]u8)game_state.players[0].name)
			}

			ctrl := rl.IsKeyDown(.LEFT_CONTROL) || rl.IsKeyDown(.RIGHT_CONTROL)
			if ctrl && rl.IsKeyPressed(.V) {
				clipboard := strings.clone_from_cstring(
					rl.GetClipboardText(),
					context.temp_allocator,
				)
				copy(text_buffer[:MAX_INPUT_CHARS], transmute([]u8)clipboard)
			}

			prev := strings.clone_from_cstring(c_text, context.temp_allocator)
			rl.GuiTextBox(w.rect, c_text, MAX_INPUT_CHARS, true)
			curr := strings.clone_from_cstring(c_text, context.temp_allocator)
			if prev != curr {
				if game_state.players[0].name != "" {
					delete(game_state.players[0].name)
					game_state.players[0].name = ""
				}
				name := strings.clone_from_cstring(c_text)
				game_state.players[0].name = name
				net_change_name(game_state)
			}
		}
	}

	{
		Player_UI_State :: struct {
			layout:         UI_Vertical_Layout,
			name:           int,
			is_ready_label: int,
			kick:           int,
		}

		player_ui_states := make(
			[]Player_UI_State,
			game_state.room_player_count,
			context.temp_allocator,
		)

		player_card_size := Vec2{}

		for i in 1 ..< game_state.room_player_count {
			player := game_state.players[i]
			ui_state := &player_ui_states[i]
			ui_state.layout = begin_vertical_layout(spacing)
			ui_state.layout.style = style

			ui_state.name = push_widget(
				&ui_state.layout,
				fmt.ctprintf("%s-%s", player.name, player.client_id[:8]),
				padding,
			)

			ui_state.is_ready_label = push_widget(
				&ui_state.layout,
				fmt.ctprintf("%s", player.is_ready ? "READY" : "UNREADY"),
				padding,
			)

			ui_state.kick = push_widget(&ui_state.layout, "KICK", padding)

			r := end_vertical_layout(&ui_state.layout)
			player_card_size.x = max(player_card_size.x, r.width)
			player_card_size.y = max(player_card_size.y, r.height)
		}

		total_width := player_card_size.x * f32(game_state.room_player_count - 1)
		if game_state.room_player_count - 2 > 0 {
			total_width += f32(game_state.room_player_count - 2) * spacing
		}

		offset := Vec2 {
			screen_size.x * 0.5 - total_width * 0.5 + player_card_size.x * 0.5,
			screen_size.y * 0.625, // half way between 50% and 75%
		}

		for i in 1 ..< game_state.room_player_count {
			player := game_state.players[i]
			ui_state := &player_ui_states[i]

			{
				w := get_widget(ui_state.layout, ui_state.name)
				r := w.rect
				r.x += offset.x
				r.y += offset.y
				rl.GuiLabel(r, w.text)
			}

			{
				w := get_widget(ui_state.layout, ui_state.is_ready_label)
				r := w.rect
				r.x += offset.x
				r.y += offset.y
				rl.GuiLabel(r, w.text)
			}

			if game_state.is_room_master {
				w := get_widget(ui_state.layout, ui_state.kick)
				r := w.rect
				r.x += offset.x
				r.y += offset.y
				if rl.GuiButton(r, w.text) {
					net_kick_player(game_state, auto_cast i)
				}
			}

			offset.x += spacing + player_card_size.x
		}
	}

	{
		layout := begin_vertical_layout(spacing)
		layout.style = style

		ready_unready_id: int
		if game_state.players[0].is_ready {
			ready_unready_id = push_widget(&layout, "UNREADY", padding)
		} else {
			ready_unready_id = push_widget(&layout, "READY", padding)
		}

		start_id := push_widget(&layout, "START", padding)
		back_id := push_widget(&layout, "BACK", padding)

		end_vertical_layout(&layout, {ui_points.center.x, screen_size.y * 0.875})

		{
			if game_state.is_trying_to_change_ready_state {
				rl.GuiDisable()
			}

			w := get_widget(layout, ready_unready_id)
			if rl.GuiButton(w.rect, w.text) {
				net_change_ready_state(game_state, !game_state.players[0].is_ready)
			}

			rl.GuiEnable()
		}

		{

			if game_state.is_trying_to_start_game ||
			   game_state.room_player_count < 2 ||
			   game_state.room_player_count != game_state.room_ready_player_count ||
			   !game_state.is_room_master {
				rl.GuiDisable()
			}

			{
				w := get_widget(layout, start_id)
				if rl.GuiButton(w.rect, w.text) {
					if game_state.game_mode == .Local {
						start_game(game_state)
					} else {
						net_start_game(game_state)
					}
				}
			}

			rl.GuiEnable()
		}


		{
			if game_state.is_trying_to_exit_room {
				rl.GuiDisable()
			}
			w := get_widget(layout, back_id)
			if rl.GuiButton(w.rect, w.text) {
				reset_game_state(game_state)
				net_exit_room(game_state)
			}
			rl.GuiEnable()
		}
	}
}
