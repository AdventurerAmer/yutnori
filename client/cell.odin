package client

SIDE_CELL_COUNT :: 4
CELL_COUNT :: SIDE_CELL_COUNT * 6 + 5

Cell_ID :: enum {
	BottomRightCorner,
	Right0,
	Right1,
	Right2,
	Right3,
	TopRightCorner,
	Top0,
	Top1,
	Top2,
	Top3,
	TopLeftCorner,
	Left0,
	Left1,
	Left2,
	Left3,
	BottomLeftCorner,
	Bottom0,
	Bottom1,
	Bottom2,
	Bottom3,
	MainDiagonal0,
	MainDiagonal1,
	MainDiagonal2,
	MainDiagonal3,
	AntiDiagonal0,
	AntiDiagonal1,
	AntiDiagonal2,
	AntiDiagonal3,
	Center,
}

#assert(len(Cell_ID) == CELL_COUNT)

get_next_cell :: proc(id: Cell_ID, at_start_position := false) -> (Cell_ID, bool) {
	switch id {
	case .BottomRightCorner:
		if at_start_position {
			return .Right0, false
		}
		return .BottomRightCorner, true
	case .Right0:
		return .Right1, false
	case .Right1:
		return .Right2, false
	case .Right2:
		return .Right3, false
	case .Right3:
		return .TopRightCorner, false
	case .TopRightCorner:
		return .AntiDiagonal0, false
	case .Top0:
		return .Top1, false
	case .Top1:
		return .Top2, false
	case .Top2:
		return .Top3, false
	case .Top3:
		return .TopLeftCorner, false
	case .TopLeftCorner:
		return .MainDiagonal0, false
	case .Left0:
		return .Left1, false
	case .Left1:
		return .Left2, false
	case .Left2:
		return .Left3, false
	case .Left3:
		return .BottomLeftCorner, false
	case .BottomLeftCorner:
		return .Bottom0, false
	case .Bottom0:
		return .Bottom1, false
	case .Bottom1:
		return .Bottom2, false
	case .Bottom2:
		return .Bottom3, false
	case .Bottom3:
		return .BottomRightCorner, false
	case .MainDiagonal0:
		return .MainDiagonal1, false
	case .MainDiagonal1:
		return .Center, false
	case .MainDiagonal2:
		return .MainDiagonal3, false
	case .MainDiagonal3:
		return .BottomRightCorner, false
	case .AntiDiagonal0:
		return .AntiDiagonal1, false
	case .AntiDiagonal1:
		return .Center, false
	case .AntiDiagonal2:
		return .AntiDiagonal3, false
	case .AntiDiagonal3:
		return .BottomLeftCorner, false
	case .Center:
		return .MainDiagonal2, false
	}
	return .BottomRightCorner, false
}

get_next_passing_cell :: proc(prev: Cell_ID, id: Cell_ID) -> (Cell_ID, bool) {
	switch id {
	case .BottomRightCorner:
		return .BottomRightCorner, true
	case .Right0:
		return .Right1, false
	case .Right1:
		return .Right2, false
	case .Right2:
		return .Right3, false
	case .Right3:
		return .TopRightCorner, false
	case .TopRightCorner:
		return .Top0, false
	case .Top0:
		return .Top1, false
	case .Top1:
		return .Top2, false
	case .Top2:
		return .Top3, false
	case .Top3:
		return .TopLeftCorner, false
	case .TopLeftCorner:
		return .Left0, false
	case .Left0:
		return .Left1, false
	case .Left1:
		return .Left2, false
	case .Left2:
		return .Left3, false
	case .Left3:
		return .BottomLeftCorner, false
	case .BottomLeftCorner:
		return .Bottom0, false
	case .Bottom0:
		return .Bottom1, false
	case .Bottom1:
		return .Bottom2, false
	case .Bottom2:
		return .Bottom3, false
	case .Bottom3:
		return .BottomRightCorner, false
	case .MainDiagonal0:
		return .MainDiagonal1, false
	case .MainDiagonal1:
		return .Center, false
	case .MainDiagonal2:
		return .MainDiagonal3, false
	case .MainDiagonal3:
		return .BottomRightCorner, false
	case .AntiDiagonal0:
		return .AntiDiagonal1, false
	case .AntiDiagonal1:
		return .Center, false
	case .AntiDiagonal2:
		return .AntiDiagonal3, false
	case .AntiDiagonal3:
		return .BottomLeftCorner, false
	case .Center:
		if prev == .MainDiagonal1 {
			return .MainDiagonal2, false
		} else if prev == .AntiDiagonal1 {
			return .AntiDiagonal2, false
		}
	}
	return .BottomRightCorner, false
}

get_prev_cell :: proc(id: Cell_ID) -> (Cell_ID, Cell_ID) {
	switch id {
	case .BottomRightCorner:
		return .Bottom3, .MainDiagonal3
	case .Right0:
		return .BottomRightCorner, .BottomRightCorner
	case .Right1:
		return .Right0, .Right0
	case .Right2:
		return .Right1, .Right1
	case .Right3:
		return .Right2, .Right2
	case .TopRightCorner:
		return .Right3, .Right3
	case .Top0:
		return .TopRightCorner, .TopRightCorner
	case .Top1:
		return .Top0, .Top0
	case .Top2:
		return .Top1, .Top1
	case .Top3:
		return .Top2, .Top2
	case .TopLeftCorner:
		return .Top3, .Top3
	case .Left0:
		return .TopLeftCorner, .TopLeftCorner
	case .Left1:
		return .Left0, .Left0
	case .Left2:
		return .Left1, .Left1
	case .Left3:
		return .Left2, .Left2
	case .BottomLeftCorner:
		return .Left3, .AntiDiagonal3
	case .Bottom0:
		return .BottomLeftCorner, .BottomLeftCorner
	case .Bottom1:
		return .Bottom0, .Bottom0
	case .Bottom2:
		return .Bottom1, .Bottom1
	case .Bottom3:
		return .Bottom2, .Bottom2
	case .MainDiagonal0:
		return .TopLeftCorner, .TopLeftCorner
	case .MainDiagonal1:
		return .MainDiagonal0, .MainDiagonal0
	case .MainDiagonal2:
		return .Center, .Center
	case .MainDiagonal3:
		return .MainDiagonal2, .MainDiagonal2
	case .AntiDiagonal0:
		return .TopRightCorner, .TopRightCorner
	case .AntiDiagonal1:
		return .AntiDiagonal0, .AntiDiagonal0
	case .AntiDiagonal2:
		return .Center, .Center
	case .AntiDiagonal3:
		return .AntiDiagonal2, .AntiDiagonal2
	case .Center:
		return .MainDiagonal1, .AntiDiagonal1
	}
	return .BottomRightCorner, .BottomRightCorner
}

select_cell_radius :: proc(cell: Cell_ID, side_radius: f32, center_and_corner_radius: f32) -> f32 {
	result := side_radius
	if cell == .Center ||
	   cell == .TopLeftCorner ||
	   cell == .TopRightCorner ||
	   cell == .BottomLeftCorner ||
	   cell == .BottomRightCorner {
		result = center_and_corner_radius
	}
	return result
}

get_move_sequance :: proc(
	piece: Piece,
	roll: i32,
	allocator := context.temp_allocator,
) -> (
	[dynamic]Cell_ID,
	[dynamic]Cell_ID,
	bool,
) {
	seq0 := make([dynamic]Cell_ID, 0, allocator)
	seq1 := make([dynamic]Cell_ID, 0, allocator)

	at_start := is_piece_at_start(piece)

	if roll == -1 && !at_start {
		back0, back1 := get_prev_cell(piece.cell)
		append(&seq0, back0)
		if back1 != back0 {
			append(&seq1, back1)
		}
	}

	prev_cell := piece.cell
	next_cell, finish := get_next_cell(piece.cell, at_start)
	append(&seq0, next_cell)
	if finish {
		return seq0, seq1, true
	}

	for i := 1; i < int(roll); i += 1 {
		cell, finish := get_next_passing_cell(prev_cell, seq0[i - 1])
		prev_cell = seq0[i - 1]
		append(&seq0, cell)
		if finish {
			return seq0, seq1, true
		}
	}
	return seq0, seq1, false
}
