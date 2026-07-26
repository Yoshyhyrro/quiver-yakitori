.PHONY: all init build python-build clean test

all: build

init:
	bash init.bash

build:
	mkdir -p build
	cd build && cmake .. && cmake --build .

python-build: build
	python3 setup.py build_ext --inplace

test-all: build
	@echo "--- Running C23/Scheme Implementation ---"
	./build/quiver_bridge

clean:
	rm -rf build *.so *.egg-info build_python
	rm -f src/scheme/*.o src/scheme/*.import.scm