package client

import "base:runtime"
import "core:container/queue"
import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:io"
import "core:mem"
import "core:net"
import "core:strings"
import "core:sync"
import "core:thread"

Net_State :: struct {
	mu:                sync.Mutex,
	allocator_data:    []byte,
	allocator:         mem.Allocator,
	socket:            net.TCP_Socket,
	net_receiver_sema: sync.Sema,
	client_id:         string,
	room_id:           string,
	net_reciver_quit:  bool,
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

Player_Room_State :: struct {
	client_id: string `json:"client_id"`,
	is_ready:  bool `json:"is_ready"`,
}

Join_Room_Response :: struct {
	join:        bool `json:"join"`,
	master:      string `json:"master"`,
	piece_count: u8 `json:"piece_count"`,
	players:     []Player_Room_State `json:"players"`,
}

Player_Joined_Response :: struct {
	client_id: string `json:"client_id"`,
}

Net_Command :: union {
	Connect_Request,
	Disconnect_Request,
	Quit_Request,
	Create_Room_Request,
	Exit_Room_Request,
	Set_Piece_Count_Request,
	Join_Room_Request,
}

Connect_Response :: struct {
	err:       net.Network_Error,
	connected: bool,
}
Disconnect_Response :: struct {}
Create_Room_Response :: struct {
	created: bool,
}
Exit_Room_Response :: struct {
	exit: bool,
}
Set_Piece_Count_Response :: struct {
	should_set:  bool,
	piece_count: i32,
}
Room_Master_Response :: struct {
	master: string,
}

Net_Response :: union {
	Connect_Response,
	Disconnect_Response,
	Create_Room_Response,
	Exit_Room_Response,
	Set_Piece_Count_Response,
	Room_Master_Response,
	Join_Room_Response,
	Player_Joined_Response,
}

Net_Message_Type :: enum u8 {
	ClientID,
	CreateRoom,
	ExitRoom,
	SetPieceCount,
	RoomMaster,
	JoinRoom,
	PlayerJoined,
}

Net_Message :: struct {
	kind:    Net_Message_Type,
	payload: []u8,
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
	^Net_Message,
	net.Network_Error,
) {
	msg_header_buf := [3]u8{}
	_, err := net.recv_tcp(socket, msg_header_buf[:])
	if err != nil {
		return nil, err
	}
	kind := msg_header_buf[0]
	payload_len, ok := endian.get_u16(msg_header_buf[1:], .Big)
	if !ok {
		return nil, err
	}
	payload := make([]u8, payload_len, allocator)
	_, err = net.recv_tcp(socket, payload[:])
	if err != nil {
		return nil, err
	}
	msg := new(Net_Message, allocator)
	msg.kind = auto_cast kind
	msg.payload = payload
	return msg, nil
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
		switch cmd in command {
		case Connect_Request:
			if socket != 0 do return
			// @Bug: net.dial_tcp_from_hostname_and_port_string returns a socket (0) and err (nil) if the host is not reachable it should return socket (0) and err(net.Dial_Error) instead 
			_socket, err := net.dial_tcp_from_hostname_and_port_string(SERVER_ADDRESS)
			if err != nil || _socket == 0 {
				fmt.println(err)
				push_net_response(game_state, Connect_Response{err, false})
				break
			}
			socket = _socket
			push_net_response(game_state, Connect_Response{err, true})

			{
				sync.lock(&net_state.mu)
				defer sync.unlock(&net_state.mu)
				net_state.socket = _socket
			}

			sync.sema_post(&net_state.net_receiver_sema)
		case Disconnect_Request:
			if socket == 0 {
				break
			}
			{
				sync.lock(&net_state.mu)
				defer sync.unlock(&net_state.mu)
				net_state.socket = 0
				if net_state.client_id != "" {
					delete(net_state.client_id, net_state.allocator)
					net_state.client_id = ""
				}
				if net_state.room_id != "" {
					delete(net_state.room_id, net_state.allocator)
					net_state.room_id = ""
				}
			}
			net.close(socket)
			socket = 0
			push_net_response(game_state, Disconnect_Response{})
		case Quit_Request:
			sync.lock(&net_state.mu)
			defer sync.unlock(&net_state.mu)
			if net_state.client_id != "" {
				delete(net_state.client_id, net_state.allocator)
				net_state.client_id = ""
			}
			if net_state.room_id != "" {
				delete(net_state.room_id, net_state.allocator)
				net_state.room_id = ""
			}
			net_state.net_reciver_quit = true
			sync.sema_post(&net_state.net_receiver_sema)
			break loop
		case Create_Room_Request:
			if socket == 0 {
				break
			}
			create_room_message := Net_Message {
				kind = .CreateRoom,
			}
			err := send_message(socket, create_room_message)
			if err != nil {
				push_net_response(game_state, Create_Room_Response{created = false})
				break
			}

		case Exit_Room_Request:
			sync.lock(&net_state.mu)
			defer sync.unlock(&net_state.mu)
			if net_state.socket == 0 || net_state.room_id == "" do return
			delete(net_state.room_id, net_state.allocator)
			net_state.room_id = ""
			exit_room_message := Net_Message {
				kind = .ExitRoom,
			}
			err := send_message(net_state.socket, exit_room_message)
			if err != nil {
				push_net_response(game_state, Exit_Room_Response{exit = false})
				break
			}
			push_net_response(game_state, Exit_Room_Response{exit = true})

		case Set_Piece_Count_Request:
			if socket == 0 {
				break
			}
			Set_Piece_Count_Msg :: struct {
				piece_count: i32 `json:"piece_count"`,
			}
			data, err := json.marshal(
				Set_Piece_Count_Msg{piece_count = cmd.piece_count},
				{},
				context.temp_allocator,
			)
			if err != nil {
				push_net_response(
					game_state,
					Set_Piece_Count_Response{should_set = false, piece_count = 0},
				)
			}
			msg := Net_Message {
				kind    = .SetPieceCount,
				payload = data,
			}
			send_message(socket, msg)
		case Join_Room_Request:
			if socket == 0 {
				break
			}
			payload, err := json.marshal(cmd, {}, context.temp_allocator)
			msg := Net_Message {
				kind    = .JoinRoom,
				payload = payload,
			}
			send_message(socket, msg)
			sync.lock(&net_state.mu)
			delete(cmd.room_id, net_state.allocator)
			sync.unlock(&net_state.mu)
		}
	}
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
			if net_state.net_reciver_quit {
				break
			}
		}
		{
			sync.lock(&net_state.mu)
			defer sync.unlock(&net_state.mu)
			if net_state.socket == 0 {
				continue
			}
			socket = net_state.socket
		}
		for {
			msg, err := read_message(socket)
			if err != nil {
				fmt.println("reciever:", err)
				socket = 0
				push_net_cmd(game_state, Disconnect_Request{})
				break
			}
			switch msg.kind {
			case .ClientID:
				Client_ID_NM :: struct {
					id: string `json:"id"`,
				}

				client_id_msg := Client_ID_NM{}
				if err := json.unmarshal(
					msg.payload,
					&client_id_msg,
					json.DEFAULT_SPECIFICATION,
					context.temp_allocator,
				); err != nil {
					push_net_response(game_state, Connect_Response{nil, false})
					break
				}

				sync.lock(&net_state.mu)
				net_state.client_id = strings.clone(client_id_msg.id, net_state.allocator)
				sync.unlock(&net_state.mu)

				push_net_response(game_state, Connect_Response{nil, true})
			case .CreateRoom:
				Create_Room_Resp :: struct {
					id: string `json:"id"`,
				}
				resp := Create_Room_Resp{}
				if err := json.unmarshal(
					msg.payload,
					&resp,
					json.DEFAULT_SPECIFICATION,
					context.temp_allocator,
				); err != nil {
					push_net_response(game_state, Create_Room_Response{created = false})
					break
				}
				sync.lock(&net_state.mu)
				net_state.room_id = strings.clone(resp.id, net_state.allocator)
				sync.unlock(&net_state.mu)
				push_net_response(game_state, Create_Room_Response{created = true})
			case .ExitRoom:
			case .SetPieceCount:
				Set_Piece_Count :: struct {
					piece_count: int `json:"piece_count"`,
					should_set:  bool `json:"should_set"`,
				}
				resp := Set_Piece_Count{}
				if err := json.unmarshal(
					msg.payload,
					&resp,
					json.DEFAULT_SPECIFICATION,
					context.temp_allocator,
				); err != nil {
					push_net_response(game_state, Set_Piece_Count_Response{should_set = false})
					break
				}
				push_net_response(
					game_state,
					Set_Piece_Count_Response {
						should_set = resp.should_set,
						piece_count = i32(resp.piece_count),
					},
				)
			case .RoomMaster:
				Room_Master :: struct {
					master: string `json:"master"`,
				}
				resp := Room_Master{}
				if err := json.unmarshal(
					msg.payload,
					&resp,
					json.DEFAULT_SPECIFICATION,
					context.temp_allocator,
				); err != nil {
					push_net_response(game_state, Set_Piece_Count_Response{should_set = false})
					break
				}
				sync.lock(&net_state.mu)
				master := strings.clone(resp.master, net_state.allocator)
				sync.unlock(&net_state.mu)
				push_net_response(game_state, Room_Master_Response{master = master})
			case .JoinRoom:
				resp := Join_Room_Response{}
				sync.lock(&net_state.mu)
				defer sync.unlock(&net_state.mu)
				if err := json.unmarshal(
					msg.payload,
					&resp,
					json.DEFAULT_SPECIFICATION,
					net_state.allocator,
				); err != nil {
					push_net_response(game_state, resp)
					break
				}
				push_net_response(game_state, {})
			case .PlayerJoined:
				resp := Player_Joined_Response{}
				sync.lock(&net_state.mu)
				defer sync.unlock(&net_state.mu)
				if err := json.unmarshal(
					msg.payload,
					&resp,
					json.DEFAULT_SPECIFICATION,
					net_state.allocator,
				); err != nil {
					push_net_response(game_state, resp)
					break
				}
				push_net_response(game_state, {})
			}
		}
	}
}


push_net_cmd :: proc(game_state: ^Game_State, cmd: Net_Command) {
	sync.lock(&game_state.net_commands_queue_mutex)
	queue.push_back(&game_state.net_commands_queue, cmd)
	sync.unlock(&game_state.net_commands_queue_mutex)
	sync.sema_post(&game_state.net_commands_semaphore)
}

push_net_response :: proc(game_state: ^Game_State, response: Net_Response) {
	sync.lock(&game_state.net_response_queue_mutex)
	queue.push_back(&game_state.net_response_queue, response)
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
	push_net_cmd(game_state, connect_cmd)
}

disconnect :: proc(game_state: ^Game_State) {
	if !game_state.connected do return
	push_net_cmd(game_state, Disconnect_Request{})
	game_state.connected = false
}

create_room :: proc(game_state: ^Game_State) {
	if !game_state.connected do return
	game_state.is_trying_to_create_room = true
	push_net_cmd(game_state, Create_Room_Request{})
}

exit_room :: proc(game_state: ^Game_State) {
	if !game_state.connected || !game_state.in_room do return
	game_state.is_trying_to_exit_room = true
	push_net_cmd(game_state, Exit_Room_Request{})
}

set_piece_count :: proc(game_state: ^Game_State, piece_count: i32) {
	if !game_state.connected || !game_state.in_room || !game_state.is_room_master do return
	game_state.is_trying_to_set_piece_count = true
	push_net_cmd(game_state, Set_Piece_Count_Request{piece_count = piece_count})
}

join_room :: proc(game_state: ^Game_State, room_id: string) {
	if !game_state.connected || game_state.in_room do return
	game_state.is_trying_to_join_room = true
	net_state := &game_state.net_state
	sync.lock(&net_state.mu)
	s := strings.clone(room_id, net_state.allocator)
	sync.unlock(&net_state.mu)
	push_net_cmd(game_state, Join_Room_Request{room_id = s})
}
