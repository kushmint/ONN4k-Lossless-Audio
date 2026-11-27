/*
 * v15 libHwAudio_dtshd.so replacement - follows the STOCK SoftDCA v2.1.0 ABI (see NOTES.md).
 *
 *   int dca_decoder_process(in, in_size, int *consumed, out_buf, int *out_size0, int *fmt,
 *                           out_buf2, int *out_size1)
 *   out_buf  : PCM carrier (silence), out_size0 bytes, fmt[0]=sample rate, fmt[1]=channels
 *   out_buf2 : IEC61937 burst, out_size1 bytes (wrapper patched: raw ch=8, inner fmt DTS_HD)
 *
 * Every DTS stream (core-only, 96/24, DTS-HD MA, DTS:X) is sent as an IEC61937-5 DTS-HD (type IV)
 * burst on the 8ch HBR link, stream byte order (big-endian words), then 16-bit byte-swapped into
 * S16LE carrier words:
 *   F8 72 4E 1F | Pc=<subtype> 11 | Pd=len bytes
 *   01 00 00 00 00 00 00 00 FE FE | len(BE16) | DTS core+ext access unit | zero pad
 *
 * v14 hardcoded one timing: 512 samples @ 48 kHz -> 192 kHz link, subtype 4, 32768-byte burst.
 * Anything else (44.1 kHz family, 256/1024-sample frames) got bursts at the wrong rate and the
 * sink could not lock (44.1 kHz DTS was silent). v15 reads the core frame header and derives:
 *   link rate   : 192000 (48k family) or 176400 (44.1k family)          -> fmt[0]
 *   period      : samples * link*4 / fs  (IEC61937-5 repetition period, 512..8192)
 *   subtype     : log2(period / 512)                                     -> Pc high byte
 *   burst bytes : period * 4    carrier bytes : period
 * Pd is padded so (Pd & 0xf) == 8, as ffmpeg's spdif muxer does ("needed with some receivers").
 * Streams with no parsable core header (substream-only) keep the v14 timing.
 */
#include <stddef.h>
#include <stdint.h>
#define BURST_STD  32768   /* largest regular burst; the wrapper's buffer size beyond this is unknown */
#define OUT_CAP    65536   /* v14 grew oversized bursts up to this; kept for identical MA behaviour */
#define DEF_PERIOD 8192
#define DEF_LINK   192000
extern int __android_log_print(int, const char *, const char *, ...);
static int g_n, g_last_period, g_last_link;

int dca_decoder_init(int a, int b) { (void)a; (void)b; g_n = 0; g_last_period = g_last_link = 0; return 0; }
int dca_decoder_deinit(void) { return 0; }
int dca_spdif_write_packet(void *a, void *b) { (void)a; (void)b; return 0; }

/* DTS core SFREQ code -> HBR link rate and link/fs ratio (0 = no integer HBR mapping, e.g. 32 kHz).
 * Table instead of division: the lib is built -nostdlib, so there is no __aeabi_idiv. */
static const int sfreq_link[16] = {
    0, 0, 0, 0, 0, 0, 176400, 176400, 176400, 0, 0, 192000, 192000, 192000, 0, 0
};
static const int sfreq_ratio[16] = {      /* 11025 22050 44100 | 12000 24000 48000 */
    0, 0, 0, 0, 0, 0, 16, 8, 4, 0, 0, 16, 8, 4, 0, 0
};

/* Link rate and IEC61937-5 repetition period for this frame, from the 16-bit big-endian DTS core
 * header. Anything we cannot parse or carry keeps the v14 timing. */
static void frame_timing(const uint8_t *p, int n, int *link, int *period)
{
    *link = DEF_LINK;
    *period = DEF_PERIOD;
    if (n < 10 || p[0] != 0x7F || p[1] != 0xFE || p[2] != 0x80 || p[3] != 0x01)
        return;
    /* after the sync word: FTYPE(1) SHORT(5) CPF(1) NBLKS(7) FSIZE(14) AMODE(6) SFREQ(4) ... */
    uint64_t h = 0;
    for (int i = 4; i < 10; i++) h = (h << 8) | p[i];
    int nblks = (int)((h >> 34) & 0x7F);
    int sfreq = (int)((h >> 10) & 0x0F);
    if (nblks < 5 || !sfreq_link[sfreq])
        return;
    int per = (nblks + 1) * 32 * sfreq_ratio[sfreq] * 4;   /* samples * link*4/fs */
    if (per < 512 || per > BURST_STD / 4 || (per & (per - 1)))
        return;
    *link = sfreq_link[sfreq];
    *period = per;
}

int dca_decoder_process(const uint8_t *in, int in_size, int *consumed,
                        uint8_t *out_buf, int *out_size0, int *fmt,
                        uint8_t *out_buf2, int *out_size1)
{
    *out_size0 = 0;
    *out_size1 = 0;
    if (!in || in_size <= 0 || !out_buf2) { if (consumed) *consumed = in_size; return in_size; }

    int link, period;
    frame_timing(in, in_size, &link, &period);
    int burst = period * 4;
    int subtype = 0;
    while ((512 << subtype) < period) subtype++;

    int len = in_size;
    if (len > OUT_CAP - 48) len = OUT_CAP - 48;
    int pd = 12 + len;                              /* start code(10) + len16 + data */
    pd = ((pd + 8 + 15) & ~15) - 8;                 /* (Pd & 0xf) == 8 */
    /* oversized AU: round up to whole bursts like v14 (burst = 2^(11+subtype); shifts, no division) */
    int shift = 11 + subtype;
    int total = ((8 + pd + burst - 1) >> shift) << shift;
    if (total > OUT_CAP) total = OUT_CAP;

    /* build the burst in stream (big-endian) byte order */
    uint8_t *s = out_buf2;
    s[0] = 0xF8; s[1] = 0x72; s[2] = 0x4E; s[3] = 0x1F;
    s[4] = (uint8_t)subtype; s[5] = 0x11;           /* Pc: DTS-HD type IV + repetition-period subtype */
    s[6] = (uint8_t)(pd >> 8); s[7] = (uint8_t)pd;  /* Pd: payload bytes */
    s[8] = 0x01; s[9] = 0x00; s[10] = 0; s[11] = 0; s[12] = 0; s[13] = 0; s[14] = 0; s[15] = 0;
    s[16] = 0xFE; s[17] = 0xFE;
    s[18] = (uint8_t)(len >> 8); s[19] = (uint8_t)len;
    for (int i = 0; i < len; i++) s[20 + i] = in[i];
    for (int i = 20 + len; i < total; i++) s[i] = 0;

    /* swap every 16-bit word for S16LE */
    for (int i = 0; i < total; i += 2) { uint8_t t = s[i]; s[i] = s[i + 1]; s[i + 1] = t; }

    for (int i = 0; i < period; i++) out_buf[i] = 0;  /* PCM carrier silence, same duration as burst */
    *out_size0 = period;
    *out_size1 = total;
    fmt[0] = link;
    fmt[1] = 2;
    if (g_n++ < 3 || period != g_last_period || link != g_last_link)
        __android_log_print(4, "DtsHdPT", "v15 in=%d link=%d period=%d subtype=%d burst=%d pd=%d",
                            in_size, link, period, subtype, total, pd);
    g_last_period = period;
    g_last_link = link;
    *consumed = in_size;
    return in_size;
}
