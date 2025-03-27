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
	MessageTypeStartGame
	MessageTypeBeginTurn
	MessageTypeCanRoll
	MessageTypeBeginRoll
	MessageTypeEndRoll
	MessageTypeEndTurn
	MessageTypeSelectingMove
	MessageTypeBeginMove
	MessageTypeEndMove
	MessageTypeEndGame
)

type Message struct {
	Kind    MessageType
	Payload []byte
}

type MessageSerializer interface {
	Kind() MessageType
}

type ConnectResponse struct {
	ClientID ClientID `json:"client_id"`
}

func (c ConnectResponse) Kind() MessageType {
	return MessageTypeConnect
}

type CreateRoomResponse struct {
	RoomID RoomID `json:"room_id"`
}

func (c CreateRoomResponse) Kind() MessageType {
	return MessageTypeCreateRoom
}

type SetPieceResponse struct {
	PieceCount uint8 `json:"piece_count"`
	ShouldSet  bool  `json:"should_set"`
}

func (c SetPieceResponse) Kind() MessageType {
	return MessageTypeSetPieceCount
}

type PlayerLeftResponse struct {
	Player ClientID `json:"player"`
	Master ClientID `json:"master"`
	Kicked bool     `json:"kicked"`
}

func (c PlayerLeftResponse) Kind() MessageType {
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

type StartGameResponse struct {
	ShouldStart    bool     `json:"should_start"`
	StartingPlayer ClientID `json:"starting_player"`
}

func (s StartGameResponse) Kind() MessageType {
	return MessageTypeStartGame
}

type BeginTurnResponse struct{}

func (b BeginTurnResponse) Kind() MessageType {
	return MessageTypeBeginTurn
}

type CallRollResponse struct{}

func (c CallRollResponse) Kind() MessageType {
	return MessageTypeCanRoll
}

type EndRollResponse struct {
	ShouldAppend bool `json:"should_append"`
	Roll         int  `json:"roll"`
}

func (e EndRollResponse) Kind() MessageType {
	return MessageTypeEndRoll
}

type EndTurnResponse struct {
	NextPlayer ClientID `json:"next_player"`
}

func (e EndTurnResponse) Kind() MessageType {
	return MessageTypeEndTurn
}

type SelectingMoveResponse struct{}

func (s SelectingMoveResponse) Kind() MessageType {
	return MessageTypeSelectingMove
}

type BeginMoveRespone struct {
	ShouldMove bool   `json:"should_move"`
	Roll       int    `json:"roll"`
	Cell       CellID `json:"cell"`
	Piece      int    `json:"piece"`
	Finished   bool   `json:"finished"`
}

func (b BeginMoveRespone) Kind() MessageType {
	return MessageTypeBeginMove
}

type EndGameResponse struct {
	Winner ClientID `json:"winner"`
}

func (b EndGameResponse) Kind() MessageType {
	return MessageTypeEndGame
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
