#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#ifdef MACSW_QUICKLOOK_THUMBNAIL
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>
#else
#import <QuickLookUI/QuickLookUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#endif
#include <zlib.h>

static const uint8_t chunkMarker[] = {0x14, 0, 6, 0, 8, 0};
static const uint8_t pngSignature[] = {0x89, 'P', 'N', 'G', 13, 10, 26, 10};
static const NSUInteger maxFileSize = 128 * 1024 * 1024;
static const NSUInteger maxPreviewSize = 8 * 1024 * 1024;

static uint32_t readLE32(const uint8_t *bytes) {
    uint32_t value;
    memcpy(&value, bytes, sizeof(value));
    return CFSwapInt32LittleToHost(value);
}

static BOOL isPreviewName(const uint8_t *bytes, unsigned shift) {
    const char name[] = "PreviewPNG";
    for (size_t i = 0; i < sizeof(name) - 1; i++) {
        uint8_t decoded = (bytes[i] << shift) | (bytes[i] >> (8 - shift));
        if (decoded != name[i]) return NO;
    }
    return YES;
}

static NSData *inflatePreview(const uint8_t *input, uint32_t compressed, uint32_t size, uint32_t crc) {
    NSMutableData *output = [NSMutableData dataWithLength:size];
    z_stream stream = {0};
    stream.next_in = (Bytef *)input;
    stream.avail_in = compressed;
    stream.next_out = output.mutableBytes;
    stream.avail_out = size;
    if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) return nil;
    int result = inflate(&stream, Z_FINISH);
    inflateEnd(&stream);
    if (result != Z_STREAM_END || stream.total_out != size || stream.total_in != compressed ||
        crc32(0, output.bytes, size) != crc ||
        memcmp(output.bytes, pngSignature, sizeof(pngSignature)) != 0) return nil;
    return output;
}

// Inline PreviewPNG stream in the modern SOLIDWORKS container.
// Format reference: openswx, libopenswx/src/internal/modern_parser.h (72291dc).
static NSData *previewData(NSURL *url) {
    NSNumber *regularFile = nil;
    NSNumber *fileSize = nil;
    if (![url getResourceValue:&regularFile forKey:NSURLIsRegularFileKey error:nil] ||
        !regularFile.boolValue ||
        ![url getResourceValue:&fileSize forKey:NSURLFileSizeKey error:nil] ||
        fileSize.unsignedLongLongValue > maxFileSize) return nil;

    NSFileHandle *file = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
    NSData *data = [file readDataUpToLength:fileSize.unsignedIntegerValue + 1 error:nil];
    [file closeAndReturnError:nil];
    if (data.length < 36 || data.length > maxFileSize) return nil;
    NSData *marker = [NSData dataWithBytes:chunkMarker length:sizeof(chunkMarker)];
    if ([data rangeOfData:marker options:0 range:NSMakeRange(0, MIN(data.length, 64))].location == NSNotFound) return nil;

    const uint8_t *bytes = data.bytes;
    unsigned shift = bytes[7] & 7;
    NSUInteger offset = 8;
    unsigned candidates = 0;
    while (offset <= data.length - 36) {
        NSRange match = [data rangeOfData:marker options:0 range:NSMakeRange(offset, data.length - offset)];
        if (match.location == NSNotFound || match.location > data.length - 36) break;
        const uint8_t *header = bytes + match.location;
        offset = match.location + sizeof(chunkMarker);
        if (readLE32(header + 22) != 10 || !isPreviewName(header + 26, shift)) continue;
        uint32_t compressed = readLE32(header + 14);
        uint32_t size = readLE32(header + 18);
        NSUInteger payload = match.location + 36;
        if (!compressed || compressed > maxPreviewSize || compressed > data.length - payload ||
            size < sizeof(pngSignature) || size > maxPreviewSize) continue;
        uint32_t crc = readLE32(header + 10);
        // Cache records carry the stream name, but contain sizes instead of image bytes.
        if (crc == size * 2 && compressed == size / 2) continue;
        if (++candidates > 4) break;
        NSData *png = inflatePreview(bytes + payload, compressed, size, crc);
        if (png) return png;
    }
    return nil;
}

static CGSize previewSize(CGImageSourceRef source) {
    NSDictionary *properties = source ? CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL)) : nil;
    NSUInteger width = [properties[(id)kCGImagePropertyPixelWidth] unsignedIntegerValue];
    NSUInteger height = [properties[(id)kCGImagePropertyPixelHeight] unsignedIntegerValue];
    if (!width || !height || width > 4096 || height > 4096) return CGSizeZero;
    return CGSizeMake(width, height);
}

static NSError *previewUnavailable(void) {
    return [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadUnsupportedSchemeError userInfo:nil];
}

#ifdef MACSW_QUICKLOOK_THUMBNAIL
@interface MacSWSolidWorksThumbnail : QLThumbnailProvider
@end

@implementation MacSWSolidWorksThumbnail
- (void)provideThumbnailForFileRequest:(QLFileThumbnailRequest *)request
                    completionHandler:(void (^)(QLThumbnailReply *, NSError *))handler {
    NSURL *url = request.fileURL;
    NSString *extension = url.pathExtension.lowercaseString;
    // eDrawings declares a shared type that also includes legacy and template files.
    if (![@[@"sldprt", @"sldasm", @"slddrw"] containsObject:extension] ||
        [url.lastPathComponent hasPrefix:@"~$"]) {
        handler(nil, previewUnavailable());
        return;
    }

    NSData *png = previewData(url);
    CGImageSourceRef source = png ? CGImageSourceCreateWithData((__bridge CFDataRef)png, NULL) : NULL;
    CGSize original = previewSize(source);
    if (source) CFRelease(source);
    if (CGSizeEqualToSize(original, CGSizeZero)) {
        handler(nil, previewUnavailable());
        return;
    }

    CGSize maximum = request.maximumSize;
    CGSize minimum = request.minimumSize;
    CGFloat scale = MIN(maximum.width / original.width, maximum.height / original.height);
    CGSize fitted = CGSizeMake(original.width * scale, original.height * scale);
    CGSize canvas = CGSizeMake(MIN(maximum.width, MAX(fitted.width, minimum.width)),
                               MIN(maximum.height, MAX(fitted.height, minimum.height)));
    QLThumbnailReply *reply = [QLThumbnailReply replyWithContextSize:canvas drawingBlock:^BOOL(CGContextRef context) {
        CGImageSourceRef imageSource = CGImageSourceCreateWithData((__bridge CFDataRef)png, NULL);
        if (!imageSource) return NO;
        CGImageRef image = CGImageSourceCreateImageAtIndex(imageSource, 0, NULL);
        CFRelease(imageSource);
        if (!image) return NO;
        // The system can supply a pixel-scaled bitmap with an unscaled CTM.
        // Fit to the actual drawing area in user space on both 1x and Retina.
        CGRect pixels = CGRectMake(0, 0, CGBitmapContextGetWidth(context), CGBitmapContextGetHeight(context));
        CGRect bounds = CGContextConvertRectToUserSpace(context, pixels);
        CGFloat drawScale = MIN(bounds.size.width / original.width, bounds.size.height / original.height);
        CGSize drawn = CGSizeMake(original.width * drawScale, original.height * drawScale);
        CGRect imageBounds = CGRectMake(CGRectGetMidX(bounds) - drawn.width / 2,
                                        CGRectGetMidY(bounds) - drawn.height / 2, drawn.width, drawn.height);
        CGContextSetRGBFillColor(context, 1, 1, 1, 1);
        CGContextFillRect(context, bounds);
        CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
        CGContextDrawImage(context, imageBounds, image);
        CGImageRelease(image);
        return YES;
    }];
    handler(reply, nil);
}
@end
#else
@interface MacSWSolidWorksPreview : QLPreviewProvider <QLPreviewingController>
@end

@implementation MacSWSolidWorksPreview
- (void)providePreviewForFileRequest:(QLFilePreviewRequest *)request
                  completionHandler:(void (^)(QLPreviewReply *, NSError *))handler {
    NSData *png = previewData(request.fileURL);
    CGImageSourceRef source = png ? CGImageSourceCreateWithData((__bridge CFDataRef)png, NULL) : NULL;
    CGSize size = previewSize(source);
    if (source) CFRelease(source);
    if (CGSizeEqualToSize(size, CGSizeZero)) {
        handler(nil, previewUnavailable());
        return;
    }
    QLPreviewReply *reply = [[QLPreviewReply alloc] initWithDataOfContentType:UTTypePNG
                                                                 contentSize:size
                                                           dataCreationBlock:^NSData *(QLPreviewReply *unused, NSError **error) {
        (void)unused;
        (void)error;
        return png;
    }];
    handler(reply, nil);
}
@end
#endif
