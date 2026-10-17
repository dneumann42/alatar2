.PHONY: run

# Ensure the Nim toolchain is discoverable even in non-interactive shells
# (e.g. when make is invoked without ~/.local/bin on PATH).
export PATH := $(HOME)/.local/share/nim/bin:$(HOME)/.local/bin:$(PATH)

NIM_SOURCES := $(shell find src -name '*.nim')

bin/alatar: $(NIM_SOURCES)
	nimble build

run: bin/alatar
	./bin/alatar
