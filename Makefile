PRODUCT := build/headless-shortcuts
SOURCES := Sources/HeadlessShortcuts/main.m

.PHONY: all clean

all: $(PRODUCT)

$(PRODUCT): $(SOURCES)
	mkdir -p build
	clang -fobjc-arc -fblocks -Wall -Wextra -framework Foundation -lsqlite3 $(SOURCES) -o $(PRODUCT)

clean:
	rm -rf build
