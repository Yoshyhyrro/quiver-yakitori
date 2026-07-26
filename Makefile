.PHONY: all init build python-build clean test

all: build

init:
	bash init.bash

build:
	mkdir -p build
	cd build && cmake .. && cmake --build .

python-build: build
	python3 setup.py build_ext --inplace

test: build
	cd build && ctest --output-on-failure

clean:
	rm -rf build *.so *.egg-info build_python
	rm -f src/scheme/*.o src/scheme/*.import.scm