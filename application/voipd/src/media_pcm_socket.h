#ifndef QMODEM_VOIP_MEDIA_PCM_SOCKET_H
#define QMODEM_VOIP_MEDIA_PCM_SOCKET_H

#include "media.h"

int qmodem_voip_pcm_socket_start(struct qmodem_voip_media_engine *engine);
int qmodem_voip_pcm_socket_capture(struct qmodem_voip_media_engine *engine,
				   uint64_t timestamp_ms);
int qmodem_voip_pcm_socket_playback(struct qmodem_voip_media_engine *engine,
				    uint64_t timestamp_ms);
void qmodem_voip_pcm_socket_close(struct qmodem_voip_media_engine *engine);

#endif
