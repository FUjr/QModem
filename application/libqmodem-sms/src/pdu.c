/*
 * 2017 - 2021 Cezary Jackiewicz <cezary@eko.one.pl>
 * 2014 lovewilliam <ztong@vt.edu>
 */
// Copyright 2011 The Avalon Project Authors. All rights reserved.
// Use of this source code is governed by the Apache License 2.0
// that can be found in the LICENSE file.
//
//  SMS encoding/decoding functions, which are based on examples from:
//  http://www.dreamfabric.com/sms/

#include "qmodem-sms/pdu.h"

#include <string.h>
#include <stdio.h>
#include <time.h>

enum {
	BITMASK_7BITS = 0x7F,
	BITMASK_8BITS = 0xFF,
	BITMASK_HIGH_4BITS = 0xF0,
	BITMASK_LOW_4BITS = 0x0F,

	TYPE_OF_ADDRESS_UNKNOWN = 0x81,
	TYPE_OF_ADDRESS_INTERNATIONAL_PHONE = 0x91,
	TYPE_OF_ADDRESS_NATIONAL_SUBSCRIBER = 0xC8,
	TYPE_OF_ADDRESS_ALPHANUMERIC = 0xD0,

	SMS_DELIVER_ONE_MESSAGE = 0x04,
	SMS_SUBMIT              = 0x11,

	SMS_MAX_7BIT_TEXT_LENGTH  = 160,
};

int sms_normalize_number(const char *input, char *output, size_t capacity)
{
	size_t length = 0;
	if (!input || !output || capacity < 2)
		return -1;
	for (; *input; input++) {
		if (*input == ' ' || *input == '\t' || *input == '(' || *input == ')' || *input == '-')
			continue;
		if ((*input < '0' || *input > '9') && !(*input == '+' && length == 0))
			return -1;
		if (length + 1 >= capacity)
			return -1;
		output[length++] = *input;
	}
	output[length] = '\0';
	if (!length || (output[0] == '+' && (length < 2 || length > 16 || output[1] == '0')) ||
	    (output[0] != '+' && length > 20))
		return -1;
	return 0;
}

int sms_resolve_number(const char *input, const char *country_code, char *output, size_t capacity)
{
	char number[22], combined[26];
	if (sms_normalize_number(input, number, sizeof(number)) != 0)
		return -1;
	if (number[0] == '+' || !country_code || !*country_code)
		return sms_normalize_number(number, output, capacity);
	if (*country_code == '+') country_code++;
	size_t length = strlen(country_code);
	if (length < 1 || length > 3 || country_code[0] == '0') return -1;
	for (size_t i = 0; i < length; i++)
		if (country_code[i] < '0' || country_code[i] > '9') return -1;
	snprintf(combined, sizeof(combined), "+%s%s", country_code, number);
	return sms_normalize_number(combined, output, capacity);
}

// Swap decimal digits of a number (e.g. 12 -> 21).
static unsigned char 
SwapDecimalNibble(const unsigned char x)
{
	return (x / 16) + ((x % 16) * 10);
}

// Encode/Decode PDU: Translate ASCII 7bit characters to 8bit buffer.
// SMS encoding example from: http://www.dreamfabric.com/sms/.
//
// 7-bit ASCII: "hellohello"
// [0]:h   [1]:e   [2]:l   [3]:l   [4]:o   [5]:h   [6]:e   [7]:l   [8]:l   [9]:o
// 1101000 1100101 1101100 1101100 1101111 1101000 1100101 1101100 1101100 1101111
//               |             |||           ||||| |               |||||||  ||||||
// /-------------/   ///-------///     /////-///// \------------\  |||||||  \\\\\\ .
// |                 |||               |||||                    |  |||||||   ||||||
// input buffer position
// 10000000 22111111 33322222 44443333 55555333 66666655 77777776 98888888 --999999
// |                 |||               |||||                    |  |||||||   ||||||
// 8bit encoded buffer
// 11101000 00110010 10011011 11111101 01000110 10010111 11011001 11101100 00110111
// E8       32       9B       FD       46       97       D9       EC       37


// Encode PDU message by merging 7 bit ASCII characters into 8 bit octets.
int
EncodePDUMessage(const char* sms_text, int sms_text_length, unsigned char* output_buffer, int buffer_size)
{
	// Check if output buffer is big enough.
	if ((sms_text_length * 7 + 7) / 8 > buffer_size)
		return -1;

	int output_buffer_length = 0;
	int carry_on_bits = 1;
	int i = 0;

	for (; i < sms_text_length - 1; ++i) {
		output_buffer[output_buffer_length++] =
			((sms_text[i] & BITMASK_7BITS) >> (carry_on_bits - 1)) |
			((sms_text[i + 1] & BITMASK_7BITS) << (8 - carry_on_bits));
		carry_on_bits++;
		if (carry_on_bits == 8) {
			carry_on_bits = 1;
			++i;
		}
	}

	if (i <= sms_text_length)
		output_buffer[output_buffer_length++] =	(sms_text[i] & BITMASK_7BITS) >> (carry_on_bits - 1);

	return output_buffer_length;
}

// Decode PDU message by splitting 8 bit encoded buffer into 7 bit ASCII
// characters.
int
DecodePDUMessage_GSM_7bit(const unsigned char* buffer, int buffer_length, char* output_sms_text, int sms_text_length)
{
	int output_text_length = 0;
	if (buffer_length > 0)
		output_sms_text[output_text_length++] = BITMASK_7BITS & buffer[0];

	if (sms_text_length > 1) {
		int carry_on_bits = 1;
		int i = 1;
		for (; i < buffer_length; ++i) {

			output_sms_text[output_text_length++] = BITMASK_7BITS &	((buffer[i] << carry_on_bits) | (buffer[i - 1] >> (8 - carry_on_bits)));

			if (output_text_length == sms_text_length) break;

			carry_on_bits++;

			if (carry_on_bits == 8) {
				carry_on_bits = 1;
				output_sms_text[output_text_length++] = buffer[i] & BITMASK_7BITS;
				if (output_text_length == sms_text_length) break;
			}

		}
		if (output_text_length < sms_text_length)  // Add last remainder.
			output_sms_text[output_text_length++] =	buffer[i - 1] >> (8 - carry_on_bits);
	}

	return output_text_length;
}

#define  GSM_7BITS_ESCAPE   0x1b

static const unsigned char gsm7bits_to_latin1[128] = {
  '@', 0xa3,  '$', 0xa5, 0xe8, 0xe9, 0xf9, 0xec, 0xf2, 0xc7, '\n', 0xd8, 0xf8, '\r', 0xc5, 0xe5,
    0,  '_',    0,    0,    0,    0,    0,    0,    0,    0,    0,    0, 0xc6, 0xe6, 0xdf, 0xc9,
  ' ',  '!',  '"',  '#', 0xa4,  '%',  '&', '\'',  '(',  ')',  '*',  '+',  ',',  '-',  '.',  '/',
  '0',  '1',  '2',  '3',  '4',  '5',  '6',  '7',  '8',  '9',  ':',  ';',  '<',  '=',  '>',  '?',
 0xa1,  'A',  'B',  'C',  'D',  'E',  'F',  'G',  'H',  'I',  'J',  'K',  'L',  'M',  'N',  'O',
  'P',  'Q',  'R',  'S',  'T',  'U',  'V',  'W',  'X',  'Y',  'Z', 0xc4, 0xd6, 0xd1, 0xdc, 0xa7,
 0xbf,  'a',  'b',  'c',  'd',  'e',  'f',  'g',  'h',  'i',  'j',  'k',  'l',  'm',  'n',  'o',
  'p',  'q',  'r',  's',  't',  'u',  'v',  'w',  'x',  'y',  'z', 0xe4, 0xf6, 0xf1, 0xfc, 0xe0,
};

static const unsigned char gsm7bits_extend_to_latin1[128] = {
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,'\f',   0,   0,   0,   0,   0,
    0,   0,   0,   0, '^',   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    0,   0,   0,   0,   0,   0,   0,   0, '{', '}',   0,   0,   0,   0,   0,'\\',
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0, '[', '~', ']',   0,
  '|',   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
};

/* 3GPP TS 23.038 Turkish National Language Single Shift table.
 * Only used when the PDU's UDH explicitly selects it (IEI 0x24/0x25,
 * language identifier 0x01 = Turkish) -- see udh_has_turkish_shift().
 * Non-Turkish messages must never be decoded through this table. */
static const unsigned char turkish_extend_to_latin1[128] = {
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,'\f',   0,   0,   0,   0,   0,
    0,   0,   0,   0, '^',   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    0,   0,   0,   0,   0,   0,   0,   0, '{', '}',   0,   0,   0,   0,   0,'\\',
    0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0, '[', '~', ']',   0,
  '|',   0,   0, 0xC7,   0,   0,   0, 0xD0,   0, 0xDD,   0,   0,   0,   0,   0,   0,
    0,   0,   0, 0xDE,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
    0,   0,   0, 0xE7,   0,   0,   0, 0xF0,   0, 0xFD,   0,   0,   0,   0,   0,   0,
    0,   0,   0, 0xFE,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,
};

/* Walks the PDU's User Data Header looking for a National Language
 * Locking Shift (IEI 0x24) or Single Shift (IEI 0x25) IE whose data
 * byte selects Turkish (0x01, per 3GPP TS 23.038 table 6.2.1.2.5).
 * Returns 1 only if such an IE is present; every other message keeps
 * using the standard extension table. */
struct udh_info {
	int present;
	int bytes;
	int turkish_locking;
	int turkish_single;
	int concat_ref;
	int concat_total;
	int concat_part;
};

/* Parse every IE in the UDH.  Concatenation is not required to be the last
 * IE; language shift IEs and application IEs may follow it. */
static int
parse_udh(const unsigned char *buffer, int buffer_length, int user_data_start,
		  int has_udh,
		  struct udh_info *info)
{
	memset(info, 0, sizeof(*info));
	if (!has_udh)
		return 0;
	if (user_data_start < 0 || user_data_start >= buffer_length)
		return -1;
	const int udhl = buffer[user_data_start];
	const int first = user_data_start + 1;
	const int end = first + udhl;
	if (end > buffer_length)
		return -1;
	info->present = 1;
	info->bytes = udhl + 1;
	for (int pos = first; pos < end;) {
		if (pos + 2 > end)
			return -1;
		const unsigned char iei = buffer[pos];
		const unsigned char iedl = buffer[pos + 1];
		if (pos + 2 + iedl > end)
			return -1;
		if (iei == 0x24 && iedl >= 1 && buffer[pos + 2] == 0x01)
			info->turkish_locking = 1;
		if (iei == 0x25 && iedl >= 1 && buffer[pos + 2] == 0x01)
			info->turkish_single = 1;
		if (iei == 0x00 && iedl == 3) {
			info->concat_ref = buffer[pos + 2];
			info->concat_total = buffer[pos + 3];
			info->concat_part = buffer[pos + 4];
		} else if (iei == 0x08 && iedl == 4) {
			info->concat_ref = (buffer[pos + 2] << 8) | buffer[pos + 3];
			info->concat_total = buffer[pos + 4];
			info->concat_part = buffer[pos + 5];
		}
		pos += 2 + iedl;
	}
	if (info->concat_total <= 1) {
		info->concat_ref = info->concat_total = info->concat_part = 0;
	}
	return 0;
}

static unsigned char
gsm7_locking_to_latin1(unsigned char value)
{
	switch (value) {
	case 0x07: return 0xFD; /* dotless i */
	case 0x0B: return 0xD0; /* G */
	case 0x0C: return 0xF0; /* g */
	case 0x1C: return 0xDE; /* S */
	case 0x1D: return 0xFE; /* s */
	case 0x40: return 0xDD; /* I with dot */
	case 0x5B: return 0xC4;
	case 0x5C: return 0xD6;
	case 0x5D: return 0xD1;
	case 0x5E: return 0xDC;
	case 0x60: return 0xE7;
	case 0x7B: return 0xE4;
	case 0x7C: return 0xF6;
	case 0x7D: return 0xF1;
	case 0x7E: return 0xFC;
	case 0x7F: return 0xE0;
	default: return gsm7bits_to_latin1[value];
	}
}

static int
G7bitToAscii(char* buffer, int buffer_length, int use_turkish_locking,
		     int use_turkish_single)
{
	int i;
	const unsigned char *ext_table = use_turkish_single ? turkish_extend_to_latin1 : gsm7bits_extend_to_latin1;

	for (i = 0; i < buffer_length; i++) {
		if ((unsigned char)buffer[i] < 128) {
			if (buffer[i] == GSM_7BITS_ESCAPE) {
				if (i + 1 >= buffer_length) {
					buffer_length--;
					break;
				}
				buffer[i] = ext_table[(unsigned char)buffer[i + 1]];
				if (i + 2 < buffer_length)
					memmove(&buffer[i + 1], &buffer[i + 2], buffer_length - i - 2);
				buffer_length--;
			} else {
				buffer[i] = use_turkish_locking ? gsm7_locking_to_latin1((unsigned char)buffer[i]) :
					gsm7bits_to_latin1[(unsigned char)buffer[i]];
			}
		}
	}

	return buffer_length;
}

#define NPC '?'

static const int latin1_to_gsm7bits[256] = {
  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC, 0x0a,  NPC,-0x0a, 0x0d,  NPC,  NPC,
  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,
 0x20, 0x21, 0x22, 0x23, 0x02, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2a, 0x2b, 0x2c, 0x2d, 0x2e, 0x2f,
 0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x3b, 0x3c, 0x3d, 0x3e, 0x3f,
 0x00, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4a, 0x4b, 0x4c, 0x4d, 0x4e, 0x4f,
 0x50, 0x51, 0x52, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a,-0x3c,-0x2f,-0x3e,-0x14, 0x11,
  NPC, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6a, 0x6b, 0x6c, 0x6d, 0x6e, 0x6f,
 0x70, 0x71, 0x72, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a,-0x28,-0x40,-0x29,-0x3d,  NPC,
  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,
  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,
  NPC, 0x40,  NPC, 0x01, 0x24, 0x03,  NPC, 0x5f,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,
  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC, 0x60,
  NPC,  NPC,  NPC,  NPC, 0x5b, 0x0e, 0x1c, 0x09,  NPC, 0x1f,  NPC,  NPC,  NPC,  NPC,  NPC,  NPC,
  NPC, 0x5d,  NPC,  NPC,  NPC,  NPC, 0x5c,  NPC, 0x0b,  NPC,  NPC,  NPC, 0x5e,  NPC,  NPC, 0x1e,
 0x7f,  NPC,  NPC,  NPC, 0x7b, 0x0f, 0x1d,  NPC, 0x04, 0x05,  NPC,  NPC, 0x07,  NPC,  NPC,  NPC,
  NPC, 0x7d, 0x08,  NPC,  NPC,  NPC, 0x7c,  NPC, 0x0c, 0x06,  NPC,  NPC, 0x7e,  NPC,  NPC,  NPC,
};

static int
AsciiToG7bit(const char* buffer, int buffer_length, unsigned char* output_buffer)
{
	int i, j, val;

	j=0;
	for (i = 0; i < buffer_length; i++) {
		val = latin1_to_gsm7bits[buffer[i] & 0xFF];
		if (val < 0) {
			output_buffer[j++] = GSM_7BITS_ESCAPE;
			output_buffer[j++] = -1*val;
		} else {
			if (((buffer[i] & 0xFF) & 0xE0) == 0xC0) { /* test for two byte utf8 char */
				val = NPC;
				i++;
			} else if (((buffer[i] & 0xFF) & 0xF0) == 0xE0) { /* test for three byte utf8 char */
				val = NPC;
				i++;
				i++;
			}
			output_buffer[j++] = val;
		}
	}
	return j;
}

// Encode a digit based phone number for SMS based format.
static int
EncodePhoneNumber(const char* phone_number, unsigned char* output_buffer, int buffer_size)
{
	int output_buffer_length = 0;  
	const int phone_number_length = strlen(phone_number);

	// Check if the output buffer is big enough.
	if ((phone_number_length + 1) / 2 > buffer_size)
		return -1;

	int i = 0;
	for (; i < phone_number_length; ++i) {

		if (phone_number[i] < '0' || phone_number[i] > '9')
			return -1;

		if (i % 2 == 0) {
			output_buffer[output_buffer_length++] =	BITMASK_HIGH_4BITS | (phone_number[i] - '0');
		} else {
			output_buffer[output_buffer_length - 1] =
				(output_buffer[output_buffer_length - 1] & BITMASK_LOW_4BITS) |
				((phone_number[i] - '0') << 4); 
		}
	}

	return output_buffer_length;
}

// Decode a digit based phone number for SMS based format.
static int
DecodePhoneNumber(const unsigned char* buffer, int phone_number_length, char* output_phone_number)
{
	int i = 0;
	for (; i < phone_number_length; ++i) {
		if (i % 2 == 0)
			output_phone_number[i] = (buffer[i / 2] & BITMASK_LOW_4BITS) + '0';
	        else
			output_phone_number[i] = ((buffer[i / 2] & BITMASK_HIGH_4BITS) >> 4) + '0';
	}
	output_phone_number[phone_number_length] = '\0';  // Terminate C string.
	return phone_number_length;
}

// Encode a SMS message to PDU
int
pdu_encode(const char* service_center_number, const char* phone_number, const char* sms_text,
	   unsigned char* output_buffer, int buffer_size)
{	
	char normalized[22];
	if (sms_normalize_number(phone_number, normalized, sizeof(normalized)) != 0)
		return -1;
	const int international = normalized[0] == '+';
	phone_number = normalized + international;
	if (buffer_size < 2)
		return -1;

	int output_buffer_length = 0;

	// 1. Set SMS center number.
	int length = 0;
	if (service_center_number && strlen(service_center_number) > 0) {
		output_buffer[1] = TYPE_OF_ADDRESS_INTERNATIONAL_PHONE;
		length = EncodePhoneNumber(service_center_number,
					   output_buffer + 2, buffer_size - 2);
		if (length < 0 && length >= 254)
			return -1;
		length++;  // Add type of address.
	}
	output_buffer[0] = length;
	output_buffer_length = length + 1;
	if (output_buffer_length + 4 > buffer_size)
		return -1;  // Check if it has space for four more bytes.

	// 2. Set type of message.
	output_buffer[output_buffer_length++] = SMS_SUBMIT;
	output_buffer[output_buffer_length++] = 0x00;  // Message reference.

	// 3. Set phone number.
	output_buffer[output_buffer_length] = strlen(phone_number);

	output_buffer[output_buffer_length + 1] = international ?
		TYPE_OF_ADDRESS_INTERNATIONAL_PHONE : TYPE_OF_ADDRESS_UNKNOWN;

	length = EncodePhoneNumber(phone_number,
				   output_buffer + output_buffer_length + 2,
				   buffer_size - output_buffer_length - 2);
	output_buffer_length += length + 2;
	if (output_buffer_length + 4 > buffer_size)
		return -1;  // Check if it has space for four more bytes.


	// 4. Protocol identifiers.
	output_buffer[output_buffer_length++] = 0x00;  // TP-PID: Protocol identifier.
	output_buffer[output_buffer_length++] = 0x00;  // TP-DCS: Data coding scheme.
	output_buffer[output_buffer_length++] = 0xB0;  // TP-VP: Validity: 10 days

	// 5. SMS message.
	int sms_text_length = strlen(sms_text);
	unsigned char sms_text_7bit[2*SMS_MAX_7BIT_TEXT_LENGTH];
	sms_text_length = AsciiToG7bit(sms_text, sms_text_length, sms_text_7bit);
	if (sms_text_length > SMS_MAX_7BIT_TEXT_LENGTH)
		return -1;
	output_buffer[output_buffer_length++] = sms_text_length;
	length = EncodePDUMessage((const char *)sms_text_7bit, sms_text_length,
				  output_buffer + output_buffer_length, 
				  buffer_size - output_buffer_length);
	if (length < 0)
		return -1;
	output_buffer_length += length;

	return output_buffer_length;
}

static int utf8_to_utf16(const char *text, unsigned short *units, int capacity)
{
	const unsigned char *p = (const unsigned char *)text;
	int count = 0;
	while (*p) {
		unsigned int cp;
		int bytes;
		if (*p < 0x80) { cp = *p; bytes = 1; }
		else if ((*p & 0xe0) == 0xc0 && p[1] && (p[1] & 0xc0) == 0x80) {
			cp = ((unsigned int)(p[0] & 0x1f) << 6) | (p[1] & 0x3f); bytes = 2;
			if (cp < 0x80) return -1;
		} else if ((*p & 0xf0) == 0xe0 && p[1] && p[2] && (p[1] & 0xc0) == 0x80 &&
			   (p[2] & 0xc0) == 0x80) {
			cp = ((unsigned int)(p[0] & 0x0f) << 12) |
			     ((unsigned int)(p[1] & 0x3f) << 6) | (p[2] & 0x3f); bytes = 3;
			if (cp < 0x800 || (cp >= 0xd800 && cp <= 0xdfff)) return -1;
		} else if ((*p & 0xf8) == 0xf0 && p[1] && p[2] && p[3] && (p[1] & 0xc0) == 0x80 &&
			   (p[2] & 0xc0) == 0x80 && (p[3] & 0xc0) == 0x80) {
			cp = ((unsigned int)(p[0] & 0x07) << 18) |
			     ((unsigned int)(p[1] & 0x3f) << 12) |
			     ((unsigned int)(p[2] & 0x3f) << 6) | (p[3] & 0x3f); bytes = 4;
			if (cp < 0x10000 || cp > 0x10ffff) return -1;
		} else return -1;
		if (cp <= 0xffff) {
			if (count >= capacity) return -1;
			units[count++] = (unsigned short)cp;
		} else {
			if (count + 1 >= capacity) return -1;
			cp -= 0x10000;
			units[count++] = (unsigned short)(0xd800 | (cp >> 10));
			units[count++] = (unsigned short)(0xdc00 | (cp & 0x3ff));
		}
		p += bytes;
	}
	return count;
}

int pdu_encode_ucs2_parts(const char *phone_number, const char *utf8_text,
			  unsigned char pdus[][SMS_MAX_PDU_LENGTH], int lengths[],
			  int max_parts, unsigned int reference)
{
	char normalized[22];
	unsigned short units[SMS_MAX_PARTS * 67];
	int unit_count, total, offset = 0;
	if (!phone_number || !*phone_number || !utf8_text || !pdus || !lengths ||
	    max_parts < 1 || max_parts > SMS_MAX_PARTS)
		return -1;
	if (sms_normalize_number(phone_number, normalized, sizeof(normalized)) != 0)
		return -1;
	const int international = normalized[0] == '+';
	phone_number = normalized + international;
	unit_count = utf8_to_utf16(utf8_text, units, (int)(sizeof(units) / sizeof(units[0])));
	if (unit_count < 0)
		return -1;
	if (unit_count <= 70) {
		total = 1;
	} else {
		int position = 0;
		total = 0;
		while (position < unit_count) {
			int take = unit_count - position < 67 ? unit_count - position : 67;
			if (position + take < unit_count && units[position + take - 1] >= 0xd800 &&
			    units[position + take - 1] <= 0xdbff)
				take--;
			position += take;
			total++;
		}
	}
	if (total > max_parts)
		return -1;
	for (int part = 0; part < total; part++) {
		unsigned char *out = pdus[part];
		int length, limit = total == 1 ? 70 : 67;
		int take = unit_count - offset < limit ? unit_count - offset : limit;
		if (offset + take < unit_count && take > 0 &&
		    units[offset + take - 1] >= 0xd800 && units[offset + take - 1] <= 0xdbff)
			take--;
		out[0] = 0;
		out[1] = SMS_SUBMIT | (total > 1 ? 0x40 : 0);
		out[2] = 0;
		out[3] = (unsigned char)strlen(phone_number);
		out[4] = international ? TYPE_OF_ADDRESS_INTERNATIONAL_PHONE : TYPE_OF_ADDRESS_UNKNOWN;
		length = EncodePhoneNumber(phone_number, out + 5, SMS_MAX_PDU_LENGTH - 5);
		if (length < 0)
			return -1;
		length += 5;
		out[length++] = 0;
		out[length++] = 0x08;
		out[length++] = 0xb0;
		out[length++] = (unsigned char)(take * 2 + (total > 1 ? 6 : 0));
		if (total > 1) {
			out[length++] = 5; out[length++] = 0; out[length++] = 3;
			out[length++] = (unsigned char)reference;
			out[length++] = (unsigned char)total;
			out[length++] = (unsigned char)(part + 1);
		}
		for (int i = 0; i < take; i++) {
			out[length++] = (unsigned char)(units[offset + i] >> 8);
			out[length++] = (unsigned char)units[offset + i];
		}
		lengths[part] = length;
		offset += take;
	}
	return total;
}

int pdu_decode(const unsigned char* buffer, int buffer_length,
	       time_t* output_sms_time,
	       char* output_sender_phone_number, int sender_phone_number_size,
	       char* output_sms_text, int sms_text_size,
	       int* tp_dcs,
	       int* ref_number,
	       int* total_parts,
	       int* part_number,
	       int* skip_bytes)
{
	
	if (buffer_length <= 0)
		return -1;

	const int sms_deliver_start = 1 + buffer[0];
	if (sms_deliver_start + 1 > buffer_length)
		return -2;

	const int sender_number_length = buffer[sms_deliver_start + 1];
	if (sender_number_length + 1 > sender_phone_number_size)
		return -3;  // Buffer too small to hold decoded phone number.

	const int sender_type_of_address = buffer[sms_deliver_start + 2];
	if (sender_type_of_address == TYPE_OF_ADDRESS_ALPHANUMERIC) {
		int sender_len1 = DecodePDUMessage_GSM_7bit(buffer + sms_deliver_start + 3, (sender_number_length + 1) / 2, output_sender_phone_number, sender_number_length);
		int sender_len2 = G7bitToAscii(output_sender_phone_number, sender_len1 - 1, 0, 0);
		output_sender_phone_number[sender_len2] = 0;
	} else {
		DecodePhoneNumber(buffer + sms_deliver_start + 3, sender_number_length, output_sender_phone_number);
	}

	const int sms_pid_start = sms_deliver_start + 3 + (buffer[sms_deliver_start + 1] + 1) / 2;

	// Decode timestamp.
	struct tm sms_broken_time;
	sms_broken_time.tm_year = 100 + SwapDecimalNibble(buffer[sms_pid_start + 2]);
	sms_broken_time.tm_mon  = SwapDecimalNibble(buffer[sms_pid_start + 3]) - 1;
	sms_broken_time.tm_mday = SwapDecimalNibble(buffer[sms_pid_start + 4]);
	sms_broken_time.tm_hour = SwapDecimalNibble(buffer[sms_pid_start + 5]);
	sms_broken_time.tm_min  = SwapDecimalNibble(buffer[sms_pid_start + 6]);
	sms_broken_time.tm_sec  = SwapDecimalNibble(buffer[sms_pid_start + 7]);
	(*output_sms_time) = timegm(&sms_broken_time);

	const int sms_start = sms_pid_start + 2 + 7;
	if (sms_start + 1 >= buffer_length) return -1;  // Invalid input buffer.

	struct udh_info udh;
	if (parse_udh(buffer, buffer_length, sms_start + 1,
		      buffer[sms_deliver_start] & 0x40, &udh) < 0)
		return -1;
	*skip_bytes = udh.present ? udh.bytes : 0;
	*ref_number = udh.concat_ref;
	*total_parts = udh.concat_total;
	*part_number = udh.concat_part;

	int output_sms_text_length = buffer[sms_start];
	if (sms_text_size < output_sms_text_length) return -1;  // Cannot hold decoded buffer.

	const int sms_tp_dcs_start = sms_pid_start + 1;
	*tp_dcs = buffer[sms_tp_dcs_start];

	switch((*tp_dcs / 4) % 4)
	{
		case 0:
			{
				// GSM 7 bit
				int decoded_sms_text_size = DecodePDUMessage_GSM_7bit(buffer + sms_start + 1, buffer_length - (sms_start + 1),
							   output_sms_text, output_sms_text_length);
				if (decoded_sms_text_size != output_sms_text_length) return -1;  // Decoder length is not as expected.
				int skip_septets = 0;
				if (*skip_bytes > 0)
					skip_septets = (*skip_bytes * 8 + 6) / 7;
				if (skip_septets > output_sms_text_length)
					return -1;
				output_sms_text_length = skip_septets + G7bitToAscii(output_sms_text + skip_septets,
					output_sms_text_length - skip_septets, udh.turkish_locking,
					udh.turkish_single);
				break;
			}
		case 2:
			{
				// UCS2
				memcpy(output_sms_text, buffer + sms_start + 1, output_sms_text_length);
				break;
			}
		default:
		break;
	}

	// Add a C string end.
	if (output_sms_text_length < sms_text_size)
		output_sms_text[output_sms_text_length] = 0;
	else
		output_sms_text[sms_text_size-1] = 0;

	return output_sms_text_length;
}
