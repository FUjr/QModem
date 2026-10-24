CC ?= cc
CFLAGS ?= -O2 -g -Wall -Wextra -Werror -std=gnu11

.PHONY: all clean
all: test_ucs2_parts test_phone_number
	./test_ucs2_parts
	./test_phone_number

test_ucs2_parts: test_ucs2_parts.c ../src/pdu.c ../src/ucs2_to_utf8.c
	$(CC) $(CFLAGS) -I../src $^ -o $@

test_phone_number: test_phone_number.c ../src/pdu.c ../src/ucs2_to_utf8.c
	$(CC) $(CFLAGS) -I../src $^ -o $@

clean:
	rm -f test_ucs2_parts test_phone_number
