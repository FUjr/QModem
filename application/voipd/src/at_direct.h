#ifndef QMODEM_VOIP_AT_DIRECT_H
#define QMODEM_VOIP_AT_DIRECT_H

#include "call_state.h"

#include <stdint.h>

struct qmodem_voip_at_direct {
	char port[QMODEM_VOIP_AT_PORT_SIZE];
	uint32_t object;
	int pending;
	unsigned failures;
};

void qmodem_voip_at_direct_reset(struct qmodem_voip_at_direct *direct);
int qmodem_voip_at_direct_ready(const struct qmodem_voip_at_direct *direct,
				const char *call_port);
void qmodem_voip_at_direct_learn(struct qmodem_voip_at_direct *direct,
				 const char *port, uint32_t object);
void qmodem_voip_at_direct_begin(struct qmodem_voip_at_direct *direct);
void qmodem_voip_at_direct_done(struct qmodem_voip_at_direct *direct, int ok);
int qmodem_voip_at_direct_reply_ok(const char *status);

#endif
