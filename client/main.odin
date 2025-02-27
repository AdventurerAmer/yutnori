package client

import "core:fmt"
import "core:mem"
import rl "vendor:raylib"

Vec2 :: rl.Vector2
Rect :: rl.Rectangle

WINDOW_WIDTH :: 1280
WINDOW_HEIGHT :: 720
WINDOW_TITLE :: "Yutnori"

UX_State :: enum {
	Main_Menu,
}

Game_State :: struct {
	ux_state: UX_State,
}

init_game :: proc(allocator := context.allocator) -> ^Game_State {
	gs := new(Game_State, allocator)
	gs.ux_state = .Main_Menu
	return gs
}

main :: proc() {
	when ODIN_DEBUG {
		tracker: mem.Tracking_Allocator
		mem.tracking_allocator_init(&tracker, context.allocator)
		context.allocator = mem.tracking_allocator(&tracker)
		defer {
			for _, entry in tracker.allocation_map {
				fmt.eprint(
					"tracking allocator: allocation not freed %v bytes @ %v\n",
					entry.size,
					entry.location,
				)
			}
			for entry in tracker.bad_free_array {
				fmt.eprint(
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

	game_state := init_game()
	defer free(game_state, context.allocator)

	font := rl.GetFontDefault()

	font_size := f32(35)
	font_spacing := f32(2)
	rl.GuiSetStyle(.DEFAULT, i32(rl.GuiDefaultProperty.TEXT_SIZE), i32(font_size))
	rl.GuiSetStyle(.DEFAULT, i32(rl.GuiDefaultProperty.TEXT_SPACING), i32(font_spacing))

	running := true

	for running {
		if rl.WindowShouldClose() {
			break
		}
		free_all(context.temp_allocator)

		rl.BeginDrawing()
		rl.ClearBackground(rl.SKYBLUE)

		screen_rect := get_screen_rect()
		screen_size := get_screen_size()
		ui_points := get_anchors_from_rect(screen_rect)

		switch game_state.ux_state {
		case .Main_Menu:
			layout := begin_vertical_layout(0.005 * screen_size.y)

			layout.style.font = font
			layout.style.font_size = font_size
			layout.style.font_spacing = font_spacing

			padding := Vec2{0.01, 0.01} * screen_size
			play_id := push_widget(&layout, "PLAY", padding)
			options_id := push_widget(&layout, "OPTIONS", padding)
			quit_id := push_widget(&layout, "QUIT", padding)

			parent := end_vertical_layout(&layout, ui_points.center)
			rl.DrawRectangleRounded(pad_rect(parent, {10, 10}), 10 * rl.DEG2RAD, 100, rl.DARKGRAY)

			{
				w := get_widget(layout, play_id)
				if rl.GuiButton(w.rect, w.text) {
					fmt.println(w.text)
				}
			}

			{
				w := get_widget(layout, options_id)
				if rl.GuiButton(w.rect, w.text) {
					fmt.println(w.text)
				}
			}

			{
				w := get_widget(layout, quit_id)
				if rl.GuiButton(w.rect, w.text) {
					fmt.println(w.text)
					running = false
				}
			}
		}

		rl.EndDrawing()
	}
}
