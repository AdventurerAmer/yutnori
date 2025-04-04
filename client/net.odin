package client

import "base:runtime"
import "core:bytes"
import "core:container/queue"
import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:mem"
import "core:net"
import "core:reflect"
import "core:strings"
import "core:sync"
import "core:thread"

Net_State :: struct {
	allocator_mu:      sync.Mutex,
	allocator_data:    []byte,
	allocator:         mem.Allocator,
	mu:                sync.Mutex,
	socket:            net.TCP_Socket,
	net_receiver_sema: sync.Sema,
	net_reciver_quit:  bool,
}

Net_Message_Type :: enum u8 {
	Keepalive,
	Connect,
	Disconnect,
	Quit,
	CreateRoom,
	ExitRoom,
	SetPieceCount,
	PlayerLeft,
	EnterRoom,
	PlayerJoined,
	Ready,
	KickPlayer,
	StartGame,
	BeginTurn,
	CanRoll,
	BeginRoll,
	EndRoll,
	EndTurn,
	SelectingMove,
	BeginMove,
	EndMove,
	EndGame,
	ChangeName,
}

Net_Message :: struct {
	kind:    Net_Message_Type,
	payload: []byte,
}

Connect_Request :: struct {}
Disconnect_Request :: struct {}
Quit_Request :: struct {}

Create_Room_Request :: struct {
	name: string `json:"name"`,
}

Exit_Room_Request :: struct {}
Set_Piece_Count_Request :: struct {
	piece_count: i32 `json:"piece_count"`,
}
Join_Room_Request :: struct {
	room_id: string `json:"room_id"`,
	name:    string `json:"name"`,
}

Kick_Player_Request :: struct {
	player: string `json:"player"`,
}
Ready_Request :: struct {
	is_ready: bool `json:"is_ready"`,
}
Start_Game_Request :: struct {}
Begin_Roll_Request :: struct {}

Begin_Move_Request :: struct {
	roll:  int `json:"roll"`,
	piece: int `json:"piece"`,
	cell:  int `json:"cell"`,
}

End_Move_Request :: struct {
	roll:  int `json:"roll"`,
	piece: int `json:"piece"`,
	cell:  int `json:"cell"`,
}

Change_Name_Request :: struct {
	name: string `json:"name"`,
}

Net_Request :: union {
	Connect_Request,
	Disconnect_Request,
	Quit_Request,
	Create_Room_Request,
	Exit_Room_Request,
	Set_Piece_Count_Request,
	Join_Room_Request,
	Ready_Request,
	Kick_Player_Request,
	Start_Game_Request,
	Begin_Roll_Request,
	Begin_Move_Request,
	End_Move_Request,
	Change_Name_Request,
}

Connect_Response :: struct {
	client_id: string `json:"client_id"`,
}

Disconnect_Response :: struct {}

Create_Room_Response :: struct {
	room_id: string `json:"room_id"`,
}

Exit_Room_Response :: struct {
	exit: bool,
}

Set_Piece_Count_Response :: struct {
	should_set:  bool `json:"should_set"`,
	piece_count: i32 `json:"piece_count"`,
}

Player_Left_Response :: struct {
	player: string `json:"player"`,
	master: string `json:"master"`,
	kicked: bool `json:"kicked"`,
}

Player_Room_State :: struct {
	client_id: string `json:"client_id"`,
	is_ready:  bool `json:"is_ready"`,
	name:      string `json:"name"`,
}

Join_Room_Response :: struct {
	room_id:     string `json:"room_id"`,
	join:        bool `json:"join"`,
	master:      string `json:"master"`,
	piece_count: u8 `json:"piece_count"`,
	players:     []Player_Room_State `json:"players"`,
}

Player_Joined_Response :: struct {
	client_id: string `json:"client_id"`,
	name:      string `json:"name"`,
}

Player_Ready_Response :: struct {
	player:   string `json:"player"`,
	is_ready: bool `json:"is_ready"`,
}

Player_Kicked_Response :: struct {
	client_id: string `json:"client_id"`,
}

Start_Game_Response :: struct {
	should_start:    bool `json:"shout_start"`,
	starting_player: string `json:"starting_player"`,
}

Begin_Turn_Response :: struct {}
End_Roll_Response :: struct {
	should_append: bool `json:"should_append"`,
	roll:          int `json:"roll"`,
}
End_Turn_Response :: struct {
	next_player: string `json:"next_player"`,
}

Can_Roll_Response :: struct {
	player: string `json:"player"`,
}

Selecting_Move_Response :: struct {
	player: string `json:"player"`,
}

Begin_Move_Response :: struct {
	player:      string `json:"player"`,
	should_move: bool `json:"should_move"`,
	roll:        int `json:"roll"`,
	cell:        Cell_ID `json:"cell"`,
	piece:       int `json:"piece"`,
	finished:    bool `json:"finished",`,
}

End_Game_Response :: struct {
	winner: string `json:"winner"`,
}

Change_Name_Response :: struct {
	player: string `json:"player"`,
	name:   string `json:"name"`,
}

send_message :: proc(
	socket: net.TCP_Socket,
	msg: Net_Message,
	allocator := context.temp_allocator,
) -> net.Network_Error {
	data := make([]u8, 3 + len(msg.payload), allocator)
	data[0] = auto_cast msg.kind
	endian.put_u16(data[1:3], .Big, u16(len(msg.payload)))
	if len(msg.payload) != 0 {
		copy(data[3:], msg.payload)
	}
	for {
		_, err := net.send_tcp(socket, data)
		if err != nil {
			if tcp_send_err, ok := err.(net.TCP_Send_Error); ok && tcp_send_err == .Timeout {
				continue
			}
			return err
		} else {
			return nil
		}
	}
	return nil
}

read_message :: proc(
	socket: net.TCP_Socket,
	allocator := context.temp_allocator,
) -> (
	Net_Message,
	net.Network_Error,
) {
	msg_header_buf := [3]u8{}

	for {
		_, err := net.recv_tcp(socket, msg_header_buf[:])
		if err != nil {
			if recv_tcp_err, ok := err.(net.TCP_Recv_Error); ok && recv_tcp_err == .Timeout {
				continue
			}
			return {}, err
		} else {
			break
		}
	}

	kind := msg_header_buf[0]
	payload_len, ok := endian.get_u16(msg_header_buf[1:], .Big)
	assert(ok)

	payload := make([]u8, payload_len, allocator)
	for {
		_, err := net.recv_tcp(socket, payload[:])
		if err != nil {
			if recv_tcp_err, ok := err.(net.TCP_Recv_Error); ok && recv_tcp_err == .Timeout {
				continue
			}
			return {}, err
		} else {
			break
		}
	}
	msg := Net_Message {
		kind    = auto_cast kind,
		payload = payload,
	}
	return msg, nil
}

compose_net_msg :: proc(
	kind: Net_Message_Type,
	v: $T,
	allocator := context.temp_allocator,
) -> Net_Message {
	msg := Net_Message {
		kind = kind,
	}
	opts := json.Marshal_Options{}
	payload, err := json.marshal(v, opts, allocator)
	if err != nil {
		panic(fmt.tprint("%s", err))
	}
	msg.payload = payload
	return msg
}

parse_msg :: proc(msg: Net_Message, v: ^$T, allocator := context.temp_allocator) {
	opts := json.Marshal_Options{}
	err := json.unmarshal(msg.payload, v, json.DEFAULT_SPECIFICATION, allocator)
	if err != nil {
		panic(fmt.tprint("%s", err))
	}
}

SERVER_ADDRESS :: "localhost:42069"

sender_thread_proc :: proc(t: ^thread.Thread) {
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

	game_state := cast(^Game_State)t.data
	q := &game_state.net_commands_queue
	mu := &game_state.net_commands_queue_mutex
	net_state := &game_state.net_state

	socket: net.TCP_Socket

	loop: for {
		free_all(context.temp_allocator)
		sync.sema_wait(&game_state.net_commands_semaphore)
		sync.lock(mu)
		command := queue.pop_front(q)
		sync.unlock(mu)

		msg_payload, err := json.marshal(command, json.Marshal_Options{}, context.temp_allocator)

		if err != nil {
			fmt.println(err)
			continue
		}
		switch cmd in command {
		case Connect_Request:
			if socket != 0 do break
			_socket, err := net.dial_tcp_from_hostname_and_port_string(SERVER_ADDRESS)
			if err != nil {
				fmt.println(err)
				push_net_response(game_state, compose_net_msg(.Connect, Connect_Response{}))
				break
			}
			socket = _socket
			sync.lock(mu)
			net_state.socket = _socket
			sync.unlock(mu)
			sync.sema_post(&net_state.net_receiver_sema)
		case Disconnect_Request:
			if socket == 0 do break
			net.close(socket)
			socket = 0
			push_net_response(game_state, compose_net_msg(.Disconnect, Disconnect_Response{}))
		case Quit_Request:
			sync.lock(mu)
			net_state.net_reciver_quit = true
			net.close(socket)
			socket = 0
			sync.unlock(mu)
			sync.sema_post(&net_state.net_receiver_sema)
			break loop
		case Create_Room_Request:
			if socket == 0 do break
			err := send_message(socket, Net_Message{kind = .CreateRoom, payload = msg_payload})
			if err != nil {
				push_net_response(game_state, compose_net_msg(.CreateRoom, Create_Room_Response{}))
				break
			}
			sync.lock(&net_state.allocator_mu)
			delete(cmd.name, net_state.allocator)
			sync.unlock(&net_state.allocator_mu)
		case Exit_Room_Request:
			if socket == 0 do break
			err := send_message(
				net_state.socket,
				Net_Message{kind = .ExitRoom, payload = msg_payload},
			)
			if err != nil {
				push_net_response(
					game_state,
					compose_net_msg(.ExitRoom, Exit_Room_Response{exit = false}),
				)
				break
			}
			push_net_response(
				game_state,
				compose_net_msg(.ExitRoom, Exit_Room_Response{exit = true}),
			)
		case Set_Piece_Count_Request:
			if socket == 0 do break
			msg := send_message(socket, Net_Message{kind = .SetPieceCount, payload = msg_payload})
		case Join_Room_Request:
			if socket == 0 do break
			if err := send_message(socket, Net_Message{kind = .EnterRoom, payload = msg_payload});
			   err != nil {
				push_net_response(game_state, compose_net_msg(.EnterRoom, Join_Room_Response{}))
				break
			}
			sync.lock(&net_state.allocator_mu)
			delete(cmd.name, net_state.allocator)
			delete(cmd.room_id, net_state.allocator)
			sync.unlock(&net_state.allocator_mu)
		case Ready_Request:
			if socket == 0 do break
			if err := send_message(socket, Net_Message{kind = .Ready, payload = msg_payload});
			   err != nil {
				push_net_response(game_state, compose_net_msg(.EnterRoom, Player_Ready_Response{}))
				break
			}
		case Kick_Player_Request:
			if socket == 0 do break
			if err := send_message(socket, Net_Message{kind = .KickPlayer, payload = msg_payload});
			   err != nil {
				push_net_response(game_state, compose_net_msg(.PlayerLeft, Player_Left_Response{}))
				break
			}
		case Start_Game_Request:
			if socket == 0 do break
			err := send_message(socket, Net_Message{kind = .StartGame, payload = msg_payload})
			if err != nil {
				push_net_response(game_state, compose_net_msg(.StartGame, Start_Game_Response{}))
				break
			}
		case Begin_Roll_Request:
			if socket == 0 do break
			err := send_message(socket, Net_Message{kind = .BeginRoll, payload = msg_payload})
			if err != nil {
				fmt.println(err)
			}
		case Begin_Move_Request:
			if socket == 0 do break
			err := send_message(socket, Net_Message{kind = .BeginMove, payload = msg_payload})
			if err != nil {
				fmt.println(err)
			}
		case End_Move_Request:
			if socket == 0 do break
			err := send_message(socket, Net_Message{kind = .EndMove, payload = msg_payload})
			if err != nil {
				fmt.println(err)
			}
		case Change_Name_Request:
			if socket == 0 do break
			err := send_message(socket, Net_Message{kind = .ChangeName, payload = msg_payload})
			if err != nil {
				fmt.println(err)
			}
			sync.lock(&net_state.allocator_mu)
			delete(cmd.name, net_state.allocator)
			sync.unlock(&net_state.allocator_mu)
			fmt.println(cmd)
		}
	}
	fmt.println("sender finished")
}

receiver_thread_proc :: proc(t: ^thread.Thread) {
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

	game_state := cast(^Game_State)t.data
	net_state := &game_state.net_state
	socket: net.TCP_Socket
	for {
		sync.sema_wait(&net_state.net_receiver_sema)
		{
			sync.lock(&net_state.mu)
			defer sync.unlock(&net_state.mu)
			if net_state.net_reciver_quit do break
		}
		{
			sync.lock(&net_state.mu)
			defer sync.unlock(&net_state.mu)
			if net_state.socket == 0 do continue
			socket = net_state.socket
		}
		for {
			msg, err := read_message(socket)
			if err != nil {
				fmt.println(err)
				socket = 0
				push_net_request(game_state, Disconnect_Request{})
				break
			}
			push_net_response(game_state, msg)
		}
	}
}

push_net_request :: proc(game_state: ^Game_State, cmd: Net_Request) {
	sync.lock(&game_state.net_commands_queue_mutex)
	queue.push_back(&game_state.net_commands_queue, cmd)
	sync.unlock(&game_state.net_commands_queue_mutex)
	sync.sema_post(&game_state.net_commands_semaphore)
}

push_net_response :: proc(game_state: ^Game_State, msg: Net_Message) {
	msg := msg
	net_state := &game_state.net_state

	sync.lock(&net_state.allocator_mu)
	msg.payload = bytes.clone(msg.payload, net_state.allocator)
	sync.unlock(&net_state.allocator_mu)

	sync.lock(&game_state.net_response_queue_mutex)
	queue.push_back(&game_state.net_response_queue, msg)
	sync.unlock(&game_state.net_response_queue_mutex)
}

net_connect :: proc(game_state: ^Game_State) {
	if game_state.net_sender_thread == nil {
		queue.init(&game_state.net_commands_queue)
		queue.init(&game_state.net_response_queue)

		sender := thread.create(sender_thread_proc)
		sender.init_context = runtime.default_context()
		sender.data = game_state
		thread.start(sender)

		receiver := thread.create(receiver_thread_proc)
		receiver.init_context = runtime.default_context()
		receiver.data = game_state
		thread.start(receiver)

		game_state.net_sender_thread = sender
		game_state.net_receiver_thread = receiver

		allocator := new(mem.Buddy_Allocator)
		data, err := mem.alloc_bytes(4 * mem.Megabyte)
		if err != nil {
			fmt.println(err)
		}
		mem.buddy_allocator_init(allocator, data, mem.DEFAULT_ALIGNMENT)
		game_state.net_state.allocator_data = data
		game_state.net_state.allocator = mem.buddy_allocator(allocator)
	}
	if game_state.connected do return
	game_state.is_trying_to_connect = true
	connect_cmd := Connect_Request{}
	push_net_request(game_state, connect_cmd)
}

net_disconnect :: proc(game_state: ^Game_State) {
	if !game_state.connected do return
	push_net_request(game_state, Disconnect_Request{})
	game_state.connected = false
}

net_create_room :: proc(game_state: ^Game_State) {
	if !game_state.connected do return
	game_state.is_trying_to_create_room = true
	net_state := &game_state.net_state
	sync.lock(&net_state.allocator_mu)
	player_name := strings.clone(game_state.players[0].name, net_state.allocator)
	sync.unlock(&net_state.allocator_mu)
	push_net_request(game_state, Create_Room_Request{name = player_name})
}

net_exit_room :: proc(game_state: ^Game_State) {
	if !game_state.connected || game_state.room_id == "" do return
	game_state.is_trying_to_exit_room = true
	push_net_request(game_state, Exit_Room_Request{})
}

net_set_piece_count :: proc(game_state: ^Game_State, piece_count: i32) {
	if !game_state.connected || game_state.room_id == "" || !game_state.is_room_master do return
	game_state.is_trying_to_set_piece_count = true
	push_net_request(game_state, Set_Piece_Count_Request{piece_count = piece_count})
}

net_join_room :: proc(game_state: ^Game_State, room_id: string) {
	if !game_state.connected || game_state.room_id != "" do return
	game_state.is_trying_to_join_room = true
	net_state := &game_state.net_state
	sync.lock(&net_state.allocator_mu)
	join_room_id := strings.clone(room_id, net_state.allocator)
	player_name := strings.clone(game_state.players[0].name, net_state.allocator)
	sync.unlock(&net_state.allocator_mu)
	push_net_request(game_state, Join_Room_Request{room_id = join_room_id, name = player_name})
}

net_change_ready_state :: proc(game_state: ^Game_State, is_ready: bool) {
	if !game_state.connected || game_state.room_id == "" do return
	game_state.is_trying_to_change_ready_state = true
	push_net_request(game_state, Ready_Request{is_ready = is_ready})
}

net_kick_player :: proc(game_state: ^Game_State, player_idx: int) {
	if !game_state.connected || game_state.room_id == "" || !game_state.is_room_master do return
	game_state.is_trying_to_kick_player_set += {player_idx}
	push_net_request(
		game_state,
		Kick_Player_Request{player = game_state.players[player_idx].client_id},
	)
}

net_start_game :: proc(game_state: ^Game_State) {
	if !game_state.connected ||
	   game_state.room_id == "" ||
	   !game_state.is_room_master ||
	   game_state.room_player_count < 2 ||
	   game_state.room_ready_player_count != game_state.room_player_count {
		return
	}
	game_state.is_trying_to_start_game = true
	push_net_request(game_state, Start_Game_Request{})
}

net_roll :: proc(game_state: ^Game_State) {
	if !game_state.connected || game_state.room_id == "" || game_state.action != .CanRoll {
		return
	}
	game_state.is_trying_to_roll = true
	push_net_request(game_state, Begin_Roll_Request{})
	game_state.action = .BeginRoll
}

net_begin_move :: proc(game_state: ^Game_State, piece_idx: int, move: Move) {
	if !game_state.connected || game_state.room_id == "" || game_state.action != .SelectingMove {
		return
	}
	push_net_request(
		game_state,
		Begin_Move_Request {
			piece = piece_idx,
			roll = auto_cast move.roll,
			cell = auto_cast move.cell,
		},
	)
	game_state.action = .Waiting
}

net_end_target_move :: proc(game_state: ^Game_State) {
	if !game_state.connected || game_state.room_id == "" || game_state.action != .OnMove {
		return
	}
	apply_move(game_state, game_state.target_move)
	push_net_request(
		game_state,
		End_Move_Request {
			piece = auto_cast game_state.target_piece_idx,
			roll = auto_cast game_state.target_move.roll,
			cell = auto_cast game_state.target_move.cell,
		},
	)
	game_state.action = .Waiting
}

net_change_name :: proc(game_state: ^Game_State) {
	if !game_state.connected || game_state.room_id == "" {
		return
	}
	net_state := &game_state.net_state
	sync.lock(&net_state.allocator_mu)
	name := strings.clone(game_state.players[0].name, net_state.allocator)
	sync.unlock(&net_state.allocator_mu)
	push_net_request(game_state, Change_Name_Request{name})
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
		fmt.println("keep alive...")
	case .Connect:
		game_state.is_trying_to_connect = false
		resp := Connect_Response{}
		parse_msg(msg, &resp)
		if resp.client_id != "" {
			game_state.connected = true
			game_state.players[0].client_id = strings.clone(resp.client_id)
		}
	case .Disconnect:
		resp := Disconnect_Response{}
		parse_msg(msg, &resp)
		if game_state.connected {
			game_state.connected = false
			game_state.game_mode = .Local
			reset_net_state(game_state)
			reset_game_state(game_state)
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
				game_state.players[idx].name = strings.clone(p.name)
				game_state.room_player_count += 1
			}
			game_state.screen_state = .Room
			game_state.room_id = strings.clone(resp.room_id)
		}
	case .PlayerJoined:
		resp := Player_Joined_Response{}
		parse_msg(msg, &resp)
		if resp.client_id != game_state.players[0].client_id {
			game_state.players[game_state.room_player_count].client_id = strings.clone(
				resp.client_id,
			)
			game_state.players[game_state.room_player_count].name = strings.clone(resp.name)
		}
		game_state.room_player_count += 1
	case .KickPlayer:
	case .Ready:
		resp := Player_Ready_Response{}
		parse_msg(msg, &resp)

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
			game_state.action = .GameStarted
		}
	case .BeginTurn:
		log(
			game_state,
			fmt.tprintf("%s's turn", game_state.players[game_state.player_turn_index].name),
		)
		game_state.action = .BeginTurn
	case .CanRoll:
		resp := Can_Roll_Response{}
		parse_msg(msg, &resp)
		if game_state.players[0].client_id == resp.player {
			game_state.action = .CanRoll
		}
		log(
			game_state,
			fmt.tprintf("%s can roll", game_state.players[game_state.player_turn_index].name),
		)
	case .BeginRoll:
		log(
			game_state,
			fmt.tprintf("%s is rolling", game_state.players[game_state.player_turn_index].name),
		)
	case .EndRoll:
		game_state.is_trying_to_roll = false
		resp := End_Roll_Response{}
		parse_msg(msg, &resp)
		if resp.should_append {
			append(&game_state.rolls, i32(resp.roll))
		}
		log(
			game_state,
			fmt.tprintf(
				"%s rolled %d",
				game_state.players[game_state.player_turn_index].name,
				resp.roll,
			),
		)
	case .EndTurn:
		log(game_state, "turn ended")
		resp := End_Turn_Response{}
		parse_msg(msg, &resp)
		for idx in 0 ..< game_state.player_count {
			if game_state.players[idx].client_id == resp.next_player {
				game_state.player_turn_index = idx
				break
			}
		}
		resize(&game_state.rolls, 0)
		game_state.action = .EndTurn
	case .SelectingMove:
		resp := Selecting_Move_Response{}
		parse_msg(msg, &resp)
		if resp.player == game_state.players[0].client_id {
			game_state.action = .SelectingMove
		}
		log(
			game_state,
			fmt.tprintf(
				"%s is selecting a move",
				game_state.players[game_state.player_turn_index].name,
			),
		)
	case .BeginMove:
		resp := Begin_Move_Response{}
		parse_msg(msg, &resp)

		if resp.should_move {
			game_state.target_piece_idx = auto_cast resp.piece
			game_state.target_move = Move {
				roll   = auto_cast resp.roll,
				cell   = resp.cell,
				finish = resp.finished,
			}
			game_state.move_seq_idx = -1
			game_state.target_piece_position_percent = 0
			game_state.action = .OnMove
		}

		log(
			game_state,
			fmt.tprintf(
				"%s is moving piece (%d) to cell (%v) consuming roll (%d)",
				game_state.players[game_state.player_turn_index].name,
				game_state.target_piece_idx + 1,
				resp.cell,
				resp.roll,
			),
		)
	case .EndMove:
	case .EndGame:
		resp := End_Game_Response{}
		parse_msg(msg, &resp)
		player_won_index := i32(-1)
		for i in 0 ..< game_state.player_count {
			if game_state.players[i].client_id == resp.winner {
				player_won_index = i
				break
			}
		}
		assert(player_won_index == game_state.player_turn_index)
		end_game(game_state)
	case .ChangeName:
		resp := Change_Name_Response{}
		parse_msg(msg, &resp)
		fmt.println(resp)
		for i in 1 ..< game_state.player_count {
			if game_state.players[i].client_id == resp.player {
				if game_state.players[i].name != "" {
					delete(game_state.players[i].name)
					game_state.players[i].name = ""
				}
				game_state.players[i].name = strings.clone(resp.name)
				break
			}
		}
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
		game_state.players[i].is_ready = false

		if game_state.players[i].client_id != "" {
			delete(game_state.players[i].client_id)
			game_state.players[i].client_id = ""
		}

		if game_state.players[i].name != "" {
			delete(game_state.players[i].name)
			game_state.players[i].name = ""
		}
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
