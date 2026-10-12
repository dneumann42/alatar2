.PHONY: run

bin/alatar:
	./setup
	nimble build

run: bin/alatar
	./bin/alatar
