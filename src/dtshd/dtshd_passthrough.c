/*
* v14 libHwAudio_dtshd.so replacement - follows the STOCK SoftDCA v2.1.0 ABI (see NOTES.md).
 *
 *   int dca_decoder_process(in, in_size, int *consumed, out_buf, int *out_size0, int *fmt,
 *                           out_buf2, int *out_size1)
 *   out_buf  : PCM carrier (silence), out_size0 bytes, fmt[0]=sample rate, fmt[1]=channels
 *   out_buf2 : IEC61937 burst, out_size1 bytes (wrapper patched: raw ch=8, inner fmt DTS_HD)
 *
 * IEC61937-5 DTS-HD (type IV) burst, stream byte order (big-endian words), then 16-bit byte-swapped
 * into S16LE carrier words:
 *   F8 72 4E 1F | Pc=00 11 | Pd=len bytes
 *   01 00 00 00 00 00 00 00 FE FE | len(BE16) | DTS core+ext access unit | zero pad
 * HBR carrier: 8ch x 192kHz x 16bit => 512-sample (48k) frame = 32768 bytes per burst.
 */
#include <stddef.h>
#include <stdint.h>
#define BURST      32768
#define OUT_CAP    65536
#define CARRIER    8192
extern int __android_log_print(int, const char *, const char *, ...);
static int g_n;

int dca_decoder_init(int a, int b) { (void)a; (void)b; return 0; }
int dca_decoder_deinit(void) { return 0; }
int dca_spdif_write_packet(void *a, void *b) { (void)a; (void)b; return 0; }

int dca_decoder_process(const uint8_t *in, int in_size, int *consumed,
                        uint8_t *out_buf, int *out_size0, int *fmt,
                        uint8_t *out_buf2, int *out_size1)
{
    *out_size0 = 0;
    *out_size1 = 0;
    if (!in || in_size <= 0 || !out_buf2) { if (consumed) *consumed = in_size; return in_size; }

    int len = in_size;
    if (len > OUT_CAP - 32) len = OUT_CAP - 32;
    int payload = 12 + len;                 /* start code(10) + len16 + data */
    int pd = payload;
    int padded = (payload + 1) & ~1;
    int total = BURST;
    while (8 + padded > total) total += BURST;

    /* build the burst in stream (big-endian) byte order */
    uint8_t *s = out_buf2;
    s[0] = 0xF8; s[1] = 0x72; s[2] = 0x4E; s[3] = 0x1F;
    s[4] = 0x04; s[5] = 0x11;                       /* Pc: DTS-HD type IV, subtype 4 = 8192-sample period @768k */
    s[6] = (uint8_t)(pd >> 8); s[7] = (uint8_t)pd;   /* Pd: payload bytes */
    s[8] = 0x01; s[9] = 0x00; s[10] = 0; s[11] = 0; s[12] = 0; s[13] = 0; s[14] = 0; s[15] = 0;
    s[16] = 0xFE; s[17] = 0xFE;
    s[18] = (uint8_t)(len >> 8); s[19] = (uint8_t)len;
    for (int i = 0; i < len; i++) s[20 + i] = in[i];
    for (int i = 8 + payload; i < total; i++) s[i] = 0;

    /* sync/preamble words stay as stream order; swap every 16-bit word of the payload for S16LE */
    for (int i = 0; i < total; i += 2) { uint8_t t = s[i]; s[i] = s[i + 1]; s[i + 1] = t; }

    for (int i = 0; i < CARRIER; i++) out_buf[i] = 0;   /* PCM carrier silence (10.67ms @192k stereo) */
    *out_size0 = CARRIER;
    *out_size1 = total;
    fmt[0] = 192000;
    fmt[1] = 2;
    if (g_n++ < 5) __android_log_print(4, "DtsHdPT", "v14 in=%d burst=%d", in_size, total);
    *consumed = in_size;
    return in_size;
}
