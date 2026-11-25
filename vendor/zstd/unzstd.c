/* Decompress one .zst file to standard output: TrackerUnzstd FILE */
#include <stdio.h>
#include <stdlib.h>
#include "zstd.h"

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: TrackerUnzstd FILE\n");
        return 2;
    }
    FILE *in = fopen(argv[1], "rb");
    if (!in) {
        perror(argv[1]);
        return 1;
    }
    size_t in_size = ZSTD_DStreamInSize(), out_size = ZSTD_DStreamOutSize();
    void *in_buffer = malloc(in_size), *out_buffer = malloc(out_size);
    ZSTD_DCtx *context = ZSTD_createDCtx();
    if (!in_buffer || !out_buffer || !context) {
        fprintf(stderr, "out of memory\n");
        return 1;
    }
    size_t last = 0, read;
    int status = 0;
    while ((read = fread(in_buffer, 1, in_size, in)) > 0) {
        ZSTD_inBuffer input = {in_buffer, read, 0};
        while (input.pos < input.size) {
            ZSTD_outBuffer output = {out_buffer, out_size, 0};
            last = ZSTD_decompressStream(context, &output, &input);
            if (ZSTD_isError(last)) {
                fprintf(stderr, "%s: not a valid zstd file\n", argv[1]);
                status = 1;
                goto done;
            }
            if (fwrite(out_buffer, 1, output.pos, stdout) != output.pos) {
                status = 1;
                goto done;
            }
        }
    }
    if (ferror(in) || last != 0) {
        /* last != 0 means the file ended inside a frame: it is still being written or truncated. */
        fprintf(stderr, "%s: incomplete zstd file\n", argv[1]);
        status = 1;
    }
done:
    ZSTD_freeDCtx(context);
    fclose(in);
    free(in_buffer);
    free(out_buffer);
    return status;
}
