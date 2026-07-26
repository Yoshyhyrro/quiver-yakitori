.PHONY: all init build python-build clean test

all: build

init:
	bash init.bash

build:
	mkdir -p build
	cd build && cmake .. && cmake --build .

python-build: build
	python3 setup.py build_ext --inplace

# Execute cross-validation suite across all language boundaries
test-all: build test-scheme test-python
	@echo "--- All integration tests completed successfully ---"

# Execute unit tests for the Scheme and C bridge implementation
test-scheme: build
	@echo "--- Running C23/Scheme Implementation ---"
	./build/quiver_bridge

# Execute unit tests for the Python and PyTorch extensions
test-python: python-build
	@echo "--- Running Python PyTorch Implementation Tests ---"
	python3 tests/test_quiver.py

clean:
	rm -rf build *.so *.egg-info build_python
	rm -f src/scheme/*.o src/scheme/*.import.scm