TARGET = tom_modem

CFLAGS += -I$(TARGET_DIR)/usr/include
CFLAGS += -I$(TARGET_DIR)/usr/include/libubox
CFLAGS += -I$(TARGET_DIR)/usr/include/json-c

LDFLAGS = -L$(TARGET_DIR)/usr/lib
LDFLAGS += -L$(TARGET_DIR)/lib
LDFLAGS += -lubus -lubox -ljson-c -lblobmsg_json

SRCS = main.c utils.c operations.c ttydevice.c ubus_client.c extlib/pdu.c extlib/ucs2_to_utf8.c

OBJS = $(SRCS:.c=.o)

$(TARGET): $(OBJS)
	$(CC) $(LDFLAGS) -o $@ $^

clean:
	rm -f $(OBJS) $(TARGET)

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@


.PHONY:clean
clean:
	rm -rf *.o *.*~ *~ *.swap $(all)
	rm -rf $(TARGET)
	rm -rf extlib/*.o
depend:
	$(CC) $(CFLAGS) -MM $(SRCS) > .depend

# 包含依赖文件
ifneq "$(wildcard .depend)" ""
include .depend
endif
