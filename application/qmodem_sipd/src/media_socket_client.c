#define _POSIX_C_SOURCE 200809L

#include "media_socket_client.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

/* Consumer-side of the daemon's SOCK_SEQPACKET media socket. Frames are built
   and validated exactly as the server (media_socket.c) expects: a 12-byte
   header followed by a payload, delivered as one datagram in native byte order.
   attach() completes the synchronous handshake (STATE_CHANGE on success, ERROR
   on refusal) so the caller can rely on attached==1 before exchanging PCM. */

#define QMODEM_VOIP_MEDIA_SOCKET_ATTACH_TIMEOUT_MS 1000

static int nonblocking(int fd)
{
	int flags = fcntl(fd, F_GETFL);
	return flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 ? -1 : 0;
}

int qmodem_voip_media_socket_client_attach(
	struct qmodem_voip_media_socket_client *client,
	const char *path, uint64_t call_revision, const char *session_id)
{
	struct qmodem_voip_media_socket_header header;
	struct qmodem_voip_media_socket_attach attach;
	struct sockaddr_un address = { 0 };
	struct pollfd poll_fd;
	uint8_t outgoing[sizeof(header) + sizeof(attach)];
	uint8_t incoming[sizeof(struct qmodem_voip_media_socket_message)];
	int fd;
	int n;

	if (!client || !path || !path[0] || !session_id || !session_id[0] ||
	    strlen(path) >= sizeof(address.sun_path) ||
	    strlen(session_id) >= sizeof(attach.session_id))
		return -1;
	fd = socket(AF_UNIX, SOCK_SEQPACKET, 0);
	if (fd < 0)
		return -1;
	address.sun_family = AF_UNIX;
	memcpy(address.sun_path, path, strlen(path) + 1U);
	/* A full local listen backlog must not block SIP registration/keepalives. */
	if (nonblocking(fd) != 0 ||
	    connect(fd, (struct sockaddr *)&address, sizeof(address)) != 0) {
		(void)close(fd);
		return -1;
	}
	memset(outgoing, 0, sizeof(outgoing));
	memset(&header, 0, sizeof(header));
	memset(&attach, 0, sizeof(attach));
	header.magic = QMODEM_VOIP_MEDIA_SOCKET_MAGIC;
	header.version = QMODEM_VOIP_MEDIA_SOCKET_VERSION;
	header.type = QMODEM_VOIP_MEDIA_SOCKET_ATTACH;
	header.payload_length = (uint32_t)sizeof(attach);
	attach.call_revision = call_revision;
	memcpy(attach.session_id, session_id, strlen(session_id) + 1U);
	memcpy(outgoing, &header, sizeof(header));
	memcpy(outgoing + sizeof(header), &attach, sizeof(attach));
	if (send(fd, outgoing, sizeof(outgoing), 0) != (ssize_t)sizeof(outgoing)) {
		(void)close(fd);
		return -1;
	}
	memset(outgoing, 0, sizeof(outgoing));
	poll_fd.fd = fd;
	poll_fd.events = POLLIN;
	n = poll(&poll_fd, 1, QMODEM_VOIP_MEDIA_SOCKET_ATTACH_TIMEOUT_MS);
	if (n <= 0) {
		(void)close(fd);
		return -1;
	}
	n = recv(fd, incoming, sizeof(incoming), 0);
	if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK))
		n = -1;
	if (n < (ssize_t)sizeof(header)) {
		(void)close(fd);
		return -1;
	}
	memcpy(&header, incoming, sizeof(header));
	if (header.magic != QMODEM_VOIP_MEDIA_SOCKET_MAGIC ||
	    header.version != QMODEM_VOIP_MEDIA_SOCKET_VERSION ||
	    header.payload_length != (uint32_t)(n - (int)sizeof(header))) {
		(void)close(fd);
		return -1;
	}
	if (header.type != QMODEM_VOIP_MEDIA_SOCKET_STATE_CHANGE) {
		(void)close(fd);
		return -1;
	}
	memset(incoming, 0, sizeof(incoming));
	client->fd = fd;
	client->attached = 1;
	client->call_revision = call_revision;
	client->outbound_sequence = 0;
	client->dropped = 0;
	return 0;
}

int qmodem_voip_media_socket_client_read(
	struct qmodem_voip_media_socket_client *client,
	struct qmodem_voip_media_socket_message *message)
{
	struct qmodem_voip_media_socket_header header;
	int received;

	if (!client || client->fd < 0 || !message)
		return -1;
	received = recv(client->fd, (uint8_t *)message, sizeof(*message), 0);
	if (received < 0) {
		if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
			return 0;
		return -1;
	}
	if (received == 0)
		return -1;
	memcpy(&header, message, sizeof(header));
	if (header.magic != QMODEM_VOIP_MEDIA_SOCKET_MAGIC ||
	    header.version != QMODEM_VOIP_MEDIA_SOCKET_VERSION ||
	    header.payload_length != (uint32_t)(received - (int)sizeof(header)))
		return -1;
	return 1;
}

int qmodem_voip_media_socket_client_write(
	struct qmodem_voip_media_socket_client *client,
	enum qmodem_voip_media_socket_frame_type type,
	const void *payload, size_t payload_size)
{
	struct qmodem_voip_media_socket_header *header;
	uint8_t outgoing[sizeof(*header) + sizeof(struct qmodem_voip_media_socket_pcm)];
	size_t used = 0;

	if (!client || client->fd < 0 || !payload ||
	    payload_size > sizeof(outgoing) - sizeof(*header))
		return -1;
	memset(outgoing, 0, sizeof(outgoing));
	header = (struct qmodem_voip_media_socket_header *)outgoing;
	header->magic = QMODEM_VOIP_MEDIA_SOCKET_MAGIC;
	header->version = QMODEM_VOIP_MEDIA_SOCKET_VERSION;
	header->type = (uint16_t)type;
	header->payload_length = (uint32_t)payload_size;
	used += sizeof(*header);
	memcpy(outgoing + used, payload, payload_size);
	used += payload_size;
	if (send(client->fd, outgoing, used, 0) != (ssize_t)used) {
		memset(outgoing, 0, used);
		return -1;
	}
	memset(outgoing, 0, used);
	return 0;
}

void qmodem_voip_media_socket_client_detach(
	struct qmodem_voip_media_socket_client *client)
{
	if (!client || client->fd < 0)
		return;
	if (client->attached) {
		struct qmodem_voip_media_socket_header header;

		memset(&header, 0, sizeof(header));
		header.magic = QMODEM_VOIP_MEDIA_SOCKET_MAGIC;
		header.version = QMODEM_VOIP_MEDIA_SOCKET_VERSION;
		header.type = QMODEM_VOIP_MEDIA_SOCKET_DETACH;
		header.payload_length = 0;
		(void)send(client->fd, &header, sizeof(header), 0);
		memset(&header, 0, sizeof(header));
		client->attached = 0;
	}
	(void)close(client->fd);
	client->fd = -1;
}
