package main

import (
	"errors"
	"math/rand"
)

type RoomID string

const MaxPlayerCountInRoom = 6
const MinPlayerCountToStartGame = 2
const MaxPieceCountInRoom = 6
const MinPieceCountInRoom = 2

type Room struct {
	ID         RoomID
	Master     *Client
	Clients    []*Client
	PieceCount uint8
}

func NewRoom(master *Client) *Room {
	return &Room{
		ID:         RoomID(generateUUID()),
		Master:     master,
		Clients:    []*Client{master},
		PieceCount: MinPieceCountInRoom,
	}
}

func (r *Room) Broadcast(serializer MessageSerializer) error {
	if r == nil {
		return errors.New("room is nil")
	}
	m, err := SerializeMessage(serializer)
	if err != nil {
		return err
	}
	for _, c := range r.Clients {
		c.SendBytes(m)
	}
	return nil
}

func (r *Room) Enter(roomID RoomID, client *Client) {
	if r == nil || len(r.Clients) == MaxPlayerCountInRoom {
		client.Send(JoinRoomResponse{})
		return
	}
	players := []PlayerRoomState{}
	for _, roomClient := range r.Clients {
		state := PlayerRoomState{
			ClientID: roomClient.ID,
			IsReady:  roomClient.IsReady.Load(),
		}
		players = append(players, state)
	}
	client.Send(JoinRoomResponse{
		RoomID:     roomID,
		Join:       true,
		Master:     r.Master.ID,
		PieceCount: r.PieceCount,
		Players:    players,
	})
	r.Broadcast(PlayerJoinedResponse{ClientID: client.ID})
	r.Clients = append(r.Clients, client)
}

func (r *Room) Exit(clientID ClientID, kicked bool) error {
	if r == nil {
		return errors.New("room is nil")
	}

	clientCount := len(r.Clients)
	for idx, client := range r.Clients {
		if client.ID == clientID {
			r.Clients[idx], r.Clients[clientCount-1] = r.Clients[clientCount-1], r.Clients[idx]
			break
		}
	}

	masterID := ClientID("")

	if clientCount-1 > 0 {
		masterIdx := rand.Int31n(int32(clientCount) - 1)
		r.Master = r.Clients[masterIdx]
		masterID = r.Clients[masterIdx].ID
	}

	r.Broadcast(PlayerLeftMessage{Master: masterID, Player: clientID, Kicked: kicked})

	if clientCount-1 > 0 {
		r.Clients = r.Clients[:clientCount-1]
	}

	return nil
}
