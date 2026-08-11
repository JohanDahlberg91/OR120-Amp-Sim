/* Translation unit providing the stb_image_write implementation for the
   asset baker. Kept separate so the header stays header-only everywhere else. */
#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBIW_ASSERT(x) ((void)0)
#include "stb_image_write.h"
