#ifndef QMODEM_VOIP_BROWSER_MEDIA_H
#define QMODEM_VOIP_BROWSER_MEDIA_H

#include "media.h"

#include <stddef.h>
#include <stdint.h>

#define QMODEM_VOIP_BROWSER_TOKEN_BYTES 16U
#define QMODEM_VOIP_BROWSER_TOKEN_TEXT 22U
#define QMODEM_VOIP_BROWSER_TOKEN_SLOTS 32U
#define QMODEM_VOIP_BROWSER_TOKEN_TTL 30U
#define QMODEM_VOIP_BROWSER_HEADER_SIZE 24U
#define QMODEM_VOIP_BROWSER_FRAME_SIZE \
	(QMODEM_VOIP_BROWSER_HEADER_SIZE + QMODEM_VOIP_BROWSER_FRAME_SAMPLES * 2U)
#define QMODEM_VOIP_BROWSER_MAGIC 0x514d5650U
#define QMODEM_VOIP_BROWSER_VERSION 1U
#define QMODEM_VOIP_BROWSER_FORMAT_S16LE 1U
#define QMODEM_VOIP_BROWSER_TLS_MAX 8192U

struct qmodem_voip_browser_token {
	uint8_t secret[QMODEM_VOIP_BROWSER_TOKEN_BYTES];
	uint64_t call_revision;
	uint64_t expires_at;
	char session_id[65];
	char origin[193];
	char peer_address[64];
	int active;
};

struct qmodem_voip_browser_tokens {
	struct qmodem_voip_browser_token slots[QMODEM_VOIP_BROWSER_TOKEN_SLOTS];
};

struct qmodem_voip_browser_frame {
	uint32_t sequence;
	uint32_t timestamp_ms;
	int16_t samples[QMODEM_VOIP_BROWSER_FRAME_SAMPLES];
};

struct qmodem_voip_browser_media {
	struct qmodem_voip_browser_tokens tokens;
	struct qmodem_voip_media_engine *engine;
	void *context;
	void *client;
	void *pending_client;
	char address[16];
    char socket_path[108];
	char certificate[256];
	char key[256];
	uint8_t certificate_data[QMODEM_VOIP_BROWSER_TLS_MAX];
	uint8_t key_data[QMODEM_VOIP_BROWSER_TLS_MAX];
	size_t certificate_length;
	size_t key_length;
	char origin[193];
	uint64_t call_revision;
	uint32_t expected_sequence;
	uint32_t last_timestamp_ms;
	int sequence_seen;
	int16_t uplink[QMODEM_VOIP_MEDIA_SAMPLES];
	unsigned uplink_count;
	uint64_t uplink_frames;
	uint64_t uplink_non_silent_frames;
	unsigned uplink_peak;
	uint64_t downlink_frames;
	uint64_t downlink_empty;
	uint64_t downlink_write_errors;
	uint64_t dropped;
	int attached;
	int ready;
};

void qmodem_voip_browser_tokens_init(struct qmodem_voip_browser_tokens *tokens);
void qmodem_voip_browser_tokens_clear(struct qmodem_voip_browser_tokens *tokens);
int qmodem_voip_browser_token_issue(struct qmodem_voip_browser_tokens *tokens,
				    const char *session_id, uint64_t call_revision,
				    const char *origin, const char *peer_address,
				    uint64_t now, char token[23]);
int qmodem_voip_browser_token_consume(struct qmodem_voip_browser_tokens *tokens,
				      const char *token, const char *session_id,
				      uint64_t call_revision, const char *origin,
				      const char *peer_address, uint64_t now);
int qmodem_voip_browser_frame_parse(const uint8_t *data, size_t length,
				    struct qmodem_voip_browser_frame *frame);
int qmodem_voip_browser_configure(struct qmodem_voip_browser_media *browser,
				  struct qmodem_voip_media_engine *engine,
				  const char *address, const char *certificate, const char *key);
int qmodem_voip_browser_media_start(struct qmodem_voip_browser_media *browser);
void qmodem_voip_browser_media_reset_call(struct qmodem_voip_browser_media *browser);
void qmodem_voip_browser_media_stop(struct qmodem_voip_browser_media *browser);
void qmodem_voip_browser_media_release(struct qmodem_voip_browser_media *browser);
int qmodem_voip_browser_media_receive(struct qmodem_voip_browser_media *browser,
				      const uint8_t *data, size_t length);
int qmodem_voip_browser_media_attach(struct qmodem_voip_browser_media *browser,
				     uint64_t call_revision);
int qmodem_voip_browser_media_service(struct qmodem_voip_browser_media *browser);
const char *qmodem_voip_browser_media_url(const struct qmodem_voip_browser_media *browser,
					   char *buffer, size_t size);

#endif
