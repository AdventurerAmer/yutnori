package main

import (
	"encoding/json"
	"log"
	"net"
	"sync/atomic"
)

type ClientID string

type Client struct {
	Conn    net.Conn
	ID      ClientID
	SendCh  chan []byte
	IsReady atomic.Bool
}

func NewClient(conn net.Conn) *Client {
	return &Client{
		Conn:   conn,
		ID:     ClientID(generateUUID()),
		SendCh: make(chan []byte, 128),
	}
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
		hub.ExitRoom(c.ID, false)
	}()

	for {
		msg, err := ReadMessage(c.Conn)
		if err != nil {
			log.Println(err)
			return
		}
		c.HandleMessage(hub, msg)
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

func (c *Client) WriteLoop(hub *Hub) {
	defer func() {
		c.Conn.Close()
		hub.ExitRoom(c.ID, false)
	}()
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
		}
	}
}

func (c *Client) HandleMessage(hub *Hub, msg Message) {
	switch msg.Kind {
	case MessageTypeCreateRoom:
		hub.CreateRoom(c)
	case MessageTypeExitRoom:
		hub.ExitRoom(c.ID, false)
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
		hub.SetPieceCount(c, pieceCount)
	case MessageTypeEnterRoom:
		req := struct {
			RoomID RoomID `json:"room_id"`
		}{}
		err := json.Unmarshal(msg.Payload, &req)
		if err != nil {
			log.Println(err)
			return
		}
		hub.EnterRoom(c, req.RoomID)
	case MessageTypePlayerReady:
		req := struct {
			IsReady bool `json:"is_ready"`
		}{}
		err := json.Unmarshal(msg.Payload, &req)
		if err != nil {
			log.Println(err)
			return
		}
		c.IsReady.Store(req.IsReady)
		hub.ReadyPlayer(c, req.IsReady)
	case MessageTypeKickPlayer:
		req := struct {
			Player ClientID `json:"player"`
		}{}
		err := json.Unmarshal(msg.Payload, &req)
		if err != nil {
			log.Println(err)
			return
		}
		log.Println("Kicking Player", req.Player)
		hub.ExitRoom(req.Player, true)
	}
}
