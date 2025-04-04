package main

import (
	"encoding/json"
	"log"
	"net"
	"sync"
	"time"
)

type ClientID string

type Client struct {
	Conn   net.Conn
	ID     ClientID
	SendCh chan []byte

	EnterRoomCh chan *Room
	ExitRoomCh  chan struct{}

	roomMu sync.RWMutex
	room   *Room // don't read or write this outside of the client's read/write loop
}

func NewClient(conn net.Conn) *Client {
	return &Client{
		Conn:        conn,
		ID:          ClientID(generateUUID()),
		SendCh:      make(chan []byte, 128),
		EnterRoomCh: make(chan *Room),
		ExitRoomCh:  make(chan struct{}),
	}
}

func (c *Client) EnterRoom(room *Room) {
	c.EnterRoomCh <- room
}

func (c *Client) ExitRoom() {
	c.ExitRoomCh <- struct{}{}
}

func setRoom(c *Client, room *Room) {
	c.roomMu.Lock()
	defer c.roomMu.Unlock()
	c.room = room
}

func getRoom(c *Client) *Room {
	c.roomMu.RLock()
	defer c.roomMu.RUnlock()
	return c.room
}

func (c *Client) Send(msg MessageSerializer) error {
	b, err := SerializeMessage(msg)
	if err != nil {
		return err
	}
	c.SendBytes(b)
	return nil
}

func (c *Client) SendBytes(msg []byte) {
	c.SendCh <- msg
}

func (c *Client) ReadLoop(hub *Hub) {
	defer func() {
		c.Conn.Close()
		room := getRoom(c)
		if room != nil {
			room.Exit(c.ID, false)
		}
	}()

	for {
		msg, err := ReadMessage(c.Conn)
		if err != nil {
			log.Println(err)
			return
		}
		handleMessage(c, hub, msg)
	}
}

func (c *Client) WriteLoop(hub *Hub) {
	defer func() {
		c.Conn.Close()
		room := getRoom(c)
		if room != nil {
			room.Exit(c.ID, false)
		}
	}()
	timer := time.NewTimer(time.Minute)
	for {
		select {
		case msg, ok := <-c.SendCh:
			if !ok {
				return
			}
			err := writeMessage(c.Conn, msg)
			if err != nil {
				log.Println(err)
				return
			}
		case room := <-c.EnterRoomCh:
			setRoom(c, room)
		case <-c.ExitRoomCh:
			setRoom(c, nil)
		case <-timer.C:
			k := KeepAliveMessage{}
			msg, err := SerializeMessage(k)
			if err != nil {
				log.Println(err)
				return
			}
			err = writeMessage(c.Conn, msg)
			if err != nil {
				log.Println(err)
				return
			}
		}
	}
}

func handleMessage(c *Client, hub *Hub, msg Message) {
	switch msg.Kind {
	case MessageTypeCreateRoom:
		req := struct {
			Name string `json:"name"`
		}{}
		err := json.Unmarshal(msg.Payload, &req)
		if err != nil {
			log.Println(err)
			return
		}
		hub.CreateRoom(c, req.Name)
	case MessageTypeExitRoom:
		room := getRoom(c)
		if room == nil {
			break
		}
		room.Exit(c.ID, false)
	case MessageTypeSetPieceCount:
		req := struct {
			PieceCount uint8 `json:"piece_count"`
		}{}
		err := json.Unmarshal(msg.Payload, &req)
		if err != nil {
			log.Println(err)
			return
		}
		pieceCount := req.PieceCount
		if pieceCount > MaxPieceCountInRoom {
			pieceCount = MaxPieceCountInRoom
		}
		if pieceCount < MinPieceCountInRoom {
			pieceCount = MinPieceCountInRoom
		}
		room := getRoom(c)
		if room == nil {
			c.Send(SetPieceResponse{})
			break
		}
		room.ExecuteGameAction(c, SetPieceCountGameAction{PieceCount: pieceCount})
	case MessageTypeEnterRoom:
		req := struct {
			RoomID RoomID `json:"room_id"`
			Name   string `json:"name"`
		}{}
		err := json.Unmarshal(msg.Payload, &req)
		if err != nil {
			log.Println(err)
			return
		}
		hub.EnterRoom(c, req.Name, req.RoomID)
	case MessageTypePlayerReady:
		req := struct {
			IsReady bool `json:"is_ready"`
		}{}
		err := json.Unmarshal(msg.Payload, &req)
		if err != nil {
			log.Println(err)
			return
		}
		room := getRoom(c)
		if room == nil {
			c.Send(PlayerReadyResponse{})
			break
		}
		room.ReadyPlayer(c, req.IsReady)
	case MessageTypeKickPlayer:
		req := struct {
			Player ClientID `json:"player"`
		}{}
		err := json.Unmarshal(msg.Payload, &req)
		if err != nil {
			log.Println(err)
			return
		}
		room := getRoom(c)
		if room == nil {
			c.Send(PlayerJoinedResponse{})
			break
		}
		room.Exit(req.Player, true)
	case MessageTypeStartGame:
		room := getRoom(c)
		if room == nil {
			c.Send(StartGameResponse{})
			break
		}
		room.StartGame(c)
	case MessageTypeBeginRoll:
		room := getRoom(c)
		if room == nil {
			break
		}
		room.ExecuteGameAction(c, BeginRollGameAction{})
	case MessageTypeBeginMove:
		req := struct {
			Roll  int    `json:"roll"`
			Cell  CellID `json:"cell"`
			Piece int    `json:"piece"`
		}{}
		err := json.Unmarshal(msg.Payload, &req)
		if err != nil {
			log.Println(err)
			return
		}
		room := getRoom(c)
		if room == nil {
			break
		}
		room.ExecuteGameAction(c, BeginMoveGameAction{
			Move: Move{
				Roll:  req.Roll,
				Cell:  req.Cell,
				Piece: req.Piece,
			},
		})
	case MessageTypeEndMove:
		req := struct {
			Roll  int    `json:"roll"`
			Cell  CellID `json:"cell"`
			Piece int    `json:"piece"`
		}{}
		err := json.Unmarshal(msg.Payload, &req)
		if err != nil {
			log.Println(err)
			return
		}
		room := getRoom(c)
		if room == nil {
			break
		}
		room.ExecuteGameAction(c, EndMoveGameAction{
			Move: Move{
				Roll:  req.Roll,
				Cell:  req.Cell,
				Piece: req.Piece,
			},
		})
	case MessageTypeChangeName:
		req := struct {
			Name string `json:"name"`
		}{}
		err := json.Unmarshal(msg.Payload, &req)
		if err != nil {
			log.Println(err)
			return
		}
		room := getRoom(c)
		if room == nil {
			break
		}
		room.ExecuteGameAction(c, ChangeNameGameAction{Name: req.Name})
		log.Println(req)
	}
}

func writeMessage(conn net.Conn, msg []byte) error {
	for {
		_, err := conn.Write(msg)
		if err != nil {
			if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
				continue
			}
			return err
		} else {
			return nil
		}
	}
}
