PRODUCT := build/headless-shortcuts
SOURCES := Sources/HeadlessShortcuts/main.m

.PHONY: all clean test

all: $(PRODUCT)

$(PRODUCT): $(SOURCES)
	mkdir -p build
	clang -fobjc-arc -fblocks -Wall -Wextra -framework Foundation -lsqlite3 $(SOURCES) -o $(PRODUCT)

test: $(PRODUCT)
	scripts/smoke-import-copy.sh

clean:
	rm -rf build
