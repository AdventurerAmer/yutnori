.PHONY: build
build:
	@odin build client -debug -out=./bin/yutnori.exe

.PHONY: run
run: build
	@./bin/yutnori