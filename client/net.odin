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
	JoinRoom,
	PlayerJoined,
	Ready,
	KickPlayer,
}

Net_Message :: struct {
	kind:    Net_Message_Type,
	payload: []byte,
}

Connect_Request :: struct {}
Disconnect_Request :: struct {}
Quit_Request :: struct {}

Create_Room_Request :: struct {}
Exit_Room_Request :: struct {}
Set_Piece_Count_Request :: struct {
	piece_count: i32 `json:"piece_count"`,
}
Join_Room_Request :: struct {
	room_id: string `json:"room_id"`,
}

Kick_Player_Request :: struct {
	player: string `json:"player"`,
}
Ready_Request :: struct {
	is_ready: bool `json:"is_ready"`,
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
}

Player_Ready_Response :: struct {
	player:   string `json:"player"`,
	is_ready: bool `json:"is_ready"`,
}

Player_Kicked_Response :: struct {
	client_id: string `json:"client_id"`,
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
	_, err := net.send_tcp(socket, data)
	return err
}

read_message :: proc(
	socket: net.TCP_Socket,
	allocator := context.temp_allocator,
) -> (
	Net_Message,
	net.Network_Error,
) {
	msg_header_buf := [3]u8{}
	_, err := net.recv_tcp(socket, msg_header_buf[:])
	if err != nil {
		return {}, err
	}
	kind := msg_header_buf[0]
	payload_len, ok := endian.get_u16(msg_header_buf[1:], .Big)
	if !ok {
		return {}, err
	}
	payload := make([]u8, payload_len, allocator)
	_, err = net.recv_tcp(socket, payload[:])
	if err != nil {
		return {}, err
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
			err := send_message(socket, Net_Message{kind = .CreateRoom})
			if err != nil {
				push_net_response(game_state, compose_net_msg(.CreateRoom, Create_Room_Response{}))
				break
			}
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
			if err := send_message(socket, Net_Message{kind = .JoinRoom, payload = msg_payload});
			   err != nil {
				push_net_response(game_state, compose_net_msg(.JoinRoom, Join_Room_Response{}))
				break
			}
		case Ready_Request:
			if socket == 0 do break
			if err := send_message(socket, Net_Message{kind = .Ready, payload = msg_payload});
			   err != nil {
				push_net_response(game_state, compose_net_msg(.JoinRoom, Player_Ready_Response{}))
				break
			}
		case Kick_Player_Request:
			if socket == 0 do break
			fmt.println("kick player request")
			if err := send_message(socket, Net_Message{kind = .KickPlayer, payload = msg_payload});
			   err != nil {
				push_net_response(game_state, compose_net_msg(.PlayerLeft, Player_Left_Response{}))
				break
			}
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
	fmt.println("reciver finished")
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

connect :: proc(game_state: ^Game_State) {
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

disconnect :: proc(game_state: ^Game_State) {
	if !game_state.connected do return
	push_net_request(game_state, Disconnect_Request{})
	game_state.connected = false
}

create_room :: proc(game_state: ^Game_State) {
	if !game_state.connected do return
	game_state.is_trying_to_create_room = true
	push_net_request(game_state, Create_Room_Request{})
}

exit_room :: proc(game_state: ^Game_State) {
	if !game_state.connected || game_state.room_id == "" do return
	game_state.is_trying_to_exit_room = true
	push_net_request(game_state, Exit_Room_Request{})
}

set_piece_count :: proc(game_state: ^Game_State, piece_count: i32) {
	if !game_state.connected || game_state.room_id == "" || !game_state.is_room_master do return
	game_state.is_trying_to_set_piece_count = true
	push_net_request(game_state, Set_Piece_Count_Request{piece_count = piece_count})
}

join_room :: proc(game_state: ^Game_State, room_id: string) {
	if !game_state.connected || game_state.room_id != "" do return
	game_state.is_trying_to_join_room = true
	net_state := &game_state.net_state
	sync.lock(&net_state.mu)
	s := strings.clone(room_id, net_state.allocator)
	sync.unlock(&net_state.mu)
	push_net_request(game_state, Join_Room_Request{room_id = s})
}

change_ready_state :: proc(game_state: ^Game_State, is_ready: bool) {
	if !game_state.connected || game_state.room_id == "" do return
	game_state.is_trying_to_change_ready_state = true
	push_net_request(game_state, Ready_Request{is_ready = is_ready})
}

kick_player :: proc(game_state: ^Game_State, player_idx: int) {
	if !game_state.connected || game_state.room_id == "" || !game_state.is_room_master do return
	game_state.is_trying_to_kick_player_set += {player_idx}
	push_net_request(
		game_state,
		Kick_Player_Request{player = game_state.players[player_idx].client_id},
	)
}
