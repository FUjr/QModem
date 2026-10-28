#ifndef QMODEM_VOIP_CALL_STATE_H
#define QMODEM_VOIP_CALL_STATE_H

#include <stddef.h>
#include <stdint.h>

#define QMODEM_VOIP_NUMBER_SIZE 64
#define QMODEM_VOIP_AT_PORT_SIZE 64

enum qmodem_voip_state {
	QMODEM_VOIP_DISABLED,
	QMODEM_VOIP_IDLE,
	QMODEM_VOIP_OUTGOING_SETUP,
	QMODEM_VOIP_INCOMING_RINGING,
	QMODEM_VOIP_EARLY_MEDIA,
	QMODEM_VOIP_ACTIVE,
	QMODEM_VOIP_TERMINATING,
	QMODEM_VOIP_RECOVERING,
	QMODEM_VOIP_FAULT
};

enum qmodem_voip_endpoint {
	QMODEM_VOIP_ENDPOINT_NONE,
	QMODEM_VOIP_ENDPOINT_BROWSER,
	QMODEM_VOIP_ENDPOINT_LAN_SIP,
	QMODEM_VOIP_ENDPOINT_CELLULAR,
	QMODEM_VOIP_ENDPOINT_EXTERNAL_SIP,
	QMODEM_VOIP_ENDPOINT_RJ11
};

enum qmodem_voip_correlation {
	QMODEM_VOIP_CORR_IDLE,
	QMODEM_VOIP_CORR_RESPONSE,
	QMODEM_VOIP_CORR_TERMINAL,
	QMODEM_VOIP_CORR_AMBIGUOUS
};

struct qmodem_voip_call {
	enum qmodem_voip_state state;
	enum qmodem_voip_endpoint origin;
	enum qmodem_voip_endpoint endpoint;
	char number[QMODEM_VOIP_NUMBER_SIZE];
	int caller_id_withheld;
	int enabled;
	char at_port[QMODEM_VOIP_AT_PORT_SIZE];
	uint64_t restart_epoch;
	uint64_t sequence;
	uint64_t drop_count;
	uint64_t revision;
	uint64_t active_since_msec;
	uint64_t started_at;
	int was_active;
	uint64_t reconcile_command_id;
	int reconcile_pending;
	int reconcile_saw_data;
	unsigned reconcile_voice_misses;
	int idle_poll;
	enum qmodem_voip_endpoint answer_owner;
	struct {
		uint64_t started_at;
		uint64_t ended_at;
		uint64_t duration_seconds;
		enum qmodem_voip_endpoint origin;
		char number[QMODEM_VOIP_NUMBER_SIZE];
		int caller_id_withheld;
		int was_active;
		int pending;
	} completed;
};

struct qmodem_voip_completed_call {
	uint64_t started_at;
	uint64_t ended_at;
	uint64_t duration_seconds;
	enum qmodem_voip_endpoint origin;
	char number[QMODEM_VOIP_NUMBER_SIZE];
	int caller_id_withheld;
	int was_active;
};

typedef void (*qmodem_voip_command_fn)(const char *command, void *opaque);
typedef void (*qmodem_voip_event_fn)(const struct qmodem_voip_call *call,
					 const char *event, void *opaque);

void qmodem_voip_call_init(struct qmodem_voip_call *call);
void qmodem_voip_call_set_enabled(struct qmodem_voip_call *call, int enabled);
void qmodem_voip_call_touch(struct qmodem_voip_call *call);
int qmodem_voip_call_select_at_port(struct qmodem_voip_call *call,
				    const char *port);
int qmodem_voip_endpoint_parse(const char *value,
				       enum qmodem_voip_endpoint *endpoint);
const char *qmodem_voip_state_name(enum qmodem_voip_state state);
const char *qmodem_voip_endpoint_name(enum qmodem_voip_endpoint endpoint);

int qmodem_voip_originate(struct qmodem_voip_call *call,
				  enum qmodem_voip_endpoint origin,
				  const char *number,
				  qmodem_voip_command_fn command,
				  void *opaque);
int qmodem_voip_answer(struct qmodem_voip_call *call,
			       enum qmodem_voip_endpoint endpoint,
			       qmodem_voip_command_fn command, void *opaque);
int qmodem_voip_reject(struct qmodem_voip_call *call,
			       enum qmodem_voip_endpoint endpoint,
			       qmodem_voip_command_fn command, void *opaque);
int qmodem_voip_hangup(struct qmodem_voip_call *call,
			       enum qmodem_voip_endpoint endpoint,
			       qmodem_voip_command_fn command, void *opaque);
int qmodem_voip_send_dtmf(struct qmodem_voip_call *call,
			  enum qmodem_voip_endpoint endpoint, char digit,
			  qmodem_voip_command_fn command, void *opaque);
uint64_t qmodem_voip_call_duration_seconds(const struct qmodem_voip_call *call);
int qmodem_voip_call_get_completed(const struct qmodem_voip_call *call,
				    struct qmodem_voip_completed_call *completed);
void qmodem_voip_call_ack_completed(struct qmodem_voip_call *call);
int qmodem_voip_start_recovery(struct qmodem_voip_call *call,
			       qmodem_voip_command_fn command, void *opaque);
int qmodem_voip_poll_active(struct qmodem_voip_call *call,
			    qmodem_voip_command_fn command, void *opaque);
int qmodem_voip_poll_idle(struct qmodem_voip_call *call,
			  qmodem_voip_command_fn command, void *opaque);
int qmodem_voip_line(struct qmodem_voip_call *call, const char *port,
			    uint64_t epoch,
			    uint64_t sequence, const char *raw,
			    enum qmodem_voip_correlation correlation,
			    uint64_t command_id, uint64_t drop_count,
			    qmodem_voip_command_fn command,
			    qmodem_voip_event_fn event, void *opaque);

#endif
