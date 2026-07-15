CC ?= cc
CFLAGS ?= -O2 -fPIC -I$(SDKROOT)/usr/include
LDFLAGS ?=

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
  SHARED = libsqlite_fire.dylib
  SHARED_FLAGS = -dynamiclib
else
  SHARED = libsqlite_fire.so
  SHARED_FLAGS = -shared
endif

all: $(SHARED)

$(SHARED): sqlite_fire.c sqlite_fire.h
	$(CC) $(CFLAGS) $(SHARED_FLAGS) -o $@ sqlite_fire.c -lsqlite3 $(LDFLAGS)

clean:
	rm -f libsqlite_fire.dylib libsqlite_fire.so
