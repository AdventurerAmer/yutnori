package main

import (
	"log"
	"net"
)

type EnterRoomParams struct {
	Client *Client
	Room   RoomID
}

type ExitRoomParams struct {
	Client ClientID
	Kicked bool
}

type SetPieceCountParams struct {
	Client     *Client
	PieceCount uint8
}

type PlayerReadyParams struct {
	Client  *Client
	IsReady bool
}

type Hub struct {
	RegisterClientCh chan net.Conn
	Rooms            map[RoomID]*Room
	ClientToRoom     map[ClientID]*Room

	CreateRoomCh    chan *Client
	EnterRoomCh     chan EnterRoomParams
	ExitRoomCh      chan ExitRoomParams
	SetPieceCountCh chan SetPieceCountParams
	PlayerReadyCh   chan PlayerReadyParams
}

func NewHub() *Hub {
	return &Hub{
		Rooms:            make(map[RoomID]*Room),
		ClientToRoom:     make(map[ClientID]*Room),
		RegisterClientCh: make(chan net.Conn),
		CreateRoomCh:     make(chan *Client),
		EnterRoomCh:      make(chan EnterRoomParams),
		ExitRoomCh:       make(chan ExitRoomParams),
		SetPieceCountCh:  make(chan SetPieceCountParams),
		PlayerReadyCh:    make(chan PlayerReadyParams),
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
			if err := client.Send(ConnectMessage{ClientID: client.ID}); err != nil {
				break
			}
			go client.ReadLoop(h)
			go client.WriteLoop(h)
		case client := <-h.CreateRoomCh:
			room := NewRoom(client)
			h.Rooms[room.ID] = room
			h.ClientToRoom[client.ID] = room
			client.Send(CreateRoomMessage{RoomID: room.ID})
		case msg := <-h.EnterRoomCh:
			c, roomID := msg.Client, msg.Room
			room := h.Rooms[roomID]
			h.ClientToRoom[c.ID] = room
			room.Enter(roomID, c)
		case msg := <-h.ExitRoomCh:
			c, kicked := msg.Client, msg.Kicked
			room := h.ClientToRoom[c]
			if room != nil {
				err := room.Exit(c, kicked)
				if err != nil {
					log.Println(err)
				}
				delete(h.ClientToRoom, c)
				if len(room.Clients) == 0 {
					delete(h.Rooms, room.ID)
				}
				log.Println("Client Exited", c)
			}
		case msg := <-h.SetPieceCountCh:
			c, pieceCount := msg.Client, msg.PieceCount
			room := h.ClientToRoom[c.ID]
			if room == nil {
				msg.Client.Send(SetPieceMessage{ShouldSet: false})
				break
			}
			if c != room.Master {
				msg.Client.Send(SetPieceMessage{ShouldSet: false})
				break
			}
			room.PieceCount = pieceCount
			err := room.Broadcast(SetPieceMessage{ShouldSet: true, PieceCount: pieceCount})
			if err != nil {
				log.Println(err)
			}
		case msg := <-h.PlayerReadyCh:
			c, isReady := msg.Client, msg.IsReady
			room := h.ClientToRoom[c.ID]
			err := room.Broadcast(PlayerReadyResponse{Player: c.ID, IsReady: isReady})
			if err != nil {
				log.Println(err)
			}
		}
	}
}

func (h *Hub) RegisterClient(conn net.Conn) {
	h.RegisterClientCh <- conn
}

func (h *Hub) CreateRoom(client *Client) {
	h.CreateRoomCh <- client
}

func (h *Hub) ExitRoom(client ClientID, kicked bool) {
	h.ExitRoomCh <- ExitRoomParams{Client: client, Kicked: kicked}
}

func (h *Hub) EnterRoom(client *Client, room RoomID) {
	h.EnterRoomCh <- EnterRoomParams{Client: client, Room: room}
}

func (h *Hub) SetPieceCount(client *Client, pieceCount uint8) {
	h.SetPieceCountCh <- SetPieceCountParams{Client: client, PieceCount: pieceCount}
}

func (h *Hub) ReadyPlayer(client *Client, isReady bool) {
	h.PlayerReadyCh <- PlayerReadyParams{Client: client, IsReady: isReady}
}
