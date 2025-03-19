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
		} else {
			log.Printf("%v connected\n", conn.RemoteAddr())
		}
		go handleConn(conn)
	}
}

func handleConn(conn net.Conn) {
	defer func() {
		conn.Close()
		log.Printf("%v disconnected\n", conn.RemoteAddr())
	}()

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
