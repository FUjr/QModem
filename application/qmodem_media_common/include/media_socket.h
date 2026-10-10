#ifndef QMODEM_VOIP_MEDIA_SOCKET_H
#define QMODEM_VOIP_MEDIA_SOCKET_H

#include "media.h"

#include <libubox/uloop.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/un.h>

#define QMODEM_VOIP_MEDIA_SOCKET_MAGIC 0x514d534bU /* "QMSK" */
#define QMODEM_VOIP_MEDIA_SOCKET_VERSION 1U
#define QMODEM_VOIP_MEDIA_SOCKET_PATH_MAX 108U
#define QMODEM_VOIP_MEDIA_SOCKET_PEERS 8U
#define QMODEM_VOIP_MEDIA_SOCKET_FRAME_SAMPLES QMODEM_VOIP_MEDIA_SAMPLES
#define QMODEM_VOIP_MEDIA_SOCKET_SESSION_SLOTS 8U
#define QMODEM_VOIP_MEDIA_SOCKET_SESSION_TTL 30U
#define QMODEM_VOIP_MEDIA_SOCKET_SESSION_ID_MAX 64U

enum qmodem_voip_media_socket_frame_type {
	QMODEM_VOIP_MEDIA_SOCKET_ATTACH = 0x01,
	QMODEM_VOIP_MEDIA_SOCKET_DETACH = 0x02,
	QMODEM_VOIP_MEDIA_SOCKET_HEARTBEAT = 0x03,
	QMODEM_VOIP_MEDIA_SOCKET_PCM_CAPTURE = 0x10,
	QMODEM_VOIP_MEDIA_SOCKET_PCM_PLAYBACK = 0x11,
	QMODEM_VOIP_MEDIA_SOCKET_STATE_CHANGE = 0x12,
	QMODEM_VOIP_MEDIA_SOCKET_ERROR = 0xFF
};

struct qmodem_voip_media_socket_header {
	uint32_t magic;
	uint16_t version;
	uint16_t type;
	uint32_t payload_length;
};

struct qmodem_voip_media_socket_attach {
	uint64_t call_revision;
	char session_id[65];
};

struct qmodem_voip_media_socket_pcm {
	uint32_t sequence;
	uint32_t timestamp_ms;
	int16_t samples[QMODEM_VOIP_MEDIA_SOCKET_FRAME_SAMPLES];
};

struct qmodem_voip_media_socket_message {
	struct qmodem_voip_media_socket_header header;
	union {
		struct qmodem_voip_media_socket_attach attach;
		struct qmodem_voip_media_socket_pcm pcm;
		struct { uint32_t state; uint32_t revision; } state;
		struct { uint32_t code; } error;
	} body;
} __attribute__((packed));

_Static_assert(sizeof(struct qmodem_voip_media_socket_header) == 12U,
	"media socket wire header must remain 12 bytes");
_Static_assert(offsetof(struct qmodem_voip_media_socket_message, body) ==
	sizeof(struct qmodem_voip_media_socket_header),
	"media socket payload must immediately follow the wire header");

struct qmodem_voip_media_socket_peer {
	struct qmodem_voip_media_socket *owner;
	struct uloop_fd fd_event;
	int fd;
	int attached;
	uint64_t call_revision;
	uint32_t outbound_sequence;
	int dropped;
};

/*
 * A locally-minted, short-lived media session. The daemon issues one of these
 * to a headless consumer (SIP bridge) that has no browser-style ubus session
 * but is an authorized local call owner. Sessions are random, bound to one call
 * revision, and expire after a bounded TTL; this is the only way such a peer can
 * satisfy the socket ATTACH without a browser login.
 */
struct qmodem_voip_media_socket_session {
	char id[QMODEM_VOIP_MEDIA_SOCKET_SESSION_ID_MAX];
	uint64_t call_revision;
	uint64_t expires_at;
	int active;
};

struct qmodem_voip_media_socket {
	struct uloop_fd listener;
	struct qmodem_voip_media_engine *engine;
	void *context;
	char path[QMODEM_VOIP_MEDIA_SOCKET_PATH_MAX];
	struct qmodem_voip_media_socket_peer peers[QMODEM_VOIP_MEDIA_SOCKET_PEERS];
	struct qmodem_voip_media_socket_session sessions[QMODEM_VOIP_MEDIA_SOCKET_SESSION_SLOTS];
	int ready;
	int running;
};

int qmodem_voip_media_socket_start(struct qmodem_voip_media_socket *socket,
				   struct qmodem_voip_media_engine *engine,
				   void *context, const char *path);
void qmodem_voip_media_socket_stop(struct qmodem_voip_media_socket *socket);
void qmodem_voip_media_socket_release(struct qmodem_voip_media_socket *socket);
int qmodem_voip_media_socket_service(struct qmodem_voip_media_socket *socket,
				     uint64_t timestamp_ms);
/*
 * Returns 1 when at least one peer is attached to the media socket. The
 * daemon uses this to keep draining canonical_to_modem playback even when
 * neither the browser nor an in-daemon RTP owner is attached, since a socket
 * consumer is the audio sink in that case.
 */
int qmodem_voip_media_socket_attached(
	const struct qmodem_voip_media_socket *socket);
int qmodem_voip_media_socket_session_issue(struct qmodem_voip_media_socket *socket,
					   uint64_t call_revision, uint64_t now,
					   char id[QMODEM_VOIP_MEDIA_SOCKET_SESSION_ID_MAX]);
int qmodem_voip_media_socket_session_valid(struct qmodem_voip_media_socket *socket,
					   const char *id, uint64_t call_revision,
					   uint64_t now);

#endif
