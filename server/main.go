package main

import (
	"bytes"
	"crypto/rand"
	"encoding/base32"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"sync"
)

type Config struct {
	Port int
}

type MessageType uint8

const (
	MessageTypeClientID MessageType = iota
	MessageTypeCreateRoom
	MessageTypeExitRoom
	MessageTypeSetPieceCount
)

func (kind MessageType) String() string {
	switch kind {
	case MessageTypeClientID:
		return "ClientID"
	case MessageTypeCreateRoom:
		return "CreateRoom"
	case MessageTypeExitRoom:
		return "ExitRoom"
	case MessageTypeSetPieceCount:
		return "SetPieceCount"
	}
	return "Unsupported"
}

type Message struct {
	Kind    MessageType
	Payload []byte
}

type MessageSerializer interface {
	Serialize() (*Message, error)
}

type ClientIDMessage struct {
	ID string `json:"id"`
}

func (c ClientIDMessage) Serialize() (*Message, error) {
	payload, err := json.Marshal(c)
	if err != nil {
		return nil, err
	}
	msg := &Message{
		Kind:    MessageTypeClientID,
		Payload: payload,
	}
	return msg, nil
}

type CreateRoomMessage struct {
	ID string `json:"id"`
}

func (c CreateRoomMessage) Serialize() (*Message, error) {
	payload, err := json.Marshal(c)
	if err != nil {
		return nil, err
	}
	msg := &Message{
		Kind:    MessageTypeCreateRoom,
		Payload: payload,
	}
	return msg, nil
}

type SetPieceMessage struct {
	PieceCount int  `json:"piece_count"`
	ShouldSet  bool `json:"should_set"`
}

func (c SetPieceMessage) Serialize() (*Message, error) {
	payload, err := json.Marshal(c)
	if err != nil {
		return nil, err
	}
	msg := &Message{
		Kind:    MessageTypeSetPieceCount,
		Payload: payload,
	}
	return msg, nil
}

func ReadMessage(conn net.Conn) (*Message, error) {
	header := make([]byte, 3)
	for {
		_, err := io.ReadFull(conn, header)
		if err != nil {
			if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
				continue
			}
			return nil, err
		} else {
			break
		}
	}
	kind := header[0]
	payloadLen := binary.BigEndian.Uint16(header[1:])
	if payloadLen == 0 {
		return &Message{Kind: MessageType(kind)}, nil
	}
	payload := make([]byte, payloadLen)
	for {
		_, err := io.ReadFull(conn, payload)
		if err != nil {
			if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
				continue
			}
			return nil, err
		} else {
			break
		}
	}
	return &Message{Kind: MessageType(kind), Payload: payload}, nil
}

func SendMessage(conn net.Conn, serializer MessageSerializer) error {
	m, err := serializer.Serialize()
	if err != nil {
		return err
	}
	var b bytes.Buffer
	b.WriteByte(byte(m.Kind))
	binary.Write(&b, binary.BigEndian, uint16(len(m.Payload)))
	if len(m.Payload) != 0 {
		b.Write(m.Payload)
	}
	for {
		_, err := conn.Write(b.Bytes())
		if err != nil {
			if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
				continue
			}
			return err
		} else {
			break
		}
	}
	return nil
}

func (s *Server) BroadcastMessage(room *Room, serializer MessageSerializer) error {
	m, err := serializer.Serialize()
	if err != nil {
		return err
	}
	var b bytes.Buffer
	b.WriteByte(byte(m.Kind))
	binary.Write(&b, binary.BigEndian, uint16(len(m.Payload)))
	if len(m.Payload) != 0 {
		b.Write(m.Payload)
	}
	for _, clientID := range room.Clients {
		client := s.clients[clientID]
		for {
			_, err := client.Conn.Write(b.Bytes())
			if err != nil {
				if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
					continue
				}
				return err
			} else {
				break
			}
		}
	}
	return nil
}

type Server struct {
	Config Config

	clientsMu sync.Mutex
	clients   map[ClientID]*Client

	roomsMu sync.Mutex
	rooms   map[RoomID]*Room
}

func NewServer(cfg Config) *Server {
	return &Server{
		Config:  cfg,
		clients: make(map[ClientID]*Client),
		rooms:   make(map[RoomID]*Room),
	}
}

type ClientID string
type RoomID string

type Client struct {
	Conn   net.Conn
	RoomID RoomID
}

const MaxPlayerCountInRoom = 6
const MinPlayerCountToStartGame = 2
const MaxPieceCountInRoom = 6
const MinPieceCountInRoom = 2

type Room struct {
	Master     ClientID
	Clients    []ClientID
	PieceCount uint8
}

func NewRoom(master ClientID) *Room {
	return &Room{
		Master:     master,
		Clients:    []ClientID{master},
		PieceCount: MinPieceCountInRoom,
	}
}

func NewClient(conn net.Conn) *Client {
	return &Client{
		Conn: conn,
	}
}

func (s *Server) Start() error {
	log.Printf("Starting server on port: %d\n", s.Config.Port)
	addr := fmt.Sprintf(":%d", s.Config.Port)
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	defer ln.Close()
	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Println(err)
			continue
		}
		s.AddClient(conn)
	}
}

func (s *Server) AddClient(conn net.Conn) {
	client := NewClient(conn)
	clientID := ClientID(generateUUID())
	s.clientsMu.Lock()
	defer s.clientsMu.Unlock()
	s.clients[clientID] = client
	go s.HandleClient(clientID, client)
}

func (s *Server) RemoveClient(clientID ClientID) {
	s.clientsMu.Lock()
	defer s.clientsMu.Unlock()
	delete(s.clients, clientID)
}

func (s *Server) CreateRoom(master ClientID) RoomID {
	roomID := RoomID(generateUUID())
	room := NewRoom(master)
	s.roomsMu.Lock()
	defer s.roomsMu.Unlock()
	s.rooms[roomID] = room
	return roomID
}

func (s *Server) ExitRoom(roomID RoomID, clientID ClientID) error {
	s.roomsMu.Lock()
	room, ok := s.rooms[roomID]
	defer s.roomsMu.Unlock()
	if !ok {
		return fmt.Errorf("room doesn't exist")
	}
	for clientIdx, client := range room.Clients {
		if client == clientID {
			room.Clients = append(room.Clients[:clientIdx], room.Clients[clientIdx+1:]...)
			break
		}
	}
	if len(room.Clients) == 0 {
		delete(s.rooms, roomID)
	}
	return nil
}

func (s *Server) HandleClient(clientID ClientID, client *Client) {
	conn := client.Conn

	defer func() {
		if client.RoomID != "" {
			s.ExitRoom(client.RoomID, clientID)
		}
		s.RemoveClient(clientID)
		conn.Close()
		log.Printf("%v disconnected\n", conn.RemoteAddr())
	}()

	log.Printf("%v connected\n", conn.RemoteAddr())

	msg := ClientIDMessage{
		ID: string(clientID),
	}
	err := SendMessage(conn, msg)
	if err != nil {
		log.Println(err)
		return
	}

	log.Printf("Sending ID '%s' to client '%s'\n", msg.ID, conn.RemoteAddr())

	for {
		msg, err := ReadMessage(conn)
		if err != nil {
			log.Println(err)
			return
		}

		switch msg.Kind {
		case MessageTypeCreateRoom:
			roomID := s.CreateRoom(clientID)
			msg := CreateRoomMessage{ID: string(roomID)}
			err := SendMessage(conn, msg)
			if err != nil {
				return
			}
			client.RoomID = roomID
			log.Printf("client '%s' created room '%s'\n", clientID, roomID)
		case MessageTypeExitRoom:
			if client.RoomID == "" {
				continue
			}
			err := s.ExitRoom(client.RoomID, clientID)
			if err != nil {
				log.Println(err)
			}
			log.Printf("client '%s' existed room '%s'\n", clientID, client.RoomID)
			client.RoomID = ""
		case MessageTypeSetPieceCount:
			if len(msg.Payload) == 0 {
				return
			}
			if client.RoomID == "" { // client is not in a room
				SendMessage(conn, SetPieceMessage{ShouldSet: false})
				break
			}
			roomID := client.RoomID
			s.roomsMu.Lock()
			room, ok := s.rooms[roomID]
			s.roomsMu.Unlock()
			if !ok { // client is in a room that does exit
				SendMessage(conn, SetPieceMessage{ShouldSet: false})
				break
			}
			if room.Master != clientID { // client can't set piece count because he is not the room master
				SendMessage(conn, SetPieceMessage{ShouldSet: false})
				break
			}
			req := struct {
				PieceCount int `json:"piece_count"`
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
			room.PieceCount = uint8(pieceCount)
			// SendMessage(conn, SetPieceMessage{ShouldSet: true, PieceCount: req.PieceCount})
			log.Println("broad cast piece count:", req.PieceCount)
			s.BroadcastMessage(room, SetPieceMessage{ShouldSet: true, PieceCount: req.PieceCount})
		}
	}
}

func main() {
	cfg := Config{}
	flag.IntVar(&cfg.Port, "port", 42069, "port of the server")
	flag.Parse()
	srv := NewServer(cfg)
	err := srv.Start()
	if err != nil {
		log.Fatal(err)
	}
}

func generateUUID() string {
	b := make([]byte, 20)
	rand.Read(b)
	return base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(b)
}
