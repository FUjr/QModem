#define _GNU_SOURCE

#include "media_pcm_socket.h"

#include <errno.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <syslog.h>
#include <unistd.h>

#define QMODEM_VOIP_PCM_SOCKET_RETRY_MS 1000U
#define QMODEM_VOIP_PCM_SOCKET_FRAME_MS 20U
#define QMODEM_VOIP_PCM_SOCKET_RESYNC_MS 200U

static int pcm_socket_connect(struct qmodem_voip_media_engine *engine)
{
	struct sockaddr_un address;
	const char *path = engine->profile.socket_path;
	size_t length = strlen(path);
	int fd;

	if (!length || length >= sizeof(address.sun_path))
		return -1;
	fd = socket(AF_UNIX, SOCK_SEQPACKET | SOCK_NONBLOCK | SOCK_CLOEXEC, 0);
	if (fd < 0)
		return -1;
	memset(&address, 0, sizeof(address));
	address.sun_family = AF_UNIX;
	memcpy(address.sun_path, path, length + 1U);
	if (connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
		(void)close(fd);
		return -1;
	}
	engine->pcm_socket.fd = fd;
	engine->pcm_socket.next_playback_ms = 0;
	engine->pcm_socket.connects++;
	syslog(LOG_INFO, "qmodem_voip media: PCM socket %s connected", path);
	return 0;
}

static void pcm_socket_drop(struct qmodem_voip_media_engine *engine,
			    uint64_t timestamp_ms)
{
	if (engine->pcm_socket.fd >= 0) {
		(void)close(engine->pcm_socket.fd);
		syslog(LOG_WARNING, "qmodem_voip media: PCM socket %s lost",
			engine->profile.socket_path);
	}
	engine->pcm_socket.fd = -1;
	engine->pcm_socket.errors++;
	engine->pcm_socket.retry_at_ms = timestamp_ms + QMODEM_VOIP_PCM_SOCKET_RETRY_MS;
}

int qmodem_voip_pcm_socket_start(struct qmodem_voip_media_engine *engine)
{
	if (!engine || !engine->profile.socket_path[0])
		return -1;
	memset(&engine->pcm_socket, 0, sizeof(engine->pcm_socket));
	engine->pcm_socket.fd = -1;
	if (pcm_socket_connect(engine) != 0)
		syslog(LOG_NOTICE, "qmodem_voip media: PCM socket %s not available yet",
			engine->profile.socket_path);
	engine->device.capture_rate = QMODEM_VOIP_MEDIA_RATE;
	engine->device.playback_rate = QMODEM_VOIP_MEDIA_RATE;
	engine->device.full_duplex = 1;
	engine->backend = QMODEM_VOIP_MEDIA_BACKEND_PCM_SOCKET;
	engine->ready = 1;
	return 0;
}

int qmodem_voip_pcm_socket_capture(struct qmodem_voip_media_engine *engine,
				   uint64_t timestamp_ms)
{
	int16_t samples[QMODEM_VOIP_MEDIA_SAMPLES];
	ssize_t received;
	int frames = 0;

	if (!engine || !engine->ready)
		return -1;
	if (engine->pcm_socket.fd < 0) {
		if (timestamp_ms < engine->pcm_socket.retry_at_ms)
			return -1;
		engine->pcm_socket.retry_at_ms = timestamp_ms + QMODEM_VOIP_PCM_SOCKET_RETRY_MS;
		if (pcm_socket_connect(engine) != 0)
			return -1;
	}
	for (;;) {
		received = recv(engine->pcm_socket.fd, samples, sizeof(samples), 0);
		if (received == (ssize_t)sizeof(samples)) {
			(void)qmodem_voip_media_queue_push(&engine->modem_to_canonical,
				samples, QMODEM_VOIP_MEDIA_SAMPLES, timestamp_ms);
			engine->pcm_socket.capture_frames++;
			frames++;
			continue;
		}
		if (received > 0)
			continue;
		if (received < 0 && errno == EINTR)
			continue;
		if (received < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
			break;
		pcm_socket_drop(engine, timestamp_ms);
		return -1;
	}
	return frames;
}

int qmodem_voip_pcm_socket_playback(struct qmodem_voip_media_engine *engine,
				    uint64_t timestamp_ms)
{
	struct qmodem_voip_media_frame frame;
	ssize_t sent;

	if (!engine || !engine->ready || engine->pcm_socket.fd < 0)
		return -1;
	if (!engine->pcm_socket.next_playback_ms ||
	    timestamp_ms > engine->pcm_socket.next_playback_ms +
		QMODEM_VOIP_PCM_SOCKET_RESYNC_MS)
		engine->pcm_socket.next_playback_ms = timestamp_ms;
	if (timestamp_ms < engine->pcm_socket.next_playback_ms)
		return 0;
	engine->pcm_socket.next_playback_ms += QMODEM_VOIP_PCM_SOCKET_FRAME_MS;
	if (qmodem_voip_media_queue_pop(&engine->canonical_to_modem, &frame) < 0)
		return -1;
	sent = send(engine->pcm_socket.fd, frame.samples, sizeof(frame.samples),
		MSG_NOSIGNAL);
	memset(&frame, 0, sizeof(frame));
	if (sent == (ssize_t)sizeof(frame.samples)) {
		engine->pcm_socket.playback_frames++;
		return 0;
	}
	if (sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR))
		return -1;
	pcm_socket_drop(engine, timestamp_ms);
	return -1;
}

void qmodem_voip_pcm_socket_close(struct qmodem_voip_media_engine *engine)
{
	if (!engine)
		return;
	if (engine->pcm_socket.fd >= 0)
		(void)close(engine->pcm_socket.fd);
	engine->pcm_socket.fd = -1;
}
