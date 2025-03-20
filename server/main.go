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
)

type Config struct {
	Port int
}

type MessageType uint8

const (
	MessageTypeClientID MessageType = iota
	MessageTypeCreateRoom
	MessageTypeExitRoom
)

func (kind MessageType) String() string {
	switch kind {
	case MessageTypeClientID:
		return "ClientID"
	case MessageTypeCreateRoom:
		return "CreateRoom"
	case MessageTypeExitRoom:
		return "ExitRoom"
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

func main() {
	cfg := Config{}
	flag.IntVar(&cfg.Port, "port", 42069, "port of the server")
	flag.Parse()

	addr := fmt.Sprintf(":%d", cfg.Port)
	log.Printf("starting server on port: %d\n", cfg.Port)
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatal(err)
	}

	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Println(err)
			continue
		}
		go handleConn(conn)
	}
}

func createUUID() string {
	b := make([]byte, 20)
	rand.Read(b)
	return base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(b)
}

func handleConn(conn net.Conn) {
	defer func() {
		conn.Close()
		log.Printf("%v disconnected\n", conn.RemoteAddr())
	}()

	log.Printf("%v connected\n", conn.RemoteAddr())

	msg := ClientIDMessage{
		ID: createUUID(),
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

		data := make(map[string]any)
		if msg.Payload != nil {
			err = json.Unmarshal(msg.Payload, &data)
			if err != nil {
				log.Println(string(msg.Payload), err)
				return
			}
		}

		log.Println(msg.Kind, data)

		switch msg.Kind {
		case MessageTypeCreateRoom:
			msg := CreateRoomMessage{ID: createUUID()}
			err := SendMessage(conn, msg)
			if err != nil {
				return
			}
		case MessageTypeExitRoom:
		}
	}
}
