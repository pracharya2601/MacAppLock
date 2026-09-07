// Generates Resources/AppIcon.icns.
//
//     ./scripts/make-icon.sh
//
// The artwork is drawn in code so it stays in step with the menu bar item, which
// uses the same lock.shield.fill SF Symbol.
#import <AppKit/AppKit.h>

static const CGFloat Canvas = 1024.0;
// macOS app icons sit on a rounded square inset from the canvas, not on the full
// square, which is what makes them read as rounded next to other Dock icons.
static const CGFloat BodyInset = 100.0;
// Apple's corner is a continuous curve (a superellipse), not a circular arc. A
// circular -bezierPathWithRoundedRect: corner looks visibly "pinched" beside real
// macOS icons, so the outline is sampled from |x|^n + |y|^n = 1 instead.
static const CGFloat SuperellipseExponent = 5.0;

static NSBezierPath *SquirclePath(NSRect rect) {
    NSBezierPath *path = [NSBezierPath bezierPath];
    CGFloat a = NSWidth(rect) / 2.0;
    CGFloat b = NSHeight(rect) / 2.0;
    CGFloat cx = NSMidX(rect);
    CGFloat cy = NSMidY(rect);
    CGFloat power = 2.0 / SuperellipseExponent;

    NSInteger steps = 720;
    for (NSInteger i = 0; i <= steps; i++) {
        double t = (2.0 * M_PI * i) / steps;
        double ct = cos(t), st = sin(t);
        double x = cx + a * copysign(pow(fabs(ct), power), ct);
        double y = cy + b * copysign(pow(fabs(st), power), st);
        NSPoint point = NSMakePoint(x, y);
        if (i == 0) {
            [path moveToPoint:point];
        } else {
            [path lineToPoint:point];
        }
    }
    [path closePath];
    return path;
}

// The drop shadow costs edge contrast at 16 and 32 points, where it blurs the
// outline into the background instead of adding depth. Geometry stays identical
// across sizes so the icon still lines up with the macOS grid.
static NSImage *RenderIcon(CGFloat canvas, BOOL withShadow) {
    CGFloat scale = canvas / Canvas;
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(canvas, canvas)];
    [image lockFocus];

    NSGraphicsContext *context = NSGraphicsContext.currentContext;
    context.imageInterpolation = NSImageInterpolationHigh;

    CGFloat inset = BodyInset * scale;
    NSRect body = NSMakeRect(inset, inset, canvas - inset * 2.0, canvas - inset * 2.0);
    NSBezierPath *shape = SquirclePath(body);

    // Drop shadow, so the icon has the same depth as system icons in the Dock.
    if (withShadow) {
        [context saveGraphicsState];
        NSShadow *shadow = [[NSShadow alloc] init];
        shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.30];
        shadow.shadowOffset = NSMakeSize(0, -18 * scale);
        shadow.shadowBlurRadius = 42 * scale;
        [shadow set];
        [[NSColor blackColor] setFill];
        [shape fill];
        [context restoreGraphicsState];
    }

    // Body gradient.
    [context saveGraphicsState];
    [shape addClip];
    NSGradient *gradient = [[NSGradient alloc] initWithColorsAndLocations:
        [NSColor colorWithSRGBRed:0.26 green:0.55 blue:0.98 alpha:1.0], 0.0,
        [NSColor colorWithSRGBRed:0.11 green:0.35 blue:0.85 alpha:1.0], 0.55,
        [NSColor colorWithSRGBRed:0.06 green:0.22 blue:0.66 alpha:1.0], 1.0, nil];
    [gradient drawInRect:body angle:-90.0];

    // Soft highlight across the top edge.
    NSGradient *sheen = [[NSGradient alloc] initWithStartingColor:
        [NSColor colorWithWhite:1.0 alpha:0.22]
                                                      endingColor:
        [NSColor colorWithWhite:1.0 alpha:0.0]];
    [sheen drawInRect:NSMakeRect(NSMinX(body), NSMidY(body),
                                 NSWidth(body), NSHeight(body) / 2.0) angle:-90.0];
    [context restoreGraphicsState];

    // Hairline edge to keep the shape crisp on light backgrounds.
    [context saveGraphicsState];
    [[NSColor colorWithWhite:1.0 alpha:0.18] setStroke];
    shape.lineWidth = 3.0 * scale;
    [shape stroke];
    [context restoreGraphicsState];

    // The same symbol the menu bar item uses. SF Symbols are template images, so
    // -set on a colour does not tint them: the glyph has to be recoloured by
    // compositing source-atop over its own alpha. The lock is a cut-out in
    // lock.shield.fill, so a white shield lets the gradient show through it.
    NSImage *glyph = [NSImage imageWithSystemSymbolName:@"lock.shield.fill"
                               accessibilityDescription:@"Mac App Lock"];
    NSImageSymbolConfiguration *configuration =
        [NSImageSymbolConfiguration configurationWithPointSize:440 * scale
                                                        weight:NSFontWeightRegular
                                                         scale:NSImageSymbolScaleLarge];
    glyph = [glyph imageWithSymbolConfiguration:configuration];
    if (glyph) {
        NSSize glyphSize = glyph.size;
        NSImage *whiteGlyph =
            [NSImage imageWithSize:glyphSize
                           flipped:NO
                    drawingHandler:^BOOL(NSRect destination) {
            [glyph drawInRect:destination
                     fromRect:NSZeroRect
                    operation:NSCompositingOperationSourceOver
                     fraction:1.0];
            [NSColor.whiteColor set];
            NSRectFillUsingOperation(destination, NSCompositingOperationSourceAtop);
            return YES;
        }];

        NSRect glyphRect = NSMakeRect(NSMidX(body) - glyphSize.width / 2.0,
                                      NSMidY(body) - glyphSize.height / 2.0,
                                      glyphSize.width, glyphSize.height);
        [context saveGraphicsState];
        if (withShadow) {
            NSShadow *glyphShadow = [[NSShadow alloc] init];
            glyphShadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.25];
            glyphShadow.shadowOffset = NSMakeSize(0, -8 * scale);
            glyphShadow.shadowBlurRadius = 22 * scale;
            [glyphShadow set];
        }
        [whiteGlyph drawInRect:glyphRect
                      fromRect:NSZeroRect
                     operation:NSCompositingOperationSourceOver
                      fraction:1.0];
        [context restoreGraphicsState];
    } else {
        fprintf(stderr, "warning: lock.shield.fill unavailable; icon has no glyph\n");
    }

    [image unlockFocus];
    return image;
}

static BOOL WritePNG(CGFloat pixels, BOOL withShadow, NSString *path) {
    NSImage *image = RenderIcon(pixels, withShadow);
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc]
        initWithBitmapDataPlanes:NULL
                      pixelsWide:(NSInteger)pixels
                      pixelsHigh:(NSInteger)pixels
                   bitsPerSample:8
                 samplesPerPixel:4
                        hasAlpha:YES
                        isPlanar:NO
                  colorSpaceName:NSCalibratedRGBColorSpace
                     bytesPerRow:0
                    bitsPerPixel:0];
    rep.size = NSMakeSize(pixels, pixels);

    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    context.imageInterpolation = NSImageInterpolationHigh;
    NSGraphicsContext.currentContext = context;
    [image drawInRect:NSMakeRect(0, 0, pixels, pixels)
             fromRect:NSZeroRect
            operation:NSCompositingOperationCopy
             fraction:1.0];
    [NSGraphicsContext restoreGraphicsState];

    NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    return [png writeToFile:path atomically:YES];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: %s <output .iconset directory>\n", argv[0]);
            return 2;
        }
        NSString *iconset = [NSString stringWithUTF8String:argv[1]];
        [NSFileManager.defaultManager createDirectoryAtPath:iconset
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:NULL];
        NSArray *sizes = @[@16, @32, @128, @256, @512];
        for (NSNumber *size in sizes) {
            CGFloat base = size.doubleValue;
            NSString *one = [iconset stringByAppendingPathComponent:
                [NSString stringWithFormat:@"icon_%.0fx%.0f.png", base, base]];
            NSString *two = [iconset stringByAppendingPathComponent:
                [NSString stringWithFormat:@"icon_%.0fx%.0f@2x.png", base, base]];
            if (!WritePNG(base, base > 32, one) || !WritePNG(base * 2.0, base * 2.0 > 32, two)) {
                fprintf(stderr, "error: could not write %.0fpt icon\n", base);
                return 1;
            }
        }
        // A standalone 1024 preview, handy for reviewing the artwork.
        WritePNG(1024, YES, [iconset stringByAppendingPathComponent:@"preview-1024.png"]);
        return 0;
    }
}
