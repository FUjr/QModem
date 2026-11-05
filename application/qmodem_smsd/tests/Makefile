CC ?= cc
CFLAGS ?= -O2 -g -Wall -Wextra -Werror -std=gnu11
SQLITE_INCLUDE ?= /usr/include
SQLITE_LIB ?= -lsqlite3
JSON_INCLUDE ?= /usr/include
JSON_LIB ?= -ljson-c

.PHONY: all daemon clean

all: test_sms_db test_legacy_migrate test_tom_response
	./test_sms_db
	./test_legacy_migrate
	./test_tom_response

test_sms_db: test_sms_db.c ../src/sms_db.c
	$(CC) $(CFLAGS) -I../src -I$(SQLITE_INCLUDE) $^ $(SQLITE_LIB) -o $@

test_legacy_migrate: test_legacy_migrate.c ../src/sms_db.c ../src/legacy_migrate.c
	$(CC) $(CFLAGS) -I../src -I$(SQLITE_INCLUDE) -I$(JSON_INCLUDE) $^ $(SQLITE_LIB) $(JSON_LIB) -o $@

test_tom_response: test_tom_response.c ../src/tom_response.c
	$(CC) $(CFLAGS) -I../src -I$(JSON_INCLUDE) $^ $(JSON_LIB) -o $@

# Optional integration target, with native libubus/libuci/libubox installed.
daemon: test_sms_daemon
	./test_sms_daemon

test_sms_daemon: test_sms_daemon.c ../src/main.c ../src/sms_db.c ../src/legacy_migrate.c ../src/tom_response.c
	$(CC) $(CPPFLAGS) $(CFLAGS) -D_GNU_SOURCE -I../src -I../../libqmodem-sms/src \
		-I$(SQLITE_INCLUDE) -I$(JSON_INCLUDE) $(filter-out ../src/main.c,$^) \
		../../libqmodem-sms/src/pdu.c ../../libqmodem-sms/src/ucs2_to_utf8.c \
		$(LDFLAGS) -lubus -lubox -lblobmsg_json -luci $(SQLITE_LIB) $(JSON_LIB) -o $@

clean:
	rm -f test_sms_db test_legacy_migrate test_tom_response test_sms_daemon
