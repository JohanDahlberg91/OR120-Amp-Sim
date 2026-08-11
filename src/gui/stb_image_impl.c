/* Translation unit providing the stb_image implementation for the plugin GUI.
   Only PNG is needed (the baked assets), so the other decoders are compiled out
   to keep the shared library small. */
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_NO_STDIO   /* assets are decoded from embedded memory, never files */
#define STBI_NO_FAILURE_STRINGS
#define STBI_ASSERT(x) ((void)0)
#include "stb_image.h"
