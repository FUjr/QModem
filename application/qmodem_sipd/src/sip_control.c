#define _POSIX_C_SOURCE 200809L

#include "sip_credentials.h"

#include <libubox/blobmsg_json.h>
#include <libubox/uloop.h>
#include <libubus.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <uci.h>

#define INBOUND_PIDFILE "/var/run/qmodem_voip/sip-inbound.pid"
#define OUTBOUND_PIDFILE "/var/run/qmodem_voip/sip-outbound.pid"

static struct ubus_context *ubus;
static struct ubus_object object;

enum { ARG_USERNAME, ARG_DIRECTION, ARG_MAX };

static const struct blobmsg_policy policy[ARG_MAX] = {
	[ARG_USERNAME] = { .name = "username", .type = BLOBMSG_TYPE_STRING },
	[ARG_DIRECTION] = { .name = "direction", .type = BLOBMSG_TYPE_STRING }
};

enum {
	MESSAGE_DIRECTION, MESSAGE_RECIPIENT, MESSAGE_SENDER, MESSAGE_TIMESTAMP,
	MESSAGE_CONTENT, MESSAGE_ID, MESSAGE_REVISION, MESSAGE_MODEM, MESSAGE_MAX
};

static const struct blobmsg_policy message_policy[MESSAGE_MAX] = {
	[MESSAGE_DIRECTION] = { .name = "direction", .type = BLOBMSG_TYPE_STRING },
	[MESSAGE_RECIPIENT] = { .name = "recipient_uri", .type = BLOBMSG_TYPE_STRING },
	[MESSAGE_SENDER] = { .name = "sender", .type = BLOBMSG_TYPE_STRING },
	[MESSAGE_TIMESTAMP] = { .name = "timestamp", .type = BLOBMSG_TYPE_UNSPEC },
	[MESSAGE_CONTENT] = { .name = "content", .type = BLOBMSG_TYPE_STRING },
	[MESSAGE_ID] = { .name = "message_id", .type = BLOBMSG_TYPE_STRING },
	[MESSAGE_REVISION] = { .name = "revision", .type = BLOBMSG_TYPE_UNSPEC },
	[MESSAGE_MODEM] = { .name = "modem_id", .type = BLOBMSG_TYPE_STRING }
};

static int enabled(const char *section)
{
	struct uci_context *context = uci_alloc_context();
	struct uci_package *package = NULL;
	struct uci_section *uci_section;
	const char *value;
	int result = 0;
	if (!context || uci_load(context, "qmodem_sip", &package) != UCI_OK)
		goto out;
	uci_section = uci_lookup_section(context, package, section);
	value = uci_section ? uci_lookup_option_string(context, uci_section, "enabled") : NULL;
	result = value && !strcmp(value, "1");
out:
	if (package)
		uci_unload(context, package);
	if (context)
		uci_free_context(context);
	return result;
}

static int process_live(const char *path)
{
	FILE *file = fopen(path, "r");
	long process = 0;
	if (!file)
		return 0;
	(void)fscanf(file, "%ld", &process);
	(void)fclose(file);
	return process > 1 && (kill((pid_t)process, 0) == 0);
}

struct direction_status_reply {
	struct blob_buf *buffer;
};

static void direction_status_cb(struct ubus_request *request, int type,
	struct blob_attr *message)
{
	static const struct blobmsg_policy reply_policy[] = {
		{ .name = "registered", .type = BLOBMSG_TYPE_BOOL }
	};
	struct blob_attr *values[1] = { 0 };
	struct direction_status_reply *reply = request->priv;
	(void)type;
	blobmsg_parse(reply_policy, 1, values, blob_data(message), blob_len(message));
	if (values[0])
		blobmsg_add_u8(reply->buffer, "registered", blobmsg_get_bool(values[0]));
}

static void add_direction(struct ubus_context *context, struct blob_buf *buffer,
	const char *name, const char *pidfile)
{
	struct direction_status_reply reply = { .buffer = buffer };
	char object_name[64];
	uint32_t id;
	void *table = blobmsg_open_table(buffer, name);
	blobmsg_add_u8(buffer, "enabled", enabled(name));
	blobmsg_add_u8(buffer, "running", process_live(pidfile));
	(void)snprintf(object_name, sizeof(object_name), "qmodem.sip.%s", name);
	if (ubus_lookup_id(context, object_name, &id) == 0)
		(void)ubus_invoke(context, id, "status", NULL, direction_status_cb,
			&reply, 1000);
	blobmsg_close_table(buffer, table);
}

static void add_credential_status(struct blob_buf *buffer)
{
	struct uci_context *context = uci_alloc_context();
	struct uci_package *package = NULL;
	struct uci_section *section;
	const char *username = NULL;
	const char *password = NULL;
	if (context && uci_load(context, "qmodem_sip", &package) == UCI_OK) {
		section = uci_lookup_section(context, package, "inbound");
		username = section ? uci_lookup_option_string(context, section, "username") : NULL;
		password = section ? uci_lookup_option_string(context, section, "password") : NULL;
		blobmsg_add_u8(buffer, "configured", username && *username && password && *password);
		blobmsg_add_string(buffer, "username", username ? username : "");
	} else {
		blobmsg_add_u8(buffer, "configured", 0);
		blobmsg_add_string(buffer, "username", "");
	}
	if (package)
		uci_unload(context, package);
	if (context)
		uci_free_context(context);
}

static int status_method(struct ubus_context *context, struct ubus_object *obj,
	struct ubus_request_data *request, const char *method, struct blob_attr *message)
{
	struct blob_buf buffer = { 0 };
	uint32_t id;
	(void)obj; (void)method; (void)message;
	blob_buf_init(&buffer, 0);
	blobmsg_add_string(&buffer, "status", "ok");
	add_credential_status(&buffer);
	add_direction(context, &buffer, "inbound", INBOUND_PIDFILE);
	add_direction(context, &buffer, "outbound", OUTBOUND_PIDFILE);
	blobmsg_add_u8(&buffer, "voipd_available",
		ubus_lookup_id(context, "qmodem_voip", &id) == 0);
	blobmsg_add_u8(&buffer, "smsd_available",
		ubus_lookup_id(context, "qmodem.sms", &id) == 0);
	ubus_send_reply(context, request, buffer.head);
	blob_buf_free(&buffer);
	return UBUS_STATUS_OK;
}

static int generate_method(struct ubus_context *context, struct ubus_object *obj,
	struct ubus_request_data *request, const char *method, struct blob_attr *message)
{
	struct blob_attr *values[ARG_MAX] = { 0 };
	struct blob_buf buffer = { 0 };
	char password[QMODEM_VOIP_SIP_PASSWORD_SIZE] = { 0 };
	FILE *file;
	long process = 0;
	(void)obj; (void)method;
	blobmsg_parse(policy, ARG_MAX, values, blob_data(message), blob_len(message));
	if (!values[ARG_USERNAME] ||
	    qmodem_voip_sip_credentials_generate(blobmsg_get_string(values[ARG_USERNAME]),
		password) != 0)
		return UBUS_STATUS_INVALID_ARGUMENT;
	file = fopen(INBOUND_PIDFILE, "r");
	if (file) {
		(void)fscanf(file, "%ld", &process);
		(void)fclose(file);
		if (process > 1)
			(void)kill((pid_t)process, SIGHUP);
	}
	blob_buf_init(&buffer, 0);
	blobmsg_add_string(&buffer, "status", "success");
	blobmsg_add_u8(&buffer, "configured", 1);
	blobmsg_add_string(&buffer, "username", blobmsg_get_string(values[ARG_USERNAME]));
	blobmsg_add_string(&buffer, "password", password);
	ubus_send_reply(context, request, buffer.head);
	blob_buf_free(&buffer);
	memset(password, 0, sizeof(password));
	return UBUS_STATUS_OK;
}

struct proxy_reply { char *json; };

static void proxy_reply_cb(struct ubus_request *request, int type, struct blob_attr *message)
{
	struct proxy_reply *reply = request->priv;
	(void)type;
	free(reply->json);
	reply->json = blobmsg_format_json(message, true);
}

static int send_message_method(struct ubus_context *context, struct ubus_object *obj,
	struct ubus_request_data *request, const char *method, struct blob_attr *message)
{
	struct blob_attr *values[MESSAGE_MAX] = { 0 };
	struct proxy_reply reply = { 0 };
	struct blob_buf buffer = { 0 };
	const char *direction;
	char target[64];
	uint32_t id;
	int result;
	(void)obj; (void)method;
	blobmsg_parse(message_policy, MESSAGE_MAX, values, blob_data(message), blob_len(message));
	if (!values[MESSAGE_DIRECTION])
		return UBUS_STATUS_INVALID_ARGUMENT;
	direction = blobmsg_get_string(values[MESSAGE_DIRECTION]);
	if (strcmp(direction, "inbound") && strcmp(direction, "outbound"))
		return UBUS_STATUS_INVALID_ARGUMENT;
	(void)snprintf(target, sizeof(target), "qmodem.sip.%s", direction);
	if (ubus_lookup_id(context, target, &id) != 0)
		return UBUS_STATUS_NOT_FOUND;
	result = ubus_invoke(context, id, "send_message", message, proxy_reply_cb,
		&reply, 35000);
	if (result != 0 || !reply.json) {
		free(reply.json);
		return result ? result : UBUS_STATUS_UNKNOWN_ERROR;
	}
	blob_buf_init(&buffer, 0);
	if (!blobmsg_add_json_from_string(&buffer, reply.json)) {
		blob_buf_free(&buffer);
		free(reply.json);
		return UBUS_STATUS_UNKNOWN_ERROR;
	}
	ubus_send_reply(context, request, buffer.head);
	blob_buf_free(&buffer);
	free(reply.json);
	return UBUS_STATUS_OK;
}

static const struct ubus_method methods[] = {
	UBUS_METHOD_NOARG("status", status_method),
	UBUS_METHOD("generate_credentials", generate_method, policy),
	UBUS_METHOD("send_message", send_message_method, message_policy)
};

static struct ubus_object_type object_type = UBUS_OBJECT_TYPE("qmodem.sip", methods);

static void stop_handler(int signo)
{
	(void)signo;
	uloop_end();
}

int main(void)
{
	char username[QMODEM_VOIP_SIP_USERNAME_SIZE];

	signal(SIGINT, stop_handler);
	signal(SIGTERM, stop_handler);
	(void)qmodem_voip_sip_credentials_sync(username);
	if (uloop_init() != 0)
		return 1;
	ubus = ubus_connect(NULL);
	if (!ubus)
		return 1;
	ubus_add_uloop(ubus);
	object.name = "qmodem.sip";
	object.type = &object_type;
	object.methods = object_type.methods;
	object.n_methods = object_type.n_methods;
	if (ubus_add_object(ubus, &object) != 0)
		return 1;
	uloop_run();
	ubus_free(ubus);
	uloop_done();
	return 0;
}
