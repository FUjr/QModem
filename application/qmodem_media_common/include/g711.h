#ifndef QMODEM_G711_H
#define QMODEM_G711_H

#include <stdint.h>

static inline uint8_t qmodem_g711_ulaw_encode(int16_t value)
{
	int sample = value;
	int sign = sample < 0;
	int exponent = 7;
	int mantissa;

	if (sign)
		sample = -sample;
	if (sample > 32635)
		sample = 32635;
	sample += 132;
	while (exponent > 0 && !(sample & (1 << (exponent + 7))))
		exponent--;
	mantissa = (sample >> (exponent + 3)) & 15;
	return (uint8_t)~((sign << 7) | (exponent << 4) | mantissa);
}

static inline int16_t qmodem_g711_ulaw_decode(uint8_t value)
{
	int sample = ((~value & 15) << 3) + 132;
	int exponent = (~value >> 4) & 7;

	sample <<= exponent;
	return (int16_t)((~value & 128) ? 132 - sample : sample - 132);
}

static inline uint8_t qmodem_g711_alaw_encode(int16_t value)
{
	int sample = value;
	int sign = sample >= 0;
	int exponent = 7;
	int mantissa;

	if (!sign)
		sample = -sample - 1;
	if (sample > 32767)
		sample = 32767;
	while (exponent > 0 && !(sample & (1 << (exponent + 7))))
		exponent--;
	mantissa = exponent ? (sample >> (exponent + 3)) & 15 : (sample >> 4) & 15;
	return (uint8_t)(((sign << 7) | (exponent << 4) | mantissa) ^ 0x55);
}

static inline int16_t qmodem_g711_alaw_decode(uint8_t value)
{
	int data = value ^ 0x55;
	int sample = (data & 15) << 4;
	int exponent = (data >> 4) & 7;

	if (!exponent)
		sample += 8;
	else if (exponent == 1)
		sample += 0x108;
	else
		sample = (sample + 0x108) << (exponent - 1);
	return (int16_t)((data & 128) ? sample : -sample);
}

#endif
