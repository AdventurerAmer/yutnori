package main

import (
	"bytes"
	"crypto/rand"
	"encoding/base32"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
)

type Config struct {
	Port int
}

type MessageType uint8

const (
	MessageTypeKeepAlive = iota
	MessageTypeClientID
)

type Message struct {
	Kind    MessageType
	Payload []byte
}

type MessageSerializer interface {
	Serialize() (*Message, error)
}

type KeepAliveMessage struct{}

func (k KeepAliveMessage) Serialize() (*Message, error) {
	msg := &Message{
		Kind:    MessageTypeKeepAlive,
		Payload: nil,
	}
	return msg, nil
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

func handleConn(conn net.Conn) {
	defer func() {
		conn.Close()
		log.Printf("%v disconnected\n", conn.RemoteAddr())
	}()

	log.Printf("%v connected\n", conn.RemoteAddr())

	clientID := make([]byte, 20)
	rand.Read(clientID)

	msg := ClientIDMessage{
		ID: base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(clientID),
	}
	err := SendMessage(conn, msg)
	if err != nil {
		log.Println(err)
	}

	log.Printf("Sending ID '%s' to client '%s'\n", msg.ID, conn.RemoteAddr())

	buf := make([]byte, 4096)
	for {
		n, err := conn.Read(buf)
		if err != nil {
			if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
				continue
			} else {
				log.Println(err)
				return
			}
		}
		msg := buf[:n]
		log.Println(msg)
	}
}
