package main

import (
	"log"
	"math/rand"
)

const MaxPieceCountInRoom = 6
const MinPieceCountInRoom = 2

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

type Move struct {
	Roll  int
	Cell  CellID
	Piece int
}

type GameState uint8

const (
	GameStateGameEnded GameState = iota
	GameStateGameStarted
	GameStateBeginTurn
	GameStateEndTurn
	GameStateCanRoll
	GameStateBeginRoll
	GameStateEndRoll
	GameStateBeginMove
	GameStateEndMove
	GameStateSelectingMove
)

type PlayerState struct {
	Client  *Client
	IsReady bool
	Pieces  [MaxPieceCountInRoom]Piece
}

type GameInstance struct {
	Players             []PlayerState
	PieceCount          uint8
	GameState           GameState
	PlayerTurnIdx       int
	Rolls               []int
	EndMoveSet          map[*Client]struct{}
	CurrentMove         Move
	CurrentMoveFinishes bool
}

func NewGameInstance() *GameInstance {
	return &GameInstance{
		PieceCount: MinPieceCountInRoom,
		GameState:  GameStateGameEnded,
		EndMoveSet: make(map[*Client]struct{}),
	}
}

func (g *GameInstance) GetClientIndex(c *Client) int {
	for idx, p := range g.Players {
		if p.Client == c {
			return idx
		}
	}
	return -1
}

func (g *GameInstance) IsClientInRoom(c *Client) bool {
	idx := g.GetClientIndex(c)
	return idx != -1
}

func (g *GameInstance) Start(room *Room) {
	if g.GameState != GameStateGameEnded {
		log.Printf("illegal move action should be %d got %d\n", GameStateGameEnded, g.GameState)
		return
	}

	readyCount := 0
	for _, p := range g.Players {
		if p.IsReady {
			readyCount++
		}
	}

	if readyCount != len(g.Players) {
		room.Broadcast(StartGameResponse{})
		return
	}

	g.Reset()
	g.PlayerTurnIdx = rand.Intn(len(g.Players))
	err := room.Broadcast(StartGameResponse{
		ShouldStart:    true,
		StartingPlayer: g.Players[g.PlayerTurnIdx].Client.ID,
	})
	if err != nil {
		log.Println(err)
	}
	err = room.Broadcast(BeginTurnResponse{})
	if err != nil {
		log.Println(err)
	}
	g.Players[g.PlayerTurnIdx].Client.Send(CallRollResponse{})
	g.GameState = GameStateCanRoll
}

func (g *GameInstance) Reset() {
	g.GameState = GameStateGameEnded
	for playerIdx := range g.Players {
		g.Players[playerIdx].IsReady = false
		for pieceIdx := 0; pieceIdx < MaxPieceCountInRoom; pieceIdx++ {
			g.Players[playerIdx].Pieces[pieceIdx] = Piece{
				Cell:       BottomRightCorner,
				IsAtStart:  true,
				IsFinished: false,
			}
		}
	}
}

func (g *GameInstance) Roll() (int, bool) {
	n := rand.Intn(7) - 1
	shouldAppend := true
	if n == 0 {
		shouldAppend = false
		g.Rolls = g.Rolls[:0]
	}
	player := g.Players[g.PlayerTurnIdx]
	IsAllPiecesAtStart := true
	for _, piece := range player.Pieces {
		if !piece.IsAtStart {
			IsAllPiecesAtStart = false
			break
		}
	}
	if n == -1 && IsAllPiecesAtStart && len(g.Rolls) == 0 {
		shouldAppend = false
	}
	if shouldAppend {
		g.Rolls = append(g.Rolls, n)
	}
	return n, shouldAppend
}

type SetPieceCountGameAction struct {
	PieceCount uint8
}

func (s SetPieceCountGameAction) Execute(c *Client, r *Room) {
	instance := r.GameInstance
	if instance.GameState != GameStateGameEnded || c != r.Master {
		c.Send(SetPieceResponse{ShouldSet: false})
		return
	}
	instance.PieceCount = s.PieceCount
	err := r.Broadcast(SetPieceResponse{ShouldSet: true, PieceCount: s.PieceCount})
	if err != nil {
		log.Println(err)
	}
}

type BeginRollGameAction struct {
}

func (b BeginRollGameAction) Execute(c *Client, r *Room) {
	instance := r.GameInstance
	if instance.GameState != GameStateCanRoll {
		log.Printf("illegal move action should be %d got %d\n", GameStateCanRoll, instance.GameState)
		return
	}
	player := &instance.Players[instance.PlayerTurnIdx]
	if player.Client != c {
		log.Printf("permission denied action should be from client '%s' but got '%s'\n", player.Client.ID, c.ID)
		return
	}
	n, shouldAppend := instance.Roll()
	err := r.Broadcast(EndRollResponse{ShouldAppend: shouldAppend, Roll: n})
	if err != nil {
		log.Println(err)
	}
	if n == 4 || n == 5 {
		c.Send(CallRollResponse{})
		instance.GameState = GameStateCanRoll
	} else if len(instance.Rolls) == 0 {
		instance.PlayerTurnIdx += 1
		instance.PlayerTurnIdx %= len(instance.Players)
		err := r.Broadcast(EndTurnResponse{NextPlayer: instance.Players[instance.PlayerTurnIdx].Client.ID})
		if err != nil {
			log.Println(err)
		}
		err = r.Broadcast(BeginTurnResponse{})
		if err != nil {
			log.Println(err)
		}
		instance.Players[instance.PlayerTurnIdx].Client.Send(CallRollResponse{})
		instance.GameState = GameStateCanRoll
	} else {
		c.Send(SelectingMoveResponse{})
		if err != nil {
			log.Println(err)
		}
		instance.GameState = GameStateSelectingMove
	}
}

type BeginMoveGameAction struct {
	Move
}

func (b BeginMoveGameAction) Execute(c *Client, r *Room) {
	instance := r.GameInstance
	if instance.GameState != GameStateSelectingMove { // illegal
		log.Println("illegal", instance.GameState)
		c.Send(BeginMoveRespone{})
		return
	}
	currentPlayer := &instance.Players[instance.PlayerTurnIdx]
	if currentPlayer.Client != c || b.Piece >= int(instance.PieceCount) { // illegal
		log.Println("illegal")
		c.Send(BeginMoveRespone{})
		return
	}
	pieceToMove := currentPlayer.Pieces[b.Piece]
	log.Printf("Piece: %+v\n", pieceToMove)
	if pieceToMove.IsFinished { // illiegal
		log.Println("illegal")
		c.Send(BeginMoveRespone{})
		return
	}

	rollIdx := -1
	for idx, roll := range instance.Rolls {
		if roll == b.Roll {
			rollIdx = idx
			break
		}
	}

	if rollIdx == -1 { // illegal
		log.Println("illegal")
		c.Send(BeginMoveRespone{})
		return
	}

	seq0, seq1, finished := getMoveSeq(pieceToMove, b.Roll)
	isValidMove := false
	if len(seq0) != 0 && seq0[len(seq0)-1] == b.Cell {
		isValidMove = true
	}
	if len(seq1) != 0 && seq0[len(seq1)-1] == b.Cell {
		isValidMove = true
	}
	if !isValidMove { // illegal
		log.Println("illegal")
		r.Broadcast(BeginMoveRespone{})
		return
	}
	instance.Rolls = append(instance.Rolls[:rollIdx], instance.Rolls[rollIdx+1:]...)

	clear(instance.EndMoveSet)

	instance.CurrentMove = b.Move
	instance.CurrentMoveFinishes = finished
	err := r.Broadcast(BeginMoveRespone{
		ShouldMove: true,
		Roll:       b.Roll,
		Cell:       b.Cell,
		Piece:      b.Piece,
		Finished:   finished,
	})
	if err != nil {
		log.Println(err)
	}
	instance.GameState = GameStateBeginMove
}

type EndMoveGameAction struct {
	Move
}

func (e EndMoveGameAction) Execute(c *Client, r *Room) {
	instance := r.GameInstance
	if instance.GameState != GameStateBeginMove {
		log.Println("illegal")
		return
	}
	IsInRoom := false
	for _, p := range instance.Players {
		if c == p.Client {
			IsInRoom = true
			break
		}
	}

	if !IsInRoom || e.Move != instance.CurrentMove {
		log.Println("illegal")
		return
	}

	instance.EndMoveSet[c] = struct{}{}
	if len(instance.EndMoveSet) != len(instance.Players) {
		return
	}

	log.Println("EndMove...")

	currentPlayer := &instance.Players[instance.PlayerTurnIdx]
	pieceToMove := currentPlayer.Pieces[instance.CurrentMove.Piece]

	// moving pieces
	if pieceToMove.IsAtStart {
		pieceToMove.IsFinished = false
		pieceToMove.Cell = e.Cell
		pieceToMove.IsAtStart = false
		currentPlayer.Pieces[e.Piece] = pieceToMove
	} else {
		for pieceIdx := 0; pieceIdx < int(instance.PieceCount); pieceIdx++ {
			piece := currentPlayer.Pieces[pieceIdx]
			if piece.IsFinished {
				continue
			}
			if piece.Cell == pieceToMove.Cell && !piece.IsAtStart {
				piece.Cell = e.Cell
				piece.IsFinished = instance.CurrentMoveFinishes
			}
			currentPlayer.Pieces[pieceIdx] = piece
		}
	}

	// stomping an opponent piece
	stomped := false
	for playerIdx := 0; playerIdx < len(instance.Players); playerIdx++ {
		player := &instance.Players[playerIdx]
		for pieceIdx := 0; pieceIdx < int(instance.PieceCount); pieceIdx++ {
			piece := player.Pieces[pieceIdx]
			if piece.IsFinished {
				continue
			}
			if piece.Cell == e.Cell &&
				!piece.IsAtStart &&
				playerIdx != instance.PlayerTurnIdx {
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
	if finishCount == int(r.GameInstance.PieceCount) {
		r.GameInstance.GameState = GameStateGameEnded
		err := r.Broadcast(EndGameResponse{Winner: currentPlayer.Client.ID})
		if err != nil {
			log.Println(err)
		}
	} else {
		if stomped {
			currentPlayer.Client.Send(CallRollResponse{})
			r.GameInstance.GameState = GameStateCanRoll
		} else if len(r.GameInstance.Rolls) == 0 {
			r.GameInstance.PlayerTurnIdx += 1
			r.GameInstance.PlayerTurnIdx %= len(r.GameInstance.Players)
			err := r.Broadcast(EndTurnResponse{NextPlayer: r.GameInstance.Players[r.GameInstance.PlayerTurnIdx].Client.ID})
			if err != nil {
				log.Println(err)
			}
			err = r.Broadcast(BeginTurnResponse{})
			if err != nil {
				log.Println(err)
			}
			r.GameInstance.Players[r.GameInstance.PlayerTurnIdx].Client.Send(CallRollResponse{})
			r.GameInstance.GameState = GameStateCanRoll
		} else {
			currentPlayer.Client.Send(SelectingMoveResponse{})
			r.GameInstance.GameState = GameStateSelectingMove
		}
	}
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
