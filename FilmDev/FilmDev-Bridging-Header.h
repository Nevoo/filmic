#ifndef FilmDev_Bridging_Header_h
#define FilmDev_Bridging_Header_h

#include <libraw/libraw.h>

// libraw's `data` field is declared `unsigned char data[1]` — a C
// flexible-array idiom. Swift imports it as a tuple and computes struct size
// with different padding than the C ABI, so calculating the byte offset in
// Swift gets the answer wrong. Doing pointer arithmetic in C is reliable.
static inline const unsigned char *filmdev_libraw_image_data(libraw_processed_image_t *img) {
    return img->data;
}

#endif
