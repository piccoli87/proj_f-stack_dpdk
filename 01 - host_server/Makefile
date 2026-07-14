FF_PATH ?= /opt/f-stack
PKGCONF ?= pkg-config

SERVER_CFLAGS = -O0 -g -gdwarf-2 -Wall $(shell $(PKGCONF) --cflags libdpdk 2>/dev/null)
SERVER_LIBS   = $(shell $(PKGCONF) --static --libs libdpdk 2>/dev/null)
SERVER_LIBS  += -L${FF_PATH}/lib -Wl,--whole-archive,-lfstack,--no-whole-archive
SERVER_LIBS  += -Wl,--no-whole-archive -lrt -lm -ldl -lcrypto -lz -pthread -lnuma

.PHONY: all server client clean

# server precisa de DPDK/F-Stack instalados (roda na maquina com a NIC bindada).
# client e um socket TCP comum e compila em qualquer maquina, sem DPDK.
all: server client

server:
	@$(PKGCONF) --exists libdpdk || (echo "No installation of DPDK found, maybe you should export PKG_CONFIG_PATH=/usr/local/lib/x86_64-linux-gnu/pkgconfig" >&2; exit 1)
	cc ${SERVER_CFLAGS} -DINET6 -o server server.c ${SERVER_LIBS}

client:
	cc -O2 -Wall -o client client.c

clean:
	rm -f server client
