.phony: build

build:
	@$(RM) -Rf bin; \
	mkdir -p bin; \
	cp xdocker.sh bin/xdocker; \
	chmod +x bin/xdocker
	@echo "Binary available in bin/"
