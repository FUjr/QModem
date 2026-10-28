#include "at_direct.h"

#include <string.h>

void qmodem_voip_at_direct_reset(struct qmodem_voip_at_direct *direct)
{
	direct->port[0] = '\0';
	direct->object = 0;
	direct->pending = 0;
}

int qmodem_voip_at_direct_ready(const struct qmodem_voip_at_direct *direct,
				const char *call_port)
{
	return direct->port[0] && direct->object != 0 && !direct->pending &&
	       call_port && strcmp(direct->port, call_port) == 0;
}

void qmodem_voip_at_direct_learn(struct qmodem_voip_at_direct *direct,
				 const char *port, uint32_t object)
{
	size_t length = port ? strlen(port) : 0;
	qmodem_voip_at_direct_reset(direct);
	if (!length || length >= sizeof(direct->port) || object == 0)
		return;
	memcpy(direct->port, port, length + 1U);
	direct->object = object;
}

void qmodem_voip_at_direct_begin(struct qmodem_voip_at_direct *direct)
{
	direct->pending = 1;
}

void qmodem_voip_at_direct_done(struct qmodem_voip_at_direct *direct, int ok)
{
	direct->pending = 0;
	if (ok)
		return;
	direct->failures++;
	qmodem_voip_at_direct_reset(direct);
}

int qmodem_voip_at_direct_reply_ok(const char *status)
{
	return status && strcmp(status, "success") == 0;
}
