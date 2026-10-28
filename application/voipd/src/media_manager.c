#define _POSIX_C_SOURCE 200809L

#include "daemon_core.h"
#include "media_manager.h"

#include <arpa/inet.h>
#include <libubox/uloop.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

static void clear_secret(void *value, size_t length)
{
	volatile unsigned char *bytes = value;
	while (length--)
		*bytes++ = 0;
}

#define QMODEM_VOIP_MEDIA_SOCKET_PATH_DEFAULT \
	"/var/run/qmodem_voip/media.sock"

void qmodem_voip_media_sync(void)
{
	struct qmodem_voip_context *app = &qmodem_voip_ctxt;
	int call_media_state = app->call.state == QMODEM_VOIP_OUTGOING_SETUP ||
		app->call.state == QMODEM_VOIP_EARLY_MEDIA ||
		app->call.state == QMODEM_VOIP_ACTIVE;
	int listener_should_run = app->media.ready && app->browser.engine == &app->media;
	int call_should_run = call_media_state &&
		(app->call.origin == QMODEM_VOIP_ENDPOINT_BROWSER ||
		 app->call.answer_owner == QMODEM_VOIP_ENDPOINT_BROWSER);
	/* Keep the local WebSocket listener stable while the media engine is
	 * available. Calls select an authenticated revision; they do not create
	 * or destroy the uhttpd proxy target. */
	if (!listener_should_run) {
		if (app->browser.ready)
			qmodem_voip_browser_media_stop(&app->browser);
		return;
	}
	if (!app->browser.ready && qmodem_voip_browser_media_start(&app->browser) != 0)
		return;
	if (!call_should_run) {
		if (app->browser.call_revision || app->browser.attached || app->browser.client)
			qmodem_voip_browser_media_reset_call(&app->browser);
		return;
	}
	if (app->browser.call_revision != app->call.revision)
		/* Keep the same authenticated context while this call advances through
		 * setup, early media, and active.  Pending tokens remain valid for this
		 * context; the context is still cleared when the call leaves these states. */
		app->browser.call_revision = app->call.revision;
}

void qmodem_voip_browser_timer(struct uloop_timeout *timeout)
{
	struct qmodem_voip_context *app = &qmodem_voip_ctxt;
	struct timespec now;
	uint64_t timestamp_ms = 0;
	int browser_attached = app->browser.ready && app->browser.attached &&
		app->call.state == QMODEM_VOIP_ACTIVE && app->media.ready;
	int rtp_attached = app->rtp.active && app->media.ready &&
		(app->call.state == QMODEM_VOIP_OUTGOING_SETUP ||
		 app->call.state == QMODEM_VOIP_EARLY_MEDIA ||
		 app->call.state == QMODEM_VOIP_ACTIVE);
	int socket_attached = app->media.ready &&
		app->call.state == QMODEM_VOIP_ACTIVE &&
		qmodem_voip_media_socket_attached(&app->media_sock);
	(void)timeout;
	qmodem_voip_media_sync();
	if (app->media.ready && !app->media_sock.ready)
		(void)qmodem_voip_media_socket_start(&app->media_sock, &app->media,
			app, app->media_socket_path[0] ? app->media_socket_path :
			QMODEM_VOIP_MEDIA_SOCKET_PATH_DEFAULT);
	if (app->media.ready && clock_gettime(CLOCK_MONOTONIC, &now) == 0) {
		timestamp_ms = (uint64_t)now.tv_sec * 1000U +
			(uint64_t)now.tv_nsec / 1000000U;
		if (app->media.backend != QMODEM_VOIP_MEDIA_BACKEND_SERIAL)
			(void)qmodem_voip_media_capture(&app->media, timestamp_ms);
	}
	if (app->browser.ready)
		(void)qmodem_voip_browser_media_service(&app->browser);
	if (app->media_sock.ready)
		(void)qmodem_voip_media_socket_service(&app->media_sock, timestamp_ms);
	if (rtp_attached)
		(void)qmodem_voip_rtp_service(&app->rtp, timestamp_ms);
	if (browser_attached || rtp_attached || socket_attached)
		(void)qmodem_voip_media_playback(&app->media, timestamp_ms);
	uloop_timeout_set(&app->browser_timer,
		(browser_attached || rtp_attached || socket_attached) ? 1 : 20);
}

void qmodem_voip_media_status(struct blob_buf *buffer)
{
	struct qmodem_voip_context *app = &qmodem_voip_ctxt;
	char media_url[96];
	const char *backend = "none";
	if (app->media.backend == QMODEM_VOIP_MEDIA_BACKEND_SERIAL)
		backend = "serial_pcm";
	else if (app->media.backend == QMODEM_VOIP_MEDIA_BACKEND_UAC)
		backend = "uac";
	else if (app->media.backend == QMODEM_VOIP_MEDIA_BACKEND_PCM_SOCKET)
		backend = "pcm_socket";
	/* `media` is the stable capability consumed by LuCI.  Keep it tied to
	 * the modem media engine, while `browser_media` continues to describe
	 * the optional, call-scoped WebSocket attachment. */
	blobmsg_add_string(buffer, "media", app->media.ready ? "ready" : "not_ready");
	blobmsg_add_string(buffer, "media_engine", app->media.ready ? "ready" : "not_ready");
	blobmsg_add_string(buffer, "media_backend", backend);
	blobmsg_add_string(buffer, "browser_media", app->browser.ready ? "ready" : "not_ready");
	blobmsg_add_string(buffer, "rtp_media", app->rtp.active ? "attached" : "detached");
	if (qmodem_voip_browser_media_url(&app->browser, media_url, sizeof(media_url)))
		blobmsg_add_string(buffer, "media_url", media_url);
	blobmsg_add_string(buffer, "canonical_format", "s16le/mono/8000/20ms");
	blobmsg_add_u32(buffer, "capture_rate", app->media.device.capture_rate);
	blobmsg_add_u32(buffer, "playback_rate", app->media.device.playback_rate);
	blobmsg_add_u64(buffer, "media_drop_count", app->media.modem_to_canonical.dropped +
		app->media.canonical_to_modem.dropped);
	blobmsg_add_u64(buffer, "media_underrun_count", app->media.modem_to_canonical.underruns +
		app->media.canonical_to_modem.underruns);
	blobmsg_add_u32(buffer, "media_drift_ppm", (uint32_t)(app->media.modem_to_canonical.drift_ppm + 100));
	blobmsg_add_u64(buffer, "media_tone_failures", app->media.tone_failures);
	blobmsg_add_u64(buffer, "browser_uplink_frames", app->browser.uplink_frames);
	blobmsg_add_u64(buffer, "browser_uplink_non_silent_frames",
		app->browser.uplink_non_silent_frames);
	blobmsg_add_u32(buffer, "browser_uplink_peak", app->browser.uplink_peak);
	blobmsg_add_u64(buffer, "browser_downlink_frames", app->browser.downlink_frames);
	blobmsg_add_u64(buffer, "browser_downlink_empty", app->browser.downlink_empty);
	blobmsg_add_u64(buffer, "browser_downlink_write_errors",
		app->browser.downlink_write_errors);
	blobmsg_add_u64(buffer, "serial_capture_frames",
		atomic_load(&app->media.serial.captured_frames));
	blobmsg_add_u64(buffer, "serial_poll_wakeups",
		atomic_load(&app->media.serial.poll_wakeups));
	blobmsg_add_u64(buffer, "serial_read_bytes",
		atomic_load(&app->media.serial.read_bytes));
	blobmsg_add_u64(buffer, "serial_read_eagain",
		atomic_load(&app->media.serial.read_eagain));
	blobmsg_add_u64(buffer, "serial_read_errors",
		atomic_load(&app->media.serial.read_errors));
	blobmsg_add_u64(buffer, "serial_write_bytes",
		atomic_load(&app->media.serial.write_bytes));
	blobmsg_add_u64(buffer, "serial_write_eagain",
		atomic_load(&app->media.serial.write_eagain));
	blobmsg_add_u64(buffer, "serial_write_errors",
		atomic_load(&app->media.serial.write_errors));
	blobmsg_add_u64(buffer, "serial_reopen_count",
		atomic_load(&app->media.serial.reopen_count));
	if (app->media.backend == QMODEM_VOIP_MEDIA_BACKEND_PCM_SOCKET) {
		blobmsg_add_u8(buffer, "pcm_socket_connected", app->media.pcm_socket.fd >= 0);
		blobmsg_add_u64(buffer, "pcm_socket_capture_frames",
			app->media.pcm_socket.capture_frames);
		blobmsg_add_u64(buffer, "pcm_socket_playback_frames",
			app->media.pcm_socket.playback_frames);
		blobmsg_add_u64(buffer, "pcm_socket_connects", app->media.pcm_socket.connects);
		blobmsg_add_u64(buffer, "pcm_socket_errors", app->media.pcm_socket.errors);
	}
	blobmsg_add_u64(buffer, "rtp_receive_packets",
		atomic_load(&app->media.rtp_received_packets));
	blobmsg_add_u64(buffer, "rtp_send_packets",
		atomic_load(&app->media.rtp_sent_packets));
}

int qmodem_voip_media_token_method(struct ubus_context *ubus,
				   struct ubus_object *object,
				   struct ubus_request_data *request,
				   const char *method, struct blob_attr *message)
{
	struct qmodem_voip_context *app = &qmodem_voip_ctxt;
	struct blob_attr *parameters[QMODEM_VOIP_MEDIA_TOKEN_MAX] = { 0 };
	const char *session_id;
	const char *origin;
	uint64_t revision;
	char token[23];
	struct blob_buf buffer = { 0 };
	(void)object;
	(void)method;
	qmodem_voip_media_sync();
	blobmsg_parse(qmodem_voip_media_token_policy, QMODEM_VOIP_MEDIA_TOKEN_MAX, parameters,
		blob_data(message), blob_len(message));
	if (!parameters[QMODEM_VOIP_MEDIA_SESSION_ID] || !parameters[QMODEM_VOIP_MEDIA_CALL_REVISION] ||
	    !parameters[QMODEM_VOIP_MEDIA_HTTPS_ORIGIN])
		return qmodem_voip_reply_status(ubus, request, UBUS_STATUS_INVALID_ARGUMENT,
			"invalid_session", "session, revision, and origin are required");
	if ((app->call.state != QMODEM_VOIP_OUTGOING_SETUP &&
	     app->call.state != QMODEM_VOIP_EARLY_MEDIA &&
	     app->call.state != QMODEM_VOIP_ACTIVE) ||
	    (app->call.origin != QMODEM_VOIP_ENDPOINT_BROWSER &&
	     app->call.answer_owner != QMODEM_VOIP_ENDPOINT_BROWSER) ||
	    !app->media.ready || !app->browser.ready)
		return qmodem_voip_reply_status(ubus, request, UBUS_STATUS_NOT_SUPPORTED,
			"unsupported", "not_ready");
	session_id = blobmsg_get_string(parameters[QMODEM_VOIP_MEDIA_SESSION_ID]);
	origin = blobmsg_get_string(parameters[QMODEM_VOIP_MEDIA_HTTPS_ORIGIN]);
	if (blobmsg_type(parameters[QMODEM_VOIP_MEDIA_CALL_REVISION]) == BLOBMSG_TYPE_INT64)
		revision = blobmsg_get_u64(parameters[QMODEM_VOIP_MEDIA_CALL_REVISION]);
	else if (blobmsg_type(parameters[QMODEM_VOIP_MEDIA_CALL_REVISION]) == BLOBMSG_TYPE_INT32)
		revision = blobmsg_get_u32(parameters[QMODEM_VOIP_MEDIA_CALL_REVISION]);
	else
		return qmodem_voip_reply_status(ubus, request, UBUS_STATUS_INVALID_ARGUMENT,
			"invalid_session", "call revision must be an integer");
	/* Call notifications advance the revision during setup/answer.  A token
	 * request carrying the immediately previous revision is still for this
	 * authenticated call; bind it to the current revision before issuing it. */
	if ((revision != app->call.revision &&
	     (!app->call.revision || revision != app->call.revision - 1U)) ||
	    !qmodem_voip_session_is_authorized(session_id))
		return qmodem_voip_reply_status(ubus, request, UBUS_STATUS_INVALID_ARGUMENT,
			"invalid_session", "session, revision, or origin is invalid");
	revision = app->call.revision;
	if (qmodem_voip_browser_token_issue(&app->browser.tokens, session_id, revision,
		origin, NULL, (uint64_t)time(NULL), token) != 0)
		return qmodem_voip_reply_status(ubus, request, UBUS_STATUS_INVALID_ARGUMENT,
			"invalid_session", "session, revision, or origin is invalid");
	blob_buf_init(&buffer, 0);
	blobmsg_add_string(&buffer, "token", token);
	blobmsg_add_u32(&buffer, "expires_in", QMODEM_VOIP_BROWSER_TOKEN_TTL);
	blobmsg_add_u64(&buffer, "call_revision", revision);
	(void)ubus_send_reply(ubus, request, buffer.head);
	blob_buf_free(&buffer);
	clear_secret(token, sizeof(token));
	return UBUS_STATUS_OK;
}

int qmodem_voip_socket_session_method(struct ubus_context *ubus,
				      struct ubus_object *object,
				      struct ubus_request_data *request,
				      const char *method, struct blob_attr *message)
{
	struct qmodem_voip_context *app = &qmodem_voip_ctxt;
	struct blob_attr *parameters[QMODEM_VOIP_SOCKET_SESSION_PARAM_MAX] = { 0 };
	struct blob_buf buffer = { 0 };
	char session_id[QMODEM_VOIP_MEDIA_SOCKET_SESSION_ID_MAX] = { 0 };
	uint64_t revision = 0;
	(void)object;
	(void)method;
	blobmsg_parse(qmodem_voip_socket_session_policy,
		QMODEM_VOIP_SOCKET_SESSION_PARAM_MAX, parameters,
		blob_data(message), blob_len(message));
	if (!parameters[QMODEM_VOIP_SOCKET_SESSION_CALL_REVISION])
		return qmodem_voip_reply_status(ubus, request, UBUS_STATUS_INVALID_ARGUMENT,
			"invalid_call", "call revision is required");
	if (blobmsg_type(parameters[QMODEM_VOIP_SOCKET_SESSION_CALL_REVISION]) == BLOBMSG_TYPE_INT64)
		revision = blobmsg_get_u64(parameters[QMODEM_VOIP_SOCKET_SESSION_CALL_REVISION]);
	else if (blobmsg_type(parameters[QMODEM_VOIP_SOCKET_SESSION_CALL_REVISION]) == BLOBMSG_TYPE_INT32)
		revision = blobmsg_get_u32(parameters[QMODEM_VOIP_SOCKET_SESSION_CALL_REVISION]);
	else
		return qmodem_voip_reply_status(ubus, request, UBUS_STATUS_INVALID_ARGUMENT,
			"invalid_call", "call revision must be an integer");
	/* Mint a short-lived local socket session only for an active call's
	   media owner. Requiring an id that matches the current revision keeps
	   the token bound to one live call. */
	if (!revision || revision != app->call.revision)
		return qmodem_voip_reply_status(ubus, request, UBUS_STATUS_INVALID_ARGUMENT,
			"invalid_call", "call revision does not match the active call");
	if (!app->media.ready || !app->media_sock.ready)
		return qmodem_voip_reply_status(ubus, request, UBUS_STATUS_NOT_SUPPORTED,
			"not_ready", "media engine or socket is not ready");
	if (qmodem_voip_media_socket_session_issue(&app->media_sock, revision,
		(uint64_t)time(NULL), session_id) != 0)
		return qmodem_voip_reply_status(ubus, request, UBUS_STATUS_UNKNOWN_ERROR,
			"session_failed", "could not issue a local socket session");
	blob_buf_init(&buffer, 0);
	blobmsg_add_string(&buffer, "session_id", session_id);
	blobmsg_add_u32(&buffer, "expires_in", QMODEM_VOIP_MEDIA_SOCKET_SESSION_TTL);
	blobmsg_add_u64(&buffer, "call_revision", revision);
	(void)ubus_send_reply(ubus, request, buffer.head);
	blob_buf_free(&buffer);
	clear_secret(session_id, sizeof(session_id));
	return UBUS_STATUS_OK;
}

int qmodem_voip_rtp_attach_method(struct ubus_context *ubus,
				  struct ubus_object *object,
				  struct ubus_request_data *request,
				  const char *method, struct blob_attr *message)
{
	struct qmodem_voip_context *app = &qmodem_voip_ctxt;
	struct blob_attr *parameters[QMODEM_VOIP_RTP_PARAM_MAX] = { 0 };
	struct in_addr address;
	uint64_t session_id;
	unsigned port;
	unsigned payload_type;
	(void)object;
	(void)method;
	blobmsg_parse(qmodem_voip_rtp_policy, QMODEM_VOIP_RTP_PARAM_MAX, parameters,
		blob_data(message), blob_len(message));
	if (!parameters[QMODEM_VOIP_RTP_PARAM_ADDRESS] || !parameters[QMODEM_VOIP_RTP_PARAM_PORT] ||
	    !parameters[QMODEM_VOIP_RTP_PARAM_PAYLOAD_TYPE] || !parameters[QMODEM_VOIP_RTP_PARAM_SESSION_ID] ||
	    inet_pton(AF_INET, blobmsg_get_string(parameters[QMODEM_VOIP_RTP_PARAM_ADDRESS]),
		&address) != 1)
		return qmodem_voip_reply_status(ubus, request, UBUS_STATUS_INVALID_ARGUMENT,
			"invalid_media", "RTP address, port, payload, and session are required");
	port = blobmsg_get_u32(parameters[QMODEM_VOIP_RTP_PARAM_PORT]);
	payload_type = blobmsg_get_u32(parameters[QMODEM_VOIP_RTP_PARAM_PAYLOAD_TYPE]);
	if (blobmsg_type(parameters[QMODEM_VOIP_RTP_PARAM_SESSION_ID]) == BLOBMSG_TYPE_INT64)
		session_id = blobmsg_get_u64(parameters[QMODEM_VOIP_RTP_PARAM_SESSION_ID]);
	else if (blobmsg_type(parameters[QMODEM_VOIP_RTP_PARAM_SESSION_ID]) == BLOBMSG_TYPE_INT32)
		session_id = blobmsg_get_u32(parameters[QMODEM_VOIP_RTP_PARAM_SESSION_ID]);
	else
		return qmodem_voip_reply_status(ubus, request, UBUS_STATUS_INVALID_ARGUMENT,
			"invalid_media", "RTP session must be an integer");
	if ((app->call.state != QMODEM_VOIP_OUTGOING_SETUP &&
	     app->call.state != QMODEM_VOIP_EARLY_MEDIA &&
	     app->call.state != QMODEM_VOIP_ACTIVE) ||
	    !app->media.ready || !session_id ||
	    !port || port > 65535 || (payload_type != QMODEM_VOIP_MEDIA_PCMA &&
		payload_type != QMODEM_VOIP_MEDIA_PCMU))
		return qmodem_voip_reply_status(ubus, request, UBUS_STATUS_NOT_SUPPORTED,
			"media_not_ready", "call or negotiated RTP media is not ready");
	if (app->browser.attached)
		return qmodem_voip_reply_status(ubus, request, UBUS_STATUS_NOT_SUPPORTED,
			"media_busy", "another media owner is active");
	if (qmodem_voip_rtp_attach(&app->rtp, &app->media, address.s_addr,
		(uint16_t)port, (enum qmodem_voip_media_codec)payload_type,
		session_id) != 0)
		return qmodem_voip_reply_status(ubus, request, UBUS_STATUS_UNKNOWN_ERROR,
			"rtp_bind_failed", "RTP port 40000 could not be attached");
	return qmodem_voip_reply_ok_snapshot(ubus, request);
}

int qmodem_voip_rtp_release_method(struct ubus_context *ubus,
				   struct ubus_object *object,
				   struct ubus_request_data *request,
				   const char *method, struct blob_attr *message)
{
	(void)object;
	(void)method;
	(void)message;
	qmodem_voip_rtp_release(&qmodem_voip_ctxt.rtp);
	return qmodem_voip_reply_ok_snapshot(ubus, request);
}

int qmodem_voip_media_manager_init(struct qmodem_voip_context *context)
{
	(void)context;
	return 0;
}

void qmodem_voip_media_manager_shutdown(struct qmodem_voip_context *context)
{
	(void)context;
	qmodem_voip_browser_media_release(&context->browser);
	qmodem_voip_rtp_release(&context->rtp);
	qmodem_voip_media_socket_stop(&context->media_sock);
	qmodem_voip_media_release(&context->media);
}
