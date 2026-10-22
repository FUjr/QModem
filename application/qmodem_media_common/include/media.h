#ifndef QMODEM_VOIP_MEDIA_H
#define QMODEM_VOIP_MEDIA_H

#include <stddef.h>
#include <stdint.h>
#include <pthread.h>
#include <stdatomic.h>

#include "modem_profile.h"

struct _snd_pcm;

#define QMODEM_VOIP_MEDIA_RATE 8000U
#define QMODEM_VOIP_BROWSER_RATE 48000U
#define QMODEM_VOIP_BROWSER_FRAME_SAMPLES 480U
#define QMODEM_VOIP_MEDIA_SAMPLES 160U
#define QMODEM_VOIP_BROWSER_SAMPLES 960U
#define QMODEM_VOIP_PCM_MAX_SAMPLES 1920U
/* Keep roughly half a second of 20 ms frames so short USB/WS scheduling
 * jitter does not turn into audible gaps, while bounding end-to-end delay. */
#define QMODEM_VOIP_MEDIA_QUEUE_FRAMES 25U
#define QMODEM_VOIP_MEDIA_PRODUCT "RM520N-GL"
#define QMODEM_VOIP_SERIAL_FRAME_BYTES (QMODEM_VOIP_MEDIA_SAMPLES * sizeof(int16_t))
#define QMODEM_VOIP_SERIAL_PLAYBACK_FRAMES 5U
#define QMODEM_VOIP_SERIAL_PLAYBACK_SAMPLES \
	(QMODEM_VOIP_MEDIA_SAMPLES * QMODEM_VOIP_SERIAL_PLAYBACK_FRAMES)
#define QMODEM_VOIP_SERIAL_TRANSFER_BYTES 1024U
#define QMODEM_VOIP_SERIAL_TRANSFER_INTERVAL_MS 60U

enum qmodem_voip_media_backend {
	QMODEM_VOIP_MEDIA_BACKEND_NONE,
	QMODEM_VOIP_MEDIA_BACKEND_UAC,
	QMODEM_VOIP_MEDIA_BACKEND_SERIAL
};

enum qmodem_voip_media_codec {
	QMODEM_VOIP_MEDIA_PCMA = 8,
	QMODEM_VOIP_MEDIA_PCMU = 0
};

enum qmodem_voip_media_attachment {
	QMODEM_VOIP_MEDIA_ATTACH_NONE,
	QMODEM_VOIP_MEDIA_ATTACH_BROWSER,
	QMODEM_VOIP_MEDIA_ATTACH_LAN_SIP,
	QMODEM_VOIP_MEDIA_ATTACH_CELLULAR,
	QMODEM_VOIP_MEDIA_ATTACH_SOCKET
};

struct qmodem_voip_media_frame {
	int16_t samples[QMODEM_VOIP_MEDIA_SAMPLES];
	uint64_t sequence;
	uint64_t timestamp_ms;
};

struct qmodem_voip_media_queue {
	struct qmodem_voip_media_frame frames[QMODEM_VOIP_MEDIA_QUEUE_FRAMES];
	unsigned first;
	unsigned count;
	uint64_t next_sequence;
	uint64_t dropped;
	uint64_t underruns;
	int drift_ppm;
	pthread_mutex_t lock;
	int lock_ready;
};

struct qmodem_voip_media_device {
	char slot[64];
	char pcm_name[32];
	unsigned card;
	unsigned device;
	unsigned capture_rate;
	unsigned playback_rate;
	int full_duplex;
};

struct qmodem_voip_media_tone {
	double rms;
	double frequency_hz;
	unsigned clipped;
	int valid;
};

struct qmodem_voip_serial_state {
	int fd;
	int active;
	atomic_int running;
	atomic_int attached;
	atomic_uint_fast64_t captured_frames;
	atomic_uint_fast64_t poll_wakeups;
	atomic_uint_fast64_t read_bytes;
	atomic_uint_fast64_t read_eagain;
	atomic_uint_fast64_t read_errors;
	atomic_uint_fast64_t write_bytes;
	atomic_uint_fast64_t write_eagain;
	atomic_uint_fast64_t write_errors;
	atomic_uint_fast64_t reopen_count;
	atomic_int reopen_pending;
	pthread_t thread;
	int thread_started;
	char path[256];
	int16_t capture[QMODEM_VOIP_SERIAL_PLAYBACK_SAMPLES];
	size_t capture_used;
	int16_t playback[QMODEM_VOIP_SERIAL_PLAYBACK_SAMPLES];
	size_t playback_used;
	size_t playback_offset;
	uint64_t next_playback_ms;
};

struct qmodem_voip_rtp_endpoint {
	uint32_t address;
	uint16_t port;
	uint16_t sequence;
	uint32_t timestamp;
	uint32_t ssrc;
	enum qmodem_voip_media_codec codec;
	uint64_t received_packets;
	uint64_t sent_packets;
};

struct qmodem_voip_media_engine {
	struct qmodem_voip_media_device device;
	struct qmodem_voip_modem_profile profile;
	struct qmodem_voip_media_queue modem_to_canonical;
	struct qmodem_voip_media_queue canonical_to_modem;
	struct qmodem_voip_rtp_endpoint rtp;
	enum qmodem_voip_media_attachment attachment;
	uint64_t session_id;
	uint64_t tone_failures;
	atomic_uint_fast64_t rtp_received_packets;
	atomic_uint_fast64_t rtp_sent_packets;
	struct _snd_pcm *capture_pcm;
	struct _snd_pcm *playback_pcm;
	struct qmodem_voip_serial_state serial;
	enum qmodem_voip_media_backend backend;
	int ready;
	int browser_media_ready;
};

void qmodem_voip_media_queue_init(struct qmodem_voip_media_queue *queue);
int qmodem_voip_media_queue_push(struct qmodem_voip_media_queue *queue,
				 const int16_t *samples, size_t sample_count,
				 uint64_t timestamp_ms);
int qmodem_voip_media_queue_pop(struct qmodem_voip_media_queue *queue,
				struct qmodem_voip_media_frame *frame);
void qmodem_voip_media_queue_clear(struct qmodem_voip_media_queue *queue);
void qmodem_voip_media_queue_drift(struct qmodem_voip_media_queue *queue,
				   int observed_ppm);
int qmodem_voip_media_resample(const int16_t *input, size_t input_samples,
			       unsigned input_rate, int16_t *output,
			       size_t output_capacity, unsigned output_rate,
			       size_t *output_samples);
int qmodem_voip_media_g711_encode(enum qmodem_voip_media_codec codec,
				  const int16_t *input, size_t samples, uint8_t *output);
int qmodem_voip_media_g711_decode(enum qmodem_voip_media_codec codec,
				  const uint8_t *input, size_t samples, int16_t *output);
void qmodem_voip_media_tone_analyse(const int16_t *samples, size_t count,
				    unsigned rate, struct qmodem_voip_media_tone *tone);
int qmodem_voip_media_attach(struct qmodem_voip_media_engine *engine,
			     enum qmodem_voip_media_attachment attachment,
			     uint64_t session_id);
void qmodem_voip_media_detach(struct qmodem_voip_media_engine *engine);
void qmodem_voip_media_release(struct qmodem_voip_media_engine *engine);
int qmodem_voip_media_rtp_receive(struct qmodem_voip_media_engine *engine,
				   const uint8_t *packet, size_t length,
				   uint32_t source_address, uint16_t source_port,
				   void (*dtmf)(unsigned digit, void *opaque), void *opaque);
int qmodem_voip_media_discover(const char *sysfs_root, const char *proc_root,
				const char *recorded_slot,
				struct qmodem_voip_media_device *device);
int qmodem_voip_media_probe(struct qmodem_voip_media_device *device);
int qmodem_voip_media_capture(struct qmodem_voip_media_engine *engine,
				uint64_t timestamp_ms);
int qmodem_voip_media_playback(struct qmodem_voip_media_engine *engine,
				uint64_t timestamp_ms);
int qmodem_voip_media_self_test(struct qmodem_voip_media_device *device,
				 struct qmodem_voip_media_tone *tone);
int qmodem_voip_media_engine_start(struct qmodem_voip_media_engine *engine);

#endif
