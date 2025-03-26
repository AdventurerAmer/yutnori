package main

import (
	"log"
	"net"
)

type EnterRoomParams struct {
	Client *Client
	Room   RoomID
}

type Hub struct {
	RegisterClientCh chan net.Conn
	Rooms            map[RoomID]*Room
	CreateRoomCh     chan *Client
	EnterRoomCh      chan EnterRoomParams
	DestroyRoomCh    chan *Room
}

func NewHub() *Hub {
	return &Hub{
		Rooms:            make(map[RoomID]*Room),
		RegisterClientCh: make(chan net.Conn),
		CreateRoomCh:     make(chan *Client),
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
		case client := <-h.CreateRoomCh:
			room := NewRoom(client)
			err := client.Send(CreateRoomResponse{RoomID: room.ID})
			if err != nil {
				log.Println(err)
				break
			}
			h.Rooms[room.ID] = room
			client.EnterRoom(room)
			go room.ReadLoop(h)
			log.Printf("hub created room '%s'\n", room.ID)
		case params := <-h.EnterRoomCh:
			client := params.Client
			room := h.Rooms[params.Room]
			room.Enter(client)
			log.Printf("client '%s' wants to enter room '%s'\n", client.ID, room.ID)
		case room := <-h.DestroyRoomCh:
			delete(h.Rooms, room.ID)
			log.Printf("hub destroyed room '%s'\n", room.ID)
		}
	}
}

func (h *Hub) RegisterClient(conn net.Conn) {
	if h == nil {
		return
	}
	h.RegisterClientCh <- conn
}

func (h *Hub) CreateRoom(client *Client) {
	if h == nil {
		return
	}
	h.CreateRoomCh <- client
}

func (h *Hub) EnterRoom(client *Client, room RoomID) {
	if h == nil {
		return
	}
	h.EnterRoomCh <- EnterRoomParams{Client: client, Room: room}
	log.Println("EnterRoomCh")
}

func (h *Hub) DestroyRoom(room *Room) {
	if h == nil {
		return
	}
	h.DestroyRoomCh <- room
}
