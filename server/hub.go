package main

import (
	"log"
	"net"
)

type CreateRoomParams struct {
	Client     *Client
	ClientName string
}

type EnterRoomParams struct {
	Client     *Client
	ClientName string
	Room       RoomID
}

type Hub struct {
	RegisterClientCh chan net.Conn
	Rooms            map[RoomID]*Room
	CreateRoomCh     chan CreateRoomParams
	EnterRoomCh      chan EnterRoomParams
	DestroyRoomCh    chan *Room
}

func NewHub() *Hub {
	return &Hub{
		Rooms:            make(map[RoomID]*Room),
		RegisterClientCh: make(chan net.Conn),
		CreateRoomCh:     make(chan CreateRoomParams),
		EnterRoomCh:      make(chan EnterRoomParams),
		DestroyRoomCh:    make(chan *Room),
	}
}

func (h *Hub) HandleClients() {
	for {
		select {
		case conn, ok := <-h.RegisterClientCh:
			if !ok {
				return
			}
			client := NewClient(conn)
			if err := client.Send(ConnectResponse{ClientID: client.ID}); err != nil {
				break
			}
			go client.ReadLoop(h)
			go client.WriteLoop(h)
		case params := <-h.CreateRoomCh:
			room := NewRoom(params.Client, params.ClientName)
			err := params.Client.Send(CreateRoomResponse{RoomID: room.ID})
			if err != nil {
				log.Println(err)
				break
			}
			h.Rooms[room.ID] = room
			params.Client.EnterRoom(room)
			go room.ReadLoop(h)
			log.Printf("created room '%s'\n", room.ID)
		case params := <-h.EnterRoomCh:
			client := params.Client
			room := h.Rooms[params.Room]
			log.Printf("client '%s' wants to enter room '%s'\n", client.ID, params.Room)
			if room == nil {
				client.Send(JoinRoomResponse{})
			} else {
				room.Enter(client, params.ClientName)
			}
		case room := <-h.DestroyRoomCh:
			delete(h.Rooms, room.ID)
			log.Printf("destroyed room '%s'\n", room.ID)
		}
	}
}

func (h *Hub) RegisterClient(conn net.Conn) {
	if h == nil {
		return
	}
	h.RegisterClientCh <- conn
}

func (h *Hub) CreateRoom(client *Client, clientName string) {
	if h == nil {
		return
	}
	h.CreateRoomCh <- CreateRoomParams{Client: client, ClientName: clientName}
}

func (h *Hub) EnterRoom(client *Client, clientName string, room RoomID) {
	if h == nil {
		return
	}
	h.EnterRoomCh <- EnterRoomParams{Client: client, ClientName: clientName, Room: room}
}

func (h *Hub) DestroyRoom(room *Room) {
	if h == nil {
		return
	}
	h.DestroyRoomCh <- room
}
