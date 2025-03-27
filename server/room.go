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

type Move struct {
	Roll  int
	Cell  CellID
	Piece int
}

type MoveParams struct {
	Move
	Client *Client
}

type CellID uint8

const (
	BottomRightCorner CellID = iota
	Right0
	Right1
	Right2
	Right3
	TopRightCorner
	Top0
	Top1
	Top2
	Top3
	TopLeftCorner
	Left0
	Left1
	Left2
	Left3
	BottomLeftCorner
	Bottom0
	Bottom1
	Bottom2
	Bottom3
	MainDiagonal0
	MainDiagonal1
	MainDiagonal2
	MainDiagonal3
	AntiDiagonal0
	AntiDiagonal1
	AntiDiagonal2
	AntiDiagonal3
	Center
)

type Piece struct {
	IsAtStart  bool
	IsFinished bool
	Cell       CellID
}

type PlayerState struct {
	Client  *Client
	IsReady bool
	Pieces  [MaxPieceCountInRoom]Piece
}

type GameAction uint8

const (
	GameActionGameEnded GameAction = iota
	GameActionGameStarted
	GameActionBeginTurn
	GameActionEndTurn
	GameActionCanRoll
	GameActionBeginRoll
	GameActionEndRoll
	GameActionBeginMove
	GameActionEndMove
	GameActionSelectingMove
)

type Room struct {
	ID                  RoomID
	Master              *Client
	Players             []PlayerState
	PieceCount          uint8
	Action              GameAction
	PlayerTurnIdx       int
	Rolls               []int
	EndMoveSet          map[*Client]struct{}
	CurrentMove         Move
	CurrentMoveFinishes bool

	EnterRoomCh     chan *Client
	ExitRoomCh      chan ExitRoomParams
	SetPieceCountCh chan SetPieceCountParams
	PlayerReadyCh   chan PlayerReadyParams
	StartGameCh     chan *Client
	BeginRollCh     chan *Client
	BeginMoveCh     chan MoveParams
	EndMoveCh       chan MoveParams
}

func NewRoom(master *Client) *Room {
	r := &Room{
		ID:              RoomID(generateUUID()),
		Master:          master,
		PieceCount:      MinPieceCountInRoom,
		Action:          GameActionGameEnded,
		EndMoveSet:      make(map[*Client]struct{}),
		EnterRoomCh:     make(chan *Client),
		ExitRoomCh:      make(chan ExitRoomParams),
		SetPieceCountCh: make(chan SetPieceCountParams),
		PlayerReadyCh:   make(chan PlayerReadyParams),
		StartGameCh:     make(chan *Client),
		BeginRollCh:     make(chan *Client),
		BeginMoveCh:     make(chan MoveParams),
		EndMoveCh:       make(chan MoveParams),
	}
	r.Players = append(r.Players, PlayerState{Client: master})
	return r
}

func (r *Room) Enter(client *Client) {
	r.EnterRoomCh <- client
}

func (r *Room) Exit(client ClientID, kicked bool) {
	r.ExitRoomCh <- ExitRoomParams{Client: client, Kicked: kicked}
}

func (r *Room) SetPieceCount(client *Client, pieceCount uint8) {
	r.SetPieceCountCh <- SetPieceCountParams{Client: client, PieceCount: pieceCount}
}

func (r *Room) ReadyPlayer(client *Client, isReady bool) {
	r.PlayerReadyCh <- PlayerReadyParams{Client: client, IsReady: isReady}
}

func (r *Room) StartGame(client *Client) {
	r.StartGameCh <- client
}

func (r *Room) Roll(client *Client) {
	r.BeginRollCh <- client
}

func (r *Room) ReadLoop(hub *Hub) {
	defer hub.DestroyRoom(r)
	for {
		select {
		case client := <-r.EnterRoomCh:
			enter(r, client)
		case msg := <-r.ExitRoomCh:
			err := exit(r, msg.Client, msg.Kicked)
			if err != nil {
				log.Println(err)
			}
			if len(r.Players) == 0 {
				return
			}
		case msg := <-r.SetPieceCountCh:
			if msg.Client != r.Master {
				msg.Client.Send(SetPieceResponse{ShouldSet: false})
				break
			}
			r.PieceCount = msg.PieceCount
			err := broadcast(r, SetPieceResponse{ShouldSet: true, PieceCount: msg.PieceCount})
			if err != nil {
				log.Println(err)
			}
		case msg := <-r.PlayerReadyCh:
			isInRoom := false
			for idx, p := range r.Players {
				if p.Client == msg.Client {
					r.Players[idx].IsReady = msg.IsReady
					isInRoom = true
					break
				}
			}
			if !isInRoom {
				msg.Client.Send(PlayerReadyResponse{})
				break
			}
			err := broadcast(r, PlayerReadyResponse{Player: msg.Client.ID, IsReady: msg.IsReady})
			if err != nil {
				log.Println(err)
			}
		case client := <-r.StartGameCh:
			if r.Action != GameActionGameEnded {
				log.Printf("illegal move action should be %d got %d\n", GameActionGameEnded, r.Action)
				break
			}
			readyCount := 0
			for _, p := range r.Players {
				if p.IsReady {
					readyCount++
				}
			}
			if r.Master != client || readyCount != len(r.Players) {
				client.Send(StartGameResponse{})
				break
			}

			reset(r)
			r.PlayerTurnIdx = rand.Intn(len(r.Players))
			err := broadcast(r, StartGameResponse{
				ShouldStart:    true,
				StartingPlayer: r.Players[r.PlayerTurnIdx].Client.ID,
			})
			if err != nil {
				log.Println(err)
			}
			err = broadcast(r, BeginTurnResponse{})
			if err != nil {
				log.Println(err)
			}
			r.Players[r.PlayerTurnIdx].Client.Send(CallRollResponse{})
			r.Action = GameActionCanRoll
		case client := <-r.BeginRollCh:
			if r.Action != GameActionCanRoll {
				log.Printf("illegal move action should be %d got %d\n", GameActionCanRoll, r.Action)
				break
			}
			player := &r.Players[r.PlayerTurnIdx]
			if player.Client != client {
				log.Printf("permission denied action should be from client '%s' but got '%s'\n", player.Client.ID, client.ID)
				break
			}
			n, shouldAppend := roll(r)
			err := broadcast(r, EndRollResponse{ShouldAppend: shouldAppend, Roll: n})
			if err != nil {
				log.Println(err)
			}
			if n == 4 || n == 5 {
				client.Send(CallRollResponse{})
				r.Action = GameActionCanRoll
			} else if len(r.Rolls) == 0 {
				r.PlayerTurnIdx += 1
				r.PlayerTurnIdx %= len(r.Players)
				err := broadcast(r, EndTurnResponse{NextPlayer: r.Players[r.PlayerTurnIdx].Client.ID})
				if err != nil {
					log.Println(err)
				}
				err = broadcast(r, BeginTurnResponse{})
				if err != nil {
					log.Println(err)
				}
				r.Players[r.PlayerTurnIdx].Client.Send(CallRollResponse{})
				r.Action = GameActionCanRoll
			} else {
				client.Send(SelectingMoveResponse{})
				if err != nil {
					log.Println(err)
				}
				r.Action = GameActionSelectingMove
				log.Println("SelectingMove")
			}
		case params := <-r.BeginMoveCh:
			if r.Action != GameActionSelectingMove { // illegal
				log.Println("illegal", r.Action)
				params.Client.Send(BeginMoveRespone{})
				break
			}
			currentPlayer := &r.Players[r.PlayerTurnIdx]
			if currentPlayer.Client != params.Client || params.Piece >= int(r.PieceCount) { // illegal
				log.Println("illegal")
				params.Client.Send(BeginMoveRespone{})
				break
			}
			pieceToMove := currentPlayer.Pieces[params.Piece]
			log.Printf("Piece: %+v\n", pieceToMove)
			if pieceToMove.IsFinished { // illiegal
				log.Println("illegal")
				params.Client.Send(BeginMoveRespone{})
				break
			}

			rollIdx := -1
			for idx, roll := range r.Rolls {
				if roll == params.Roll {
					rollIdx = idx
					break
				}
			}
			if rollIdx == -1 { // illegal
				log.Println("illegal")
				params.Client.Send(BeginMoveRespone{})
				break
			}
			seq0, seq1, finished := getMoveSeq(pieceToMove, params.Roll)
			isValidMove := false
			if len(seq0) != 0 && seq0[len(seq0)-1] == params.Cell {
				isValidMove = true
			}
			if len(seq1) != 0 && seq0[len(seq1)-1] == params.Cell {
				isValidMove = true
			}
			if !isValidMove { // illegal
				log.Println("illegal")
				broadcast(r, BeginMoveRespone{})
				break
			}
			r.Rolls = append(r.Rolls[:rollIdx], r.Rolls[rollIdx+1:]...)

			clear(r.EndMoveSet)

			r.CurrentMove = params.Move
			r.CurrentMoveFinishes = finished
			err := broadcast(r, BeginMoveRespone{
				ShouldMove: true,
				Roll:       params.Roll,
				Cell:       params.Cell,
				Piece:      params.Piece,
				Finished:   finished,
			})
			if err != nil {
				log.Println(err)
			}
			r.Action = GameActionBeginMove
			log.Println("BeginMove...")
		case params := <-r.EndMoveCh:
			if r.Action != GameActionBeginMove {
				log.Println("illegal")
				break
			}
			IsInRoom := false
			for _, p := range r.Players {
				if params.Client == p.Client {
					IsInRoom = true
					break
				}
			}

			if !IsInRoom || params.Move != r.CurrentMove {
				log.Println("illegal")
				break
			}

			r.EndMoveSet[params.Client] = struct{}{}
			if len(r.EndMoveSet) != len(r.Players) {
				break
			}

			log.Println("EndMove...")

			currentPlayer := &r.Players[r.PlayerTurnIdx]
			pieceToMove := currentPlayer.Pieces[r.CurrentMove.Piece]

			// moving pieces
			if pieceToMove.IsAtStart {
				pieceToMove.IsFinished = false
				pieceToMove.Cell = params.Cell
				pieceToMove.IsAtStart = false
				currentPlayer.Pieces[params.Piece] = pieceToMove
			} else {
				for pieceIdx := 0; pieceIdx < int(r.PieceCount); pieceIdx++ {
					piece := currentPlayer.Pieces[pieceIdx]
					if piece.IsFinished {
						continue
					}
					if piece.Cell == pieceToMove.Cell && !piece.IsAtStart {
						piece.Cell = params.Cell
						piece.IsFinished = r.CurrentMoveFinishes
					}
					currentPlayer.Pieces[pieceIdx] = piece
				}
			}

			// stomping an opponent piece
			stomped := false
			for playerIdx := 0; playerIdx < len(r.Players); playerIdx++ {
				player := &r.Players[playerIdx]
				for pieceIdx := 0; pieceIdx < int(r.PieceCount); pieceIdx++ {
					piece := player.Pieces[pieceIdx]
					if piece.IsFinished {
						continue
					}
					if piece.Cell == params.Cell &&
						!piece.IsAtStart &&
						playerIdx != r.PlayerTurnIdx {
						piece.Cell = BottomRightCorner
						piece.IsAtStart = true
						stomped = true
					}
					player.Pieces[pieceIdx] = piece
				}
			}
			finishCount := 0
			for _, p := range currentPlayer.Pieces {
				if p.IsFinished {
					finishCount++
				}
			}
			if finishCount == int(r.PieceCount) {
				r.Action = GameActionGameEnded
				err := broadcast(r, EndGameResponse{Winner: currentPlayer.Client.ID})
				if err != nil {
					log.Println(err)
				}
			} else {
				if stomped {
					currentPlayer.Client.Send(CallRollResponse{})
					r.Action = GameActionCanRoll
				} else if len(r.Rolls) == 0 {
					r.PlayerTurnIdx += 1
					r.PlayerTurnIdx %= len(r.Players)
					err := broadcast(r, EndTurnResponse{NextPlayer: r.Players[r.PlayerTurnIdx].Client.ID})
					if err != nil {
						log.Println(err)
					}
					err = broadcast(r, BeginTurnResponse{})
					if err != nil {
						log.Println(err)
					}
					r.Players[r.PlayerTurnIdx].Client.Send(CallRollResponse{})
					r.Action = GameActionCanRoll
				} else {
					currentPlayer.Client.Send(SelectingMoveResponse{})
					r.Action = GameActionSelectingMove
					log.Println("Selecting Move")
				}
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
	client.EnterRoom(r)
}

func exit(r *Room, clientID ClientID, kicked bool) error {
	clientCount := len(r.Players)
	if clientCount == 0 {
		return nil
	}

	isInRoom := false

	for idx, p := range r.Players {
		if p.Client.ID == clientID {
			isInRoom = true
			if kicked {
				p.Client.ExitRoom()
			}
			r.Players[idx], r.Players[clientCount-1] = r.Players[clientCount-1], r.Players[idx]
			break
		}
	}

	if !isInRoom {
		return nil
	}

	masterID := ClientID("")

	if clientCount-1 > 0 {
		masterIdx := rand.Int31n(int32(clientCount) - 1)
		r.Master = r.Players[masterIdx].Client
		masterID = r.Master.ID
	}

	err := broadcast(r, PlayerLeftResponse{Master: masterID, Player: clientID, Kicked: kicked})
	if err != nil {
		return err
	}

	r.Players = r.Players[:clientCount-1]
	if r.Action != GameActionGameEnded {
		reset(r)
	}
	return nil
}

func reset(r *Room) {
	r.Action = GameActionGameEnded
	for playerIdx := range r.Players {
		r.Players[playerIdx].IsReady = false
		for pieceIdx := 0; pieceIdx < MaxPieceCountInRoom; pieceIdx++ {
			r.Players[playerIdx].Pieces[pieceIdx] = Piece{
				Cell:       BottomRightCorner,
				IsAtStart:  true,
				IsFinished: false,
			}
		}
	}
}

func roll(r *Room) (int, bool) {
	n := rand.Intn(7) - 1
	shouldAppend := true
	if n == 0 {
		shouldAppend = false
		r.Rolls = r.Rolls[:0]
	}
	player := r.Players[r.PlayerTurnIdx]
	IsAllPiecesAtStart := true
	for _, piece := range player.Pieces {
		if !piece.IsAtStart {
			IsAllPiecesAtStart = false
			break
		}
	}
	if n == -1 && IsAllPiecesAtStart && len(r.Rolls) == 0 {
		shouldAppend = false
	}
	if shouldAppend {
		r.Rolls = append(r.Rolls, n)
	}
	return n, shouldAppend
}

func getNextCell(id CellID, AtStartPosition bool) (CellID, bool) {
	switch id {
	case BottomRightCorner:
		if AtStartPosition {
			return Right0, false
		}
		return BottomRightCorner, true
	case Right0:
		return Right1, false
	case Right1:
		return Right2, false
	case Right2:
		return Right3, false
	case Right3:
		return TopRightCorner, false
	case TopRightCorner:
		return AntiDiagonal0, false
	case Top0:
		return Top1, false
	case Top1:
		return Top2, false
	case Top2:
		return Top3, false
	case Top3:
		return TopLeftCorner, false
	case TopLeftCorner:
		return MainDiagonal0, false
	case Left0:
		return Left1, false
	case Left1:
		return Left2, false
	case Left2:
		return Left3, false
	case Left3:
		return BottomLeftCorner, false
	case BottomLeftCorner:
		return Bottom0, false
	case Bottom0:
		return Bottom1, false
	case Bottom1:
		return Bottom2, false
	case Bottom2:
		return Bottom3, false
	case Bottom3:
		return BottomRightCorner, false
	case MainDiagonal0:
		return MainDiagonal1, false
	case MainDiagonal1:
		return Center, false
	case MainDiagonal2:
		return MainDiagonal3, false
	case MainDiagonal3:
		return BottomRightCorner, false
	case AntiDiagonal0:
		return AntiDiagonal1, false
	case AntiDiagonal1:
		return Center, false
	case AntiDiagonal2:
		return AntiDiagonal3, false
	case AntiDiagonal3:
		return BottomLeftCorner, false
	case Center:
		return MainDiagonal2, false
	}
	return BottomRightCorner, false
}

func getNextPassingCell(prev CellID, id CellID) (CellID, bool) {
	switch id {
	case BottomRightCorner:
		return BottomRightCorner, true
	case Right0:
		return Right1, false
	case Right1:
		return Right2, false
	case Right2:
		return Right3, false
	case Right3:
		return TopRightCorner, false
	case TopRightCorner:
		return Top0, false
	case Top0:
		return Top1, false
	case Top1:
		return Top2, false
	case Top2:
		return Top3, false
	case Top3:
		return TopLeftCorner, false
	case TopLeftCorner:
		return Left0, false
	case Left0:
		return Left1, false
	case Left1:
		return Left2, false
	case Left2:
		return Left3, false
	case Left3:
		return BottomLeftCorner, false
	case BottomLeftCorner:
		return Bottom0, false
	case Bottom0:
		return Bottom1, false
	case Bottom1:
		return Bottom2, false
	case Bottom2:
		return Bottom3, false
	case Bottom3:
		return BottomRightCorner, false
	case MainDiagonal0:
		return MainDiagonal1, false
	case MainDiagonal1:
		return Center, false
	case MainDiagonal2:
		return MainDiagonal3, false
	case MainDiagonal3:
		return BottomRightCorner, false
	case AntiDiagonal0:
		return AntiDiagonal1, false
	case AntiDiagonal1:
		return Center, false
	case AntiDiagonal2:
		return AntiDiagonal3, false
	case AntiDiagonal3:
		return BottomLeftCorner, false
	case Center:
		if prev == MainDiagonal1 {
			return MainDiagonal2, false
		} else if prev == AntiDiagonal1 {
			return AntiDiagonal2, false
		}
	}
	return BottomRightCorner, false
}

func getPrevCell(id CellID) (CellID, CellID) {
	switch id {
	case BottomRightCorner:
		return Bottom3, MainDiagonal3
	case Right0:
		return BottomRightCorner, BottomRightCorner
	case Right1:
		return Right0, Right0
	case Right2:
		return Right1, Right1
	case Right3:
		return Right2, Right2
	case TopRightCorner:
		return Right3, Right3
	case Top0:
		return TopRightCorner, TopRightCorner
	case Top1:
		return Top0, Top0
	case Top2:
		return Top1, Top1
	case Top3:
		return Top2, Top2
	case TopLeftCorner:
		return Top3, Top3
	case Left0:
		return TopLeftCorner, TopLeftCorner
	case Left1:
		return Left0, Left0
	case Left2:
		return Left1, Left1
	case Left3:
		return Left2, Left2
	case BottomLeftCorner:
		return Left3, AntiDiagonal3
	case Bottom0:
		return BottomLeftCorner, BottomLeftCorner
	case Bottom1:
		return Bottom0, Bottom0
	case Bottom2:
		return Bottom1, Bottom1
	case Bottom3:
		return Bottom2, Bottom2
	case MainDiagonal0:
		return TopLeftCorner, TopLeftCorner
	case MainDiagonal1:
		return MainDiagonal0, MainDiagonal0
	case MainDiagonal2:
		return Center, Center
	case MainDiagonal3:
		return MainDiagonal2, MainDiagonal2
	case AntiDiagonal0:
		return TopRightCorner, TopRightCorner
	case AntiDiagonal1:
		return AntiDiagonal0, AntiDiagonal0
	case AntiDiagonal2:
		return Center, Center
	case AntiDiagonal3:
		return AntiDiagonal2, AntiDiagonal2
	case Center:
		return MainDiagonal1, AntiDiagonal1
	}
	return BottomRightCorner, BottomRightCorner
}

func getMoveSeq(piece Piece, roll int) ([]CellID, []CellID, bool) {
	var (
		seq0 []CellID
		seq1 []CellID
	)
	if roll == -1 {
		if !piece.IsAtStart {
			back0, back1 := getPrevCell(piece.Cell)
			seq0 = append(seq0, back0)
			if back1 != back0 {
				seq1 = append(seq1, back1)
			}
		}
		return seq0, seq1, false
	}

	prev_cell := piece.Cell
	next_cell, finish := getNextCell(piece.Cell, piece.IsAtStart)
	seq0 = append(seq0, next_cell)
	if finish {
		return seq0, seq1, true
	}
	for i := 1; i < int(roll); i += 1 {
		cell, finish := getNextPassingCell(prev_cell, seq0[i-1])
		prev_cell = seq0[i-1]
		seq0 = append(seq0, cell)
		if finish {
			return seq0, seq1, true
		}
	}
	return seq0, seq1, false
}
