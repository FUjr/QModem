#ifndef QMODEM_VOIP_DAEMON_CORE_H
#define QMODEM_VOIP_DAEMON_CORE_H

#include "at_direct.h"
#include "call_state.h"
#include "media.h"
#include "rtp_transport.h"
#include "browser_media.h"
#include "media_socket.h"

#include <libubus.h>
#include <libubox/uloop.h>
#include <libubox/blobmsg.h>

struct qmodem_voip_media_manager;

struct qmodem_voip_context {
	struct ubus_context *ubus;
	struct ubus_object object;
	struct ubus_event_handler at_events;
	struct ubus_event_handler urc_events;
	struct qmodem_voip_call call;
	struct qmodem_voip_at_direct idle_at;
	struct ubus_request idle_at_request;
	int idle_at_reply_ok;
	struct qmodem_voip_media_engine media;
	struct qmodem_voip_rtp_transport rtp;
	struct qmodem_voip_browser_media browser;
	struct qmodem_voip_media_socket media_sock;
	char media_socket_path[QMODEM_VOIP_MEDIA_SOCKET_PATH_MAX];
	struct uloop_timeout browser_timer;
	struct uloop_timeout call_timer;
	struct uloop_timeout activation_timer;
	struct uloop_timeout restart_timer;
	struct uloop_process serial_arm_process;
	struct uloop_process voice_restart_process;
	uint64_t voice_restart_revision;
	int voice_restart_needed;
	int command_failed;
	unsigned int serial_active_arm_attempts;
	unsigned int serial_active_generation;
	unsigned int serial_arm_process_generation;
	int start_enabled;
	int stop;
};

extern struct qmodem_voip_context qmodem_voip_ctxt;
extern struct ubus_object_type qmodem_voip_object_type;

enum qmodem_voip_media_token_index {
	QMODEM_VOIP_MEDIA_SESSION_ID,
	QMODEM_VOIP_MEDIA_CALL_REVISION,
	QMODEM_VOIP_MEDIA_HTTPS_ORIGIN,
	QMODEM_VOIP_MEDIA_TOKEN_MAX
};
enum qmodem_voip_socket_session_param {
	QMODEM_VOIP_SOCKET_SESSION_CALL_REVISION,
	QMODEM_VOIP_SOCKET_SESSION_PARAM_MAX
};
enum qmodem_voip_rtp_param {
	QMODEM_VOIP_RTP_PARAM_ADDRESS,
	QMODEM_VOIP_RTP_PARAM_PORT,
	QMODEM_VOIP_RTP_PARAM_PAYLOAD_TYPE,
	QMODEM_VOIP_RTP_PARAM_SESSION_ID,
	QMODEM_VOIP_RTP_PARAM_MAX
};
extern const struct blobmsg_policy qmodem_voip_media_token_policy[QMODEM_VOIP_MEDIA_TOKEN_MAX];
extern const struct blobmsg_policy qmodem_voip_socket_session_policy[QMODEM_VOIP_SOCKET_SESSION_PARAM_MAX];
extern const struct blobmsg_policy qmodem_voip_rtp_policy[QMODEM_VOIP_RTP_PARAM_MAX];

struct blob_buf;
struct ubus_request_data;
struct blob_attr;

/* Event publication and call-control helpers (daemon_core.c). */
void qmodem_voip_publish_event(const struct qmodem_voip_call *call,
			       const char *event, void *opaque);
void qmodem_voip_issue_at(const char *command, void *opaque);
void qmodem_voip_cancel_serial_prepare(void);
int qmodem_voip_prepare_adb(const struct qmodem_voip_modem_profile *profile);
int qmodem_voip_prepare_media_gate(const struct qmodem_voip_modem_profile *profile);
void qmodem_voip_add_redacted_status(struct blob_buf *buffer,
				     const struct qmodem_voip_call *call);
int qmodem_voip_reply_status(struct ubus_context *ubus,
			     struct ubus_request_data *request, int status,
			     const char *error, const char *message);
int qmodem_voip_reply_ok_snapshot(struct ubus_context *ubus,
				  struct ubus_request_data *request);
void qmodem_voip_call_timer(struct uloop_timeout *timeout);
void qmodem_voip_activation_timer(struct uloop_timeout *timeout);
void qmodem_voip_restart_timer(struct uloop_timeout *timeout);
int qmodem_voip_correlation_parse(const char *value);
int qmodem_voip_session_is_authorized(const char *session_id);
void at_line_event(struct ubus_context *ubus,
		   struct ubus_event_handler *handler,
		   const char *type, struct blob_attr *message);
void at_urc_event(struct ubus_context *ubus,
		  struct ubus_event_handler *handler,
		  const char *type, struct blob_attr *message);

/* Media manager interface (media_manager.c). */
void qmodem_voip_media_sync(void);
void qmodem_voip_media_status(struct blob_buf *buffer);
void qmodem_voip_browser_timer(struct uloop_timeout *timeout);
int qmodem_voip_media_token_method(struct ubus_context *ubus,
				   struct ubus_object *object,
				   struct ubus_request_data *request,
				   const char *method, struct blob_attr *message);
int qmodem_voip_socket_session_method(struct ubus_context *ubus,
				      struct ubus_object *object,
				      struct ubus_request_data *request,
				      const char *method, struct blob_attr *message);
int qmodem_voip_rtp_attach_method(struct ubus_context *ubus,
				  struct ubus_object *object,
				  struct ubus_request_data *request,
				  const char *method, struct blob_attr *message);
int qmodem_voip_rtp_release_method(struct ubus_context *ubus,
				   struct ubus_object *object,
				   struct ubus_request_data *request,
				   const char *method, struct blob_attr *message);

#endif
