package main

import (
	"log"
	"math/rand"
)

type RoomID string

const MaxPlayerCountInRoom = 6
const MinPlayerCountToStartGame = 2
const MaxPieceCountInRoom = 6
const MinPieceCountInRoom = 2

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

type PlayerState struct {
	Client  *Client
	IsReady bool
}

type Room struct {
	ID         RoomID
	Master     *Client
	Players    []PlayerState
	PieceCount uint8

	EnterRoomCh     chan *Client
	ExitRoomCh      chan ExitRoomParams
	SetPieceCountCh chan SetPieceCountParams
	PlayerReadyCh   chan PlayerReadyParams
}

func NewRoom(master *Client) *Room {
	r := &Room{
		ID:              RoomID(generateUUID()),
		Master:          master,
		PieceCount:      MinPieceCountInRoom,
		EnterRoomCh:     make(chan *Client),
		ExitRoomCh:      make(chan ExitRoomParams),
		SetPieceCountCh: make(chan SetPieceCountParams),
		PlayerReadyCh:   make(chan PlayerReadyParams),
	}
	r.Players = append(r.Players, PlayerState{Client: master})
	return r
}

func (r *Room) Enter(client *Client) {
	if r == nil {
		log.Println("Room is nil")
		return
	}
	r.EnterRoomCh <- client
}

func (r *Room) Exit(client ClientID, kicked bool) {
	if r == nil {
		log.Println("Room is nil")
		return
	}
	r.ExitRoomCh <- ExitRoomParams{Client: client, Kicked: kicked}
}

func (r *Room) SetPieceCount(client *Client, pieceCount uint8) {
	if r == nil {
		log.Println("Room is nil")
		return
	}
	r.SetPieceCountCh <- SetPieceCountParams{Client: client, PieceCount: pieceCount}
}

func (r *Room) ReadyPlayer(client *Client, isReady bool) {
	if r == nil {
		log.Println("Room is nil")
		return
	}
	r.PlayerReadyCh <- PlayerReadyParams{Client: client, IsReady: isReady}
}

func (r *Room) ReadLoop(hub *Hub) {
	defer hub.DestroyRoom(r)
	for {
		select {
		case client := <-r.EnterRoomCh:
			enter(r, client)
		case msg := <-r.ExitRoomCh:
			c, kicked := msg.Client, msg.Kicked
			err := exit(r, c, kicked)
			if err != nil {
				log.Println(err)
			}
			if len(r.Players) == 0 {
				return
			}
		case msg := <-r.SetPieceCountCh:
			if msg.Client != r.Master {
				msg.Client.Send(SetPieceMessage{ShouldSet: false})
				break
			}
			r.PieceCount = msg.PieceCount
			err := broadcast(r, SetPieceMessage{ShouldSet: true, PieceCount: msg.PieceCount})
			if err != nil {
				log.Println(err)
			}
		case msg := <-r.PlayerReadyCh:
			err := broadcast(r, PlayerReadyResponse{Player: msg.Client.ID, IsReady: msg.IsReady})
			if err != nil {
				log.Println(err)
			}
		}
	}
}

func broadcast(r *Room, serializer MessageSerializer) error {
	msg, err := SerializeMessage(serializer)
	if err != nil {
		return err
	}
	for _, p := range r.Players {
		p.Client.SendBytes(msg)
	}
	return nil
}

func enter(r *Room, client *Client) {
	if len(r.Players) == MaxPlayerCountInRoom {
		client.Send(JoinRoomResponse{})
		return
	}
	players := []PlayerRoomStateRespone{}
	for _, p := range r.Players {
		state := PlayerRoomStateRespone{
			ClientID: p.Client.ID,
			IsReady:  p.IsReady,
		}
		players = append(players, state)
	}
	client.Send(JoinRoomResponse{
		RoomID:     r.ID,
		Join:       true,
		Master:     r.Master.ID,
		PieceCount: r.PieceCount,
		Players:    players,
	})
	broadcast(r, PlayerJoinedResponse{ClientID: client.ID})
	r.Players = append(r.Players, PlayerState{Client: client})
	client.SetRoom(r)
}

func exit(r *Room, clientID ClientID, kicked bool) error {
	clientCount := len(r.Players)
	if clientCount == 0 {
		return nil
	}

	for idx, p := range r.Players {
		if p.Client.ID == clientID {
			r.Players[idx], r.Players[clientCount-1] = r.Players[clientCount-1], r.Players[idx]
			break
		}
	}

	masterID := ClientID("")

	if clientCount-1 > 0 {
		masterIdx := rand.Int31n(int32(clientCount) - 1)
		r.Master = r.Players[masterIdx].Client
		masterID = r.Master.ID
	}

	err := broadcast(r, PlayerLeftMessage{Master: masterID, Player: clientID, Kicked: kicked})
	if err != nil {
		return err
	}

	r.Players = r.Players[:clientCount-1]
	return nil
}
