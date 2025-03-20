package client

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

Connect_NC :: struct {
	server_addr: string,
}

Disconnect_NC :: struct {}

Quit_NC :: struct {}

Create_Room_NC :: struct {}

Net_Command :: union {
	Connect_NC,
	Disconnect_NC,
	Quit_NC,
	Create_Room_NC,
}

Connect_NR :: struct {
	err:       net.Network_Error,
	connected: bool,
}

Net_Response :: union {
	Connect_NR,
}

Net_Message_Type :: enum u8 {
	KeepAlive,
	ClientID,
	CreateRoom,
}

Net_Message :: struct {
	kind:    Net_Message_Type,
	payload: []u8,
}

Client_ID_NM :: struct {
	id: string `json:"id"`,
}

serialize_net_message :: proc(msg: Net_Message, allocator := context.temp_allocator) -> []u8 {
	data := make([]u8, 1 + len(msg.payload), allocator)
	data[0] = auto_cast msg.kind
	if len(msg.payload) != 0 {
		copy(data[1:], msg.payload)
	}
	return data
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

net_thread_proc :: proc(t: ^thread.Thread) {
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
	socket: net.TCP_Socket
	client_id: string
	loop: for {
		free_all(context.temp_allocator)
		sync.sema_wait(&game_state.net_commands_semaphore)
		sync.lock(mu)
		cmd := queue.pop_front(q)
		sync.unlock(mu)
		switch c in cmd {
		case Connect_NC:
			if socket == 0 {
				err: net.Network_Error
				socket, err = net.dial_tcp_from_hostname_and_port_string(c.server_addr)
				if err != nil {
					fmt.println(err)
					push_net_response(game_state, Connect_NR{err, false})
					break
				}
				msg: ^Net_Message
				msg, err = read_message(socket)
				if err != nil {
					fmt.println(err)
					net.close(socket)
					socket = 0
					push_net_response(game_state, Connect_NR{err, false})
					break
				}
				if msg.kind != .ClientID {
					fmt.printf("message should be client id got %d\n", msg.kind)
					net.close(socket)
					socket = 0
					push_net_response(game_state, Connect_NR{nil, false})
					break
				}
				client_id_msg := Client_ID_NM{}
				if err := json.unmarshal(
					msg.payload,
					&client_id_msg,
					json.DEFAULT_SPECIFICATION,
					context.temp_allocator,
				); err != nil {
					net.close(socket)
					socket = 0
					push_net_response(game_state, Connect_NR{nil, false})
					break
				}
				client_id = strings.clone(client_id_msg.id)
				fmt.println(client_id)
				push_net_response(game_state, Connect_NR{nil, true})
			}
		case Create_Room_NC:
		case Disconnect_NC:
			delete(client_id)
			net.close(socket)
			socket = 0
		case Quit_NC:
			break loop
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
	if game_state.net_thread == nil {
		queue.init(&game_state.net_commands_queue)
		queue.init(&game_state.net_response_queue)
		net_thread := thread.create(net_thread_proc, .High)
		net_thread.data = game_state
		thread.start(net_thread)
		game_state.net_thread = net_thread
	}
	if !game_state.connected {
		game_state.is_trying_to_connect = true
		connect_cmd := Connect_NC {
			server_addr = SERVER_ADDRESS,
		}
		push_net_cmd(game_state, connect_cmd)
	}
}

disconnect :: proc(game_state: ^Game_State) {
	if !game_state.connected do return
	push_net_cmd(game_state, Disconnect_NC{})
	game_state.connected = false
}

create_room :: proc(game_state: ^Game_State) {
	if !game_state.connected do return
}
