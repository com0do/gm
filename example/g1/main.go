package main

import (
	"fmt"

	"example.com/g1/internal/greeter"
)

func main() {
	fmt.Println("--> g1_main")
	fmt.Println(greeter.Hello("cyrus"))
}
