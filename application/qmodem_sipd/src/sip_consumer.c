/*
 * qmodem_voip_sip_consumer - a headless SIP consumer that owns the LAN SIP
 * user-agent surface and bridges the cellular call's PCM to the far-end RTP
 * peer locally, using only the daemon's media socket.
 *
 * Unlike qmodem_voip_registrar, this process does NOT ask the daemon to
 * attach an in-daemon RTP socket. Instead it:
 *   1. authenticates and handles SIP signalling (reusing sip_gateway.c),
 *   2. asks the daemon for the current call revision and a short-lived local
 *      socket session (issue_socket_session),
 *   3. attaches to the daemon media socket with that (revision, session),
 *   4. decodes the modem PCM_CAPTURE frames and sends them as G.711 RTP to the
 *      LAN peer, and forwards the LAN peer's RTP payload back as PCM_PLAYBACK.
 *
 * Media is therefore owned by this consumer; the daemon only streams raw PCM
 * over the unix socket. The in-daemon attach_rtp/release_rtp path is left in
 * place for compatibility but is unused by this process.
 */
#define _POSIX_C_SOURCE 200809L

#include "sip_gateway.h"
#include "sip_activation.h"
#include "g711.h"
#include "sip_registration.h"
#include "media_socket_client.h"
#include "rtp_transport.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <libubox/blobmsg.h>
#include <libubox/uloop.h>
#include <libubus.h>
#include <netinet/in.h>
#include <pjlib.h>
#include <pjlib-util.h>
#include <pjsip.h>
#include <pjsip-ua/sip_regc.h>
#include <pjsip/sip_transport_tcp.h>
#include <pjsip/sip_transport_tls.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <syslog.h>
#include <time.h>
#include <unistd.h>

#define REALM QMODEM_VOIP_SIP_REALM
#define BINDING_SIZE 384
#define MAX_SIP_MESSAGE 4096
#define MAX_SIP_BODY 2048
#define RATE_SLOTS 32
#define UBUS_ACTION_TIMEOUT_MS 30000
#define DEFAULT_PIDFILE "/var/run/qmodem_voip_sip_consumer.pid"
#define MEDIA_ATTACH_RETRY_MS 250
#define MEDIA_ATTACH_RETRY_MAX 20
#define EVENT_LOOP_SLICE_MS 10

#define RTP_HEADER_SIZE 12U
#define RTP_PACKET_SIZE (RTP_HEADER_SIZE + QMODEM_VOIP_MEDIA_SAMPLES)

struct consumer {
	pjsip_endpoint *endpoint;
	pjsip_auth_srv auth;
	pj_caching_pool caching_pool;
	pj_pool_t *pool;
	pjsip_module module;
	char username[QMODEM_VOIP_SIP_USERNAME_SIZE];
	char ha1[QMODEM_VOIP_SIP_HA1_SIZE];
	char challenge_nonce[QMODEM_VOIP_SIP_NONCE_SIZE];
	struct qmodem_voip_sip_nonce_store nonces;
	char binding[BINDING_SIZE];
	unsigned expires;
	pj_time_val binding_until;
	struct ubus_context *ubus;
	struct ubus_event_handler call_events;
	struct qmodem_voip_sip_rate auth_rates[RATE_SLOTS];
	struct qmodem_voip_sip_rate invite_rates[RATE_SLOTS];
	struct qmodem_voip_sip_call call;
	struct qmodem_voip_sip_media media;
	struct qmodem_voip_media_socket_client media_sock;
	char media_socket_path[QMODEM_VOIP_MEDIA_SOCKET_PATH_MAX];
	uint64_t media_revision;
	int media_attached;
	struct uloop_fd media_fd_event;
	int rtp_fd;
	struct uloop_fd rtp_fd_event;
	int rtp_attached;
	struct uloop_timeout media_attach_timeout;
	unsigned media_attach_attempts;
	struct sockaddr_in rtp_peer;
	enum qmodem_voip_media_codec rtp_codec;
	uint16_t rtp_sequence;
	uint32_t rtp_timestamp;
	uint32_t rtp_ssrc;
	pjsip_tx_data *pending_lan_response;
	pjsip_response_addr pending_lan_response_addr;
	int reload_requested;
	char lan_address[16];
	int outbound;
	pjsip_regc *regc;
	pjsip_auth_clt_sess outbound_auth;
	int outbound_auth_initialized;
	pjsip_tx_data *outbound_invite;
	char dialog_contact[BINDING_SIZE];
	char outbound_server[256];
	char outbound_server_uri[384];
	char outbound_username[QMODEM_VOIP_SIP_USERNAME_SIZE];
	char outbound_aor[320];
	char outbound_password[128];
	char outbound_realm[128];
	char incoming_number[64];
	int incoming_caller_id_withheld;
	int incoming_ringing;
	int invite_alerted;
	unsigned outbound_port;
	unsigned outbound_interval;
	int outbound_registered;
	struct uloop_timeout outbound_register_retry;
	struct qmodem_voip_sip_registration_retry registration_retry;
	char direction[9];
	char pidfile[128];
	char sms_modem[64];
	unsigned listen_port;
	struct ubus_object ubus_object;
	char ubus_object_name[32];
	struct {
		struct ubus_request_data request;
		struct uloop_timeout timeout;
		int active;
		int auth_retried;
	} pending_message;
};

static int g711_bridge_encode(enum qmodem_voip_media_codec codec,
		       const int16_t *input, size_t samples, uint8_t *output)
{
	if (codec != QMODEM_VOIP_MEDIA_PCMA && codec != QMODEM_VOIP_MEDIA_PCMU)
		return -1;
	for (size_t i = 0; i < samples; i++)
		output[i] = codec == QMODEM_VOIP_MEDIA_PCMA
			? qmodem_g711_alaw_encode(input[i]) : qmodem_g711_ulaw_encode(input[i]);
	return 0;
}

static int g711_bridge_decode(enum qmodem_voip_media_codec codec,
		       const uint8_t *input, size_t samples, int16_t *output)
{
	if (codec != QMODEM_VOIP_MEDIA_PCMA && codec != QMODEM_VOIP_MEDIA_PCMU)
		return -1;
	for (size_t i = 0; i < samples; i++)
		output[i] = codec == QMODEM_VOIP_MEDIA_PCMA
			? qmodem_g711_alaw_decode(input[i]) : qmodem_g711_ulaw_decode(input[i]);
	return 0;
}

static struct consumer app;
static volatile sig_atomic_t running = 1;
static void stop_media(void);
static void resend_incoming_invite(void);
static int rtp_open(void);
static int attach_media(void);
static void outbound_register(void);

static uint32_t registration_retry_entropy(void)
{
	struct timespec now;
	uint64_t entropy = (uint64_t)getpid() ^ app.registration_retry.failures;

	if (clock_gettime(CLOCK_MONOTONIC, &now) == 0)
		entropy ^= (uint64_t)now.tv_sec ^ (uint64_t)now.tv_nsec;
	return (uint32_t)(entropy ^ (entropy >> 32));
}

static void schedule_outbound_register_retry(void)
{
	unsigned delay;

	if (!running || !app.outbound || app.outbound_register_retry.pending)
		return;
	delay = qmodem_voip_sip_registration_failed(&app.registration_retry,
		registration_retry_entropy());
	uloop_timeout_set(&app.outbound_register_retry, (int)delay);
	syslog(LOG_WARNING,
		"qmodem_voip sip: outbound REGISTER retry scheduled in %u ms",
		delay);
}

static void outbound_regc_cb(struct pjsip_regc_cbparam *param)
{
	if (!param)
		return;
	app.outbound_registered = param->status == PJ_SUCCESS &&
		param->code >= 200 && param->code < 300 && param->expiration > 0;
	if (app.outbound_registered) {
		uloop_timeout_cancel(&app.outbound_register_retry);
		qmodem_voip_sip_registration_succeeded(&app.registration_retry);
		if (strlen(app.outbound_aor) >= sizeof(app.binding)) {
			app.outbound_registered = 0;
			schedule_outbound_register_retry();
			return;
		}
		(void)snprintf(app.binding, sizeof(app.binding), "%s", app.outbound_aor);
		app.expires = param->expiration ? param->expiration : app.outbound_interval;
		pj_gettimeofday(&app.binding_until);
		app.binding_until.sec += (long)app.expires;
		syslog(LOG_INFO, "qmodem_voip sip: outbound REGISTER succeeded code=%d expires=%u",
			param->code, app.expires);
	} else {
		app.binding[0] = '\0';
		app.expires = 0;
		syslog(LOG_WARNING, "qmodem_voip sip: outbound REGISTER failed status=%d code=%d",
			(int)param->status, param->code);
		schedule_outbound_register_retry();
	}
}

static int outbound_setup_registration(void)
{
	pj_str_t server = pj_str(app.outbound_server_uri);
	pj_str_t aor = pj_str(app.outbound_aor);
	char contact[384];
	pj_str_t contact_str;
	pjsip_cred_info credential;
	unsigned interval = app.outbound_interval;
	if (!app.outbound || !app.outbound_server[0] || !app.outbound_password[0])
		return -1;
	(void)snprintf(contact, sizeof(contact), "<sip:%s@%s:%u;transport=tls>",
		app.username, app.lan_address, app.listen_port);
	contact_str = pj_str(contact);
	if (pjsip_regc_create(app.endpoint, NULL, &outbound_regc_cb, &app.regc) != PJ_SUCCESS ||
		pjsip_regc_init(app.regc, &server, &aor, &aor, 1, &contact_str,
			interval) != PJ_SUCCESS)
		return -1;
	pj_bzero(&credential, sizeof(credential));
	credential.realm = pj_str(app.outbound_realm[0] ? app.outbound_realm : (char *)"*");
	credential.scheme = pj_str((char *)"Digest");
	credential.username = pj_str(app.username);
	credential.data_type = PJSIP_CRED_DATA_PLAIN_PASSWD;
	credential.data = pj_str(app.outbound_password);
	if (pjsip_regc_set_credentials(app.regc, 1, &credential) != PJ_SUCCESS ||
		pjsip_regc_set_delay_before_refresh(app.regc, interval > 60 ? 30 : 5) != PJ_SUCCESS)
		return -1;
	if (pjsip_auth_clt_init(&app.outbound_auth, app.endpoint, app.pool, 0) != PJ_SUCCESS ||
	    pjsip_auth_clt_set_credentials(&app.outbound_auth, 1, &credential) != PJ_SUCCESS)
		return -1;
	app.outbound_auth_initialized = 1;
	return 0;
}

static void outbound_register(void)
{
	pjsip_tx_data *request = NULL;
	pj_status_t status;
	if (!app.outbound || !app.regc)
		return;
	qmodem_voip_sip_registration_attempt(&app.registration_retry);
	if (pjsip_regc_register(app.regc, PJ_TRUE, &request) != PJ_SUCCESS) {
		syslog(LOG_WARNING, "qmodem_voip sip: outbound REGISTER request creation failed");
		schedule_outbound_register_retry();
		return;
	}
	status = pjsip_regc_send(app.regc, request);
	if (status != PJ_SUCCESS) {
		syslog(LOG_WARNING, "qmodem_voip sip: outbound REGISTER send failed status=%d",
			(int)status);
		schedule_outbound_register_retry();
	}
}

static void outbound_register_retry(struct uloop_timeout *timeout)
{
	(void)timeout;
	qmodem_voip_sip_registration_retry_started(&app.registration_retry);
	outbound_register();
}

static void stop_handler(int signo)
{
	(void)signo;
	running = 0;
}

static void reload_handler(int signo)
{
	(void)signo;
	app.reload_requested = 1;
}

static int str_equal(const pj_str_t *value, const char *expected)
{
	size_t length = strlen(expected);
	return value && value->slen == (pj_ssize_t)length &&
	       memcmp(value->ptr, expected, length) == 0;
}

static pj_status_t lookup_credential(pj_pool_t *pool, const pj_str_t *realm,
				     const pj_str_t *account,
				     pjsip_cred_info *credential)
{
	(void)pool;
	if (!str_equal(realm, REALM) || !str_equal(account, app.username))
		return PJSIP_EAUTHACCNOTFOUND;
	pj_bzero(credential, sizeof(*credential));
	credential->realm = pj_str((char *)REALM);
	credential->scheme = pjsip_DIGEST_STR;
	credential->username = pj_str(app.username);
	credential->data_type = PJSIP_CRED_DATA_DIGEST;
	credential->data = pj_str(app.ha1);
	return PJ_SUCCESS;
}

static int new_nonce(pjsip_rx_data *request)
{
	pj_time_val now;
	pj_gettimeofday(&now);
	return qmodem_voip_sip_nonce_issue(&app.nonces,
		request->pkt_info.src_addr.ipv4.sin_addr.s_addr,
		(uint64_t)now.sec, app.challenge_nonce);
}

static uint32_t source_address(pjsip_rx_data *request)
{
	return request->pkt_info.src_addr.ipv4.sin_addr.s_addr;
}

static int rate_allow(struct qmodem_voip_sip_rate *rates, pjsip_rx_data *request,
		      unsigned limit)
{
	pj_time_val now;
	pj_gettimeofday(&now);
	return qmodem_voip_sip_rate_allow(rates, RATE_SLOTS, source_address(request),
					  (uint64_t)now.sec, limit);
}

static void add_string_header(pjsip_tx_data *response, const char *name,
			      const char *value)
{
	pj_str_t header_name = pj_str((char *)name);
	pj_str_t header_value = pj_str((char *)value);
	pjsip_generic_string_hdr *header = pjsip_generic_string_hdr_create(
		response->pool, &header_name, &header_value);
	pjsip_msg_add_hdr(response->msg, (pjsip_hdr *)header);
}

static void send_response(pjsip_rx_data *request, int status,
			  pj_bool_t challenge, pj_bool_t stale)
{
	pjsip_tx_data *response;
	pj_status_t rc = pjsip_endpt_create_response(app.endpoint, request, status,
						NULL, &response);
	if (rc != PJ_SUCCESS)
		return;
	if (challenge) {
		pj_str_t qop = pj_str((char *)"auth");
		pj_str_t nonce = pj_str(app.challenge_nonce);
		(void)pjsip_auth_srv_challenge(&app.auth, &qop, &nonce, NULL,
					       stale, response);
	}
	(void)pjsip_endpt_send_response2(app.endpoint, request, response, NULL, NULL);
}

static pjsip_authorization_hdr *authorization(pjsip_rx_data *request)
{
	return (pjsip_authorization_hdr *)pjsip_msg_find_hdr(
		request->msg_info.msg, PJSIP_H_AUTHORIZATION, NULL);
}

static int nonce_check(pjsip_rx_data *request, pjsip_authorization_hdr *header,
		       unsigned long *nc, struct qmodem_voip_sip_nonce **accepted)
{
	pj_time_val now;
	char nc_text[9];
	char *end;
	char nonce[QMODEM_VOIP_SIP_NONCE_SIZE];
	if (!header || !str_equal(&header->credential.digest.qop, "auth") ||
	    header->credential.digest.nonce.slen != 32 ||
	    header->credential.digest.nc.slen != 8)
		return 0;
	memcpy(nonce, header->credential.digest.nonce.ptr, 32);
	nonce[32] = '\0';
	pj_gettimeofday(&now);
	memcpy(nc_text, header->credential.digest.nc.ptr, 8);
	nc_text[8] = '\0';
	errno = 0;
	*nc = strtoul(nc_text, &end, 16);
	return errno == 0 && *end == '\0' &&
		qmodem_voip_sip_nonce_check(&app.nonces, source_address(request),
			nonce, (uint64_t)now.sec, *nc, accepted) ==
		QMODEM_VOIP_SIP_NONCE_OK;
}

static int authenticate(pjsip_rx_data *request)
{
	pjsip_authorization_hdr *header = authorization(request);
	struct qmodem_voip_sip_nonce *accepted = NULL;
	unsigned long nc = 0;
	int status = PJSIP_SC_FORBIDDEN;
	if (!header) {
		if (!rate_allow(app.auth_rates, request, 10)) {
			send_response(request, PJSIP_SC_FORBIDDEN, PJ_FALSE, PJ_FALSE);
			return 0;
		}
		if (new_nonce(request) != 0) {
			send_response(request, PJSIP_SC_SERVICE_UNAVAILABLE, PJ_FALSE, PJ_FALSE);
			return 0;
		}
		send_response(request, PJSIP_SC_UNAUTHORIZED, PJ_TRUE, PJ_FALSE);
		return 0;
	}
	if (!nonce_check(request, header, &nc, &accepted)) {
		if (!rate_allow(app.auth_rates, request, 10)) {
			send_response(request, PJSIP_SC_FORBIDDEN, PJ_FALSE, PJ_FALSE);
			return 0;
		}
		if (new_nonce(request) != 0) {
			send_response(request, PJSIP_SC_SERVICE_UNAVAILABLE, PJ_FALSE, PJ_FALSE);
			return 0;
		}
		send_response(request, PJSIP_SC_UNAUTHORIZED, PJ_TRUE, PJ_TRUE);
		return 0;
	}
	if (pjsip_auth_srv_verify(&app.auth, request, &status) != PJ_SUCCESS) {
		if (!rate_allow(app.auth_rates, request, 10)) {
			send_response(request, PJSIP_SC_FORBIDDEN, PJ_FALSE, PJ_FALSE);
			return 0;
		}
		send_response(request, status, PJ_FALSE, PJ_FALSE);
		return 0;
	}
	qmodem_voip_sip_nonce_commit(accepted, nc);
	return 1;
}

static int trusted_outbound_request(pjsip_rx_data *request)
{
	return app.outbound && request && request->tp_info.transport &&
		PJSIP_TRANSPORT_IS_SECURE(request->tp_info.transport) &&
		request->tp_info.transport->dir == PJSIP_TP_DIR_OUTGOING;
}

static unsigned request_expiry(pjsip_msg *message, pjsip_contact_hdr *contact)
{
	pjsip_expires_hdr *expires;
	long value = contact->expires;
	if (value == (long)PJSIP_EXPIRES_NOT_SPECIFIED) {
		expires = (pjsip_expires_hdr *)pjsip_msg_find_hdr(
			message, PJSIP_H_EXPIRES, NULL);
		value = expires ? expires->ivalue : 3600;
	}
	if (value == 0)
		return 0;
	if (value < 60)
		return 60;
	if (value > 3600)
		return 3600;
	return (unsigned)value;
}

static void register_contact(pjsip_rx_data *request)
{
	pjsip_msg *message = request->msg_info.msg;
	pjsip_contact_hdr *contact;
	pjsip_tx_data *response;
	char expiry[16];
	unsigned requested;
	if (!authenticate(request))
		return;
	contact = (pjsip_contact_hdr *)pjsip_msg_find_hdr(message,
							 PJSIP_H_CONTACT, NULL);
	if (!contact || contact->star) {
		send_response(request, PJSIP_SC_BAD_REQUEST, PJ_FALSE, PJ_FALSE);
		return;
	}
	requested = request_expiry(message, contact);
	if (requested == 0) {
		app.binding[0] = '\0';
		app.expires = 0;
		app.binding_until.sec = 0;
	} else {
		int length = pjsip_uri_print(PJSIP_URI_IN_CONTACT_HDR, contact->uri,
					     app.binding, sizeof(app.binding) - 1);
		if (length < 0) {
			send_response(request, PJSIP_SC_BAD_REQUEST, PJ_FALSE, PJ_FALSE);
			return;
		}
		app.binding[length] = '\0';
		app.expires = requested;
		pj_gettimeofday(&app.binding_until);
		app.binding_until.sec += (long)requested;
	}
	if (pjsip_endpt_create_response(app.endpoint, request, PJSIP_SC_OK, NULL,
					&response) != PJ_SUCCESS)
		return;
	(void)snprintf(expiry, sizeof(expiry), "%u", app.expires);
	add_string_header(response, "X-QModem-Expires", expiry);
	add_string_header(response, "X-QModem-Binding",
			  app.binding[0] ? app.binding : "none");
	(void)pjsip_endpt_send_response2(app.endpoint, request, response, NULL, NULL);
	if (app.binding[0])
		resend_incoming_invite();
}

static int binding_active(void)
{
	pj_time_val now;
	pj_gettimeofday(&now);
	return app.binding[0] && now.sec < app.binding_until.sec;
}

static int sip_number(pjsip_rx_data *request, char number[64])
{
	pjsip_sip_uri *uri = (pjsip_sip_uri *)pjsip_uri_get_uri(
		request->msg_info.msg->line.req.uri);
	pj_ssize_t length;
	if (!uri || !uri->user.ptr || uri->user.slen <= 0 || uri->user.slen >= 64)
		return -1;
	length = uri->user.slen;
	memcpy(number, uri->user.ptr, (size_t)length);
	number[length] = '\0';
	return strspn(number, "0123456789+*#,p") == (size_t)length ? 0 : -1;
}

static int ubus_action(const char *action, const char *number)
{
	struct blob_buf buffer = { 0 };
	uint32_t object;
	int result;
	if (!app.ubus || ubus_lookup_id(app.ubus, "qmodem_voip", &object) != 0)
		return -1;
	blob_buf_init(&buffer, 0);
	blobmsg_add_string(&buffer, "endpoint",
		app.outbound ? "external_sip" : "lan_sip");
	if (number)
		blobmsg_add_string(&buffer, "number", number);
	result = ubus_invoke(app.ubus, object, action, buffer.head, NULL, NULL,
			     UBUS_ACTION_TIMEOUT_MS);
	blob_buf_free(&buffer);
	return result == 0 ? 0 : -1;
}

static int ubus_lookup_voip(uint32_t *object)
{
	if (!app.ubus || ubus_lookup_id(app.ubus, "qmodem_voip", object) != 0)
		return -1;
	return 0;
}

static void session_reply(struct ubus_request *request, int type,
			  struct blob_attr *message)
{
	static const struct blobmsg_policy policy[] = {
		{ .name = "session_id", .type = BLOBMSG_TYPE_STRING },
		{ .name = "call_revision", .type = BLOBMSG_TYPE_UNSPEC }
	};
	struct blob_attr *values[ARRAY_SIZE(policy)] = { 0 };
	struct qmodem_voip_media_socket_client *client =
		(struct qmodem_voip_media_socket_client *)request->priv;
	(void)type;
	blobmsg_parse(policy, ARRAY_SIZE(policy), values, blob_data(message),
		      blob_len(message));
	if (!values[0])
		return;
	(void)snprintf(client->session_id, sizeof(client->session_id), "%s",
		blobmsg_get_string(values[0]));
}

static int ubus_issue_socket_session(void)
{
	struct blob_buf buffer = { 0 };
	uint32_t object;
	int result;
	if (ubus_lookup_voip(&object) != 0)
		return -1;
	blob_buf_init(&buffer, 0);
	blobmsg_add_u64(&buffer, "call_revision", app.media_revision);
	result = ubus_invoke(app.ubus, object, "issue_socket_session", buffer.head,
			     session_reply, &app.media_sock, UBUS_ACTION_TIMEOUT_MS);
	blob_buf_free(&buffer);
	return result == 0 && app.media_sock.session_id[0] ? 0 : -1;
}

static int supported_sdp(pjsip_rx_data *request,
			 struct qmodem_voip_sip_media *media)
{
	pjsip_msg_body *body = request->msg_info.msg->body;
	if (!body)
		return -1;
	if (body->len > MAX_SIP_BODY)
		return -1;
	return qmodem_voip_sip_parse_media((const char *)body->data, body->len,
		media);
}

static int copy_pj_string(char *output, size_t size, const pj_str_t *value)
{
	if (!output || !size || !value || value->slen <= 0 ||
	    value->slen >= (pj_ssize_t)size)
		return -1;
	memcpy(output, value->ptr, (size_t)value->slen);
	output[value->slen] = '\0';
	return 0;
}

static int request_identity(pjsip_rx_data *request, char *call_id,
			    size_t call_id_size, char *remote_tag,
			    size_t remote_tag_size, char *branch,
			    size_t branch_size, unsigned *cseq)
{
	if (!request->msg_info.cid || !request->msg_info.from ||
	    !request->msg_info.cseq || !request->msg_info.via ||
	    request->msg_info.cseq->cseq < 0 ||
	    copy_pj_string(call_id, call_id_size, &request->msg_info.cid->id) != 0 ||
	    copy_pj_string(remote_tag, remote_tag_size,
		&request->msg_info.from->tag) != 0 ||
	    copy_pj_string(branch, branch_size,
		&request->msg_info.via->branch_param) != 0)
		return -1;
	*cseq = (unsigned)request->msg_info.cseq->cseq;
	return 0;
}

static int set_lan_answer(pjsip_rx_data *request, pjsip_tx_data *response,
			  unsigned payload_type)
{
	pjsip_sip_uri *uri;
	pj_str_t type = pj_str((char *)"application");
	pj_str_t subtype = pj_str((char *)"sdp");
	pj_str_t text;
	pjsip_to_hdr *to;
	pjsip_contact_hdr *contact;
	pjsip_uri *parsed_contact;
	char address[INET_ADDRSTRLEN];
	char body[512];
	char contact_value[64];
	struct in_addr parsed;
	const char *payloads;
	const char *rtpmap;
	int length;
	if (payload_type == 8U) {
		payloads = "8 101";
		rtpmap = "a=rtpmap:8 PCMA/8000\r\n";
	} else if (payload_type == 0U) {
		payloads = "0 101";
		rtpmap = "a=rtpmap:0 PCMU/8000\r\n";
	} else {
		return -1;
	}
	uri = (pjsip_sip_uri *)pjsip_uri_get_uri(request->msg_info.msg->line.req.uri);
	if (!uri || uri->host.slen <= 0 || uri->host.slen >= (pj_ssize_t)sizeof(address))
		return -1;
	memcpy(address, uri->host.ptr, (size_t)uri->host.slen);
	address[uri->host.slen] = '\0';
	if (inet_pton(AF_INET, address, &parsed) != 1)
		return -1;
	length = snprintf(body, sizeof(body),
		"v=0\r\no=qmodem_voip 1 1 IN IP4 %s\r\ns=QModem VoIP\r\n"
		"c=IN IP4 %s\r\nt=0 0\r\nm=audio 40000 RTP/AVP %s\r\n%s"
		"a=rtpmap:101 telephone-event/8000\r\na=sendrecv\r\n",
		address, address, payloads, rtpmap);
	if (length < 0 || length >= (int)sizeof(body))
		return -1;
	to = (pjsip_to_hdr *)pjsip_msg_find_hdr(response->msg, PJSIP_H_TO, NULL);
	if (!to)
		return -1;
	/* The initial INVITE has no local tag, while an in-dialog re-INVITE
	 * already carries the tag we selected for the dialog.  Replacing that
	 * tag would make the response belong to a new dialog and causes clients
	 * such as Linphone to tear the call down after their session refresh. */
	if (to->tag.slen == 0)
		pj_create_unique_string(response->pool, &to->tag);
	length = snprintf(contact_value, sizeof(contact_value),
		"sip:qmodem_voip@%s:%u%s", address, app.listen_port,
		app.outbound ? ";transport=tls" : "");
	if (length < 0 || length >= (int)sizeof(contact_value))
		return -1;
	contact = pjsip_contact_hdr_create(response->pool);
	/* pjsip_parse_uri() may retain pointers into its input buffer.  The
	 * formatted value above is stack storage, so clone the parsed URI into the
	 * response pool before returning from this function. */
	parsed_contact = pjsip_parse_uri(response->pool, contact_value, length, 0);
	if (!parsed_contact)
		return -1;
	contact->uri = (pjsip_uri *)pjsip_uri_clone(response->pool, parsed_contact);
	if (!contact->uri)
		return -1;
	pjsip_msg_add_hdr(response->msg, (pjsip_hdr *)contact);
	text = pj_str(body);
	response->msg->body = pjsip_msg_body_create(response->pool, &type, &subtype, &text);
	return response->msg->body ? 0 : -1;
}

static void invite_call(pjsip_rx_data *request)
{
	char number[64];
	char call_id[QMODEM_VOIP_SIP_CALL_ID_SIZE];
	char remote_tag[QMODEM_VOIP_SIP_TAG_SIZE];
	char branch[QMODEM_VOIP_SIP_BRANCH_SIZE];
	struct qmodem_voip_sip_media media;
	unsigned cseq;
	pjsip_tx_data *response = NULL;
	if (!rate_allow(app.invite_rates, request, 5)) {
		syslog(LOG_WARNING, "qmodem_voip sip: invite rate limit");
		send_response(request, PJSIP_SC_SERVICE_UNAVAILABLE, PJ_FALSE, PJ_FALSE);
		return;
	}
	if (!trusted_outbound_request(request) && !authenticate(request))
		return;
	if (supported_sdp(request, &media) != 0) {
		send_response(request, PJSIP_SC_NOT_ACCEPTABLE_HERE, PJ_FALSE, PJ_FALSE);
		return;
	}
	if (!binding_active()) {
		send_response(request, PJSIP_SC_BUSY_HERE, PJ_FALSE, PJ_FALSE);
		return;
	}
	/* The daemon's originate method is the authoritative arbitration point.
	 * A status RPC can race a release event or fail to parse a freshly-added
	 * status field; treating that observation as Busy Here strands all later
	 * calls even though the daemon is idle. */
	/* A previous consumer instance can miss the daemon's release event while
	 * the modem itself has already returned to idle.  Do not let that stale
	 * local record make every subsequent INVITE look busy. */
	if (app.call.active) {
		syslog(LOG_WARNING,
			"qmodem_voip sip: clearing stale local call before new INVITE");
		stop_media();
		qmodem_voip_sip_call_release(&app.call);
	}
	if (sip_number(request, number) != 0 ||
	    request_identity(request, call_id, sizeof(call_id), remote_tag,
		    sizeof(remote_tag), branch, sizeof(branch), &cseq) != 0) {
		send_response(request, PJSIP_SC_NOT_ACCEPTABLE_HERE, PJ_FALSE, PJ_FALSE);
		return;
	}
	if (ubus_action("originate", number) != 0) {
		syslog(LOG_WARNING, "qmodem_voip sip: cellular originate rejected");
		send_response(request, PJSIP_SC_SERVICE_UNAVAILABLE, PJ_FALSE, PJ_FALSE);
		return;
	}
	if (qmodem_voip_sip_call_begin(&app.call, QMODEM_VOIP_SIP_CALL_LAN,
			call_id, remote_tag, branch, cseq) != 0) {
		(void)ubus_action("hangup", NULL);
		syslog(LOG_WARNING, "qmodem_voip sip: call record rejected");
		send_response(request, PJSIP_SC_SERVICE_UNAVAILABLE, PJ_FALSE, PJ_FALSE);
		return;
	}
	app.media = media;
	if (pjsip_endpt_create_response(app.endpoint, request, PJSIP_SC_OK, NULL,
				       &response) != PJ_SUCCESS ||
	    set_lan_answer(request, response, media.payload_type) != 0 ||
	    pjsip_get_response_addr(app.pool, request, &app.pending_lan_response_addr) != PJ_SUCCESS) {
		if (response)
			pjsip_tx_data_dec_ref(response);
		(void)ubus_action("hangup", NULL);
		qmodem_voip_sip_call_clear(&app.call);
		send_response(request, PJSIP_SC_SERVICE_UNAVAILABLE, PJ_FALSE, PJ_FALSE);
		return;
	}
	if (app.pending_lan_response_addr.transport)
		pjsip_transport_add_ref(app.pending_lan_response_addr.transport);
	app.pending_lan_response = response;
	send_response(request, PJSIP_SC_TRYING, PJ_FALSE, PJ_FALSE);
	send_response(request, PJSIP_SC_RINGING, PJ_FALSE, PJ_FALSE);
}

/* Handle a session-refresh/re-negotiation INVITE (or UPDATE) inside the
 * established LAN dialog.  Treating every INVITE as a new cellular originate
 * makes Linphone's refresh receive 486 Busy Here; the peer then ends an
 * otherwise healthy call roughly 30-40 seconds after it was answered. */
static int in_dialog_media_refresh(pjsip_rx_data *request)
{
	char call_id[QMODEM_VOIP_SIP_CALL_ID_SIZE];
	char remote_tag[QMODEM_VOIP_SIP_TAG_SIZE];
	char branch[QMODEM_VOIP_SIP_BRANCH_SIZE];
	struct qmodem_voip_sip_media media;
	unsigned cseq;
	pjsip_tx_data *response = NULL;

	if (!app.call.active || !app.call.established ||
	    app.call.origin != QMODEM_VOIP_SIP_CALL_LAN ||
	    request_identity(request, call_id, sizeof(call_id), remote_tag,
		    sizeof(remote_tag), branch, sizeof(branch), &cseq) != 0 ||
	    strcmp(call_id, app.call.call_id) != 0 ||
	    strcmp(remote_tag, app.call.remote_tag) != 0)
		return -1;
	(void)branch;
	(void)cseq;
	if (!trusted_outbound_request(request) && !authenticate(request))
		return 0;
	if (supported_sdp(request, &media) != 0) {
		send_response(request, PJSIP_SC_NOT_ACCEPTABLE_HERE, PJ_FALSE, PJ_FALSE);
		return 0;
	}
	if (pjsip_endpt_create_response(app.endpoint, request, PJSIP_SC_OK, NULL,
				       &response) != PJ_SUCCESS ||
	    set_lan_answer(request, response, media.payload_type) != 0) {
		if (response)
			pjsip_tx_data_dec_ref(response);
		send_response(request, PJSIP_SC_SERVICE_UNAVAILABLE, PJ_FALSE, PJ_FALSE);
		return 0;
	}
	app.media = media;
	if (app.media_attached) {
		app.rtp_codec = (enum qmodem_voip_media_codec)media.payload_type;
		app.rtp_peer.sin_port = htons((uint16_t)media.port);
		if (inet_pton(AF_INET, media.address, &app.rtp_peer.sin_addr) != 1) {
			pjsip_tx_data_dec_ref(response);
			send_response(request, PJSIP_SC_NOT_ACCEPTABLE_HERE, PJ_FALSE, PJ_FALSE);
			return 0;
		}
	}
	if (pjsip_endpt_send_response2(app.endpoint, request, response, NULL, NULL) !=
	    PJ_SUCCESS)
		pjsip_tx_data_dec_ref(response);
	else
		syslog(LOG_INFO, "qmodem_voip sip: accepted in-dialog INVITE refresh cseq %u",
		       cseq);
	return 0;
}

static int set_incoming_offer(pjsip_tx_data *request)
{
	pj_str_t type = pj_str((char *)"application");
	pj_str_t subtype = pj_str((char *)"sdp");
	pj_str_t text;
	char body[512];
	int length = snprintf(body, sizeof(body),
		"v=0\r\no=qmodem_voip 1 1 IN IP4 %s\r\n"
		"s=QModem VoIP\r\nc=IN IP4 %s\r\nt=0 0\r\n"
		"m=audio 40000 RTP/AVP 8 0 101\r\n"
		"a=rtpmap:8 PCMA/8000\r\na=rtpmap:0 PCMU/8000\r\n"
		"a=rtpmap:101 telephone-event/8000\r\na=sendrecv\r\n",
		app.lan_address, app.lan_address);
	if (length < 0 || length >= (int)sizeof(body))
		return -1;
	text = pj_str(body);
	request->msg->body = pjsip_msg_body_create(request->pool, &type, &subtype, &text);
	return request->msg->body ? 0 : -1;
}

static void remember_outbound_invite(pjsip_tx_data *request)
{
	if (app.outbound_invite)
		pjsip_tx_data_dec_ref(app.outbound_invite);
	app.outbound_invite = request;
	if (request)
		pjsip_tx_data_add_ref(request);
}

static void send_dialog_bye(void)
{
	pjsip_method method;
	pjsip_tx_data *bye = NULL;
	pjsip_contact_hdr *contact;
	pjsip_cid_hdr *call_id;
	pjsip_from_hdr *from;
	pjsip_to_hdr *to;
	pjsip_cseq_hdr *cseq;
	pjsip_uri *target;
	pj_str_t remote_tag;
	unsigned next_cseq;

	if (!app.call.active || !app.call.established || !app.outbound_invite ||
	    !app.dialog_contact[0])
		return;
	contact = (pjsip_contact_hdr *)pjsip_msg_find_hdr(
		app.outbound_invite->msg, PJSIP_H_CONTACT, NULL);
	call_id = PJSIP_MSG_CID_HDR(app.outbound_invite->msg);
	from = PJSIP_MSG_FROM_HDR(app.outbound_invite->msg);
	to = PJSIP_MSG_TO_HDR(app.outbound_invite->msg);
	cseq = PJSIP_MSG_CSEQ_HDR(app.outbound_invite->msg);
	if (!contact || !call_id || !from || !to || !cseq)
		return;
	pjsip_method_set(&method, PJSIP_BYE_METHOD);
	target = pjsip_parse_uri(app.outbound_invite->pool, app.dialog_contact,
		strlen(app.dialog_contact), 0);
	if (!target)
		return;
	next_cseq = cseq->cseq + 1U;
	if (pjsip_endpt_create_request_from_hdr(app.endpoint, &method,
		target, from, to, NULL, call_id, next_cseq, NULL, &bye) != PJ_SUCCESS)
		return;
	remote_tag = pj_str(app.call.remote_tag);
	pj_strdup(bye->pool, &PJSIP_MSG_TO_HDR(bye->msg)->tag, &remote_tag);
	if (pjsip_endpt_send_request(app.endpoint, bye, 30000, NULL, NULL) != PJ_SUCCESS)
		syslog(LOG_WARNING, "qmodem_voip sip: cellular release BYE send failed");
}

static void send_invite_cancel(void)
{
	pjsip_tx_data *cancel = NULL;

	if (!app.call.active || app.call.established ||
	    app.call.origin != QMODEM_VOIP_SIP_CALL_CELLULAR || !app.outbound_invite)
		return;
	if (pjsip_endpt_create_cancel(app.endpoint, app.outbound_invite, &cancel) != PJ_SUCCESS)
		return;
	if (pjsip_endpt_send_request(app.endpoint, cancel, 30000, NULL, NULL) == PJ_SUCCESS)
		syslog(LOG_INFO, "qmodem_voip sip: call offer to the SIP phone cancelled");
	else
		syslog(LOG_WARNING, "qmodem_voip sip: cellular release CANCEL send failed");
}

static pj_status_t send_outbound_ack(pjsip_tx_data *invite,
		pjsip_rx_data *response)
{
	pjsip_contact_hdr *contact;
	pjsip_cid_hdr *call_id;
	pjsip_from_hdr *from;
	pjsip_to_hdr *to;
	pjsip_cseq_hdr *cseq;
	pjsip_tx_data *ack = NULL;
	pjsip_tpselector selector;
	pj_status_t status;
	if (!invite || !response || !invite->tp_info.transport)
		return PJ_EINVAL;
	contact = (pjsip_contact_hdr *)pjsip_msg_find_hdr(
		response->msg_info.msg, PJSIP_H_CONTACT, NULL);
	call_id = PJSIP_MSG_CID_HDR(invite->msg);
	from = PJSIP_MSG_FROM_HDR(invite->msg);
	to = response->msg_info.to;
	cseq = response->msg_info.cseq;
	if (!contact || !contact->uri || !call_id || !from || !to || !cseq)
		return PJ_EINVAL;
	status = pjsip_endpt_create_request_from_hdr(app.endpoint, &pjsip_ack_method,
		contact->uri, from, to, NULL, call_id, cseq->cseq, NULL, &ack);
	pj_bzero(&selector, sizeof(selector));
	selector.type = PJSIP_TPSELECTOR_TRANSPORT;
	selector.u.transport = invite->tp_info.transport;
	if (status == PJ_SUCCESS)
		status = pjsip_tx_data_set_transport(ack, &selector);
	if (status == PJ_SUCCESS)
		status = pjsip_endpt_send_request_stateless(app.endpoint, ack, NULL, NULL);
	else if (ack)
		pjsip_tx_data_dec_ref(ack);
	return status;
}

static pj_bool_t on_response(pjsip_rx_data *response);

static void outbound_invite_cb(void *token, pjsip_event *event)
{
	pjsip_transaction *transaction;
	pjsip_tx_data *request;
	pj_status_t status;
	(void)token;
	if (!event || event->type != PJSIP_EVENT_TSX_STATE)
		return;
	transaction = event->body.tsx_state.tsx;
	if (!transaction || transaction->status_code < 200)
		return;
	if (event->body.tsx_state.type == PJSIP_EVENT_RX_MSG &&
	    (transaction->status_code == PJSIP_SC_UNAUTHORIZED ||
	     transaction->status_code == PJSIP_SC_PROXY_AUTHENTICATION_REQUIRED)) {
		status = pjsip_auth_clt_reinit_req(&app.outbound_auth,
			event->body.tsx_state.src.rdata, transaction->last_tx, &request);
		if (status == PJ_SUCCESS) {
			PJSIP_MSG_CSEQ_HDR(request->msg)->cseq++;
			remember_outbound_invite(request);
			status = pjsip_endpt_send_request(app.endpoint, request, 30000,
				NULL, &outbound_invite_cb);
		}
		if (status == PJ_SUCCESS)
			return;
		syslog(LOG_WARNING, "qmodem_voip sip: outbound INVITE authentication failed status=%d",
			(int)status);
		(void)ubus_action("reject", NULL);
		qmodem_voip_sip_call_release(&app.call);
	} else if (event->body.tsx_state.type == PJSIP_EVENT_RX_MSG) {
		(void)on_response(event->body.tsx_state.src.rdata);
	}
}

static void incoming_invite_cb(void *token, pjsip_event *event)
{
	pjsip_transaction *transaction;
	pjsip_cid_hdr *cid;
	char call_id[QMODEM_VOIP_SIP_CALL_ID_SIZE];
	(void)token;
	if (!event || event->type != PJSIP_EVENT_TSX_STATE ||
	    !(transaction = event->body.tsx_state.tsx))
		return;
	if (event->body.tsx_state.type == PJSIP_EVENT_RX_MSG) {
		if (transaction->status_code < 200)
			app.invite_alerted = 1;
		else
			(void)on_response(event->body.tsx_state.src.rdata);
		return;
	}
	if (transaction->state != PJSIP_TSX_STATE_TERMINATED ||
	    transaction->status_code < 300 || !transaction->last_tx ||
	    !app.call.active || app.call.established)
		return;
	cid = (pjsip_cid_hdr *)pjsip_msg_find_hdr(transaction->last_tx->msg,
						  PJSIP_H_CALL_ID, NULL);
	if (!cid || copy_pj_string(call_id, sizeof(call_id), &cid->id) != 0 ||
	    strcmp(call_id, app.call.call_id) != 0)
		return;
	qmodem_voip_sip_call_release(&app.call);
	remember_outbound_invite(NULL);
}

static void send_incoming_invite(void);

static void resend_incoming_invite(void)
{
	if (app.outbound || !app.incoming_ringing || app.call.established)
		return;
	if (app.call.active) {
		if (app.invite_alerted)
			return;
		send_invite_cancel();
		qmodem_voip_sip_call_release(&app.call);
		remember_outbound_invite(NULL);
	}
	syslog(LOG_INFO, "qmodem_voip sip: SIP phone registered while ringing, offering the call again");
	send_incoming_invite();
}

static void send_incoming_invite(void)
{
	pjsip_method method;
	pjsip_tx_data *request;
	char address[384];
	pj_str_t target = pj_str(app.binding);
	pj_str_t from;
	pj_str_t to = pj_str(app.binding);
	pj_str_t contact;
	char call_id[QMODEM_VOIP_SIP_CALL_ID_SIZE];
	char pending_tag[] = "pending";
	char pending_branch[] = "pending";
	pjsip_cid_hdr *cid;
	if (!binding_active() || app.call.active)
		return;
	(void)snprintf(address, sizeof(address), "%s:%s@%s:%u%s",
		app.outbound ? "sips" : "sip", app.username, app.lan_address,
		app.listen_port, app.outbound ? ";transport=tls" : "");
	from = pj_str(address);
	contact = pj_str(address);
	pjsip_method_set(&method, PJSIP_INVITE_METHOD);
	if (pjsip_endpt_create_request(app.endpoint, &method, &target, &from, &to,
					      &contact, NULL, 1, NULL, &request) != PJ_SUCCESS ||
		set_incoming_offer(request) != 0)
		return;
	if (!app.incoming_caller_id_withheld && app.incoming_number[0] &&
		strspn(app.incoming_number, "0123456789+") == strlen(app.incoming_number)) {
		char asserted_identity[160];
		(void)snprintf(asserted_identity, sizeof(asserted_identity), "<sip:%s@%s>",
			app.incoming_number, app.lan_address);
		add_string_header(request, "P-Asserted-Identity", asserted_identity);
	}
	cid = (pjsip_cid_hdr *)pjsip_msg_find_hdr(request->msg, PJSIP_H_CALL_ID, NULL);
	if (!cid || copy_pj_string(call_id, sizeof(call_id), &cid->id) != 0 ||
	    qmodem_voip_sip_call_begin(&app.call, QMODEM_VOIP_SIP_CALL_CELLULAR,
		call_id, pending_tag, pending_branch, 1) != 0)
		return;
	remember_outbound_invite(request);
	app.dialog_contact[0] = '\0';
	app.invite_alerted = 0;
	if (pjsip_endpt_send_request(app.endpoint, request, 30000, NULL,
		app.outbound ? &outbound_invite_cb : &incoming_invite_cb) != PJ_SUCCESS) {
		remember_outbound_invite(NULL);
		app.dialog_contact[0] = '\0';
		qmodem_voip_sip_call_release(&app.call);
	} else {
		syslog(LOG_INFO, "qmodem_voip sip: call offered to the SIP phone");
	}
}

static pj_bool_t on_response(pjsip_rx_data *response)
{
	int status = response->msg_info.msg->line.status.code;
	char call_id[QMODEM_VOIP_SIP_CALL_ID_SIZE];
	if (!app.call.active || app.call.origin != QMODEM_VOIP_SIP_CALL_CELLULAR ||
	    !response->msg_info.cid ||
	    copy_pj_string(call_id, sizeof(call_id), &response->msg_info.cid->id) != 0 ||
	    strcmp(call_id, app.call.call_id) != 0)
		return PJ_FALSE;
	if (status == PJSIP_SC_UNAUTHORIZED ||
	    status == PJSIP_SC_PROXY_AUTHENTICATION_REQUIRED)
		return PJ_FALSE;
	if (app.call.established) {
		if (status >= 200 && status < 300)
			(void)send_outbound_ack(app.outbound_invite, response);
		return PJ_FALSE;
	}
	if (status >= 200 && status < 300) {
		pj_status_t ack_status = send_outbound_ack(app.outbound_invite, response);
		char remote_tag[QMODEM_VOIP_SIP_TAG_SIZE];
		pjsip_msg_body *body = response->msg_info.msg->body;
		struct qmodem_voip_sip_media media;
		int media_attached = body && qmodem_voip_sip_parse_media(
			(const char *)body->data, body->len, &media) == 0;
		if (ack_status != PJ_SUCCESS) {
			syslog(LOG_WARNING, "qmodem_voip sip: outbound ACK failed status=%d",
				(int)ack_status);
			(void)ubus_action("reject", NULL);
			qmodem_voip_sip_call_release(&app.call);
		} else if (media_attached) {
			pjsip_contact_hdr *contact = (pjsip_contact_hdr *)pjsip_msg_find_hdr(
				response->msg_info.msg, PJSIP_H_CONTACT, NULL);
			if (contact)
				(void)pjsip_uri_print(PJSIP_URI_IN_CONTACT_HDR, contact->uri,
					app.dialog_contact, sizeof(app.dialog_contact) - 1);
			app.dialog_contact[sizeof(app.dialog_contact) - 1] = '\0';
			app.media = media;
			/* For a cellular-originated call the SIP 200 response is the
			 * answer trigger.  The old path answered the modem call but never
			 * attached the RTP/local media socket, so the call looked connected
			 * while no modem PCM could reach the SIP peer.  Answer first so the
			 * daemon has an active revision, then bind both media directions. */
			if (ubus_action("answer", NULL) == 0 && rtp_open() == 0 &&
				attach_media() == 0 && response->msg_info.to &&
			    copy_pj_string(remote_tag, sizeof(remote_tag),
				&response->msg_info.to->tag) == 0)
				(void)qmodem_voip_sip_call_establish(&app.call, remote_tag);
			else {
				if (response->msg_info.to &&
				    copy_pj_string(remote_tag, sizeof(remote_tag),
					&response->msg_info.to->tag) == 0 &&
				    qmodem_voip_sip_call_establish(&app.call, remote_tag) == 0)
					send_dialog_bye();
				stop_media();
				qmodem_voip_sip_call_release(&app.call);
			}
		} else {
			(void)ubus_action("reject", NULL);
			qmodem_voip_sip_call_release(&app.call);
		}
	} else if (status >= 300) {
		syslog(LOG_INFO, "qmodem_voip sip: SIP phone declined the call (%d)", status);
		if (status == PJSIP_SC_BUSY_HERE || status == PJSIP_SC_BUSY_EVERYWHERE ||
		    status == PJSIP_SC_DECLINE)
			(void)ubus_action("reject", NULL);
		app.incoming_ringing = 0;
		qmodem_voip_sip_call_release(&app.call);
		remember_outbound_invite(NULL);
	}
	return PJ_FALSE;
}

static void release_pending_lan_response(void);

static int invoke_action(void *opaque)
{
	return ubus_action((const char *)opaque, NULL);
}

static void end_call(pjsip_rx_data *request, int cancel)
{
	char call_id[QMODEM_VOIP_SIP_CALL_ID_SIZE];
	char remote_tag[QMODEM_VOIP_SIP_TAG_SIZE];
	char branch[QMODEM_VOIP_SIP_BRANCH_SIZE];
	unsigned cseq;
	int status;
	/* CANCEL belongs to the original INVITE transaction and commonly has no
	 * Authorization header (Linphone follows that SIP behavior).  Challenging
	 * it with 401 leaves the cellular leg active and the caller stuck waiting;
	 * identity and Via-branch matching below still prevent unrelated calls from
	 * being cancelled.  BYE remains Digest-authenticated. */
	if (request_identity(request, call_id, sizeof(call_id), remote_tag,
		    sizeof(remote_tag), branch, sizeof(branch), &cseq) != 0) {
		send_response(request, PJSIP_SC_BAD_REQUEST, PJ_FALSE, PJ_FALSE);
		return;
	}
	if (!cancel && !trusted_outbound_request(request) &&
	    !(app.call.active && app.call.established &&
	      app.call.origin == QMODEM_VOIP_SIP_CALL_CELLULAR &&
	      strcmp(call_id, app.call.call_id) == 0 &&
	      strcmp(remote_tag, app.call.remote_tag) == 0) &&
	    !authenticate(request))
		return;
	syslog(LOG_INFO,
		"qmodem_voip sip: received %s call-id=%s tag=%s branch=%s cseq=%u stored-active=%u stored-origin=%u stored-tag=%s stored-branch=%s stored-cseq=%u established=%u",
		cancel ? "CANCEL" : "BYE", call_id, remote_tag, branch, cseq,
		app.call.active, app.call.origin, app.call.remote_tag,
		app.call.branch, app.call.cseq, app.call.established);
	status = cancel ? qmodem_voip_sip_call_cancel(&app.call, 1, call_id,
		remote_tag, branch, cseq, invoke_action, "hangup") :
			qmodem_voip_sip_call_bye(&app.call, 1, call_id, remote_tag,
				invoke_action, "hangup");
	syslog(LOG_INFO, "qmodem_voip sip: %s result=%d", cancel ? "CANCEL" : "BYE",
		status);
	if (status == PJSIP_SC_OK) {
		/* A CANCEL/BYE can race the delayed final response while the modem is
		 * still transitioning to active.  Drop that response and its retry
		 * timer when the dialog is torn down; otherwise the next call inherits
		 * a stale transaction and can remain in the waiting state. */
		uloop_timeout_cancel(&app.media_attach_timeout);
		if (app.pending_lan_response) {
			pjsip_tx_data_dec_ref(app.pending_lan_response);
			app.pending_lan_response = NULL;
			release_pending_lan_response();
		}
		(void)stop_media();
	}
	send_response(request, status, PJ_FALSE, PJ_FALSE);
}

static int sms_send_ok;

static void sms_send_reply(struct ubus_request *request, int type,
			   struct blob_attr *message)
{
	static const struct blobmsg_policy reply_policy[] = {
		{ .name = "status", .type = BLOBMSG_TYPE_STRING }
	};
	struct blob_attr *values[ARRAY_SIZE(reply_policy)] = { 0 };
	(void)request; (void)type;
	blobmsg_parse(reply_policy, ARRAY_SIZE(reply_policy), values,
		blob_data(message), blob_len(message));
	sms_send_ok = values[0] && !strcmp(blobmsg_get_string(values[0]), "success");
}

static int message_request_id(pjsip_rx_data *request, char output[64])
{
	const pj_str_t *call_id;
	size_t offset = 0;
	if (!request->msg_info.cid || !request->msg_info.cseq)
		return -1;
	call_id = &request->msg_info.cid->id;
	for (pj_ssize_t i = 0; i < call_id->slen && offset < 44; i++) {
		unsigned char c = (unsigned char)call_id->ptr[i];
		output[offset++] = ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
			(c >= '0' && c <= '9') || c == '_' || c == '-') ? (char)c : '_';
	}
	(void)snprintf(output + offset, 64 - offset, "-%ld-%s",
		(long)request->msg_info.cseq->cseq, app.direction);
	return 0;
}

static void message_to_sms(pjsip_rx_data *request)
{
	struct blob_buf buffer = { 0 };
	struct pjsip_msg_body *body = request->msg_info.msg->body;
	uint32_t object;
	char number[64], request_id[64], content[MAX_SIP_BODY + 1];
	if (!trusted_outbound_request(request) && !authenticate(request))
		return;
	if (!app.sms_modem[0] || ubus_lookup_id(app.ubus, "qmodem.sms", &object) != 0) {
		send_response(request, PJSIP_SC_TEMPORARILY_UNAVAILABLE, PJ_FALSE, PJ_FALSE);
		return;
	}
	if (!body || !str_equal(&body->content_type.type, "text") ||
	    !str_equal(&body->content_type.subtype, "plain")) {
		send_response(request, PJSIP_SC_UNSUPPORTED_MEDIA_TYPE, PJ_FALSE, PJ_FALSE);
		return;
	}
	if (body->len <= 0 || body->len > MAX_SIP_BODY) {
		send_response(request, PJSIP_SC_REQUEST_ENTITY_TOO_LARGE, PJ_FALSE, PJ_FALSE);
		return;
	}
	if (sip_number(request, number) != 0 || message_request_id(request, request_id) != 0) {
		send_response(request, PJSIP_SC_BAD_REQUEST, PJ_FALSE, PJ_FALSE);
		return;
	}
	memcpy(content, body->data, (size_t)body->len);
	content[body->len] = '\0';
	blob_buf_init(&buffer, 0);
	blobmsg_add_string(&buffer, "modem_id", app.sms_modem);
	blobmsg_add_string(&buffer, "recipient", number);
	blobmsg_add_string(&buffer, "content", content);
	blobmsg_add_string(&buffer, "request_id", request_id);
	sms_send_ok = 0;
	if (ubus_invoke(app.ubus, object, "send_managed", buffer.head, sms_send_reply,
		NULL, UBUS_ACTION_TIMEOUT_MS) != 0 || !sms_send_ok)
		send_response(request, PJSIP_SC_SERVICE_UNAVAILABLE, PJ_FALSE, PJ_FALSE);
	else
		send_response(request, PJSIP_SC_OK, PJ_FALSE, PJ_FALSE);
	blob_buf_free(&buffer);
	memset(content, 0, sizeof(content));
}

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

static void complete_message(const char *status, int sip_status, const char *error)
{
	struct blob_buf buffer = { 0 };
	if (!app.pending_message.active)
		return;
	uloop_timeout_cancel(&app.pending_message.timeout);
	blob_buf_init(&buffer, 0);
	blobmsg_add_string(&buffer, "status", status);
	blobmsg_add_u32(&buffer, "sip_status", (uint32_t)sip_status);
	if (error)
		blobmsg_add_string(&buffer, "error", error);
	ubus_send_reply(app.ubus, &app.pending_message.request, buffer.head);
	ubus_complete_deferred_request(app.ubus, &app.pending_message.request,
		UBUS_STATUS_OK);
	blob_buf_free(&buffer);
	app.pending_message.active = 0;
	app.pending_message.auth_retried = 0;
}

static void message_timeout(struct uloop_timeout *timeout)
{
	(void)timeout;
	complete_message("error", 408, "SIP MESSAGE timed out");
}

static void message_response(void *token, pjsip_event *event)
{
	pjsip_transaction *transaction;
	pjsip_tx_data *retry = NULL;
	pj_status_t status;
	(void)token;
	if (!event || event->type != PJSIP_EVENT_TSX_STATE)
		return;
	transaction = event->body.tsx_state.tsx;
	if (!transaction || transaction->status_code < 200)
		return;
	if (app.outbound && !app.pending_message.auth_retried &&
	    event->body.tsx_state.type == PJSIP_EVENT_RX_MSG &&
	    (transaction->status_code == PJSIP_SC_UNAUTHORIZED ||
	     transaction->status_code == PJSIP_SC_PROXY_AUTHENTICATION_REQUIRED)) {
		app.pending_message.auth_retried = 1;
		status = pjsip_auth_clt_reinit_req(&app.outbound_auth,
			event->body.tsx_state.src.rdata, transaction->last_tx, &retry);
		if (status == PJ_SUCCESS) {
			PJSIP_MSG_CSEQ_HDR(retry->msg)->cseq++;
			status = pjsip_endpt_send_request(app.endpoint, retry,
				UBUS_ACTION_TIMEOUT_MS, NULL, message_response);
		}
		if (status == PJ_SUCCESS)
			return;
		complete_message("error", 503, "SIP MESSAGE authentication failed");
		return;
	}
	if (transaction->status_code >= 200 && transaction->status_code < 300)
		complete_message("success", transaction->status_code, NULL);
	else
		complete_message("error", transaction->status_code,
			"remote SIP endpoint rejected MESSAGE");
}

static int send_message_method(struct ubus_context *context, struct ubus_object *object,
	struct ubus_request_data *request, const char *method, struct blob_attr *message)
{
	struct blob_attr *values[MESSAGE_MAX] = { 0 };
	pjsip_tx_data *tx = NULL;
	pjsip_uri *parsed;
	pjsip_method message_method;
	pj_str_t target, from, to, contact, type, subtype, text;
	pj_str_t message_name = pj_str((char *)"MESSAGE");
	char local_uri[384], target_uri[384], reply_uri[384] = { 0 };
	const char *recipient, *content;
	const char *sender = NULL;
	(void)context; (void)object; (void)method;
	blobmsg_parse(message_policy, MESSAGE_MAX, values, blob_data(message), blob_len(message));
	if (!values[MESSAGE_RECIPIENT] || !values[MESSAGE_CONTENT] ||
	    !values[MESSAGE_ID] || app.pending_message.active)
		return UBUS_STATUS_INVALID_ARGUMENT;
	recipient = blobmsg_get_string(values[MESSAGE_RECIPIENT]);
	content = blobmsg_get_string(values[MESSAGE_CONTENT]);
	if (values[MESSAGE_SENDER])
		sender = blobmsg_get_string(values[MESSAGE_SENDER]);
	if (!*content || strlen(content) > MAX_SIP_BODY || strlen(recipient) >= sizeof(target_uri))
		return UBUS_STATUS_INVALID_ARGUMENT;
	if (!binding_active())
		return UBUS_STATUS_NOT_FOUND;
	(void)snprintf(target_uri, sizeof(target_uri), "%s",
		app.outbound ? recipient : app.binding);
	parsed = pjsip_parse_uri(app.pool, target_uri, strlen(target_uri), 0);
	if (!parsed)
		return UBUS_STATUS_INVALID_ARGUMENT;
	(void)snprintf(local_uri, sizeof(local_uri), "%s:%s@%s:%u%s",
		app.outbound ? "sips" : "sip", app.username, app.lan_address,
		app.listen_port, app.outbound ? ";transport=tls" : "");
	/* Keep From bound to the authenticated SIP account, and advertise the
	 * cellular sender as the standard logical return URI. */
	if (sender && *sender && strspn(sender, "0123456789+*#,p") == strlen(sender) &&
		strlen(sender) < sizeof(reply_uri)) {
		(void)snprintf(reply_uri, sizeof(reply_uri), "%s:%s@%s:%u%s",
			app.outbound ? "sips" : "sip", sender, app.lan_address,
			app.listen_port, app.outbound ? ";transport=tls" : "");
	}
	target = pj_str(target_uri);
	from = pj_str(local_uri);
	to = pj_str((char *)recipient);
	contact = pj_str(local_uri);
	pjsip_method_init_np(&message_method, &message_name);
	if (pjsip_endpt_create_request(app.endpoint, &message_method, &target,
		&from, &to, &contact, NULL, -1, NULL, &tx) != PJ_SUCCESS)
		return UBUS_STATUS_UNKNOWN_ERROR;
	type = pj_str((char *)"text");
	subtype = pj_str((char *)"plain");
	text = pj_str((char *)content);
	tx->msg->body = pjsip_msg_body_create(tx->pool, &type, &subtype, &text);
	if (!tx->msg->body) {
		pjsip_tx_data_dec_ref(tx);
		return UBUS_STATUS_UNKNOWN_ERROR;
	}
	if (reply_uri[0])
		add_string_header(tx, "Reply-To", reply_uri);
	if (values[MESSAGE_SENDER])
		add_string_header(tx, "X-QModem-SMS-From", blobmsg_get_string(values[MESSAGE_SENDER]));
	add_string_header(tx, "X-QModem-Message-ID", blobmsg_get_string(values[MESSAGE_ID]));
	ubus_defer_request(app.ubus, request, &app.pending_message.request);
	app.pending_message.active = 1;
	app.pending_message.auth_retried = 0;
	app.pending_message.timeout.cb = message_timeout;
	uloop_timeout_set(&app.pending_message.timeout, UBUS_ACTION_TIMEOUT_MS);
	if (pjsip_endpt_send_request(app.endpoint, tx, UBUS_ACTION_TIMEOUT_MS,
		NULL, message_response) != PJ_SUCCESS) {
		complete_message("error", 503, "SIP MESSAGE could not be sent");
	}
	return UBUS_STATUS_OK;
}

static int sip_status_method(struct ubus_context *context, struct ubus_object *object,
	struct ubus_request_data *request, const char *method, struct blob_attr *message)
{
	struct blob_buf buffer = { 0 };
	uint32_t id;
	(void)object; (void)method; (void)message;
	blob_buf_init(&buffer, 0);
	blobmsg_add_string(&buffer, "status", "ok");
	blobmsg_add_string(&buffer, "direction", app.direction);
	blobmsg_add_u8(&buffer, "registered",
		app.outbound ? app.outbound_registered : binding_active());
	if (app.outbound) {
		blobmsg_add_u64(&buffer, "registration_attempts",
			app.registration_retry.attempts);
		blobmsg_add_u64(&buffer, "registration_failures",
			app.registration_retry.failures);
		blobmsg_add_u8(&buffer, "retry_scheduled",
			app.outbound_register_retry.pending);
		blobmsg_add_u32(&buffer, "retry_delay_ms",
			app.registration_retry.scheduled_delay_ms);
	}
	blobmsg_add_u8(&buffer, "voipd_available",
		ubus_lookup_id(context, "qmodem_voip", &id) == 0);
	blobmsg_add_u8(&buffer, "smsd_available",
		ubus_lookup_id(context, "qmodem.sms", &id) == 0);
	blobmsg_add_u8(&buffer, "sms_enabled", app.sms_modem[0] != '\0');
	ubus_send_reply(context, request, buffer.head);
	blob_buf_free(&buffer);
	return UBUS_STATUS_OK;
}

static const struct ubus_method sip_methods[] = {
	UBUS_METHOD_NOARG("status", sip_status_method),
	UBUS_METHOD("send_message", send_message_method, message_policy)
};

static struct ubus_object_type sip_object_type =
	UBUS_OBJECT_TYPE("qmodem.sip.direction", sip_methods);

static pj_bool_t on_request(pjsip_rx_data *request)
{
	pjsip_method *method = &request->msg_info.msg->line.req.method;
	if (request->msg_info.len > MAX_SIP_MESSAGE) {
		send_response(request, PJSIP_SC_REQUEST_ENTITY_TOO_LARGE, PJ_FALSE, PJ_FALSE);
		return PJ_TRUE;
	}
	if (method->id == PJSIP_REGISTER_METHOD) {
		if (app.outbound) {
			send_response(request, PJSIP_SC_METHOD_NOT_ALLOWED, PJ_FALSE, PJ_FALSE);
			return PJ_TRUE;
		}
		register_contact(request);
		return PJ_TRUE;
	}
	if (method->id == PJSIP_INVITE_METHOD ||
	    (method->id == PJSIP_OTHER_METHOD && str_equal(&method->name, "UPDATE"))) {
		if (in_dialog_media_refresh(request) == 0)
			return PJ_TRUE;
		if (method->id == PJSIP_INVITE_METHOD)
			invite_call(request);
		else
			send_response(request, PJSIP_SC_METHOD_NOT_ALLOWED, PJ_FALSE, PJ_FALSE);
		return PJ_TRUE;
	}
	if (method->id == PJSIP_ACK_METHOD) {
		return PJ_TRUE;
	}
	if (method->id == PJSIP_OTHER_METHOD && str_equal(&method->name, "MESSAGE")) {
		message_to_sms(request);
		return PJ_TRUE;
	}
	if (method->id == PJSIP_OTHER_METHOD && str_equal(&method->name, "OPTIONS")) {
		if (trusted_outbound_request(request))
			send_response(request, PJSIP_SC_OK, PJ_FALSE, PJ_FALSE);
		else
			send_response(request, PJSIP_SC_FORBIDDEN, PJ_FALSE, PJ_FALSE);
		return PJ_TRUE;
	}
	if (method->id == PJSIP_CANCEL_METHOD) {
		end_call(request, 1);
		return PJ_TRUE;
	}
	if (method->id == PJSIP_BYE_METHOD) {
		end_call(request, 0);
		return PJ_TRUE;
	}
	send_response(request, PJSIP_SC_METHOD_NOT_ALLOWED, PJ_FALSE, PJ_FALSE);
	return PJ_TRUE;
}

static uint32_t monotonic_ms(void)
{
	struct timespec now;
	(void)clock_gettime(CLOCK_MONOTONIC, &now);
	return (uint32_t)((uint64_t)now.tv_sec * 1000U +
		(uint64_t)now.tv_nsec / 1000000U);
}

static void detach_media(void)
{
	if (app.media_fd_event.fd >= 0) {
		uloop_fd_delete(&app.media_fd_event);
		app.media_fd_event.fd = -1;
	}
	qmodem_voip_media_socket_client_detach(&app.media_sock);
	if (app.rtp_fd >= 0) {
		uloop_fd_delete(&app.rtp_fd_event);
		app.rtp_fd_event.fd = -1;
		(void)close(app.rtp_fd);
		app.rtp_fd = -1;
	}
	app.media_attached = 0;
	app.rtp_attached = 0;
}

static void stop_media(void)
{
	detach_media();
	(void)ubus_action("hangup", NULL);
}

static int rtp_open(void)
{
	struct sockaddr_in local = { 0 };
	int fd;
	int flags;
	if (app.rtp_fd >= 0)
		return 0;
	fd = socket(AF_INET, SOCK_DGRAM, 0);
	if (fd < 0)
		return -1;
	flags = fcntl(fd, F_GETFL, 0);
	local.sin_family = AF_INET;
	local.sin_addr.s_addr = htonl(INADDR_ANY);
	local.sin_port = htons(QMODEM_VOIP_RTP_PORT);
	if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) != 0 ||
	    bind(fd, (struct sockaddr *)&local, sizeof(local)) != 0) {
		(void)close(fd);
		return -1;
	}
	app.rtp_fd = fd;
	return 0;
}

static void media_readable(struct uloop_fd *event, unsigned events)
{
	struct qmodem_voip_media_socket_message message;
	struct qmodem_voip_media_socket_pcm pcm;
	uint8_t packet[RTP_PACKET_SIZE] = { 0 };
	int result;
	int i;
	(void)events;
	(void)event;
	result = qmodem_voip_media_socket_client_read(&app.media_sock, &message);
	if (result < 0) {
		stop_media();
		return;
	}
	if (result == 0)
		return;
	if (message.header.type != QMODEM_VOIP_MEDIA_SOCKET_PCM_CAPTURE ||
	    message.header.payload_length != sizeof(pcm))
		return;
	memcpy(&pcm, &message.body.pcm, sizeof(pcm));
	packet[0] = 0x80;
	packet[1] = (uint8_t)app.rtp_codec;
	packet[2] = (uint8_t)(app.rtp_sequence >> 8);
	packet[3] = (uint8_t)app.rtp_sequence;
	packet[4] = (uint8_t)(app.rtp_timestamp >> 24);
	packet[5] = (uint8_t)(app.rtp_timestamp >> 16);
	packet[6] = (uint8_t)(app.rtp_timestamp >> 8);
	packet[7] = (uint8_t)app.rtp_timestamp;
	packet[8] = (uint8_t)(app.rtp_ssrc >> 24);
	packet[9] = (uint8_t)(app.rtp_ssrc >> 16);
	packet[10] = (uint8_t)(app.rtp_ssrc >> 8);
	packet[11] = (uint8_t)app.rtp_ssrc;
	if (g711_bridge_encode(app.rtp_codec, pcm.samples,
		QMODEM_VOIP_MEDIA_SAMPLES, &packet[RTP_HEADER_SIZE]) != 0)
		return;
	if (app.rtp_attached && app.rtp_fd >= 0 &&
	    sendto(app.rtp_fd, packet, sizeof(packet), 0,
		(const struct sockaddr *)&app.rtp_peer, sizeof(app.rtp_peer)) !=
		(ssize_t)sizeof(packet)) {
		stop_media();
		return;
	}
	app.rtp_sequence++;
	app.rtp_timestamp += QMODEM_VOIP_MEDIA_SAMPLES;
	for (i = 0; i < (int)sizeof(packet); i++)
		packet[i] = 0;
}

static int media_playback_to_modem(const uint8_t *packet, size_t length)
{
	struct qmodem_voip_media_socket_pcm pcm;
	size_t payload_offset = RTP_HEADER_SIZE;
	size_t payload_length;
	unsigned extension_words;
	int16_t samples[QMODEM_VOIP_MEDIA_SAMPLES];
	if (!packet || length < RTP_HEADER_SIZE || (packet[0] >> 6) != 2)
		return -1;
	payload_offset += (size_t)(packet[0] & 15U) * 4U;
	if (payload_offset > length)
		return -1;
	if (packet[0] & 0x10U) {
		if (length - payload_offset < 4U)
			return -1;
		extension_words = ((unsigned)packet[payload_offset + 2] << 8) |
			packet[payload_offset + 3];
		if (extension_words > (length - payload_offset - 4U) / 4U)
			return -1;
		payload_offset += 4U + (size_t)extension_words * 4U;
	}
	payload_length = length - payload_offset;
	if ((packet[1] & 127U) != (unsigned)app.rtp_codec ||
	    payload_length != QMODEM_VOIP_MEDIA_SAMPLES)
		return -1;
	if (g711_bridge_decode(app.rtp_codec, packet + payload_offset,
		payload_length, samples) != 0)
		return -1;
	memset(&pcm, 0, sizeof(pcm));
	pcm.sequence = app.media_sock.outbound_sequence;
	pcm.timestamp_ms = monotonic_ms();
	memcpy(pcm.samples, samples, sizeof(samples));
	if (qmodem_voip_media_socket_client_write(&app.media_sock,
		QMODEM_VOIP_MEDIA_SOCKET_PCM_PLAYBACK, &pcm, sizeof(pcm)) != 0)
		return -1;
	return 0;
}

static void rtp_readable(struct uloop_fd *event, unsigned events)
{
	uint8_t packet[2048];
	struct sockaddr_in source;
	socklen_t source_length;
	ssize_t received;
	(void)events;
	(void)event;
	if (!app.rtp_attached || app.rtp_fd < 0)
		return;
	for (;;) {
		source_length = sizeof(source);
		received = recvfrom(app.rtp_fd, packet, sizeof(packet), 0,
			(struct sockaddr *)&source, &source_length);
		if (received < 0) {
			if (errno == EINTR)
				continue;
			if (errno == EAGAIN || errno == EWOULDBLOCK)
				return;
			stop_media();
			return;
		}
		if (source.sin_family == AF_INET &&
		    source.sin_addr.s_addr == app.rtp_peer.sin_addr.s_addr) {
			app.rtp_peer.sin_port = source.sin_port;
			(void)media_playback_to_modem(packet, (size_t)received);
		}
		return;
	}
}

static int ubus_fetch_status_is_active;
static uint64_t ubus_fetch_status_revision;

static void status_reply(struct ubus_request *request, int type,
			 struct blob_attr *message)
{
	static const struct blobmsg_policy policy[] = {
		{ .name = "state", .type = BLOBMSG_TYPE_STRING },
		{ .name = "revision", .type = BLOBMSG_TYPE_UNSPEC }
	};
	struct blob_attr *values[ARRAY_SIZE(policy)] = { 0 };
	(void)request;
	(void)type;
	ubus_fetch_status_is_active = 0;
	blobmsg_parse(policy, ARRAY_SIZE(policy), values, blob_data(message),
		      blob_len(message));
	if (values[0] && strcmp(blobmsg_get_string(values[0]), "active") == 0)
		ubus_fetch_status_is_active = 1;
	if (values[1]) {
		if (blobmsg_type(values[1]) == BLOBMSG_TYPE_INT64)
			ubus_fetch_status_revision = blobmsg_get_u64(values[1]);
		else
			ubus_fetch_status_revision = blobmsg_get_u32(values[1]);
	}
}

static int ubus_fetch_status(void)
{
	struct blob_buf buffer = { 0 };
	uint32_t object;
	int result;
	if (ubus_lookup_voip(&object) != 0)
		return -1;
	blob_buf_init(&buffer, 0);
	result = ubus_invoke(app.ubus, object, "status", buffer.head, status_reply,
			     NULL, UBUS_ACTION_TIMEOUT_MS);
	blob_buf_free(&buffer);
	if (result != 0 || !ubus_fetch_status_is_active)
		return -1;
	app.media_revision = ubus_fetch_status_revision;
	return 0;
}

static int attach_media(void)
{
	if (app.media_attached)
		return 0;
	app.rtp_codec = (enum qmodem_voip_media_codec)app.media.payload_type;
	memset(&app.rtp_peer, 0, sizeof(app.rtp_peer));
	app.rtp_peer.sin_family = AF_INET;
	app.rtp_peer.sin_port = htons((uint16_t)app.media.port);
	if (inet_pton(AF_INET, app.media.address,
		&app.rtp_peer.sin_addr) != 1)
		return -1;
	if (ubus_fetch_status() != 0) {
		syslog(LOG_WARNING, "qmodem_voip sip: media attach status unavailable");
		return -1;
	}
	if (ubus_issue_socket_session() != 0) {
		syslog(LOG_WARNING,
			"qmodem_voip sip: media session rejected at revision %llu",
			(unsigned long long)app.media_revision);
		return -1;
	}
	if (qmodem_voip_media_socket_client_attach(&app.media_sock,
		app.media_socket_path, app.media_revision,
		app.media_sock.session_id) != 0) {
		syslog(LOG_WARNING,
			"qmodem_voip sip: media socket handshake rejected at revision %llu",
			(unsigned long long)app.media_revision);
		return -1;
	}
	app.media_fd_event.fd = app.media_sock.fd;
	app.media_fd_event.cb = media_readable;
	app.rtp_fd_event.fd = app.rtp_fd;
	app.rtp_fd_event.cb = rtp_readable;
	uloop_fd_add(&app.media_fd_event, ULOOP_READ);
	uloop_fd_add(&app.rtp_fd_event, ULOOP_READ);
	app.media_attached = 1;
	app.rtp_attached = 1;
	return 0;
}

static void release_pending_lan_response(void)
{
	if (app.pending_lan_response_addr.transport)
		pjsip_transport_dec_ref(app.pending_lan_response_addr.transport);
	memset(&app.pending_lan_response_addr, 0,
		sizeof(app.pending_lan_response_addr));
}

static void media_attach_retry(struct uloop_timeout *timeout)
{
	pjsip_tx_data *response;
	pj_status_t send_status;
	(void)timeout;
	if (!app.call.active || !app.pending_lan_response)
		return;
	app.media_attach_attempts++;
	if (rtp_open() != 0 || attach_media() != 0) {
		if (app.media_attach_attempts < MEDIA_ATTACH_RETRY_MAX) {
			uloop_timeout_set(&app.media_attach_timeout,
				MEDIA_ATTACH_RETRY_MS);
			return;
		}
		syslog(LOG_WARNING,
			"qmodem_voip sip: media attach failed after %u attempts",
			app.media_attach_attempts);
		app.pending_lan_response->msg->line.status.code =
			PJSIP_SC_TEMPORARILY_UNAVAILABLE;
		app.pending_lan_response->msg->line.status.reason =
			*pjsip_get_status_text(PJSIP_SC_TEMPORARILY_UNAVAILABLE);
		response = app.pending_lan_response;
		app.pending_lan_response = NULL;
		if (pjsip_endpt_send_response(app.endpoint,
			&app.pending_lan_response_addr, response, NULL, NULL) != PJ_SUCCESS)
			pjsip_tx_data_dec_ref(response);
		release_pending_lan_response();
		stop_media();
		qmodem_voip_sip_call_clear(&app.call);
		return;
	}

	response = app.pending_lan_response;
	app.pending_lan_response = NULL;
	send_status = pjsip_endpt_send_response(app.endpoint,
		&app.pending_lan_response_addr, response, NULL, NULL);
	if (send_status != PJ_SUCCESS) {
		syslog(LOG_WARNING, "qmodem_voip sip: active response failed");
		pjsip_tx_data_dec_ref(response);
		stop_media();
	} else {
		char remote_tag[QMODEM_VOIP_SIP_TAG_SIZE];
		if (app.call.remote_tag[0]) {
			memcpy(remote_tag, app.call.remote_tag, sizeof(remote_tag));
			(void)qmodem_voip_sip_call_establish(&app.call, remote_tag);
		}
		syslog(LOG_INFO,
			"qmodem_voip sip: active response sent after %u attach attempt(s)",
			app.media_attach_attempts);
	}
	release_pending_lan_response();
}

static void consumer_event(struct ubus_context *context,
			   struct ubus_event_handler *handler, const char *type,
			   struct blob_attr *message)
{
	static const struct blobmsg_policy policy[] = {
		{ .name = "event", .type = BLOBMSG_TYPE_STRING },
		{ .name = "state", .type = BLOBMSG_TYPE_STRING },
		{ .name = "revision", .type = BLOBMSG_TYPE_UNSPEC },
		{ .name = "remote_number", .type = BLOBMSG_TYPE_STRING },
		{ .name = "caller_id_withheld", .type = BLOBMSG_TYPE_UNSPEC },
		{ .name = "answer_owner", .type = BLOBMSG_TYPE_STRING }
	};
	struct blob_attr *values[ARRAY_SIZE(policy)] = { 0 };
	const char *event, *state, *owner;
	int ended;
	(void)context;
	(void)handler;
	(void)type;
	blobmsg_parse(policy, ARRAY_SIZE(policy), values, blob_data(message),
		      blob_len(message));
	if (!values[0] || !values[1])
		return;
	if (values[3])
		(void)snprintf(app.incoming_number, sizeof(app.incoming_number), "%s",
			blobmsg_get_string(values[3]));
	if (values[4])
		app.incoming_caller_id_withheld = blobmsg_get_u8(values[4]);
	if (values[2]) {
		if (blobmsg_type(values[2]) == BLOBMSG_TYPE_INT64)
			app.media_revision = blobmsg_get_u64(values[2]);
		else
			app.media_revision = blobmsg_get_u32(values[2]);
	}
	event = blobmsg_get_string(values[0]);
	state = blobmsg_get_string(values[1]);
	owner = values[5] ? blobmsg_get_string(values[5]) : "none";
	app.incoming_ringing = strcmp(state, "incoming_ringing") == 0;
	ended = strcmp(event, "release") == 0 ||
		(app.call.active && (strcmp(state, "idle") == 0 ||
		 strcmp(state, "disabled") == 0 || strcmp(state, "fault") == 0)) ||
		(app.call.active && !app.call.established &&
		 app.call.origin == QMODEM_VOIP_SIP_CALL_CELLULAR &&
		 strcmp(owner, "none") != 0 &&
		 strcmp(owner, app.outbound ? "external_sip" : "lan_sip") != 0);
	if (ended) {
		app.incoming_number[0] = '\0';
		app.incoming_caller_id_withheld = 0;
		uloop_timeout_cancel(&app.media_attach_timeout);
		if (app.pending_lan_response) {
			app.pending_lan_response->msg->line.status.code = PJSIP_SC_TEMPORARILY_UNAVAILABLE;
			app.pending_lan_response->msg->line.status.reason =
				*pjsip_get_status_text(PJSIP_SC_TEMPORARILY_UNAVAILABLE);
			if (pjsip_endpt_send_response(app.endpoint,
				    &app.pending_lan_response_addr,
				    app.pending_lan_response, NULL, NULL) != PJ_SUCCESS)
				pjsip_tx_data_dec_ref(app.pending_lan_response);
			app.pending_lan_response = NULL;
			release_pending_lan_response();
		}
		send_invite_cancel();
		send_dialog_bye();
		detach_media();
		qmodem_voip_sip_call_release(&app.call);
		remember_outbound_invite(NULL);
		app.dialog_contact[0] = '\0';
	} else if (strcmp(event, "call_state") == 0 && strcmp(state, "active") == 0 &&
		   app.call.active) {
		if (app.pending_lan_response && !app.media_attach_timeout.pending) {
			app.media_attach_attempts = 0;
			uloop_timeout_set(&app.media_attach_timeout, 0);
		}
	} else if (strcmp(event, "ring") == 0)
		send_incoming_invite();
}

static int load_credentials(void)
{
	struct qmodem_voip_sip_credentials credentials;
	if (qmodem_voip_sip_read_credentials(QMODEM_VOIP_SIP_CONFIG, &credentials) != 0)
		return -1;
	memcpy(app.username, credentials.username, sizeof(app.username));
	memcpy(app.ha1, credentials.ha1, sizeof(app.ha1));
	memset(&credentials, 0, sizeof(credentials));
	return 0;
}

static int advertise_address_is_local_voice(const char *address)
{
	struct ifaddrs *interfaces;
	struct ifaddrs *entry;
	int found = 0;
	if (getifaddrs(&interfaces) != 0)
		return 0;
	for (entry = interfaces; entry; entry = entry->ifa_next) {
		char actual[INET_ADDRSTRLEN];
		if (!entry->ifa_name || !entry->ifa_addr ||
		    strcmp(entry->ifa_name, "lo") == 0 ||
		    entry->ifa_addr->sa_family != AF_INET)
			continue;
		if (inet_ntop(AF_INET,
		    &((struct sockaddr_in *)entry->ifa_addr)->sin_addr,
		    actual, sizeof(actual)) && strcmp(actual, address) == 0) {
			found = 1;
			break;
		}
	}
	freeifaddrs(interfaces);
	return found;
}

static int copy_config_value(char *destination, size_t size, const char *value)
{
	size_t length = value ? strlen(value) : 0;
	if (!destination || !value || length >= size)
		return -1;
	memcpy(destination, value, length + 1);
	return 0;
}

static int load_outbound_config(const char *path)
{
	FILE *file;
	char line[512];
	char key[64];
	char value[384];
	if (!path || !path[0] || strlen(path) >= 256)
		return -1;
	file = fopen(path, "r");
	if (!file)
		return -1;
	while (fgets(line, sizeof(line), file)) {
		if (sscanf(line, "%63[^=]=%383[^\n]", key, value) != 2)
			continue;
		if (strcmp(key, "server") == 0) {
			if (copy_config_value(app.outbound_server, sizeof(app.outbound_server), value) != 0) return -1;
		} else if (strcmp(key, "aor") == 0) {
			if (copy_config_value(app.outbound_aor, sizeof(app.outbound_aor), value) != 0) return -1;
		} else if (strcmp(key, "server_uri") == 0) {
			if (copy_config_value(app.outbound_server_uri, sizeof(app.outbound_server_uri), value) != 0) return -1;
		} else if (strcmp(key, "password") == 0) {
			if (copy_config_value(app.outbound_password, sizeof(app.outbound_password), value) != 0) return -1;
		} else if (strcmp(key, "username") == 0) {
			if (copy_config_value(app.outbound_username, sizeof(app.outbound_username), value) != 0) return -1;
		} else if (strcmp(key, "realm") == 0) {
			if (copy_config_value(app.outbound_realm, sizeof(app.outbound_realm), value) != 0) return -1;
		}
		else if (strcmp(key, "port") == 0)
			app.outbound_port = (unsigned)strtoul(value, NULL, 10);
		else if (strcmp(key, "interval") == 0)
			app.outbound_interval = (unsigned)strtoul(value, NULL, 10);
	}
	(void)fclose(file);
	return app.outbound_server[0] && app.outbound_aor[0] && app.outbound_username[0] &&
		app.outbound_server_uri[0] && app.outbound_password[0] &&
		app.outbound_port >= 1 && app.outbound_port <= 65535 &&
		app.outbound_interval >= 60 ? 0 : -1;
}

int main(int argc, char **argv)
{
	pj_sockaddr_in address;
	pj_status_t rc;
	pj_time_val delay = {0, 0};
	const char *outbound_config = NULL;
	int i;
	(void)snprintf(app.direction, sizeof(app.direction), "%s", "inbound");
	(void)snprintf(app.pidfile, sizeof(app.pidfile), "%s", DEFAULT_PIDFILE);
	app.listen_port = 5060;
	if (argc < 7 || strcmp(argv[1], "--listen-address") != 0 ||
	    strcmp(argv[3], "--advertise-address") != 0 ||
	    strcmp(argv[5], "--media-socket-path") != 0 ||
	    strcmp(argv[2], "0.0.0.0") != 0 ||
	    !qmodem_voip_sip_valid_lan_address(argv[4]) ||
	    !advertise_address_is_local_voice(argv[4]) ||
	    !argv[6][0] ||
	    strlen(argv[6]) >= sizeof(app.media_socket_path)) {
		fprintf(stderr,
			"usage: %s --listen-address 0.0.0.0 --advertise-address IPV4 --media-socket-path SOCKET [--mode outbound --outbound-config FILE]\n",
			argv[0]);
		return 2;
	}
	for (i = 7; i < argc; i++) {
		if (strcmp(argv[i], "--mode") == 0 && i + 1 < argc)
			app.outbound = strcmp(argv[++i], "outbound") == 0;
		else if (strcmp(argv[i], "--outbound-config") == 0 && i + 1 < argc)
			outbound_config = argv[++i];
		else if (strcmp(argv[i], "--direction") == 0 && i + 1 < argc) {
			if (copy_config_value(app.direction, sizeof(app.direction), argv[++i]) != 0 ||
			    (strcmp(app.direction, "inbound") && strcmp(app.direction, "outbound")))
				return 2;
		} else if (strcmp(argv[i], "--pidfile") == 0 && i + 1 < argc) {
			if (copy_config_value(app.pidfile, sizeof(app.pidfile), argv[++i]) != 0)
				return 2;
		} else if (strcmp(argv[i], "--sms-modem") == 0 && i + 1 < argc) {
			if (copy_config_value(app.sms_modem, sizeof(app.sms_modem), argv[++i]) != 0)
				return 2;
		} else if (strcmp(argv[i], "--listen-port") == 0 && i + 1 < argc) {
			char *end = NULL;
			unsigned long port = strtoul(argv[++i], &end, 10);
			if (!end || *end || port < 1 || port > 65535)
				return 2;
			app.listen_port = (unsigned)port;
		}
		else
			return 2;
	}
	if (app.outbound != !strcmp(app.direction, "outbound"))
		return 2;
	app.media_sock.fd = -1;
	app.media_fd_event.fd = -1;
	app.rtp_fd_event.fd = -1;
	app.rtp_fd = -1;
	app.media_attach_timeout.cb = media_attach_retry;
	app.outbound_register_retry.cb = outbound_register_retry;
	qmodem_voip_sip_registration_retry_init(&app.registration_retry);
	app.media_revision = (uint64_t)time(NULL);
	if (!app.outbound && load_credentials() != 0) {
		return 2;
	}
	(void)strcpy(app.lan_address, argv[4]);
	(void)snprintf(app.media_socket_path, sizeof(app.media_socket_path), "%s", argv[6]);
	if (app.outbound && (!outbound_config || load_outbound_config(outbound_config) != 0))
		return 2;
	if (app.outbound)
		(void)snprintf(app.username, sizeof(app.username), "%s", app.outbound_username);
	if (pj_init() != PJ_SUCCESS || pjlib_util_init() != PJ_SUCCESS)
		return 1;
	pj_caching_pool_init(&app.caching_pool, NULL, 0);
	app.pool = pj_pool_create(&app.caching_pool.factory, "consumer", 4096, 4096, NULL);
	if (!app.pool)
		return 1;
	rc = pjsip_endpt_create(&app.caching_pool.factory, "qmodem_voip", &app.endpoint);
	if (rc != PJ_SUCCESS)
		return 1;
	if (pjsip_tsx_layer_init_module(app.endpoint) != PJ_SUCCESS)
		return 1;
	app.module = (pjsip_module){
		.name = {"mod-qmodem-sip", 15},
		.id = -1,
		.priority = PJSIP_MOD_PRIORITY_APPLICATION,
		.on_rx_request = on_request,
		.on_rx_response = on_response,
	};
	if (pjsip_endpt_register_module(app.endpoint, &app.module) != PJ_SUCCESS)
		return 1;
	{
		pj_str_t realm = pj_str((char *)REALM);
		if (pjsip_auth_srv_init(app.pool, &app.auth, &realm,
					lookup_credential, 0) != PJ_SUCCESS)
			return 1;
	}
	pj_bzero(&address, sizeof(address));
	address.sin_family = pj_AF_INET();
	address.sin_port = pj_htons((pj_uint16_t)app.listen_port);
	address.sin_addr = pj_inet_addr(&((pj_str_t){argv[2],
		(pj_ssize_t)strlen(argv[2])}));
	if (!app.outbound) {
		if (pjsip_udp_transport_start(app.endpoint, &address, NULL, 1, NULL) != PJ_SUCCESS)
			return 1;
		if (pjsip_tcp_transport_start(app.endpoint, &address, 1, NULL) != PJ_SUCCESS)
			return 1;
	} else {
		pjsip_tls_setting tls;
		pjsip_tls_setting_default(&tls);
		tls.ca_list_file = pj_str((char *)"/etc/ssl/certs/ca-certificates.crt");
		tls.verify_server = PJ_TRUE;
		address.sin_port = pj_htons((pj_uint16_t)app.listen_port);
		if (pjsip_tls_transport_start(app.endpoint, &tls, &address, NULL, 1, NULL) != PJ_SUCCESS)
			return 1;
	}
	app.ubus = ubus_connect(NULL);
	if (!app.ubus)
		return 1;
	if (uloop_init() != 0)
		return 1;
	ubus_add_uloop(app.ubus);
	(void)snprintf(app.ubus_object_name, sizeof(app.ubus_object_name),
		"qmodem.sip.%s", app.direction);
	app.ubus_object.name = app.ubus_object_name;
	app.ubus_object.type = &sip_object_type;
	app.ubus_object.methods = sip_object_type.methods;
	app.ubus_object.n_methods = sip_object_type.n_methods;
	if (ubus_add_object(app.ubus, &app.ubus_object) != 0)
		return 1;
	app.call_events.cb = consumer_event;
	if (ubus_register_event_handler(app.ubus, &app.call_events,
				"qmodem_voip.call") != 0)
		return 1;
	if (app.outbound) {
		if (outbound_setup_registration() != 0)
			return 1;
	}
	signal(SIGINT, stop_handler);
	signal(SIGTERM, stop_handler);
	signal(SIGHUP, reload_handler);
	{
		FILE *pidfile = fopen(app.pidfile, "w");
		unsigned long long start;
		if (!pidfile)
			return 1;
		if (qmodem_voip_sip_process_start(getpid(), &start) != 0) {
			(void)fclose(pidfile);
			return 1;
		}
		(void)fprintf(pidfile, "%ld %llu\n", (long)getpid(), start);
		(void)fclose(pidfile);
	}
	fprintf(stdout, "READY transport=%s listen=%s:%u advertise=%s realm=%s rtp=40000 socket=%s\n",
		app.outbound ? "tls" : "udp,tcp", argv[2], app.listen_port,
		app.lan_address, app.outbound ? app.outbound_realm : REALM,
		app.media_socket_path);
	fflush(stdout);
	if (app.outbound)
		outbound_register();
	while (running) {
		if (app.reload_requested) {
			app.reload_requested = 0;
			uloop_timeout_cancel(&app.media_attach_timeout);
			if (!app.outbound)
				(void)load_credentials();
			app.binding[0] = '\0';
			app.expires = 0;
			qmodem_voip_sip_call_release(&app.call);
		}
		(void)uloop_run_timeout(EVENT_LOOP_SLICE_MS);
		(void)pjsip_endpt_handle_events(app.endpoint, &delay);
	}
	(void)unlink(app.pidfile);
	uloop_timeout_cancel(&app.media_attach_timeout);
	uloop_timeout_cancel(&app.outbound_register_retry);
	stop_media();
	remember_outbound_invite(NULL);
	uloop_done();
	ubus_free(app.ubus);
	if (app.regc) {
		pjsip_tx_data *request = NULL;
		if (app.outbound_registered &&
		    pjsip_regc_unregister(app.regc, &request) == PJ_SUCCESS)
			(void)pjsip_regc_send(app.regc, request);
		(void)pjsip_regc_destroy(app.regc);
		app.regc = NULL;
	}
	if (app.outbound_auth_initialized)
		(void)pjsip_auth_clt_deinit(&app.outbound_auth);
	pjsip_endpt_destroy(app.endpoint);
	pj_pool_release(app.pool);
	pj_caching_pool_destroy(&app.caching_pool);
	pj_shutdown();
	memset(app.ha1, 0, sizeof(app.ha1));
	memset(app.outbound_password, 0, sizeof(app.outbound_password));
	return 0;
}
