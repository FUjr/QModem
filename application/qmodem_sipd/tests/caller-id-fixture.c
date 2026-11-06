/* Compile with the same PJSIP/libubus dependencies as sip_consumer.c. */
#define main consumer_program_main
#include "../src/sip_consumer.c"
#undef main
#undef NDEBUG
#include <assert.h>

static void event(const char *name, const char *state, const char *number)
{
	struct blob_buf message = { 0 };
	blob_buf_init(&message, 0);
	blobmsg_add_string(&message, "event", name);
	blobmsg_add_string(&message, "state", state);
	blobmsg_add_string(&message, "remote_number", number);
	blobmsg_add_u8(&message, "caller_id_withheld", 0);
	consumer_event(NULL, NULL, NULL, message.head);
	blob_buf_free(&message);
}

int main(void)
{
	pj_caching_pool pool;
	pjsip_tx_data *request;
	pj_str_t address = pj_str("sip:gateway@example.invalid");
	char packet[4096];
	int size;
	pj_log_set_level(0);
	assert(pj_init() == PJ_SUCCESS);
	assert(pjlib_util_init() == PJ_SUCCESS);
	pj_caching_pool_init(&pool, NULL, 0);
	assert(pjsip_endpt_create(&pool.factory, NULL, &app.endpoint) == PJ_SUCCESS);
	assert(uloop_init() == 0);
	strcpy(app.lan_address, "192.0.2.1");
	const char *numbers[] = { "+15500001234", "", "1+23", "123\r\nInjected: x" };
	for (unsigned hidden = 0; hidden < 2; hidden++) {
		for (unsigned i = 0; i < ARRAY_SIZE(numbers); i++) {
			assert(pjsip_endpt_create_request(app.endpoint, &pjsip_invite_method,
				&address, &address, &address, &address, NULL, 1, NULL,
				&request) == PJ_SUCCESS);
			strcpy(app.incoming_number, numbers[i]);
			app.incoming_caller_id_withheld = hidden;
			set_incoming_identity(request);
			size = pjsip_msg_print(request->msg, packet, sizeof(packet) - 1);
			assert(size > 0);
			packet[size] = 0;
			assert(strstr(packet, "gateway@example.invalid"));
			assert(!strstr(packet, "Injected:"));
			assert(!!strstr(packet, "P-Asserted-Identity:") == (!hidden && i == 0));
			assert(!!strstr(packet, "Privacy: id") == !!hidden);
			assert(strstr(packet, hidden ? "Anonymous" : i == 0 ? "+15500001234" : "Unknown"));
			pjsip_tx_data_dec_ref(request);
		}
	}
	event("ring", "incoming_ringing", "");
	assert(app.incoming_offer_timeout.pending);
	int64_t remaining = uloop_timeout_remaining64(&app.incoming_offer_timeout);
	event("ring", "incoming_ringing", "");
	assert(uloop_timeout_remaining64(&app.incoming_offer_timeout) <= remaining);
	event("caller_id", "incoming_ringing", "+15500001234");
	assert(!app.incoming_offer_timeout.pending);
	event("release", "idle", "");
	assert(!app.incoming_number[0]);
	event("ring", "incoming_ringing", "");
	assert(app.incoming_offer_timeout.pending);
	event("call_state", "idle", "");
	assert(!app.incoming_offer_timeout.pending);
	uloop_done();
	pjsip_endpt_destroy(app.endpoint);
	pj_caching_pool_destroy(&pool);
	pj_shutdown();
	puts("PASS: SIP caller identity, privacy, late number, coalescing and release");
	return 0;
}
