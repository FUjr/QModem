#include "at_direct.h"
#include "call_state.h"

#include <assert.h>
#include <string.h>

static unsigned commands;
static char last_command[32];
static unsigned rings;
static unsigned states;
static unsigned other_events;
static uint64_t sequence;

static void command(const char *value, void *opaque)
{
	(void)opaque;
	commands++;
	strncpy(last_command, value, sizeof(last_command) - 1U);
}

static void event(const struct qmodem_voip_call *call, const char *name, void *opaque)
{
	(void)call;
	(void)opaque;
	if (strcmp(name, "ring") == 0)
		rings++;
	else if (strcmp(name, "call_state") == 0)
		states++;
	else
		other_events++;
}

static int line(struct qmodem_voip_call *call, const char *raw,
		enum qmodem_voip_correlation correlation, uint64_t command_id)
{
	return qmodem_voip_line(call, "/dev/ttyUSB2", 1, ++sequence, raw, correlation,
				command_id, 0, command, event, NULL);
}

static void test_direct_cache(void)
{
	struct qmodem_voip_at_direct direct;
	memset(&direct, 0, sizeof(direct));
	qmodem_voip_at_direct_reset(&direct);
	assert(!qmodem_voip_at_direct_ready(&direct, "/dev/ttyUSB2"));

	qmodem_voip_at_direct_learn(&direct, "/dev/ttyUSB2", 0);
	assert(!qmodem_voip_at_direct_ready(&direct, "/dev/ttyUSB2"));
	qmodem_voip_at_direct_learn(&direct, "", 7);
	assert(!qmodem_voip_at_direct_ready(&direct, ""));

	qmodem_voip_at_direct_learn(&direct, "/dev/ttyUSB2", 7);
	assert(qmodem_voip_at_direct_ready(&direct, "/dev/ttyUSB2"));
	assert(!qmodem_voip_at_direct_ready(&direct, "/dev/ttyUSB3"));
	assert(!qmodem_voip_at_direct_ready(&direct, NULL));

	qmodem_voip_at_direct_begin(&direct);
	assert(!qmodem_voip_at_direct_ready(&direct, "/dev/ttyUSB2"));
	qmodem_voip_at_direct_done(&direct, 1);
	assert(qmodem_voip_at_direct_ready(&direct, "/dev/ttyUSB2"));
	assert(direct.failures == 0);

	qmodem_voip_at_direct_begin(&direct);
	qmodem_voip_at_direct_done(&direct, 0);
	assert(!qmodem_voip_at_direct_ready(&direct, "/dev/ttyUSB2"));
	assert(direct.port[0] == '\0' && direct.object == 0);
	assert(direct.failures == 1);

	assert(qmodem_voip_at_direct_reply_ok("success"));
	assert(!qmodem_voip_at_direct_reply_ok("error"));
	assert(!qmodem_voip_at_direct_reply_ok("timeout"));
	assert(!qmodem_voip_at_direct_reply_ok(NULL));
}

static void test_idle_poll(void)
{
	struct qmodem_voip_call call;
	enum qmodem_voip_endpoint endpoint;

	qmodem_voip_call_init(&call);
	assert(qmodem_voip_poll_idle(&call, command, NULL) == -1);
	qmodem_voip_call_set_enabled(&call, 1);
	assert(qmodem_voip_call_select_at_port(&call, "/dev/ttyUSB2") >= 0);
	assert(call.state == QMODEM_VOIP_IDLE);

	assert(qmodem_voip_poll_idle(&call, command, NULL) == 0);
	assert(commands == 1 && strcmp(last_command, "AT+CLCC") == 0);
	assert(qmodem_voip_poll_idle(&call, command, NULL) == -1);
	assert(commands == 1);

	assert(line(&call, "OK", QMODEM_VOIP_CORR_TERMINAL, 5) == 0);
	assert(!call.reconcile_pending && !call.idle_poll);
	assert(call.state == QMODEM_VOIP_IDLE);
	assert(rings == 0 && states == 0 && other_events == 0);

	assert(qmodem_voip_poll_idle(&call, command, NULL) == 0);
	assert(line(&call, "+CLCC: 1,1,0,1,0,\"\",128", QMODEM_VOIP_CORR_RESPONSE, 8) == 0);
	assert(line(&call, "+CME ERROR: 100", QMODEM_VOIP_CORR_TERMINAL, 8) == 0);
	assert(!call.reconcile_pending && !call.idle_poll);
	assert(call.state == QMODEM_VOIP_IDLE && other_events == 0);

	assert(qmodem_voip_poll_idle(&call, command, NULL) == 0);
	assert(line(&call, "+CLCC: 1,1,4,0,0,\"0712345678\",129",
		    QMODEM_VOIP_CORR_RESPONSE, 6) == 0);
	assert(call.state == QMODEM_VOIP_INCOMING_RINGING);
	assert(strcmp(call.number, "0712345678") == 0);
	assert(rings == 1 && states == 1);
	assert(!call.idle_poll);
	assert(line(&call, "OK", QMODEM_VOIP_CORR_TERMINAL, 6) == 0);
	assert(call.state == QMODEM_VOIP_INCOMING_RINGING);

	assert(qmodem_voip_poll_idle(&call, command, NULL) == -1);
	assert(qmodem_voip_poll_active(&call, command, NULL) == 0);
	assert(line(&call, "+CLCC: 1,1,4,0,0,\"0712345678\",129",
		    QMODEM_VOIP_CORR_RESPONSE, 7) == 0);
	assert(rings == 1 && states == 1);
	assert(line(&call, "OK", QMODEM_VOIP_CORR_TERMINAL, 7) == 0);

	assert(qmodem_voip_poll_active(&call, command, NULL) == 0);
	assert(line(&call, "ERROR", QMODEM_VOIP_CORR_TERMINAL, 10) == 0);
	assert(!call.reconcile_pending);
	assert(call.state == QMODEM_VOIP_INCOMING_RINGING);
	assert(qmodem_voip_poll_active(&call, command, NULL) == 0);

	assert(qmodem_voip_endpoint_parse("rj11", &endpoint) == 0);
	assert(endpoint == QMODEM_VOIP_ENDPOINT_RJ11);
	assert(strcmp(qmodem_voip_endpoint_name(endpoint), "rj11") == 0);
	assert(qmodem_voip_answer(&call, QMODEM_VOIP_ENDPOINT_RJ11, command, NULL) == 0);
	assert(strcmp(last_command, "ATA") == 0);
	assert(call.state == QMODEM_VOIP_ACTIVE);
	assert(line(&call, "+CLCC: 1,1,4,0,0,\"0712345678\",129",
		    QMODEM_VOIP_CORR_RESPONSE, 10) == 0);
	assert(call.state == QMODEM_VOIP_ACTIVE);
	assert(line(&call, "+CLCC: 1,1,0,0,0,\"0712345678\",129",
		    QMODEM_VOIP_CORR_RESPONSE, 11) == 0);
	assert(call.state == QMODEM_VOIP_ACTIVE);
}

int main(void)
{
	test_direct_cache();
	test_idle_poll();
	return 0;
}
