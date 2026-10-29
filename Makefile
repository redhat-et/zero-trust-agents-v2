.PHONY: lint test build

lint:
	golangci-lint run

test:
	go test ./...

build:
	go build -o bin/token-issuer ./token-issuer
	go build -o bin/document-service ./document-service
