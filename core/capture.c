// core/capture.c
// Single file for the portable capture core (Slice A)

#include <CoreGraphics/CoreGraphics.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdio.h>
#include <dlfcn.h>

// Forward declarations for stb allocator hooks (must come before the macros)
static void *stb_arena_malloc(size_t size);
static void  stb_arena_free(void *ptr);
static void *stb_arena_realloc(void *ptr, size_t new_size);

// Define stb allocators BEFORE including the implementation
#define STBIW_MALLOC(sz)        stb_arena_malloc(sz)
#define STBIW_FREE(p)           stb_arena_free(p)
#define STBIW_REALLOC(p,newsz)  stb_arena_realloc(p, newsz)

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "../vendor/stb/stb_image_write.h"

#define ARENA_SIZE (256 * 1024 * 1024)   // 256 MiB — PNG encoding of large screens + stb's internal buffers (hash tables etc.) can be memory hungry

static uint8_t arena[ARENA_SIZE];
static size_t  arena_pos = 0;

// Per-capture mark so we can zero *everything* allocated during a capture on free/error (Approach A)
static size_t  arena_capture_mark = 0;

// Track the most recent allocation (user pointer) for fast-path in-place reallocs
static void  *last_alloc_ptr = NULL;
static size_t last_alloc_size = 0;

typedef struct {
    void *data;
    int   size;
} PngBuffer;

// --- Arena ---

// Every allocation gets a small header so realloc always knows the true old size (fixes unsafe copies)
#define ARENA_HEADER_SIZE sizeof(size_t)

static void arena_zero_range(size_t start, size_t end);  // forward decl

static void arena_begin_capture(void) {
    arena_capture_mark = arena_pos;
}

// Zero everything allocated since begin_capture and fully reset the bump pointer + tracking state.
static void arena_end_capture(void) {
    if (arena_capture_mark < arena_pos) {
        arena_zero_range(arena_capture_mark, arena_pos);
    }
    last_alloc_ptr = NULL;
    last_alloc_size = 0;
    arena_pos = 0;
    arena_capture_mark = 0;
}

static void *arena_alloc(size_t size) {
    size_t total = ARENA_HEADER_SIZE + size;
    if (arena_pos + total > ARENA_SIZE) {
        return NULL;
    }

    uint8_t *base = &arena[arena_pos];
    *(size_t *)base = size;                 // header stores user size
    void *user_ptr = base + ARENA_HEADER_SIZE;

    arena_pos += total;

    last_alloc_ptr = user_ptr;
    last_alloc_size = size;
    return user_ptr;
}

static size_t arena_get_alloc_size(const void *user_ptr) {
    if (!user_ptr) return 0;
    const uint8_t *base = (const uint8_t *)user_ptr - ARENA_HEADER_SIZE;
    return *(const size_t *)base;
}

static void arena_zero_range(size_t start, size_t end) {
    if (end > ARENA_SIZE) end = ARENA_SIZE;
    if (start < end) {
        memset(&arena[start], 0, end - start);
    }
}

// --- stb allocator hook implementations ---

static void *stb_arena_malloc(size_t size) {
    return arena_alloc(size);
}

static void stb_arena_free(void *ptr) {
    (void)ptr;
}

static void *stb_arena_realloc(void *ptr, size_t new_size) {
    if (ptr == NULL) {
        return arena_alloc(new_size);
    }

    size_t old_size = arena_get_alloc_size(ptr);

    // Fast path: grow the most recent allocation in place when possible
    if (ptr == last_alloc_ptr) {
        if (old_size >= new_size) {
            last_alloc_size = new_size;
            return ptr;
        }
        size_t extra = new_size - old_size;
        if (arena_pos + extra <= ARENA_SIZE) {
            arena_pos += extra;
            last_alloc_size = new_size;
            return ptr;   // in-place growth
        }
        // fall through to allocate + copy
    }

    // Allocate new block and copy the real old contents (now safe because of headers)
    void *new_ptr = arena_alloc(new_size);
    if (new_ptr && ptr && old_size > 0) {
        size_t to_copy = (old_size < new_size) ? old_size : new_size;
        memcpy(new_ptr, ptr, to_copy);
    }
    return new_ptr;
}

// --- Capture using runtime lookup to bypass SDK unavailability ---

static CGImageRef capture_main_display_image(void) {
    // Use dlsym to call the function even if the SDK marks it unavailable.
    static CGImageRef (*createImage)(CGRect, uint32_t, uint32_t, uint32_t) = NULL;

    if (!createImage) {
        createImage = (CGImageRef (*)(CGRect, uint32_t, uint32_t, uint32_t))
                      dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
    }

    if (createImage) {
        return createImage(
            CGRectInfinite,
            kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
            kCGNullWindowID,
            kCGWindowImageDefault
        );
    }

    return NULL;
}

// --- Public API ---

int capture_fullscreen(PngBuffer *out) {
    if (!out) return -1;

#ifndef NDEBUG
    fprintf(stderr, "[capture] capture_fullscreen called\n");
#endif

    arena_begin_capture();

    CGImageRef cgImage = capture_main_display_image();
    if (!cgImage) {
#ifndef NDEBUG
        fprintf(stderr, "[capture] capture_main_display_image returned NULL\n");
#endif
        arena_end_capture();
        return -1;
    }

#ifndef NDEBUG
    fprintf(stderr, "[capture] Got CGImage %ldx%ld\n", CGImageGetWidth(cgImage), CGImageGetHeight(cgImage));
#endif

    size_t width  = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);

    size_t bytes_per_pixel = 4;
    size_t buffer_size = width * height * bytes_per_pixel;

    uint8_t *pixel_buffer = arena_alloc(buffer_size);
    if (!pixel_buffer) {
        CGImageRelease(cgImage);
        arena_end_capture();
        return -1;
    }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
        pixel_buffer,
        width,
        height,
        8,
        width * bytes_per_pixel,
        colorSpace,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little
    );

    if (!context) {
        CGColorSpaceRelease(colorSpace);
        CGImageRelease(cgImage);
        arena_end_capture();
        return -1;
    }

    CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgImage);

    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);

    int png_size = 0;
    unsigned char *png_data = stbi_write_png_to_mem(
        pixel_buffer,
        (int)(width * bytes_per_pixel),
        (int)width,
        (int)height,
        4,
        &png_size
    );

    CGImageRelease(cgImage);

    if (!png_data || png_size <= 0) {
#ifndef NDEBUG
        fprintf(stderr, "[capture] stbi_write_png_to_mem failed\n");
#endif
        arena_end_capture();
        return -1;
    }

#ifndef NDEBUG
    fprintf(stderr, "[capture] PNG encoded successfully (%d bytes)\n", png_size);
#endif

    out->data = png_data;
    out->size = png_size;

    // Data stays live in the arena until the caller (platform layer) calls png_buffer_free.
    // png_buffer_free will do the full zero + reset (Approach A).
    return 0;
}

int capture_rect(int x, int y, int width, int height, PngBuffer *out) {
    if (!out || width <= 0 || height <= 0) return -1;

#ifndef NDEBUG
    fprintf(stderr, "[capture] capture_rect called (%d,%d %dx%d)\n", x, y, width, height);
#endif

    arena_begin_capture();

    // Use dlsym to get the function (bypasses SDK unavailability)
    static CGImageRef (*createImage)(CGRect, uint32_t, uint32_t, uint32_t) = NULL;
    if (!createImage) {
        createImage = (CGImageRef (*)(CGRect, uint32_t, uint32_t, uint32_t))
                      dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
    }

    if (!createImage) {
#ifndef NDEBUG
        fprintf(stderr, "[capture] CGWindowListCreateImage symbol not found\n");
#endif
        arena_end_capture();
        return -1;
    }

    CGRect captureRect = CGRectMake(x, y, width, height);
    CGImageRef cgImage = createImage(
        captureRect,
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID,
        kCGWindowImageDefault
    );

    if (!cgImage) {
#ifndef NDEBUG
        fprintf(stderr, "[capture] CGWindowListCreateImage returned NULL for rect\n");
#endif
        arena_end_capture();
        return -1;
    }

#ifndef NDEBUG
    size_t pxW = CGImageGetWidth(cgImage);
    size_t pxH = CGImageGetHeight(cgImage);
    fprintf(stderr, "[capture] Got CGImage for rect %ldx%ld (pixels: %zux%zu)\n",
            CGImageGetWidth(cgImage), CGImageGetHeight(cgImage), pxW, pxH);
#endif

    // Note on multi-monitor / mixed-scale: With a trustworthy global rect (after the
    // RectSelectionController fixes), the single spanning call to CGWindowListCreateImage
    // produces a CGImage whose pixel buffer already contains the correctly sampled native
    // pixels from each participating display. We do not need manual per-screen compositing
    // for correctness in the common case. If future problems appear on exotic layouts we
    // can switch to enumerating intersecting displays + CGDisplayCreateImageForRect.

    size_t imgWidth  = CGImageGetWidth(cgImage);
    size_t imgHeight = CGImageGetHeight(cgImage);
    size_t bytesPerPixel = 4;
    size_t bufferSize = imgWidth * imgHeight * bytesPerPixel;

    uint8_t *pixelBuffer = arena_alloc(bufferSize);
    if (!pixelBuffer) {
        CGImageRelease(cgImage);
        arena_end_capture();
        return -1;
    }

    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
        pixelBuffer,
        imgWidth,
        imgHeight,
        8,
        imgWidth * bytesPerPixel,
        colorSpace,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little
    );

    if (!context) {
        CGColorSpaceRelease(colorSpace);
        CGImageRelease(cgImage);
        arena_end_capture();
        return -1;
    }

    CGContextDrawImage(context, CGRectMake(0, 0, imgWidth, imgHeight), cgImage);

    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);

    int pngSize = 0;
    unsigned char *pngData = stbi_write_png_to_mem(
        pixelBuffer,
        (int)(imgWidth * bytesPerPixel),
        (int)imgWidth,
        (int)imgHeight,
        4,
        &pngSize
    );

    CGImageRelease(cgImage);

    if (!pngData || pngSize <= 0) {
#ifndef NDEBUG
        fprintf(stderr, "[capture] stbi_write_png_to_mem failed for rect\n");
#endif
        arena_end_capture();
        return -1;
    }

    out->data = pngData;
    out->size = pngSize;

#ifndef NDEBUG
    fprintf(stderr, "[capture] Rect PNG encoded successfully (%d bytes)\n", pngSize);
#endif
    // Caller must call png_buffer_free (which does arena_end_capture + zero).
    return 0;
}

void png_buffer_free(PngBuffer *png) {
    if (!png) return;

    // The entire region from the start of this capture (pixel buffer + any stb internals + final PNG)
    // is zeroed and the bump pointer reset. This is the core of Approach A.
    arena_end_capture();

    png->data = NULL;
    png->size = 0;
}
