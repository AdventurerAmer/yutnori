package main

import (
	"bytes"
	"encoding/binary"
	"encoding/json"
	"io"
	"net"
)

type MessageType uint8

const (
	MessageTypeKeepalive MessageType = iota
	MessageTypeConnect
	MessageTypeDisconnect
	MessageTypeQuit
	MessageTypeCreateRoom
	MessageTypeExitRoom
	MessageTypeSetPieceCount
	MessageTypePlayerLeft
	MessageTypeEnterRoom
	MessageTypePlayerJoined
	MessageTypePlayerReady
	MessageTypeKickPlayer
)

type Message struct {
	Kind    MessageType
	Payload []byte
}

type MessageSerializer interface {
	Kind() MessageType
}

type ConnectMessage struct {
	ClientID ClientID `json:"client_id"`
}

func (c ConnectMessage) Kind() MessageType {
	return MessageTypeConnect
}

type CreateRoomMessage struct {
	RoomID RoomID `json:"room_id"`
}

func (c CreateRoomMessage) Kind() MessageType {
	return MessageTypeCreateRoom
}

type SetPieceMessage struct {
	PieceCount uint8 `json:"piece_count"`
	ShouldSet  bool  `json:"should_set"`
}

func (c SetPieceMessage) Kind() MessageType {
	return MessageTypeSetPieceCount
}

type PlayerLeftMessage struct {
	Player ClientID `json:"player"`
	Master ClientID `json:"master"`
	Kicked bool     `json:"kicked"`
}

func (c PlayerLeftMessage) Kind() MessageType {
	return MessageTypePlayerLeft
}

type PlayerRoomStateRespone struct {
	ClientID ClientID `json:"client_id"`
	IsReady  bool     `json:"is_ready"`
}

type JoinRoomResponse struct {
	RoomID     RoomID                   `json:"room_id"`
	Join       bool                     `json:"join"`
	Master     ClientID                 `json:"master"`
	PieceCount uint8                    `json:"piece_count"`
	Players    []PlayerRoomStateRespone `json:"players"`
}

func (j JoinRoomResponse) Kind() MessageType {
	return MessageTypeEnterRoom
}

type PlayerJoinedResponse struct {
	ClientID ClientID `json:"client_id"`
}

func (j PlayerJoinedResponse) Kind() MessageType {
	return MessageTypePlayerJoined
}

type PlayerReadyResponse struct {
	Player  ClientID `json:"player"`
	IsReady bool     `json:"is_ready"`
}

func (p PlayerReadyResponse) Kind() MessageType {
	return MessageTypePlayerReady
}

func ReadMessage(conn net.Conn) (Message, error) {
	header := make([]byte, 3)
	for {
		_, err := io.ReadFull(conn, header)
		if err != nil {
			if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
				continue
			}
			return Message{}, err
		} else {
			break
		}
	}
	kind := header[0]
	payloadLen := binary.BigEndian.Uint16(header[1:])
	if payloadLen == 0 {
		return Message{Kind: MessageType(kind)}, nil
	}
	payload := make([]byte, payloadLen)
	for {
		_, err := io.ReadFull(conn, payload)
		if err != nil {
			if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
				continue
			}
			return Message{}, err
		} else {
			break
		}
	}
	return Message{Kind: MessageType(kind), Payload: payload}, nil
}

func SerializeMessage(message MessageSerializer) ([]byte, error) {
	payload, err := json.Marshal(message)
	if err != nil {
		return nil, err
	}
	var b bytes.Buffer
	b.WriteByte(byte(message.Kind()))
	binary.Write(&b, binary.BigEndian, uint16(len(payload)))
	b.Write(payload)
	return b.Bytes(), nil
}
