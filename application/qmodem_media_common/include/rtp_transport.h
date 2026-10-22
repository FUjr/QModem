#ifndef QMODEM_VOIP_RTP_TRANSPORT_H
#define QMODEM_VOIP_RTP_TRANSPORT_H

#include "media.h"

#include <netinet/in.h>
#include <stdint.h>

#define QMODEM_VOIP_RTP_PORT 40000U

struct qmodem_voip_rtp_transport {
	int fd;
	int active;
	struct sockaddr_in peer;
	struct qmodem_voip_media_engine *engine;
	enum qmodem_voip_media_codec codec;
	uint16_t sequence;
	uint32_t timestamp;
	uint32_t ssrc;
};

int qmodem_voip_rtp_attach(struct qmodem_voip_rtp_transport *transport,
	struct qmodem_voip_media_engine *engine, uint32_t peer_address,
	uint16_t peer_port, enum qmodem_voip_media_codec codec,
	uint64_t session_id);
int qmodem_voip_rtp_service(struct qmodem_voip_rtp_transport *transport,
	uint64_t timestamp_ms);
void qmodem_voip_rtp_release(struct qmodem_voip_rtp_transport *transport);

#endif
