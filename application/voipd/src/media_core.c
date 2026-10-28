#include "media.h"
#include "media_pcm_socket.h"
#include "media_serial.h"
#include "g711.h"

#include <math.h>
#include <string.h>

#ifndef QMODEM_VOIP_HOST_TEST
#include <alsa/asoundlib.h>
#endif

#ifndef QMODEM_VOIP_HOST_TEST
#include <soxr.h>
#endif

static void zero(void *value, size_t length)
{
	volatile unsigned char *bytes = value;
	while (length--)
		*bytes++ = 0;
}

void qmodem_voip_media_queue_init(struct qmodem_voip_media_queue *queue)
{
	if (!queue)
		return;
	zero(queue, sizeof(*queue));
	if (pthread_mutex_init(&queue->lock, NULL) == 0)
		queue->lock_ready = 1;
}

int qmodem_voip_media_queue_push(struct qmodem_voip_media_queue *queue,
				 const int16_t *samples, size_t sample_count,
				 uint64_t timestamp_ms)
{
	unsigned slot;
	if (!queue || !samples || sample_count != QMODEM_VOIP_MEDIA_SAMPLES)
		return -1;
	if (!queue->lock_ready || pthread_mutex_lock(&queue->lock) != 0)
		return -1;
	if (queue->count == QMODEM_VOIP_MEDIA_QUEUE_FRAMES) {
		zero(&queue->frames[queue->first], sizeof(queue->frames[0]));
		queue->first = (queue->first + 1U) % QMODEM_VOIP_MEDIA_QUEUE_FRAMES;
		queue->count--;
		queue->dropped++;
	}
	slot = (queue->first + queue->count) % QMODEM_VOIP_MEDIA_QUEUE_FRAMES;
	memcpy(queue->frames[slot].samples, samples, sizeof(queue->frames[slot].samples));
	queue->frames[slot].sequence = queue->next_sequence++;
	queue->frames[slot].timestamp_ms = timestamp_ms;
	queue->count++;
	(void)pthread_mutex_unlock(&queue->lock);
	return 0;
}

int qmodem_voip_media_queue_pop(struct qmodem_voip_media_queue *queue,
				struct qmodem_voip_media_frame *frame)
{
	if (!queue || !frame)
		return -1;
	if (!queue->lock_ready || pthread_mutex_lock(&queue->lock) != 0)
		return -1;
	if (!queue->count) {
		zero(frame, sizeof(*frame));
		frame->sequence = queue->next_sequence++;
		queue->underruns++;
		(void)pthread_mutex_unlock(&queue->lock);
		return 1;
	}
	*frame = queue->frames[queue->first];
	zero(&queue->frames[queue->first], sizeof(queue->frames[0]));
	queue->first = (queue->first + 1U) % QMODEM_VOIP_MEDIA_QUEUE_FRAMES;
	queue->count--;
	(void)pthread_mutex_unlock(&queue->lock);
	return 0;
}

void qmodem_voip_media_queue_clear(struct qmodem_voip_media_queue *queue)
{
	if (!queue || !queue->lock_ready || pthread_mutex_lock(&queue->lock) != 0)
		return;
	zero(queue->frames, sizeof(queue->frames));
	queue->first = 0;
	queue->count = 0;
	(void)pthread_mutex_unlock(&queue->lock);
}

void qmodem_voip_media_queue_drift(struct qmodem_voip_media_queue *queue,
				   int observed_ppm)
{
	if (!queue)
		return;
	if (!queue->lock_ready || pthread_mutex_lock(&queue->lock) != 0)
		return;
	if (observed_ppm > 100)
		observed_ppm = 100;
	if (observed_ppm < -100)
		observed_ppm = -100;
	queue->drift_ppm = observed_ppm;
	(void)pthread_mutex_unlock(&queue->lock);
}

int qmodem_voip_media_g711_encode(enum qmodem_voip_media_codec codec,
				  const int16_t *input, size_t samples, uint8_t *output)
{
	if (!input || !output || (codec != QMODEM_VOIP_MEDIA_PCMA && codec != QMODEM_VOIP_MEDIA_PCMU))
		return -1;
	for (size_t i = 0; i < samples; i++)
		output[i] = codec == QMODEM_VOIP_MEDIA_PCMA
			? qmodem_g711_alaw_encode(input[i]) : qmodem_g711_ulaw_encode(input[i]);
	return 0;
}

int qmodem_voip_media_g711_decode(enum qmodem_voip_media_codec codec,
				  const uint8_t *input, size_t samples, int16_t *output)
{
	if (!input || !output || (codec != QMODEM_VOIP_MEDIA_PCMA && codec != QMODEM_VOIP_MEDIA_PCMU))
		return -1;
	for (size_t i = 0; i < samples; i++)
		output[i] = codec == QMODEM_VOIP_MEDIA_PCMA
			? qmodem_g711_alaw_decode(input[i]) : qmodem_g711_ulaw_decode(input[i]);
	return 0;
}

int qmodem_voip_media_resample(const int16_t *input, size_t input_samples,
			       unsigned input_rate, int16_t *output,
			       size_t output_capacity, unsigned output_rate,
			       size_t *output_samples)
{
	size_t required;
	if (!input || !output || !output_samples || !input_rate || !output_rate)
		return -1;
	required = (input_samples * output_rate + input_rate / 2U) / input_rate;
	if (!required || required > output_capacity)
		return -1;
#ifdef QMODEM_VOIP_HOST_TEST
	for (size_t i = 0; i < required; i++)
		output[i] = input[(i * input_rate) / output_rate];
#else
	{
		soxr_error_t error;
		soxr_io_spec_t io_spec = soxr_io_spec(SOXR_INT16_I, SOXR_INT16_I);
		size_t done = 0;
		error = soxr_oneshot(input_rate, output_rate, 1, input, input_samples, NULL,
			output, output_capacity, &done, &io_spec, NULL, NULL);
		if (error || done != required)
			return -1;
	}
#endif
	*output_samples = required;
	return 0;
}

void qmodem_voip_media_tone_analyse(const int16_t *samples, size_t count,
				    unsigned rate, struct qmodem_voip_media_tone *tone)
{
	double energy = 0.0;
	double crossings = 0.0;
	if (!tone)
		return;
	zero(tone, sizeof(*tone));
	if (!samples || count < 2 || !rate)
		return;
	for (size_t i = 0; i < count; i++) {
		double value = samples[i];
		energy += value * value;
		if (samples[i] == 32767 || samples[i] == -32768)
			tone->clipped++;
		if (i && ((samples[i - 1] < 0 && samples[i] >= 0) ||
			  (samples[i - 1] >= 0 && samples[i] < 0)))
			crossings += 0.5;
	}
	tone->rms = sqrt(energy / (double)count);
	tone->frequency_hz = crossings * rate / (double)count;
	tone->valid = tone->rms > 1000.0 && tone->rms < 30000.0 &&
		tone->frequency_hz >= 900.0 && tone->frequency_hz <= 1100.0 && !tone->clipped;
}

int qmodem_voip_media_attach(struct qmodem_voip_media_engine *engine,
			     enum qmodem_voip_media_attachment attachment,
			     uint64_t session_id)
{
	if (!engine || !engine->ready || !session_id || attachment == QMODEM_VOIP_MEDIA_ATTACH_NONE ||
		attachment > QMODEM_VOIP_MEDIA_ATTACH_SOCKET ||
		(engine->session_id && engine->session_id != session_id))
		return -1;
	engine->session_id = session_id;
	engine->attachment = attachment;
	return 0;
}

void qmodem_voip_media_detach(struct qmodem_voip_media_engine *engine)
{
	if (!engine)
		return;
	if (engine->backend == QMODEM_VOIP_MEDIA_BACKEND_SERIAL)
		qmodem_voip_serial_set_attached(engine, 0);
	qmodem_voip_media_queue_clear(&engine->modem_to_canonical);
	qmodem_voip_media_queue_clear(&engine->canonical_to_modem);
	zero(&engine->rtp, sizeof(engine->rtp));
	engine->attachment = QMODEM_VOIP_MEDIA_ATTACH_NONE;
	engine->session_id = 0;
}

void qmodem_voip_media_release(struct qmodem_voip_media_engine *engine)
{
	struct qmodem_voip_modem_profile profile;

	if (!engine)
		return;
	profile = engine->profile;
#ifndef QMODEM_VOIP_HOST_TEST
	if (engine->backend == QMODEM_VOIP_MEDIA_BACKEND_UAC && engine->capture_pcm)
		snd_pcm_close(engine->capture_pcm);
	if (engine->backend == QMODEM_VOIP_MEDIA_BACKEND_UAC && engine->playback_pcm)
		snd_pcm_close(engine->playback_pcm);
#endif
	if (engine->backend == QMODEM_VOIP_MEDIA_BACKEND_SERIAL)
		qmodem_voip_serial_close(engine);
	if (engine->backend == QMODEM_VOIP_MEDIA_BACKEND_PCM_SOCKET)
		qmodem_voip_pcm_socket_close(engine);
	if (engine->modem_to_canonical.lock_ready)
		(void)pthread_mutex_destroy(&engine->modem_to_canonical.lock);
	if (engine->canonical_to_modem.lock_ready)
		(void)pthread_mutex_destroy(&engine->canonical_to_modem.lock);
	zero(engine, sizeof(*engine));
	engine->profile = profile;
}

int qmodem_voip_media_rtp_receive(struct qmodem_voip_media_engine *engine,
				   const uint8_t *packet, size_t length,
				   uint32_t source_address, uint16_t source_port,
				   void (*dtmf)(unsigned digit, void *opaque), void *opaque)
{
	unsigned payload_type;
	unsigned offset;
	if (!engine || !packet || length < 12 || (packet[0] >> 6) != 2)
		return -1;
	offset = 12U + (packet[0] & 15U) * 4U;
	if (packet[0] & 0x10U) {
		if (length < offset + 4U)
			return -1;
		offset += 4U + ((unsigned)packet[offset + 2] << 8 | packet[offset + 3]);
	}
	if (offset > length)
		return -1;
	payload_type = packet[1] & 127U;
	engine->rtp.address = source_address;
	engine->rtp.port = source_port;
	engine->rtp.sequence = (uint16_t)((packet[2] << 8) | packet[3]);
	engine->rtp.timestamp = ((uint32_t)packet[4] << 24) | ((uint32_t)packet[5] << 16) |
		((uint32_t)packet[6] << 8) | packet[7];
	if (payload_type == 101U && length >= offset + 4U && dtmf)
		dtmf(packet[offset] & 15U, opaque);
	return payload_type == QMODEM_VOIP_MEDIA_PCMA || payload_type == QMODEM_VOIP_MEDIA_PCMU ||
		payload_type == 101U ? 0 : -1;
}
