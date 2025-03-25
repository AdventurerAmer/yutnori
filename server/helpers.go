package main

import (
	"crypto/rand"
	"encoding/base32"
)

func generateUUID() string {
	b := make([]byte, 20)
	rand.Read(b)
	return base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(b)
}
