package main

import (
	"flag"
	"fmt"
	"log"
	"net"
)

type Config struct {
	Port int
}

type Server struct {
	Config Config
}

func NewServer(cfg Config) *Server {
	return &Server{
		Config: cfg,
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

	hub := NewHub()
	go hub.HandleClients()

	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Println(err)
			continue
		}
		hub.RegisterClient(conn)
	}
}

func main() {
	log.SetFlags(log.Llongfile | log.LUTC)

	cfg := Config{}
	flag.IntVar(&cfg.Port, "port", 42069, "port of the server")
	flag.Parse()
	srv := NewServer(cfg)
	err := srv.Start()
	if err != nil {
		log.Fatal(err)
	}
}
