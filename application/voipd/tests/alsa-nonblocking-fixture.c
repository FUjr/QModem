#include "media.h"
#include <alsa/asoundlib.h>
#include <assert.h>
#include <errno.h>
#include <stdint.h>
#include <string.h>

static unsigned reads, writes;
static int open_error = -EBUSY, capture_error;
int __wrap_snd_pcm_open(snd_pcm_t **pcm, const char *name,
		snd_pcm_stream_t stream, int mode)
{
	(void)pcm; (void)name; (void)stream;
	assert(mode == SND_PCM_NONBLOCK);
	return open_error;
}
snd_pcm_sframes_t __wrap_snd_pcm_readi(snd_pcm_t *pcm, void *buffer, snd_pcm_uframes_t count)
{
	int16_t *samples = buffer;
	(void)pcm;
	if (capture_error) return capture_error;
	if (++reads == 2) return -EAGAIN;
	assert(count == (reads == 1 ? 160U : 80U));
	for (unsigned i = 0; i < 80; i++) samples[i] = reads == 1 ? 11 : 22;
	return 80;
}
snd_pcm_sframes_t __wrap_snd_pcm_writei(snd_pcm_t *pcm, const void *buffer, snd_pcm_uframes_t count)
{
	const int16_t *samples = buffer;
	(void)pcm;
	if (++writes == 2) return -EAGAIN;
	assert(count == (writes == 1 ? 160U : 80U));
	for (unsigned i = 0; i < 80; i++) assert(samples[i] == (writes == 1 ? 33 : 44));
	return 80;
}
int qmodem_voip_serial_capture(struct qmodem_voip_media_engine *e, uint64_t t) { (void)e; (void)t; return -1; }
int qmodem_voip_serial_playback(struct qmodem_voip_media_engine *e, uint64_t t) { (void)e; (void)t; return -1; }
int qmodem_voip_pcm_socket_capture(struct qmodem_voip_media_engine *e, uint64_t t) { (void)e; (void)t; return -1; }
int qmodem_voip_pcm_socket_playback(struct qmodem_voip_media_engine *e, uint64_t t) { (void)e; (void)t; return -1; }
int main(int argc, char **argv)
{
	struct qmodem_voip_media_engine engine = { 0 };
	struct qmodem_voip_media_frame frame;
	struct qmodem_voip_media_device device;
	int16_t data[160];
	assert(argc == 3);
	assert(qmodem_voip_media_discover(argv[1], argv[2], "2-1", &device) == 0);
	assert(device.card == 3 && device.device == 0);
	assert(qmodem_voip_media_probe(&device) == -EBUSY);
	open_error = -ENODEV;
	assert(qmodem_voip_media_probe(&device) == -ENODEV);
	assert(qmodem_voip_media_discover(argv[1], argv[2], "3-1", &device) == -2);
	assert(qmodem_voip_media_discover(argv[1], argv[2], "4-1", &device) == -1);
	engine.backend = QMODEM_VOIP_MEDIA_BACKEND_UAC;
	engine.ready = 1;
	engine.device.capture_rate = engine.device.playback_rate = 8000;
	engine.capture_pcm = engine.playback_pcm = (snd_pcm_t *)(uintptr_t)1;
	qmodem_voip_media_queue_init(&engine.modem_to_canonical);
	qmodem_voip_media_queue_init(&engine.canonical_to_modem);
	assert(qmodem_voip_media_capture(&engine, 1) == 0);
	assert(engine.alsa_capture_used == 80);
	assert(qmodem_voip_media_capture(&engine, 2) == 0);
	assert(engine.alsa_capture_used == 80 && engine.modem_to_canonical.count == 0);
	assert(qmodem_voip_media_capture(&engine, 3) == 0);
	assert(qmodem_voip_media_queue_pop(&engine.modem_to_canonical, &frame) == 0);
	for (unsigned i = 0; i < 160; i++) assert(frame.samples[i] == (i < 80 ? 11 : 22));
	for (unsigned i = 0; i < 160; i++) data[i] = i < 80 ? 33 : 44;
	assert(qmodem_voip_media_queue_push(&engine.canonical_to_modem, data, 160, 1) == 0);
	assert(qmodem_voip_media_playback(&engine, 1) == 0);
	assert(engine.alsa_playback_used == 80);
	assert(qmodem_voip_media_playback(&engine, 2) == 0);
	assert(engine.alsa_playback_used == 80);
	assert(qmodem_voip_media_playback(&engine, 3) == 0);
	assert(engine.alsa_playback_count == 0 && engine.canonical_to_modem.count == 0);
	capture_error = -ENODEV;
	assert(qmodem_voip_media_capture(&engine, 4) != 0);
	assert(engine.alsa_io_failed);
	return 0;
}
