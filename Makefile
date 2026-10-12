.PHONY: run

NIM_SOURCES := $(shell find src -name '*.nim')

bin/alatar: $(NIM_SOURCES)
	@if [ ! -x bin/alatar ]; then ./setup; fi
	nimble build

run: bin/alatar
	./bin/alatar
