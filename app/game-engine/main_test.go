package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHandlePlay_ValidMoves(t *testing.T) {
	for _, move := range moves {
		req := httptest.NewRequest(http.MethodPost, "/play", bytes.NewBufferString(`{"move":"`+move+`"}`))
		w := httptest.NewRecorder()

		handlePlay(w, req)

		if w.Code != http.StatusOK {
			t.Fatalf("move %q: expected 200, got %d", move, w.Code)
		}
		var resp playResponse
		if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
			t.Fatalf("move %q: invalid JSON response: %v", move, err)
		}
		if resp.PlayerMove != move {
			t.Errorf("move %q: player_move = %q", move, resp.PlayerMove)
		}
		if resp.Result != "win" && resp.Result != "lose" && resp.Result != "tie" {
			t.Errorf("move %q: unexpected result %q", move, resp.Result)
		}
		if resp.Result == "tie" && resp.ComputerMove != move {
			t.Errorf("move %q: tie result but computer_move = %q", move, resp.ComputerMove)
		}
	}
}

func TestHandlePlay_InvalidMove(t *testing.T) {
	req := httptest.NewRequest(http.MethodPost, "/play", bytes.NewBufferString(`{"move":"lizard"}`))
	w := httptest.NewRecorder()

	handlePlay(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", w.Code)
	}
}

func TestHandlePlay_InvalidJSON(t *testing.T) {
	req := httptest.NewRequest(http.MethodPost, "/play", bytes.NewBufferString(`not json`))
	w := httptest.NewRecorder()

	handlePlay(w, req)

	if w.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", w.Code)
	}
}

func TestHandlePlay_WrongMethod(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/play", nil)
	w := httptest.NewRecorder()

	handlePlay(w, req)

	if w.Code != http.StatusMethodNotAllowed {
		t.Fatalf("expected 405, got %d", w.Code)
	}
}

func TestBeatsIsConsistentRPS(t *testing.T) {
	// Every move beats exactly one other move, and no move beats itself.
	for _, m := range moves {
		beaten, ok := beats[m]
		if !ok {
			t.Fatalf("move %q has no entry in beats map", m)
		}
		if beaten == m {
			t.Errorf("move %q cannot beat itself", m)
		}
	}
}

func TestHandleHealthz(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	w := httptest.NewRecorder()

	handleHealthz(w, req)

	if w.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", w.Code)
	}
	if w.Body.String() != "ok" {
		t.Fatalf("expected body \"ok\", got %q", w.Body.String())
	}
}
