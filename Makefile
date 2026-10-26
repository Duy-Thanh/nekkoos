# NekkoOS is Pascal (FPC) + NASM, linked by lld. build.sh and run.sh are the
# real entry points; this Makefile only forwards to them.

all: build run

build:
	./build.sh

run:
	./run.sh

test:
	python3 test/automation/smoke_test.py
	python3 test/automation/extra_test.py
	python3 test/automation/hwcheck_test.py

verify:
	./verify_pascal_link.sh

clean:
	./clean.sh

.PHONY: all build run test verify clean
