package client

import rl "vendor:raylib"

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
		}
	}

	{
		w := get_widget(layout, back_id)
		if rl.GuiButton(w.rect, w.text) {
			game_state.screen_state = .MainMenu
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
