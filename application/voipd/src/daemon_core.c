#define _POSIX_C_SOURCE 200809L

#include "daemon_core.h"
#include "call_history.h"
#include "media_serial.h"

#include <errno.h>
#include <fcntl.h>
#include <libubox/blobmsg_json.h>
#include <libubox/uloop.h>
#include <libubus.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define AT_ADAPTER "/usr/lib/qmodem_voip/at_daemon_adapter.sh"
#define SAFETY_HELPER "/usr/sbin/qmodem_voip_modem_safety"
#define SAFETY_JOURNAL "/var/lib/qmodem_voip/modem-safety.journal"
#define UCI_PROGRAM "/sbin/uci"
#define ADB_UNLOCK_HELPER "/usr/bin/qmodem_voip_adb_unlock"
#define ADB_PROGRAM "/usr/bin/adb"

struct qmodem_voip_context qmodem_voip_ctxt;

enum {
	PARAM_ENDPOINT,
	PARAM_NUMBER,
	PARAM_ORIGIN,
	PARAM_USERNAME,
	PARAM_DIGIT,
	PARAM_MAX
};

static const struct blobmsg_policy action_policy[PARAM_MAX] = {
	[PARAM_ENDPOINT] = { .name = "endpoint", .type = BLOBMSG_TYPE_STRING },
	[PARAM_NUMBER] = { .name = "number", .type = BLOBMSG_TYPE_STRING },
	[PARAM_ORIGIN] = { .name = "origin", .type = BLOBMSG_TYPE_STRING },
	[PARAM_USERNAME] = { .name = "username", .type = BLOBMSG_TYPE_STRING },
	[PARAM_DIGIT] = { .name = "digit", .type = BLOBMSG_TYPE_STRING }
};

const struct blobmsg_policy qmodem_voip_media_token_policy[QMODEM_VOIP_MEDIA_TOKEN_MAX] = {
	[QMODEM_VOIP_MEDIA_SESSION_ID] = { .name = "session_id", .type = BLOBMSG_TYPE_STRING },
	[QMODEM_VOIP_MEDIA_CALL_REVISION] = { .name = "call_revision", .type = BLOBMSG_TYPE_UNSPEC },
	[QMODEM_VOIP_MEDIA_HTTPS_ORIGIN] = { .name = "https_origin", .type = BLOBMSG_TYPE_STRING }
};

const struct blobmsg_policy qmodem_voip_socket_session_policy[QMODEM_VOIP_SOCKET_SESSION_PARAM_MAX] = {
	[QMODEM_VOIP_SOCKET_SESSION_CALL_REVISION] = { .name = "call_revision",
		.type = BLOBMSG_TYPE_UNSPEC }
};

const struct blobmsg_policy qmodem_voip_rtp_policy[QMODEM_VOIP_RTP_PARAM_MAX] = {
	[QMODEM_VOIP_RTP_PARAM_ADDRESS] = { .name = "address", .type = BLOBMSG_TYPE_STRING },
	[QMODEM_VOIP_RTP_PARAM_PORT] = { .name = "port", .type = BLOBMSG_TYPE_INT32 },
	[QMODEM_VOIP_RTP_PARAM_PAYLOAD_TYPE] = { .name = "payload_type", .type = BLOBMSG_TYPE_INT32 },
	[QMODEM_VOIP_RTP_PARAM_SESSION_ID] = { .name = "session_id", .type = BLOBMSG_TYPE_UNSPEC }
};

static int wait_program(pid_t child)
{
	int status;
	while (waitpid(child, &status, 0) < 0) {
		if (errno != EINTR)
			return -1;
	}
	return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : -1;
}

int qmodem_voip_prepare_adb(const struct qmodem_voip_modem_profile *profile)
{
	pid_t child;
	int status;

	if (!profile || !profile->adb_unlock)
		return 0;
	child = fork();
	if (child < 0)
		return -1;
	if (child == 0) {
		execl(ADB_UNLOCK_HELPER, ADB_UNLOCK_HELPER, "unlock", (char *)NULL);
		_exit(127);
	}
	while (waitpid(child, &status, 0) < 0) {
		if (errno != EINTR)
			return -1;
	}
	if (!WIFEXITED(status))
		return -1;
	if (WEXITSTATUS(status) == 2)
		return 1;
	return WEXITSTATUS(status) == 0 ? 0 : -1;
}

int qmodem_voip_prepare_media_gate(const struct qmodem_voip_modem_profile *profile)
{
	pid_t child;

	if (!profile || !profile->voice_server_media_gate)
		return 0;
	child = fork();
	if (child < 0)
		return -1;
	if (child == 0) {
		execl(ADB_UNLOCK_HELPER, ADB_UNLOCK_HELPER, "install-media-gate",
			(char *)NULL);
		_exit(127);
	}
	return wait_program(child);
}

static int resolve_at_port(char port[QMODEM_VOIP_AT_PORT_SIZE])
{
	int pipe_fd[2];
	pid_t child;
	ssize_t length;
	int status;
	if (pipe(pipe_fd) != 0)
		return -1;
	child = fork();
	if (child < 0) {
		close(pipe_fd[0]);
		close(pipe_fd[1]);
		return -1;
	}
	if (child == 0) {
		close(pipe_fd[0]);
		if (dup2(pipe_fd[1], STDOUT_FILENO) < 0)
			_exit(127);
		if (pipe_fd[1] > STDOUT_FILENO)
			close(pipe_fd[1]);
		execl(AT_ADAPTER, AT_ADAPTER, "endpoint", (char *)NULL);
		_exit(127);
	}
	close(pipe_fd[1]);
	length = read(pipe_fd[0], port, QMODEM_VOIP_AT_PORT_SIZE - 1U);
	close(pipe_fd[0]);
	if (waitpid(child, &status, 0) < 0 || !WIFEXITED(status) ||
	    WEXITSTATUS(status) != 0 || length <= 0)
		return -1;
	port[length] = '\0';
	while (length > 0 && (port[length - 1] == '\n' || port[length - 1] == '\r'))
		port[--length] = '\0';
	return length > 0 ? 0 : -1;
}

static int run_at(const char *command)
{
	char port[QMODEM_VOIP_AT_PORT_SIZE];
	pid_t child;
	if (resolve_at_port(port) != 0 ||
	    qmodem_voip_call_select_at_port(&qmodem_voip_ctxt.call, port) < 0)
		return -1;
	child = fork();
	if (child < 0)
		return -1;
	if (child == 0) {
		execl(AT_ADAPTER, AT_ADAPTER, "at", command, (char *)NULL);
		_exit(127);
	}
	return wait_program(child);
}

static int run_safety(const char *action, int quiet)
{
	pid_t child = fork();
	if (child < 0)
		return -1;
	if (child == 0) {
		if (quiet) {
			int null_fd = open("/dev/null", O_WRONLY);
			if (null_fd < 0 || dup2(null_fd, STDOUT_FILENO) < 0 ||
			    dup2(null_fd, STDERR_FILENO) < 0)
				_exit(127);
			if (null_fd > STDERR_FILENO)
				close(null_fd);
		}
		execl(SAFETY_HELPER, SAFETY_HELPER, action, (char *)NULL);
		_exit(127);
	}
	return wait_program(child);
}

static void serial_arm_process_done(struct uloop_process *process, int status)
{
	struct qmodem_voip_context *app = &qmodem_voip_ctxt;
	(void)process;
	if (app->serial_arm_process_generation != app->serial_active_generation ||
	    app->call.state != QMODEM_VOIP_ACTIVE)
		return;
	/* QPCMV must be armed before ATD/ATA. Reopening the tty after the
	 * call becomes active tears down the modem's live RX stream; keep the
	 * existing fd and let the pre-call recovery own stream setup. */
	if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
		app->call.state = QMODEM_VOIP_FAULT;
		qmodem_voip_call_touch(&app->call);
		qmodem_voip_publish_event(&app->call, "fault", app);
	} else {
		/* The timer retries only while attempts is in [1, 3]. */
		app->serial_active_arm_attempts = 4;
	}
}

static int start_serial_arm(struct qmodem_voip_context *app)
{
	pid_t child;
	if (app->serial_arm_process.pending)
		return 0;
	child = fork();
	if (child < 0)
		return -1;
	if (child == 0) {
		int null_fd = open("/dev/null", O_WRONLY);
		if (null_fd < 0 || dup2(null_fd, STDOUT_FILENO) < 0 ||
		    dup2(null_fd, STDERR_FILENO) < 0)
			_exit(127);
		if (null_fd > STDERR_FILENO)
			close(null_fd);
		execl(SAFETY_HELPER, SAFETY_HELPER, "arm", (char *)NULL);
		_exit(127);
	}
	app->serial_arm_process.cb = serial_arm_process_done;
	app->serial_arm_process.pid = child;
	app->serial_arm_process_generation = app->serial_active_generation;
	if (uloop_process_add(&app->serial_arm_process) != 0)
		return -1;
	app->serial_active_arm_attempts++;
	return 0;
}

static void voice_restart_process_done(struct uloop_process *process, int status)
{
	(void)process;
	if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
		syslog(LOG_ERR, "voice-server restart command failed");
	else
		syslog(LOG_NOTICE, "voice-server restart completed");
}

static void restart_voice_server(struct qmodem_voip_context *app)
{
	pid_t child;
	char command[256];

	if (!app->media.profile.voice_server_restart ||
	    !app->media.profile.voice_server_service[0]) {
		syslog(LOG_ERR, "voice-server recovery requested without profile support");
		return;
	}
	if (app->voice_restart_process.pending) {
		syslog(LOG_INFO, "voice-server recovery already in progress");
		return;
	}
	if (app->voice_restart_revision == app->call.revision) {
		syslog(LOG_INFO, "voice-server recovery already attempted for revision %llu",
			(unsigned long long)app->call.revision);
		return;
	}
	if (app->media.profile.voice_server_dependency_service[0])
		(void)snprintf(command, sizeof(command),
			"systemctl restart %s && systemctl restart %s",
			app->media.profile.voice_server_dependency_service,
			app->media.profile.voice_server_service);
	else
		(void)snprintf(command, sizeof(command), "systemctl restart %s",
			app->media.profile.voice_server_service);
	child = fork();
	if (child < 0) {
		syslog(LOG_ERR, "unable to fork voice-server restart");
		return;
	}
	if (child == 0) {
		execl(ADB_PROGRAM, ADB_PROGRAM, "shell", command,
			(char *)NULL);
		_exit(127);
	}
	app->voice_restart_revision = app->call.revision;
	syslog(LOG_NOTICE, "voice-server recovery scheduled after call revision %llu%s",
		(unsigned long long)app->call.revision,
		app->media.profile.voice_server_dependency_service[0] ?
			" (with dependency service)" : "");
	app->voice_restart_process.cb = voice_restart_process_done;
	app->voice_restart_process.pid = child;
	if (uloop_process_add(&app->voice_restart_process) != 0)
		syslog(LOG_ERR, "unable to monitor voice-server restart");
}

static int journal_enabled(void)
{
	char line[128];
	FILE *file = fopen(SAFETY_JOURNAL, "r");
	if (!file)
		return 0;
	while (fgets(line, sizeof(line), file))
		if (strcmp(line, "phase=enabled\n") == 0 || strcmp(line, "phase=enabled\r\n") == 0) {
			fclose(file);
			return 1;
		}
	fclose(file);
	return 0;
}

static int commit_application_config(void)
{
	pid_t child = fork();
	if (child < 0)
		return -1;
	if (child == 0) {
		char *const arguments[] = { "uci", "commit", "qmodem_voip", NULL };
		execv(UCI_PROGRAM, arguments);
		_exit(127);
	}
	return wait_program(child);
}

static int set_application_enabled(int enabled)
{
	pid_t child = fork();
	if (child < 0)
		return -1;
	if (child == 0) {
		char *const arguments[] = { "uci", "set",
			enabled ? "qmodem_voip.main.enabled=1" :
				"qmodem_voip.main.enabled=0", NULL };
		execv(UCI_PROGRAM, arguments);
		_exit(127);
	}
	if (wait_program(child) != 0)
		return -1;
	return commit_application_config();
}

void qmodem_voip_issue_at(const char *command, void *opaque)
{
	struct qmodem_voip_context *context = opaque;
	if (run_at(command) != 0)
		context->command_failed = 1;
}

static void idle_at_data(struct ubus_request *request, int type,
			 struct blob_attr *message)
{
	static const struct blobmsg_policy policy[] = {
		{ .name = "status", .type = BLOBMSG_TYPE_STRING }
	};
	struct blob_attr *values[ARRAY_SIZE(policy)] = { 0 };
	struct qmodem_voip_context *app = request->priv;
	(void)type;
	if (!message)
		return;
	blobmsg_parse(policy, ARRAY_SIZE(policy), values, blob_data(message),
		      blob_len(message));
	app->idle_at_reply_ok = qmodem_voip_at_direct_reply_ok(
		values[0] ? blobmsg_get_string(values[0]) : NULL);
}

static void idle_at_failed(struct qmodem_voip_context *app)
{
	qmodem_voip_at_direct_done(&app->idle_at, 0);
	if (app->call.idle_poll) {
		app->call.idle_poll = 0;
		app->call.reconcile_pending = 0;
		app->call.reconcile_command_id = 0;
	}
}

static void idle_at_complete(struct ubus_request *request, int result)
{
	struct qmodem_voip_context *app = request->priv;
	if (result == 0 && app->idle_at_reply_ok)
		qmodem_voip_at_direct_done(&app->idle_at, 1);
	else
		idle_at_failed(app);
}

static void qmodem_voip_issue_idle_at(const char *command, void *opaque)
{
	struct qmodem_voip_context *context = opaque;
	static struct blob_buf buffer;
	uint32_t object;
	if (!qmodem_voip_at_direct_ready(&context->idle_at, context->call.at_port)) {
		if (run_at(command) != 0) {
			context->command_failed = 1;
			return;
		}
		if (ubus_lookup_id(context->ubus, "at-daemon", &object) == 0)
			qmodem_voip_at_direct_learn(&context->idle_at,
						    context->call.at_port, object);
		return;
	}
	blob_buf_init(&buffer, 0);
	blobmsg_add_string(&buffer, "at_port", context->idle_at.port);
	blobmsg_add_string(&buffer, "at_cmd", command);
	context->idle_at_reply_ok = 0;
	if (ubus_invoke_async(context->ubus, context->idle_at.object, "sendat",
			      buffer.head, &context->idle_at_request) != 0) {
		qmodem_voip_at_direct_done(&context->idle_at, 0);
		context->command_failed = 1;
		return;
	}
	context->idle_at_request.data_cb = idle_at_data;
	context->idle_at_request.complete_cb = idle_at_complete;
	context->idle_at_request.priv = context;
	qmodem_voip_at_direct_begin(&context->idle_at);
	ubus_complete_request_async(context->ubus, &context->idle_at_request);
}

void qmodem_voip_cancel_serial_prepare(void)
{
	struct qmodem_voip_context *app = &qmodem_voip_ctxt;
	if (app->media.backend != QMODEM_VOIP_MEDIA_BACKEND_SERIAL)
		return;
	if (atomic_load(&app->media.serial.reopen_pending) &&
	    qmodem_voip_serial_reopen(&app->media) != 0) {
		app->media.ready = 0;
		return;
	}
	qmodem_voip_serial_set_attached(&app->media, 0);
}

void qmodem_voip_add_redacted_status(struct blob_buf *buffer,
					const struct qmodem_voip_call *call)
{
	blobmsg_add_string(buffer, "state", qmodem_voip_state_name(call->state));
	blobmsg_add_string(buffer, "origin",
			   qmodem_voip_endpoint_name(call->origin));
	blobmsg_add_string(buffer, "endpoint",
			   qmodem_voip_endpoint_name(call->endpoint));
	blobmsg_add_u8(buffer, "number_present", call->number[0] != '\0');
	blobmsg_add_u8(buffer, "caller_id_withheld", call->caller_id_withheld);
	blobmsg_add_string(buffer, "remote_number",
		call->caller_id_withheld ? "" : call->number);
	blobmsg_add_u64(buffer, "call_duration_seconds",
		qmodem_voip_call_duration_seconds(call));
	blobmsg_add_u8(buffer, "enabled", call->enabled);
	blobmsg_add_u64(buffer, "revision", call->revision);
	blobmsg_add_u64(buffer, "restart_epoch", call->restart_epoch);
	blobmsg_add_u64(buffer, "sequence", call->sequence);
	blobmsg_add_u64(buffer, "drop_count", call->drop_count);
	blobmsg_add_u8(buffer, "reconcile_pending", call->reconcile_pending);
	blobmsg_add_string(buffer, "answer_owner",
			   qmodem_voip_endpoint_name(call->answer_owner));
}

int qmodem_voip_reply_status(struct ubus_context *ubus,
			     struct ubus_request_data *request, int status,
			     const char *error, const char *message)
{
	struct blob_buf buffer = { 0 };
	blob_buf_init(&buffer, 0);
	blobmsg_add_string(&buffer, "status", status == 0 ? "ok" : "error");
	if (error)
		blobmsg_add_string(&buffer, "error", error);
	if (message)
		blobmsg_add_string(&buffer, "message", message);
	(void)ubus_send_reply(ubus, request, buffer.head);
	blob_buf_free(&buffer);
	return status;
}

int qmodem_voip_reply_ok_snapshot(struct ubus_context *ubus,
				  struct ubus_request_data *request)
{
	struct qmodem_voip_context *app = &qmodem_voip_ctxt;
	struct blob_buf buffer = { 0 };
	blob_buf_init(&buffer, 0);
	blobmsg_add_string(&buffer, "status", "ok");
	qmodem_voip_add_redacted_status(&buffer, &app->call);
	qmodem_voip_media_status(&buffer);
	(void)ubus_send_reply(ubus, request, buffer.head);
	blob_buf_free(&buffer);
	return UBUS_STATUS_OK;
}

static int parse_endpoint(struct blob_attr **parameters,
			  enum qmodem_voip_endpoint *endpoint,
			  int index)
{
	if (!parameters[index] ||
	    qmodem_voip_endpoint_parse(blobmsg_get_string(parameters[index]),
					endpoint) != 0)
		return -1;
	return 0;
}

static int action_call(struct ubus_context *ubus,
		       struct ubus_request_data *request,
		       struct blob_attr *message, const char *action)
{
	struct qmodem_voip_context *app = &qmodem_voip_ctxt;
	struct blob_attr *parameters[PARAM_MAX] = { 0 };
	enum qmodem_voip_endpoint endpoint;
	const char *number = NULL;
	int result;

	blobmsg_parse(action_policy, PARAM_MAX, parameters,
		      blob_data(message), blob_len(message));
	if (parse_endpoint(parameters, &endpoint, PARAM_ENDPOINT) != 0)
		return qmodem_voip_reply_status(ubus, request, UBUS_STATUS_INVALID_ARGUMENT,
				    "invalid_endpoint", "endpoint is unsupported");
	if (!app->call.enabled)
		return qmodem_voip_reply_status(ubus, request, UBUS_STATUS_NOT_SUPPORTED,
				    "disabled", "qmodem voip is disabled");
	app->command_failed = 0;
	if (strcmp(action, "send_dtmf") == 0) {
		const char *digit;
		if (!parameters[PARAM_DIGIT] ||
		    strlen(blobmsg_get_string(parameters[PARAM_DIGIT])) != 1U)
			return qmodem_voip_reply_status(ubus, request,
				UBUS_STATUS_INVALID_ARGUMENT, "invalid_dtmf",
				"one DTMF digit is required");
		digit = blobmsg_get_string(parameters[PARAM_DIGIT]);
		result = qmodem_voip_send_dtmf(&app->call, endpoint, digit[0],
			qmodem_voip_issue_at, app);
	} else if (strcmp(action, "originate") == 0) {
		if (!parameters[PARAM_NUMBER])
			return qmodem_voip_reply_status(ubus, request, UBUS_STATUS_INVALID_ARGUMENT,
					    "invalid_number", "number is required");
		if (app->call.state != QMODEM_VOIP_IDLE)
			return qmodem_voip_reply_status(ubus, request, UBUS_STATUS_NOT_SUPPORTED,
					    "busy", "another call or answer owner exists");
		if (app->voice_restart_process.pending)
			return qmodem_voip_reply_status(ubus, request, UBUS_STATUS_NOT_SUPPORTED,
					    "media_not_ready", "modem voice service is recovering");
		/* The modem can reboot after the startup check while its USB functions
		 * are being re-enumerated. Revalidate the running voice-server process
		 * at the call boundary so an un-gated process can never own PCM. */
		if (qmodem_voip_prepare_media_gate(&app->media.profile) != 0)
			return qmodem_voip_reply_status(ubus, request, UBUS_STATUS_NOT_SUPPORTED,
				"media_not_ready", "modem voice media gate is not active");
		if (!journal_enabled() || run_safety("recover", 1) != 0)
			return qmodem_voip_reply_status(ubus, request, UBUS_STATUS_NOT_SUPPORTED,
				"media_not_ready", "modem PCM forwarding could not be armed");
		qmodem_voip_serial_prepare_call(&app->media);
		app->serial_active_arm_attempts = 0;
		number = blobmsg_get_string(parameters[PARAM_NUMBER]);
		result = qmodem_voip_originate(&app->call, endpoint, number,
					       qmodem_voip_issue_at, app);
		if (result != 0)
			qmodem_voip_cancel_serial_prepare();
	} else if (strcmp(action, "answer") == 0) {
		if (app->voice_restart_process.pending)
			return qmodem_voip_reply_status(ubus, request, UBUS_STATUS_NOT_SUPPORTED,
					    "media_not_ready", "modem voice service is recovering");
		if (qmodem_voip_prepare_media_gate(&app->media.profile) != 0)
			return qmodem_voip_reply_status(ubus, request, UBUS_STATUS_NOT_SUPPORTED,
				"media_not_ready", "modem voice media gate is not active");
		if (!journal_enabled() || run_safety("recover", 1) != 0)
			return qmodem_voip_reply_status(ubus, request, UBUS_STATUS_NOT_SUPPORTED,
				"media_not_ready", "modem PCM forwarding could not be armed");
		/* Incoming ringing can leave a partial serial frame queued before ATA.
		 * Match originate preparation so playback starts on a clean USB transfer
		 * boundary when the modem opens the bidirectional PCM stream. */
		qmodem_voip_serial_prepare_call(&app->media);
		result = qmodem_voip_answer(&app->call, endpoint, qmodem_voip_issue_at, app);
		if (result != 0)
			qmodem_voip_cancel_serial_prepare();
	} else if (strcmp(action, "reject") == 0) {
		result = qmodem_voip_reject(&app->call, endpoint, qmodem_voip_issue_at, app);
	} else {
		result = qmodem_voip_hangup(&app->call, endpoint, qmodem_voip_issue_at, app);
	}
	if (app->command_failed) {
		if (strcmp(action, "send_dtmf") == 0)
			return qmodem_voip_reply_status(ubus, request,
				UBUS_STATUS_UNKNOWN_ERROR, "at_failed",
				"DTMF command failed");
		qmodem_voip_cancel_serial_prepare();
		app->call.state = QMODEM_VOIP_FAULT;
		qmodem_voip_call_touch(&app->call);
		qmodem_voip_publish_event(&app->call, "fault", app);
		return qmodem_voip_reply_status(ubus, request, UBUS_STATUS_UNKNOWN_ERROR,
				    "at_failed", "AT command failed");
	}
	if (strcmp(action, "send_dtmf") == 0) {
		if (result == -4)
			return qmodem_voip_reply_status(ubus, request,
				UBUS_STATUS_INVALID_ARGUMENT, "invalid_dtmf",
				"DTMF digit is unsupported");
		if (result == -3)
			return qmodem_voip_reply_status(ubus, request,
				UBUS_STATUS_PERMISSION_DENIED, "invalid_endpoint",
				"endpoint does not own this call");
		if (result == -2)
			return qmodem_voip_reply_status(ubus, request,
				UBUS_STATUS_NOT_SUPPORTED, "invalid_state",
				"DTMF requires an active call");
		if (result != 0)
			return qmodem_voip_reply_status(ubus, request,
				UBUS_STATUS_INVALID_ARGUMENT, "invalid_endpoint",
				"endpoint is unsupported");
		return qmodem_voip_reply_ok_snapshot(ubus, request);
	}
	if (result == -3)
		return qmodem_voip_reply_status(ubus, request, UBUS_STATUS_NOT_SUPPORTED,
				    "busy", "another call or answer owner exists");
	if (result == -2)
		return qmodem_voip_reply_status(ubus, request, UBUS_STATUS_INVALID_ARGUMENT,
				    "invalid_state", "call is not in this state");
	if (result != 0)
		return qmodem_voip_reply_status(ubus, request, UBUS_STATUS_INVALID_ARGUMENT,
				    strcmp(action, "originate") == 0 ? "invalid_number" : "invalid_endpoint",
				    "call request rejected");
	qmodem_voip_publish_event(&app->call, action, app);
	return qmodem_voip_reply_ok_snapshot(ubus, request);
}

static int action_method(struct ubus_context *ubus,
			 struct ubus_object *object,
			 struct ubus_request_data *request,
			 const char *method, struct blob_attr *message)
{
	(void)object;
	return action_call(ubus, request, message, method);
}

static int status_method(struct ubus_context *ubus, struct ubus_object *object,
			 struct ubus_request_data *request, const char *method,
			 struct blob_attr *message)
{
	struct qmodem_voip_context *app = &qmodem_voip_ctxt;
	struct blob_buf buffer = { 0 };
	(void)object;
	(void)method;
	(void)message;
	qmodem_voip_media_sync();
	blob_buf_init(&buffer, 0);
	qmodem_voip_add_redacted_status(&buffer, &app->call);
	qmodem_voip_media_status(&buffer);
	(void)ubus_send_reply(ubus, request, buffer.head);
	blob_buf_free(&buffer);
	return UBUS_STATUS_OK;
}

static int capabilities_method(struct ubus_context *ubus,
			       struct ubus_object *object,
			       struct ubus_request_data *request,
			       const char *method, struct blob_attr *message)
{
	struct qmodem_voip_context *app = &qmodem_voip_ctxt;
	struct blob_buf buffer = { 0 };
	int supported;
	(void)object;
	(void)method;
	(void)message;
	qmodem_voip_media_sync();
	supported = run_safety("probe", 1) == 0;
	blob_buf_init(&buffer, 0);
	blobmsg_add_string(&buffer, "status", "experimental");
	blobmsg_add_u8(&buffer, "supported", supported);
	blobmsg_add_string(&buffer, "support_state",
			   supported ? "supported" : "unsupported");
	blobmsg_add_string(&buffer, "reason",
			   supported ? "probe_passed" : "hardware_probe_failed");
	blobmsg_add_u8(&buffer, "enabled", app->call.enabled);
	blobmsg_add_string(&buffer, "hardware", app->media.profile.model);
	blobmsg_add_string(&buffer, "external_sip", "unsupported");
	qmodem_voip_media_status(&buffer);
	(void)ubus_send_reply(ubus, request, buffer.head);
	blob_buf_free(&buffer);
	return UBUS_STATUS_OK;
}

enum qmodem_voip_activation_result {
	QMODEM_VOIP_ACTIVATION_FAILED = -1,
	QMODEM_VOIP_ACTIVATION_READY = 0,
	QMODEM_VOIP_ACTIVATION_RESTART = 1
};

static void release_runtime(struct qmodem_voip_context *app)
{
	uloop_timeout_cancel(&app->browser_timer);
	qmodem_voip_browser_media_stop(&app->browser);
	qmodem_voip_rtp_release(&app->rtp);
	qmodem_voip_media_socket_stop(&app->media_sock);
	qmodem_voip_media_release(&app->media);
}

static int activate_runtime(struct qmodem_voip_context *app)
{
	int result;

	result = qmodem_voip_prepare_adb(&app->media.profile);
	if (result < 0) {
		syslog(LOG_ERR, "ADB unlock check failed");
		return QMODEM_VOIP_ACTIVATION_FAILED;
	}
	if (result > 0) {
		syslog(LOG_NOTICE,
			"ADB enabled; waiting for modem USB re-enumeration");
		return QMODEM_VOIP_ACTIVATION_RESTART;
	}
	if (qmodem_voip_prepare_media_gate(&app->media.profile) != 0) {
		syslog(LOG_ERR, "voice-server media gate installation failed");
		return QMODEM_VOIP_ACTIVATION_FAILED;
	}
	if (run_safety("enable", 0) != 0)
		return QMODEM_VOIP_ACTIVATION_FAILED;
	qmodem_voip_profile_select(&app->media.profile, QMODEM_VOIP_PROFILE_PATH);
	if (qmodem_voip_media_engine_start(&app->media) != 0) {
		(void)run_safety("disable", 0);
		return QMODEM_VOIP_ACTIVATION_FAILED;
	}
	qmodem_voip_call_set_enabled(&app->call, 1);
	app->command_failed = 0;
	result = qmodem_voip_start_recovery(&app->call,
		qmodem_voip_issue_at, app);
	if (result != 0 || app->command_failed) {
		release_runtime(app);
		(void)run_safety("disable", 0);
		qmodem_voip_call_set_enabled(&app->call, 0);
		return QMODEM_VOIP_ACTIVATION_FAILED;
	}
	uloop_timeout_set(&app->browser_timer, 20);
	qmodem_voip_publish_event(&app->call, "enabled", app);
	return QMODEM_VOIP_ACTIVATION_READY;
}

static void schedule_modem_reenumeration(struct qmodem_voip_context *app)
{
	qmodem_voip_call_set_enabled(&app->call, 1);
	app->call.state = QMODEM_VOIP_RECOVERING;
	qmodem_voip_call_touch(&app->call);
	uloop_timeout_set(&app->restart_timer, 500);
}

void qmodem_voip_activation_timer(struct uloop_timeout *timeout)
{
	struct qmodem_voip_context *app = &qmodem_voip_ctxt;
	int result;
	(void)timeout;

	if (!app->start_enabled || app->call.enabled)
		return;
	result = activate_runtime(app);
	if (result == QMODEM_VOIP_ACTIVATION_RESTART) {
		schedule_modem_reenumeration(app);
		return;
	}
	if (result == QMODEM_VOIP_ACTIVATION_FAILED) {
		app->start_enabled = 0;
		(void)set_application_enabled(0);
		syslog(LOG_ERR,
			"persisted qmodem voip enable failed; application disabled");
	}
}

void qmodem_voip_restart_timer(struct uloop_timeout *timeout)
{
	struct qmodem_voip_context *app = &qmodem_voip_ctxt;
	(void)timeout;
	app->stop = 1;
	uloop_end();
}

static int enable_method(struct ubus_context *ubus, struct ubus_object *object,
			 struct ubus_request_data *request, const char *method,
			 struct blob_attr *message)
{
	struct qmodem_voip_context *app = &qmodem_voip_ctxt;
	int result;
	(void)object;
	(void)method;
	(void)message;
	app->command_failed = 0;
	if (app->call.enabled)
		return qmodem_voip_reply_ok_snapshot(ubus, request);
	if (set_application_enabled(1) != 0)
		return qmodem_voip_reply_status(ubus, request, UBUS_STATUS_UNKNOWN_ERROR,
				    "config_failed", "application enable could not be persisted");
	app->start_enabled = 1;
	result = activate_runtime(app);
	if (result == QMODEM_VOIP_ACTIVATION_RESTART) {
		schedule_modem_reenumeration(app);
		return qmodem_voip_reply_ok_snapshot(ubus, request);
	}
	if (result == QMODEM_VOIP_ACTIVATION_FAILED) {
		app->start_enabled = 0;
		(void)set_application_enabled(0);
		return qmodem_voip_reply_status(ubus, request, UBUS_STATUS_NOT_SUPPORTED,
				    "unsupported", "unsupported or unsafe modem media path");
	}
	return qmodem_voip_reply_ok_snapshot(ubus, request);
}

static int disable_method(struct ubus_context *ubus, struct ubus_object *object,
			  struct ubus_request_data *request, const char *method,
			  struct blob_attr *message)
{
	struct qmodem_voip_context *app = &qmodem_voip_ctxt;
	(void)object;
	(void)method;
	(void)message;
	app->command_failed = 0;
	if (set_application_enabled(0) != 0)
		return qmodem_voip_reply_status(ubus, request, UBUS_STATUS_UNKNOWN_ERROR,
				    "config_failed", "application disable could not be persisted");
	app->start_enabled = 0;
	if (app->restart_timer.pending) {
		uloop_timeout_cancel(&app->restart_timer);
	} else if (app->call.enabled && run_safety("disable", 0) != 0) {
		app->start_enabled = 1;
		(void)set_application_enabled(1);
		return qmodem_voip_reply_status(ubus, request, UBUS_STATUS_UNKNOWN_ERROR,
				    "restore_failed", "modem restore failed");
	}
	qmodem_voip_call_set_enabled(&app->call, 0);
	release_runtime(app);
	qmodem_voip_publish_event(&app->call, "disabled", app);
	return qmodem_voip_reply_ok_snapshot(ubus, request);
}

static void session_access_result(struct ubus_request *request, int type,
				  struct blob_attr *message)
{
	int *allowed = request->priv;
	static const struct blobmsg_policy policy[] = {
		{ .name = "access", .type = BLOBMSG_TYPE_BOOL }
	};
	struct blob_attr *attributes[ARRAY_SIZE(policy)] = { 0 };
	(void)type;
	if (!allowed || !message)
		return;
	blobmsg_parse(policy, ARRAY_SIZE(policy), attributes, blob_data(message), blob_len(message));
	if (attributes[0] && blobmsg_get_bool(attributes[0]))
		*allowed = 1;
}

int qmodem_voip_session_is_authorized(const char *session_id)
{
	struct ubus_context *authorization_ubus;
	struct blob_buf buffer = { 0 };
	uint32_t object;
	int allowed = 0;
	if (!session_id)
		return 0;
	authorization_ubus = ubus_connect(NULL);
	if (!authorization_ubus ||
	    ubus_lookup_id(authorization_ubus, "session", &object) != 0) {
		if (authorization_ubus)
			ubus_free(authorization_ubus);
		return 0;
	}
	blob_buf_init(&buffer, 0);
	blobmsg_add_string(&buffer, "ubus_rpc_session", session_id);
	blobmsg_add_string(&buffer, "scope", "ubus");
	blobmsg_add_string(&buffer, "object", "qmodem_voip");
	blobmsg_add_string(&buffer, "function", "issue_media_token");
	if (ubus_invoke(authorization_ubus, object, "access", buffer.head, session_access_result,
		&allowed, 1000) != 0)
		allowed = 0;
	blob_buf_free(&buffer);
	ubus_free(authorization_ubus);
	return allowed;
}

static int call_history_method(struct ubus_context *ubus,
	struct ubus_object *object, struct ubus_request_data *request,
	const char *method, struct blob_attr *message)
{
	struct json_object *history;
	struct json_object *reply;
	struct blob_buf buffer = { 0 };
	(void)object;
	(void)method;
	(void)message;
	history = qmodem_voip_call_history_load(QMODEM_VOIP_CALL_HISTORY_PATH);
	if (!history)
		return qmodem_voip_reply_status(ubus, request,
			UBUS_STATUS_UNKNOWN_ERROR, "history_unavailable",
			"call history could not be read");
	reply = json_object_new_object();
	if (!reply) {
		json_object_put(history);
		return UBUS_STATUS_UNKNOWN_ERROR;
	}
	json_object_object_add(reply, "calls", history);
	blob_buf_init(&buffer, 0);
	if (!blobmsg_add_json_from_string(&buffer,
		json_object_to_json_string_ext(reply, JSON_C_TO_STRING_PLAIN))) {
		blob_buf_free(&buffer);
		json_object_put(reply);
		return UBUS_STATUS_UNKNOWN_ERROR;
	}
	(void)ubus_send_reply(ubus, request, buffer.head);
	blob_buf_free(&buffer);
	json_object_put(reply);
	return UBUS_STATUS_OK;
}

void qmodem_voip_publish_event(const struct qmodem_voip_call *call,
			       const char *event, void *opaque)
{
	struct qmodem_voip_context *app = opaque;
	struct qmodem_voip_completed_call completed;
	struct blob_buf buffer = { 0 };
	if (qmodem_voip_call_get_completed(&app->call, &completed)) {
		if (qmodem_voip_call_history_append(QMODEM_VOIP_CALL_HISTORY_PATH,
			&completed) == 0)
			qmodem_voip_call_ack_completed(&app->call);
		else
			syslog(LOG_ERR, "unable to persist completed call history");
	}
	if (call->state == QMODEM_VOIP_ACTIVE &&
	    app->media.backend == QMODEM_VOIP_MEDIA_BACKEND_SERIAL &&
	    app->serial_active_arm_attempts == 0) {
		app->serial_active_generation++;
		app->serial_active_arm_attempts = 1;
	}
	if (app->media.backend == QMODEM_VOIP_MEDIA_BACKEND_SERIAL &&
	    (call->state == QMODEM_VOIP_EARLY_MEDIA ||
	     call->state == QMODEM_VOIP_ACTIVE))
		qmodem_voip_serial_set_attached(&app->media, 1);
	/* A normal call must not schedule a voice-server restart.  On this
	 * firmware the dependency restart can take over a minute; arming it from
	 * ringing/active/terminating therefore makes the next call fail with
	 * "modem voice service is recovering" even though the previous call ended
	 * cleanly.  Recovery is reserved for a media safety failure, which moves
	 * the call into FAULT and is followed by the normal idle transition. */
	if (call->state == QMODEM_VOIP_FAULT) {
		if (!app->voice_restart_needed)
			syslog(LOG_INFO, "voice-server recovery armed by call state %s",
				qmodem_voip_state_name(call->state));
		app->voice_restart_needed = 1;
	}
	if (call->state == QMODEM_VOIP_IDLE ||
	    call->state == QMODEM_VOIP_TERMINATING ||
	    call->state == QMODEM_VOIP_DISABLED ||
	    call->state == QMODEM_VOIP_FAULT) {
		app->serial_active_arm_attempts = 0;
		app->serial_active_generation++;
		if (app->rtp.active)
			qmodem_voip_rtp_release(&app->rtp);
		qmodem_voip_media_socket_release(&app->media_sock);
	}
	if ((call->state == QMODEM_VOIP_IDLE ||
	     call->state == QMODEM_VOIP_TERMINATING ||
	     call->state == QMODEM_VOIP_DISABLED ||
	     call->state == QMODEM_VOIP_FAULT) &&
	    app->media.backend == QMODEM_VOIP_MEDIA_BACKEND_SERIAL) {
		qmodem_voip_serial_set_attached(&app->media, 0);
		qmodem_voip_serial_reset_stream(&app->media);
	}
	if (call->state == QMODEM_VOIP_IDLE && app->voice_restart_needed) {
		syslog(LOG_INFO,
			"voice-server recovery requested at idle revision %llu",
			(unsigned long long)call->revision);
		app->voice_restart_needed = 0;
		restart_voice_server(app);
	}
	qmodem_voip_media_sync();
	blob_buf_init(&buffer, 0);
	blobmsg_add_string(&buffer, "event", event);
	qmodem_voip_add_redacted_status(&buffer, call);
	(void)ubus_send_event(app->ubus, "qmodem_voip.call", buffer.head);
	blob_buf_free(&buffer);
}

int qmodem_voip_correlation_parse(const char *value)
{
	if (!value || strcmp(value, "response") == 0)
		return QMODEM_VOIP_CORR_RESPONSE;
	if (strcmp(value, "terminal") == 0)
		return QMODEM_VOIP_CORR_TERMINAL;
	if (strcmp(value, "ambiguous") == 0)
		return QMODEM_VOIP_CORR_AMBIGUOUS;
	return QMODEM_VOIP_CORR_IDLE;
}

void at_line_event(struct ubus_context *ubus,
		   struct ubus_event_handler *handler,
		   const char *type, struct blob_attr *message)
{
	struct qmodem_voip_context *app = &qmodem_voip_ctxt;
	static const struct blobmsg_policy policy[] = {
		{ .name = "port", .type = BLOBMSG_TYPE_STRING },
		{ .name = "restart_epoch", .type = BLOBMSG_TYPE_INT64 },
		{ .name = "sequence", .type = BLOBMSG_TYPE_INT64 },
		{ .name = "raw_line", .type = BLOBMSG_TYPE_STRING },
		{ .name = "correlation", .type = BLOBMSG_TYPE_STRING },
		{ .name = "command_id", .type = BLOBMSG_TYPE_INT64 },
		{ .name = "drop_count", .type = BLOBMSG_TYPE_INT64 }
	};
	struct blob_attr *values[ARRAY_SIZE(policy)] = { 0 };
	const char *correlation;
	uint64_t command_id = 0;
	(void)handler;
	(void)type;
	blobmsg_parse(policy, ARRAY_SIZE(policy), values, blob_data(message),
		      blob_len(message));
	if (!values[0] || !values[1] || !values[2] || !values[3])
		return;
	if (values[5])
		command_id = blobmsg_get_u64(values[5]);
	correlation = values[4] ? blobmsg_get_string(values[4]) : NULL;
	if (!values[5] || command_id == 0 ||
	    qmodem_voip_correlation_parse(correlation) == QMODEM_VOIP_CORR_IDLE)
		return;
	app->command_failed = 0;
	(void)qmodem_voip_line(&app->call, blobmsg_get_string(values[0]),
			       blobmsg_get_u64(values[1]), blobmsg_get_u64(values[2]),
			       blobmsg_get_string(values[3]),
			       qmodem_voip_correlation_parse(correlation), command_id,
			       values[6] ? blobmsg_get_u64(values[6]) : 0,
			       qmodem_voip_issue_at, qmodem_voip_publish_event, app);
	if (app->command_failed) {
		app->call.state = QMODEM_VOIP_FAULT;
		qmodem_voip_call_touch(&app->call);
		qmodem_voip_publish_event(&app->call, "fault", app);
	}
	(void)ubus;
}

void at_urc_event(struct ubus_context *ubus,
		  struct ubus_event_handler *handler,
		  const char *type, struct blob_attr *message)
{
	struct qmodem_voip_context *app = &qmodem_voip_ctxt;
	static const struct blobmsg_policy policy[] = {
		{ .name = "port", .type = BLOBMSG_TYPE_STRING },
		{ .name = "owner", .type = BLOBMSG_TYPE_STRING },
		{ .name = "raw_line", .type = BLOBMSG_TYPE_STRING },
		{ .name = "restart_epoch", .type = BLOBMSG_TYPE_INT64 },
		{ .name = "sequence", .type = BLOBMSG_TYPE_INT64 },
		{ .name = "drop_count", .type = BLOBMSG_TYPE_INT64 }
	};
	struct blob_attr *values[ARRAY_SIZE(policy)] = { 0 };
	(void)ubus;
	(void)handler;
	(void)type;
	blobmsg_parse(policy, ARRAY_SIZE(policy), values, blob_data(message),
		      blob_len(message));
	if (!values[0] || !values[1] || !values[2] || !values[3] || !values[4] ||
	    strcmp(blobmsg_get_string(values[1]), "qmodem.voip") != 0)
		return;
	app->command_failed = 0;
	(void)qmodem_voip_line(&app->call, blobmsg_get_string(values[0]),
			       blobmsg_get_u64(values[3]), blobmsg_get_u64(values[4]),
			       blobmsg_get_string(values[2]), QMODEM_VOIP_CORR_IDLE, 0,
			       values[5] ? blobmsg_get_u64(values[5]) : 0,
			       qmodem_voip_issue_at, qmodem_voip_publish_event, app);
	if (app->command_failed) {
		app->call.state = QMODEM_VOIP_FAULT;
		qmodem_voip_call_touch(&app->call);
		qmodem_voip_publish_event(&app->call, "fault", app);
	}
}

void qmodem_voip_call_timer(struct uloop_timeout *timeout)
{
	struct qmodem_voip_context *app = &qmodem_voip_ctxt;
	(void)timeout;
	if (app->call.state == QMODEM_VOIP_ACTIVE &&
	    app->media.backend == QMODEM_VOIP_MEDIA_BACKEND_SERIAL &&
	    app->serial_active_arm_attempts > 0 &&
	    app->serial_active_arm_attempts <= 3) {
		if (start_serial_arm(app) != 0) {
			app->call.state = QMODEM_VOIP_FAULT;
			qmodem_voip_call_touch(&app->call);
			qmodem_voip_publish_event(&app->call, "fault", app);
		}
	}
	if (app->serial_arm_process.pending) {
		uloop_timeout_set(&app->call_timer, 1000);
		return;
	}
	if (app->call.enabled &&
	    (app->call.state == QMODEM_VOIP_OUTGOING_SETUP ||
	     app->call.state == QMODEM_VOIP_INCOMING_RINGING ||
	     app->call.state == QMODEM_VOIP_EARLY_MEDIA)) {
		app->command_failed = 0;
		(void)qmodem_voip_poll_active(&app->call, qmodem_voip_issue_at, app);
		if (app->command_failed) {
			app->call.state = QMODEM_VOIP_FAULT;
			qmodem_voip_call_touch(&app->call);
			qmodem_voip_publish_event(&app->call, "fault", app);
		}
	} else if (app->call.enabled &&
		   (app->call.state == QMODEM_VOIP_ACTIVE ||
		    app->call.state == QMODEM_VOIP_TERMINATING) &&
		   !app->call.reconcile_pending) {
		app->command_failed = 0;
		(void)qmodem_voip_poll_active(&app->call, qmodem_voip_issue_at, app);
		if (app->command_failed) {
			app->call.reconcile_pending = 0;
			app->call.reconcile_command_id = 0;
		}
	} else if (app->call.enabled && app->call.state == QMODEM_VOIP_IDLE &&
		   app->media.profile.idle_clcc_poll) {
		static unsigned idle_poll_waits;
		if (app->call.reconcile_pending && app->call.idle_poll &&
		    ++idle_poll_waits >= 5U) {
			if (app->idle_at.pending) {
				ubus_abort_request(app->ubus, &app->idle_at_request);
				qmodem_voip_at_direct_done(&app->idle_at, 0);
			}
			app->call.idle_poll = 0;
			app->call.reconcile_pending = 0;
			app->call.reconcile_command_id = 0;
		}
		if (!app->call.reconcile_pending) {
			idle_poll_waits = 0;
			app->command_failed = 0;
			(void)qmodem_voip_poll_idle(&app->call, qmodem_voip_issue_idle_at, app);
			if (app->command_failed) {
				app->call.idle_poll = 0;
				app->call.reconcile_pending = 0;
				app->call.reconcile_command_id = 0;
			}
		}
	}
	uloop_timeout_set(&app->call_timer, 1000);
}

static const struct ubus_method methods[] = {
	UBUS_METHOD_NOARG("status", status_method),
	UBUS_METHOD_NOARG("capabilities", capabilities_method),
	UBUS_METHOD_NOARG("enable", enable_method),
	UBUS_METHOD_NOARG("disable", disable_method),
	UBUS_METHOD("originate", action_method, action_policy),
	UBUS_METHOD("answer", action_method, action_policy),
	UBUS_METHOD("reject", action_method, action_policy),
	UBUS_METHOD("hangup", action_method, action_policy),
	UBUS_METHOD("send_dtmf", action_method, action_policy),
	UBUS_METHOD_NOARG("call_history", call_history_method),
	UBUS_METHOD("issue_media_token", qmodem_voip_media_token_method, qmodem_voip_media_token_policy),
	UBUS_METHOD("issue_socket_session", qmodem_voip_socket_session_method, qmodem_voip_socket_session_policy),
	UBUS_METHOD("attach_rtp", qmodem_voip_rtp_attach_method, qmodem_voip_rtp_policy),
	UBUS_METHOD_NOARG("release_rtp", qmodem_voip_rtp_release_method)
};

struct ubus_object_type qmodem_voip_object_type =
	UBUS_OBJECT_TYPE("qmodem_voip", methods);
