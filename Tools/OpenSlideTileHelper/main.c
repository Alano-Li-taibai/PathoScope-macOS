#include <errno.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <openslide/openslide.h>

static const uint32_t RESPONSE_MAGIC = 0x5053544c;

static void write_u32(uint32_t value) {
  unsigned char bytes[4] = {
      value & 0xff,
      (value >> 8) & 0xff,
      (value >> 16) & 0xff,
      (value >> 24) & 0xff,
  };
  fwrite(bytes, 1, sizeof(bytes), stdout);
}

static void write_response(uint32_t status,
                           uint32_t width,
                           uint32_t height,
                           const void *payload,
                           uint32_t payload_size) {
  write_u32(RESPONSE_MAGIC);
  write_u32(status);
  write_u32(width);
  write_u32(height);
  write_u32(payload_size);
  if (payload_size > 0 && payload != NULL) {
    fwrite(payload, 1, payload_size, stdout);
  }
  fflush(stdout);
}

static void write_error(const char *message) {
  const char *safe = message != NULL ? message : "unknown OpenSlide error";
  size_t length = strlen(safe);
  if (length > UINT32_MAX) {
    length = UINT32_MAX;
  }
  write_response(1, 0, 0, safe, (uint32_t) length);
}

static openslide_t *open_slide(const char *path) {
  openslide_t *slide = openslide_open(path);
  if (slide == NULL) {
    fprintf(stderr, "openslide_open failed\n");
    return NULL;
  }
  const char *open_error = openslide_get_error(slide);
  if (open_error != NULL) {
    fprintf(stderr, "%s\n", open_error);
    openslide_close(slide);
    return NULL;
  }
  return slide;
}

static int print_properties(const char *path) {
  openslide_t *slide = open_slide(path);
  if (slide == NULL) {
    return 65;
  }
  int32_t level_count = openslide_get_level_count(slide);
  printf("openslide.level-count: '%d'\n", level_count);
  for (int32_t level = 0; level < level_count; level++) {
    int64_t width = 0;
    int64_t height = 0;
    openslide_get_level_dimensions(slide, level, &width, &height);
    printf("openslide.level[%d].width: '%" PRId64 "'\n", level, width);
    printf("openslide.level[%d].height: '%" PRId64 "'\n", level, height);
    printf(
        "openslide.level[%d].downsample: '%.17g'\n",
        level,
        openslide_get_level_downsample(slide, level)
    );
  }

  const char *properties[] = {
      OPENSLIDE_PROPERTY_NAME_BOUNDS_X,
      OPENSLIDE_PROPERTY_NAME_BOUNDS_Y,
      OPENSLIDE_PROPERTY_NAME_BOUNDS_WIDTH,
      OPENSLIDE_PROPERTY_NAME_BOUNDS_HEIGHT,
      OPENSLIDE_PROPERTY_NAME_MPP_X,
      OPENSLIDE_PROPERTY_NAME_MPP_Y,
  };
  for (size_t index = 0; index < sizeof(properties) / sizeof(properties[0]); index++) {
    const char *value = openslide_get_property_value(slide, properties[index]);
    if (value != NULL) {
      printf("%s: '%s'\n", properties[index], value);
    }
  }
  openslide_close(slide);
  return 0;
}

int main(int argc, char **argv) {
  if (argc == 3 && strcmp(argv[1], "--properties") == 0) {
    return print_properties(argv[2]);
  }
  if (argc != 2) {
    fprintf(stderr, "usage: openslide-tile-helper [--properties] <slide>\n");
    return 64;
  }
  setvbuf(stdin, NULL, _IONBF, 0);
  setvbuf(stdout, NULL, _IONBF, 0);

  openslide_t *slide = open_slide(argv[1]);
  if (slide == NULL) {
    return 65;
  }

  openslide_cache_t *cache = openslide_cache_create(128ULL * 1024ULL * 1024ULL);
  if (cache != NULL) {
    openslide_set_cache(slide, cache);
  }

  char line[256];
  while (fgets(line, sizeof(line), stdin) != NULL) {
    int level = 0;
    int width = 0;
    int height = 0;
    int64_t x = 0;
    int64_t y = 0;
    if (sscanf(line, "%d %" SCNd64 " %" SCNd64 " %d %d",
               &level, &x, &y, &width, &height) != 5) {
      write_error("invalid request");
      continue;
    }
    if (level < 0 || width <= 0 || height <= 0 ||
        width > 4096 || height > 4096) {
      write_error("request out of range");
      continue;
    }

    size_t pixel_count = (size_t) width * (size_t) height;
    if (pixel_count > SIZE_MAX / sizeof(uint32_t)) {
      write_error("request too large");
      continue;
    }
    uint32_t *pixels = calloc(pixel_count, sizeof(uint32_t));
    if (pixels == NULL) {
      write_error(strerror(errno));
      continue;
    }
    openslide_read_region(slide, pixels, x, y, level, width, height);
    const char *error = openslide_get_error(slide);
    if (error != NULL) {
      free(pixels);
      write_error(error);
      continue;
    }
    write_response(
        0,
        (uint32_t) width,
        (uint32_t) height,
        pixels,
        (uint32_t) (pixel_count * sizeof(uint32_t))
    );
    free(pixels);
  }

  openslide_close(slide);
  if (cache != NULL) {
    openslide_cache_release(cache);
  }
  return 0;
}
