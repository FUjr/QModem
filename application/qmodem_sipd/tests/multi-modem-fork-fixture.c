/* Exercise production SIP handlers with virtual modem call reducers. Network
 * sends are captured at PJSIP's boundary; this does not test TLS or real audio. */
#define _POSIX_C_SOURCE 200809L
#include <libubus.h>
#include <pjsip.h>
#include <pjsip/sip_transport_udp.h>
static int virtual_lookup(struct ubus_context *, const char *, uint32_t *);
static int virtual_invoke(struct ubus_context *, uint32_t, const char *, struct blob_attr *, ubus_data_handler_t, void *, int);
static pj_status_t capture_request(pjsip_endpoint *, pjsip_tx_data *, pj_int32_t, void *, pjsip_endpt_send_callback);
static pj_status_t capture_stateless(pjsip_endpoint *, pjsip_tx_data *, void *, pjsip_send_callback);
#define ubus_lookup_id virtual_lookup
#define ubus_invoke virtual_invoke
#define pjsip_endpt_send_request capture_request
#define pjsip_endpt_send_request_stateless capture_stateless
#define main consumer_program_main
#include "../src/sip_consumer.c"
#undef main
#include "../../voipd/src/call_state.h"
#undef NDEBUG
#include <assert.h>

static struct qmodem_voip_call modems[2];
static struct consumer connections[4];
static pjsip_transport *transport;
static unsigned selected, invites[4], cancels[4], byes[4], acks[4], answers[2];

static int virtual_lookup(struct ubus_context *ctx, const char *name, uint32_t *id)
{
 (void)ctx;
 if (!strcmp(name, "qmodem.voip.sip_modem_a")) *id = 0;
 else if (!strcmp(name, "qmodem.voip.sip_modem_b")) *id = 1;
 else return UBUS_STATUS_NOT_FOUND;
 return 0;
}
static int virtual_invoke(struct ubus_context *ctx, uint32_t id, const char *method,
 struct blob_attr *msg, ubus_data_handler_t cb, void *priv, int timeout)
{
 (void)ctx; (void)cb; (void)priv; (void)timeout;
 assert(id < 2);
 if (!strcmp(method, "answer")) {
  static const struct blobmsg_policy policy[] = {{ .name = "endpoint", .type = BLOBMSG_TYPE_STRING }};
  struct blob_attr *values[1]; enum qmodem_voip_endpoint endpoint;
  blobmsg_parse(policy, 1, values, blob_data(msg), blob_len(msg));
  assert(values[0]);
  assert(qmodem_voip_endpoint_parse(blobmsg_get_string(values[0]), &endpoint) == 0);
  if (qmodem_voip_answer(&modems[id], endpoint, NULL, NULL)) return UBUS_STATUS_NOT_SUPPORTED;
  answers[id]++;
  return 0;
 }
 /* A SIP decline or a losing answer must never hang up the cellular leg. */
 assert(strcmp(method, "reject") && strcmp(method, "hangup"));
 return 0;
}
static pj_status_t capture_request(pjsip_endpoint *endpoint, pjsip_tx_data *tx,
 pj_int32_t timeout, void *token, pjsip_endpt_send_callback cb)
{
 (void)endpoint; (void)timeout; (void)token; (void)cb;
 int method = tx->msg->line.req.method.id;
 if (method == PJSIP_INVITE_METHOD) {
  invites[selected]++;
  tx->tp_info.transport = transport;
  pjsip_via_hdr *via = pjsip_msg_find_hdr(tx->msg, PJSIP_H_VIA, NULL);
  assert(via);
  via->transport = pj_str("UDP");
  via->sent_by.host = pj_str("127.0.0.1");
  pj_create_unique_string(tx->pool, &via->branch_param);
  char packet[4096];
  int size = pjsip_msg_print(tx->msg, packet, sizeof(packet) - 1);
  assert(size > 0); packet[size] = 0;
  assert(strstr(packet, selected / 2 ? "account_b" : "account_a"));
  char audio[64]; snprintf(audio, sizeof(audio), "m=audio %u ", 49000 + selected * 2);
  assert(strstr(packet, audio));
 } else if (method == PJSIP_CANCEL_METHOD) cancels[selected]++;
 else if (method == PJSIP_BYE_METHOD) byes[selected]++;
 pjsip_tx_data_dec_ref(tx);
 return PJ_SUCCESS;
}
static pj_status_t capture_stateless(pjsip_endpoint *endpoint, pjsip_tx_data *tx,
 void *token, pjsip_send_callback cb)
{
 (void)endpoint; (void)token; (void)cb;
 assert(tx->msg->line.req.method.id == PJSIP_ACK_METHOD);
 acks[selected]++;
 pjsip_tx_data_dec_ref(tx);
 return PJ_SUCCESS;
}
static void select_connection(unsigned index)
{
 selected = index;
 app = connections[index];
 snprintf(app.group, sizeof(app.group), "sip_modem_%c", index / 2 ? 'b' : 'a');
 snprintf(app.modem_id, sizeof(app.modem_id), "modem_%c", index / 2 ? 'b' : 'a');
 snprintf(app.voice_object, sizeof(app.voice_object), "qmodem.voip.%s", app.group);
 app.rtp_start = 49000 + index * 2;
 app.receive_voice = 1; app.send_voice = 1; app.voice_enabled = 1;

}
static void event(const char *name, const char *state, const char *owner)
{
 struct blob_buf b = {0}; blob_buf_init(&b, 0);
 blobmsg_add_string(&b, "modem_id", app.modem_id); blobmsg_add_string(&b, "event", name); blobmsg_add_string(&b, "state", state);
 blobmsg_add_string(&b, "remote_number", "+15500001234"); blobmsg_add_string(&b, "answer_owner", owner);
 consumer_event(NULL, NULL, NULL, b.head); blob_buf_free(&b);
}
static void response(int status)
{
 pjsip_rx_data rx = {0};
 pj_pool_t *pool = pj_pool_create(&app.caching_pool.factory, "reply", 4096, 4096, NULL);
 pjsip_msg *msg = pjsip_msg_create(pool, PJSIP_RESPONSE_MSG);
 msg->line.status.code = status; msg->line.status.reason = *pjsip_get_status_text(status);
 pjsip_cid_hdr *cid = pjsip_cid_hdr_create(pool); pj_strdup2(pool, &cid->id, app.call.call_id);
 pjsip_cseq_hdr *seq = pjsip_cseq_hdr_create(pool); seq->cseq = 1; seq->method = pjsip_invite_method;
 pjsip_to_hdr *to = pjsip_to_hdr_create(pool); to->uri = pjsip_parse_uri(pool, "sip:phone@127.0.0.1", 19, 0); to->tag = pj_str("phone-tag");
 pjsip_contact_hdr *contact = pjsip_contact_hdr_create(pool); contact->uri = to->uri;
 pjsip_msg_add_hdr(msg, (pjsip_hdr *)cid); pjsip_msg_add_hdr(msg, (pjsip_hdr *)seq);
 pjsip_msg_add_hdr(msg, (pjsip_hdr *)to); pjsip_msg_add_hdr(msg, (pjsip_hdr *)contact);
 pj_str_t type = pj_str("application"), subtype = pj_str("sdp"), body = pj_str("v=0\r\no=test 1 1 IN IP4 127.0.0.1\r\ns=test\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\nm=audio 52000 RTP/AVP 8\r\na=rtpmap:8 PCMA/8000\r\n");
 msg->body = pjsip_msg_body_create(pool, &type, &subtype, &body);
 rx.msg_info.msg = msg; rx.msg_info.cid = cid; rx.msg_info.to = to; rx.msg_info.cseq = seq;
 assert(on_response(&rx) == PJ_FALSE || app.fork_cancelled == 0);
 pj_pool_release(pool);
}
int main(void)
{
 pj_log_set_level(0); assert(pj_init() == PJ_SUCCESS); assert(pjlib_util_init() == PJ_SUCCESS);
 assert(uloop_init() == 0);
 pj_caching_pool_init(&app.caching_pool, NULL, 0);
 assert(pjsip_endpt_create(&app.caching_pool.factory, "fork-test", &app.endpoint) == PJ_SUCCESS);
 pj_sockaddr_in addr; pj_sockaddr_in_init(&addr, NULL, 0);
 assert(pjsip_udp_transport_start(app.endpoint, &addr, NULL, 1, &transport) == PJ_SUCCESS);
 app.ubus = (struct ubus_context *)1; app.rtp_fd = -1; app.media_sock.fd = -1;
 strcpy(app.lan_address, "127.0.0.1"); strcpy(app.binding, "sip:phone@127.0.0.1:52000");
 pj_gettimeofday(&app.binding_until); app.binding_until.sec += 3600;
 /* Media handshakes/audio are covered separately: preattach for reducer tests. */
 app.media_attached = 1;
 for (unsigned i = 0; i < 4; i++) {
  app.outbound = i % 2; app.listen_port = 15060 + i;
  strcpy(app.username, i / 2 ? "account_b" : "account_a"); connections[i] = app;
 }
 for (unsigned i = 0; i < 2; i++) {
  qmodem_voip_call_init(&modems[i]); qmodem_voip_call_set_enabled(&modems[i], 1);
  modems[i].state = QMODEM_VOIP_INCOMING_RINGING; modems[i].origin = QMODEM_VOIP_ENDPOINT_CELLULAR;
 }
 for (unsigned i = 0; i < 4; i++) { select_connection(i); event("ring", "incoming_ringing", "none"); connections[i] = app; assert(invites[i] == 1); }
 // Modem A external endpoint answers; direct branch receives CANCEL then a late 200.
 select_connection(1); response(200); assert(app.call.established && answers[0] == 1); connections[1] = app;
 select_connection(0); event("answer", "active", "external_sip"); assert(cancels[0] == 1 && app.fork_cancelled);
 response(200); assert(acks[0] == 1 && byes[0] == 1 && !app.call.active); connections[0] = app;
 assert(modems[1].state == QMODEM_VOIP_INCOMING_RINGING && answers[1] == 0);
 // Rejecting one branch does not reject the still-ringing cellular call.
 select_connection(2); response(486); assert(!app.call.active); connections[2] = app;
 assert(modems[1].state == QMODEM_VOIP_INCOMING_RINGING);
 select_connection(3); response(200); assert(app.call.established && answers[1] == 1); connections[3] = app;
 // Both accept before the cancellation event is delivered: only the first wins.
 modems[0].state = QMODEM_VOIP_INCOMING_RINGING; modems[0].answer_owner = QMODEM_VOIP_ENDPOINT_NONE;
 select_connection(0); app.media_attached = 1; event("ring", "incoming_ringing", "none"); response(200);
 assert(app.call.established && answers[0] == 2); connections[0] = app;
 select_connection(1); event("release", "idle", "none");
 app.media_attached = 1; event("ring", "incoming_ringing", "none"); response(200);
 assert(!app.call.active && answers[0] == 2 && byes[1] == 2);
 assert(modems[0].answer_owner == QMODEM_VOIP_ENDPOINT_LAN_SIP);
 assert(modems[1].answer_owner == QMODEM_VOIP_ENDPOINT_EXTERNAL_SIP);
 // A route disabled for incoming calls never rings.
 app.receive_voice = 0; unsigned before = invites[1];
 event("ring", "incoming_ringing", "none"); assert(invites[1] == before);
 // Complete Call-ID and connection identity participate in SMS idempotency.
 pjsip_rx_data sms = {0};
 pj_pool_t *sms_pool = pjsip_endpt_create_pool(app.endpoint, "sms", 2048, 2048);
 sms.msg_info.msg = pjsip_msg_create(sms_pool, PJSIP_REQUEST_MSG); pjsip_cid_hdr cid = {0}; pjsip_cseq_hdr seq = {0};
 char first[64], second[64]; cid.id = pj_str("a-very-long-call-id-with-identical-first-forty-four-characters-one");
 sms.msg_info.cid = &cid; sms.msg_info.cseq = &seq; assert(message_request_id(&sms, first) == 0);
 cid.id = pj_str("a-very-long-call-id-with-identical-first-forty-four-characters-two");
 assert(message_request_id(&sms, second) == 0); assert(strcmp(first, second));
 strcpy(app.group, "another_group"); assert(message_request_id(&sms, first) == 0); assert(strcmp(first, second));
 for (unsigned i = 0; i < 4; i++) { if (i == 1) connections[i] = app; select_connection(i); detach_media(); remember_outbound_invite(NULL); }
 uloop_done(); pjsip_endpt_destroy(app.endpoint); pj_caching_pool_destroy(&app.caching_pool); pj_shutdown();
 puts("PASS: two virtual modems, dual ringing, first answer wins, late 200 ACK/BYE, decline isolation, disabled routes and SMS identity");
 return 0;
}
