#ifndef WECHAT_SILK_H
#define WECHAT_SILK_H
#include <stdint.h>
int wechat_silk_encode(const int16_t *pcm, int samples, int sample_rate,
                       unsigned char *dst, int dst_cap);
#endif
