#include "FlyAICompression.h"
#include <zlib.h>
#include <limits.h>
static size_t transform(const unsigned char *input, size_t length, unsigned char *output, size_t capacity, int compress) {
    if (!input || !output || !length || length > UINT_MAX || capacity > UINT_MAX) return 0;
    z_stream stream = {0};
    stream.next_in = (Bytef *)input; stream.avail_in = (uInt)length;
    stream.next_out = output; stream.avail_out = (uInt)capacity;
    int code = compress ? deflateInit2(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 16 + MAX_WBITS, 8, Z_DEFAULT_STRATEGY)
                        : inflateInit2(&stream, 16 + MAX_WBITS);
    if (code != Z_OK) return 0;
    code = compress ? deflate(&stream, Z_FINISH) : inflate(&stream, Z_FINISH);
    size_t count = code == Z_STREAM_END && stream.avail_in == 0 ? stream.total_out : 0;
    if (compress) deflateEnd(&stream); else inflateEnd(&stream);
    return count;
}
size_t arl_gzip(const unsigned char *input, size_t length, unsigned char *output, size_t capacity) { return transform(input, length, output, capacity, 1); }
size_t arl_gunzip(const unsigned char *input, size_t length, unsigned char *output, size_t capacity) { return transform(input, length, output, capacity, 0); }
