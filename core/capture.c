// core/capture.c
// Single file for the portable capture core (Slice A)

#include <CoreGraphics/CoreGraphics.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <dlfcn.h>

// Use stb_image_write with its default (real) malloc. The previous custom
// bump allocator + realloc hacks were producing corrupt deflate streams
// inside the generated PNGs (InvalidUncompressedBlockLength).
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "../vendor/stb/stb_image_write.h"

typedef struct {
    void *data;
    int   size;
} PngBuffer;

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

    CGImageRef cgImage = capture_main_display_image();
    if (!cgImage) {
#ifndef NDEBUG
        fprintf(stderr, "[capture] capture_main_display_image returned NULL\n");
#endif
        return -1;
    }

#ifndef NDEBUG
    fprintf(stderr, "[capture] Got CGImage %ldx%ld\n", CGImageGetWidth(cgImage), CGImageGetHeight(cgImage));
#endif

    size_t width  = CGImageGetWidth(cgImage);
    size_t height = CGImageGetHeight(cgImage);

    size_t bytes_per_pixel = 4;
    size_t buffer_size = width * height * bytes_per_pixel;

    uint8_t *pixel_buffer = (uint8_t *)malloc(buffer_size);
    if (!pixel_buffer) {
        CGImageRelease(cgImage);
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
        free(pixel_buffer);
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

    // Zero and free the raw pixel buffer immediately. It contains a full
    // screenshot (potentially sensitive). We only keep the final compressed PNG.
    memset(pixel_buffer, 0, buffer_size);
    free(pixel_buffer);

    if (!png_data || png_size <= 0) {
#ifndef NDEBUG
        fprintf(stderr, "[capture] stbi_write_png_to_mem failed\n");
#endif
        return -1;
    }

#ifndef NDEBUG
    fprintf(stderr, "[capture] PNG encoded successfully (%d bytes)\n", png_size);
#endif

    out->data = png_data;
    out->size = png_size;
    return 0;
}

int capture_rect(int x, int y, int width, int height, PngBuffer *out) {
    if (!out || width <= 0 || height <= 0) return -1;

#ifndef NDEBUG
    fprintf(stderr, "[capture] capture_rect called (%d,%d %dx%d)\n", x, y, width, height);
#endif

    CGRect captureRect = CGRectMake(x, y, width, height);
    CGImageRef cgImage = NULL;

    // Prefer per-display capture. We use dlsym because CGDisplayCreateImageForRect
    // is marked unavailable in the macOS 15+ SDK (Apple wants ScreenCaptureKit).
    // The symbol often still exists at runtime, so this gives us reliable capture
    // on secondary/external monitors while still compiling on new SDKs.
    static CGImageRef (*createImageForRect)(CGDirectDisplayID, CGRect) = NULL;
    if (!createImageForRect) {
        createImageForRect = (CGImageRef (*)(CGDirectDisplayID, CGRect))
                             dlsym(RTLD_DEFAULT, "CGDisplayCreateImageForRect");
    }

    if (createImageForRect) {
        CGDirectDisplayID displays[8];
        uint32_t displayCount = 0;
        CGGetDisplaysWithRect(captureRect, 8, displays, &displayCount);

        if (displayCount > 0) {
            // Pick the display with the largest intersection (handles rects
            // contained on secondary monitors or lightly spanning).
            CGDirectDisplayID bestDisplay = displays[0];
            CGFloat bestArea = 0;
            CGRect bestIntersection = CGRectZero;

            for (uint32_t i = 0; i < displayCount; i++) {
                CGRect dbounds = CGDisplayBounds(displays[i]);
                CGRect inter = CGRectIntersection(captureRect, dbounds);
                CGFloat area = inter.size.width * inter.size.height;
                if (area > bestArea) {
                    bestArea = area;
                    bestDisplay = displays[i];
                    bestIntersection = inter;
                }
            }

            if (bestArea > 0) {
                cgImage = createImageForRect(bestDisplay, bestIntersection);
            }
        }
    }

    // Fallback to the (already dlsym'd) global-rect method. This is what
    // previously made "monitor1 works" while secondary monitors were flaky.
    if (!cgImage) {
        static CGImageRef (*createImage)(CGRect, uint32_t, uint32_t, uint32_t) = NULL;
        if (!createImage) {
            createImage = (CGImageRef (*)(CGRect, uint32_t, uint32_t, uint32_t))
                          dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
        }
        if (createImage) {
            cgImage = createImage(
                captureRect,
                kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
                kCGNullWindowID,
                kCGWindowImageDefault
            );
        }
    }

    if (!cgImage) {
#ifndef NDEBUG
        fprintf(stderr, "[capture] rect capture returned NULL\n");
#endif
        return -1;
    }

#ifndef NDEBUG
    fprintf(stderr, "[capture] Got CGImage for rect %ldx%ld\n",
            CGImageGetWidth(cgImage), CGImageGetHeight(cgImage));
#endif

    size_t imgWidth  = CGImageGetWidth(cgImage);
    size_t imgHeight = CGImageGetHeight(cgImage);
    size_t bytesPerPixel = 4;
    size_t bufferSize = imgWidth * imgHeight * bytesPerPixel;

    uint8_t *pixelBuffer = (uint8_t *)malloc(bufferSize);
    if (!pixelBuffer) {
        CGImageRelease(cgImage);
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
        free(pixelBuffer);
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

    // Zero and free the raw pixel buffer immediately (contains screen contents).
    memset(pixelBuffer, 0, bufferSize);
    free(pixelBuffer);

    if (!pngData || pngSize <= 0) {
#ifndef NDEBUG
        fprintf(stderr, "[capture] stbi_write_png_to_mem failed for rect\n");
#endif
        return -1;
    }

    out->data = pngData;
    out->size = pngSize;

#ifndef NDEBUG
    fprintf(stderr, "[capture] Rect PNG encoded successfully (%d bytes)\n", pngSize);
#endif
    return 0;
}

void png_buffer_free(PngBuffer *png) {
    if (!png || !png->data) return;

    // Best-effort zero before free. The PNG bytes may contain a screenshot of
    // potentially private content (passwords, chats, etc.).
    if (png->size > 0) {
        memset(png->data, 0, (size_t)png->size);
    }
    free(png->data);

    png->data = NULL;
    png->size = 0;
}
