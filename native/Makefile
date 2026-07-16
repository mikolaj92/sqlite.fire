CC ?= cc
CFLAGS ?= -O2 -fPIC -I$(SDKROOT)/usr/include
LDFLAGS ?=

BUILD_DIR ?= .native-tests
STRICT_FLAGS = -std=c11 -Wall -Wextra -Werror
SANITIZER_FLAGS = -fsanitize=address,undefined -fno-omit-frame-pointer
NATIVE_TEST_NAMES = native_callbacks native_vfs

UNAME_S := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
  SHARED = libsqlite_fire.dylib
  SHARED_FLAGS = -dynamiclib
else
  SHARED = libsqlite_fire.so
  SHARED_FLAGS = -shared
endif

all: $(SHARED)

strict: strict-build

strict-build: | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(STRICT_FLAGS) $(SHARED_FLAGS) -o $(BUILD_DIR)/$(SHARED) sqlite_fire.c -lsqlite3 $(LDFLAGS)

strict-test: $(addprefix $(BUILD_DIR)/,$(NATIVE_TEST_NAMES))
	@set -eu; for test in $(NATIVE_TEST_NAMES); do ./$(BUILD_DIR)/$$test; done

test: strict-test

sanitize: | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(STRICT_FLAGS) $(SANITIZER_FLAGS) -I. -o $(BUILD_DIR)/native_callbacks_sanitize ../tests/native_callbacks.c sqlite_fire.c -lsqlite3 $(LDFLAGS)
	$(CC) $(CFLAGS) $(STRICT_FLAGS) $(SANITIZER_FLAGS) -I. -o $(BUILD_DIR)/native_vfs_sanitize ../tests/native_vfs.c sqlite_fire.c -lsqlite3 $(LDFLAGS)
	@set -eu; ./$(BUILD_DIR)/native_callbacks_sanitize; ./$(BUILD_DIR)/native_vfs_sanitize

$(BUILD_DIR):
	mkdir -p $@

$(BUILD_DIR)/native_callbacks: ../tests/native_callbacks.c sqlite_fire.c sqlite_fire.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(STRICT_FLAGS) -I. -o $@ ../tests/native_callbacks.c sqlite_fire.c -lsqlite3 $(LDFLAGS)

$(BUILD_DIR)/native_vfs: ../tests/native_vfs.c sqlite_fire.c sqlite_fire.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(STRICT_FLAGS) -I. -o $@ ../tests/native_vfs.c sqlite_fire.c -lsqlite3 $(LDFLAGS)

$(SHARED): sqlite_fire.c sqlite_fire.h
	$(CC) $(CFLAGS) $(SHARED_FLAGS) -o $@ sqlite_fire.c -lsqlite3 $(LDFLAGS)

clean:
	rm -rf libsqlite_fire.dylib libsqlite_fire.so $(BUILD_DIR)
