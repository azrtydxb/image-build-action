package main

import (
	"fmt"
	"runtime"
)

var msg string

func main() { fmt.Println("hello from", runtime.GOARCH, msg) }
