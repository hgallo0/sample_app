package main

import (
	"encoding/json"
	"log"
	"math/rand"
	"net/http"
	"os"
)

var moves = []string{"rock", "paper", "scissors"}

// beats[a][b] is true when move a defeats move b.
var beats = map[string]string{
	"rock":     "scissors",
	"paper":    "rock",
	"scissors": "paper",
}

type playRequest struct {
	Move string `json:"move"`
}

type playResponse struct {
	PlayerMove   string `json:"player_move"`
	ComputerMove string `json:"computer_move"`
	Result       string `json:"result"` // "win", "lose", or "tie"
}

func isValidMove(m string) bool {
	for _, v := range moves {
		if v == m {
			return true
		}
	}
	return false
}

func handlePlay(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req playRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}
	if !isValidMove(req.Move) {
		http.Error(w, "move must be one of: rock, paper, scissors", http.StatusBadRequest)
		return
	}

	computerMove := moves[rand.Intn(len(moves))]

	result := "tie"
	if req.Move != computerMove {
		if beats[req.Move] == computerMove {
			result = "win"
		} else {
			result = "lose"
		}
	}

	resp := playResponse{
		PlayerMove:   req.Move,
		ComputerMove: computerMove,
		Result:       result,
	}

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(resp)
}

func handleHealthz(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("ok"))
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	http.HandleFunc("/play", handlePlay)
	http.HandleFunc("/healthz", handleHealthz)

	log.Printf("game-engine listening on :%s", port)
	log.Fatal(http.ListenAndServe(":"+port, nil))
}
