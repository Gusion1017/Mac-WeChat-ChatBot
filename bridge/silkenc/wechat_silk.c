// WeChat/QQ 兼容 SILK v3 编码包装（官方 SILK SDK，MIT；见同目录 LICENSE/NOTICE）。
#include "SKP_Silk_SDK_API.h"
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define WECHAT_SILK_MAX_FRAME_BYTES 1000

int wechat_silk_encode(const int16_t *pcm, int samples, int sample_rate,
                       unsigned char *dst, int dst_cap) {
    if (!pcm || samples <= 0 || !dst || dst_cap < 16 || sample_rate <= 0) return -1;
    if (samples % (sample_rate / 50) != 0) return -2; // 20ms frames only
    if (dst_cap < 10) return -1;
    static const unsigned char header[10] = {0x02, '#', '!', 'S', 'I', 'L', 'K', '_', 'V', '3'};
    memcpy(dst, header, sizeof(header));
    int pos = (int)sizeof(header);

    SKP_int32 enc_size = 0;
    if (SKP_Silk_SDK_Get_Encoder_Size(&enc_size) != 0 || enc_size <= 0) return -3;
    void *enc = malloc((size_t)enc_size);
    if (!enc) return -4;
    SKP_SILK_SDK_EncControlStruct ctrl;
    memset(&ctrl, 0, sizeof(ctrl));
    ctrl.API_sampleRate = sample_rate;
    ctrl.maxInternalSampleRate = sample_rate;
    ctrl.packetSize = sample_rate / 50;
    ctrl.packetLossPercentage = 0;
    ctrl.useInBandFEC = 0;
    ctrl.useDTX = 0;
    ctrl.complexity = 2;
    ctrl.bitRate = 24000;
    SKP_SILK_SDK_EncControlStruct encStatus;
    memset(&encStatus, 0, sizeof(encStatus));
    if (SKP_Silk_SDK_InitEncoder(enc, &encStatus) != 0) { free(enc); return -5; }

    const int packet = ctrl.packetSize;
    for (int off = 0; off < samples; off += packet) {
        SKP_int16 nbytes = WECHAT_SILK_MAX_FRAME_BYTES;
        unsigned char payload[WECHAT_SILK_MAX_FRAME_BYTES];
        int ret = SKP_Silk_SDK_Encode(enc, &ctrl, pcm + off, packet, payload, &nbytes);
        if (ret != 0 || nbytes < 0) { free(enc); return -6; }
        if (pos + 2 + nbytes > dst_cap) { free(enc); return -7; }
        dst[pos++] = (unsigned char)(nbytes & 0xff);
        dst[pos++] = (unsigned char)((nbytes >> 8) & 0xff);
        memcpy(dst + pos, payload, (size_t)nbytes);
        pos += nbytes;
    }
    free(enc);
    return pos;
}
