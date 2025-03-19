.PHONY: build_client
build_client:
	@odin build client -debug -out=./bin/yutnori.exe

.PHONY: run_client
run_client: build_client
	@./bin/yutnori

.PHONY: build_server
build_server:
	@go build -o ./bin/yutnori_server ./server

.PHONY: run_server
run_server: build_server
	@./bin/yutnori_server