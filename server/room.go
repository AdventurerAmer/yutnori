package main

import (
	"log"
	"math/rand"
)

type RoomID string

const MaxPlayerCountInRoom = 6
const MinPlayerCountToStartGame = 2

type ExitRoomParams struct {
	Client ClientID
	Kicked bool
}

type PlayerReadyParams struct {
	Client  *Client
	IsReady bool
}

type StartGameParams struct {
	Client *Client
}

type GameExecutor interface {
	Execute(*Client, *Room)
}

type GameActionParams struct {
	Client   *Client
	Executor GameExecutor
}

type Room struct {
	ID           RoomID
	Master       *Client
	GameInstance *GameInstance

	EnterRoomCh   chan EnterRoomParams
	ExitRoomCh    chan ExitRoomParams
	PlayerReadyCh chan PlayerReadyParams
	StartGameCh   chan *Client

	GameActionCh chan GameActionParams
}

func NewRoom(master *Client, masterName string) *Room {
	r := &Room{
		ID:           RoomID(generateUUID()),
		Master:       master,
		GameInstance: NewGameInstance(),

		EnterRoomCh:   make(chan EnterRoomParams),
		ExitRoomCh:    make(chan ExitRoomParams),
		PlayerReadyCh: make(chan PlayerReadyParams),
		StartGameCh:   make(chan *Client),

		GameActionCh: make(chan GameActionParams),
	}
	r.GameInstance.Players = append(r.GameInstance.Players, PlayerState{Client: master, Name: masterName})
	return r
}

func (r *Room) Enter(client *Client, clientName string) {
	if r == nil {
		return
	}
	r.EnterRoomCh <- EnterRoomParams{Client: client, ClientName: clientName}
}

func (r *Room) Exit(client ClientID, kicked bool) {
	if r == nil {
		return
	}
	r.ExitRoomCh <- ExitRoomParams{Client: client, Kicked: kicked}
}

func (r *Room) ReadyPlayer(client *Client, isReady bool) {
	if r == nil {
		return
	}
	r.PlayerReadyCh <- PlayerReadyParams{Client: client, IsReady: isReady}
}

func (r *Room) StartGame(client *Client) {
	if r == nil {
		return
	}
	r.StartGameCh <- client
}

func (r *Room) ExecuteGameAction(c *Client, e GameExecutor) {
	if r == nil {
		return
	}
	r.GameActionCh <- GameActionParams{Client: c, Executor: e}
}

func (r *Room) ReadLoop(hub *Hub) {
	defer hub.DestroyRoom(r)
	for {
		select {
		case params := <-r.EnterRoomCh:
			enter(r, params.Client, params.ClientName)
		case msg := <-r.ExitRoomCh:
			err := exit(r, msg.Client, msg.Kicked)
			if err != nil {
				log.Println(err)
			}
			if len(r.GameInstance.Players) == 0 {
				return
			}
		case msg := <-r.PlayerReadyCh:
			idx := r.GameInstance.GetClientIndex(msg.Client)
			if idx == -1 {
				msg.Client.Send(PlayerReadyResponse{})
				break
			}
			r.GameInstance.Players[idx].IsReady = msg.IsReady
			err := r.Broadcast(PlayerReadyResponse{Player: msg.Client.ID, IsReady: msg.IsReady})
			if err != nil {
				log.Println(err)
			}
		case client := <-r.StartGameCh:
			if r.Master != client {
				r.Broadcast(StartGameResponse{})
				break
			}
			r.GameInstance.Start(r)
		case action := <-r.GameActionCh:
			if !r.GameInstance.IsClientInRoom(action.Client) {
				log.Printf("client '%s' cannot execute action because he is not in the room\n", action.Client.ID)
				break
			}
			action.Executor.Execute(action.Client, r)
		}
	}
}

func (r *Room) Broadcast(serializer MessageSerializer) error {
	msg, err := SerializeMessage(serializer)
	if err != nil {
		return err
	}
	for _, p := range r.GameInstance.Players {
		p.Client.SendBytes(msg)
	}
	return nil
}

func enter(r *Room, client *Client, clientName string) {
	if len(r.GameInstance.Players) == MaxPlayerCountInRoom {
		client.Send(JoinRoomResponse{})
		return
	}
	players := []PlayerRoomStateRespone{}
	for _, p := range r.GameInstance.Players {
		state := PlayerRoomStateRespone{
			ClientID: p.Client.ID,
			IsReady:  p.IsReady,
			Name:     p.Name,
		}
		players = append(players, state)
	}
	client.Send(JoinRoomResponse{
		RoomID:     r.ID,
		Join:       true,
		Master:     r.Master.ID,
		PieceCount: r.GameInstance.PieceCount,
		Players:    players,
	})
	r.Broadcast(PlayerJoinedResponse{ClientID: client.ID, Name: clientName})
	r.GameInstance.Players = append(r.GameInstance.Players, PlayerState{Client: client, Name: clientName})
	client.EnterRoom(r)
}

func exit(r *Room, clientID ClientID, kicked bool) error {
	clientCount := len(r.GameInstance.Players)
	if clientCount == 0 {
		return nil
	}

	isInRoom := false

	for idx, p := range r.GameInstance.Players {
		if p.Client.ID == clientID {
			isInRoom = true
			if kicked {
				p.Client.ExitRoom()
			}
			r.GameInstance.Players[idx], r.GameInstance.Players[clientCount-1] = r.GameInstance.Players[clientCount-1], r.GameInstance.Players[idx]
			break
		}
	}

	if !isInRoom {
		return nil
	}

	masterID := ClientID("")

	if clientCount-1 > 0 {
		masterIdx := rand.Int31n(int32(clientCount) - 1)
		r.Master = r.GameInstance.Players[masterIdx].Client
		masterID = r.Master.ID
	}

	err := r.Broadcast(PlayerLeftResponse{Master: masterID, Player: clientID, Kicked: kicked})
	if err != nil {
		return err
	}

	r.GameInstance.Players = r.GameInstance.Players[:clientCount-1]
	if r.GameInstance.GameState != GameStateGameEnded {
		r.GameInstance.Reset()
	}
	return nil
}
