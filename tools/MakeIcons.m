#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>

// CPU-only asset generation; no screen or app access. Preserve the full image.
static BOOL WriteIcon(CGImageRef image, size_t pixels, NSString *path, BOOL rounded) {
    CGColorSpaceRef colors=CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx=CGBitmapContextCreate(NULL,pixels,pixels,8,0,colors,kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(colors);
    if(!ctx) return NO;
    CGRect square=CGRectMake(0,0,pixels,pixels);
    if(rounded) {
        CGPathRef clip=CGPathCreateWithRoundedRect(square,pixels*0.22,pixels*0.22,NULL);
        CGContextAddPath(ctx,clip); CGContextClip(ctx); CGPathRelease(clip);
    }
    CGContextSetRGBFillColor(ctx,1,1,1,1); CGContextFillRect(ctx,square);
    CGFloat w=CGImageGetWidth(image),h=CGImageGetHeight(image);
    CGFloat scale=MIN(pixels/w,pixels/h);
    CGContextSetInterpolationQuality(ctx,kCGInterpolationHigh);
    CGContextDrawImage(ctx,CGRectMake((pixels-w*scale)/2,(pixels-h*scale)/2,w*scale,h*scale),image);
    CGImageRef output=CGBitmapContextCreateImage(ctx);
    CGImageDestinationRef destination=CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],CFSTR("public.png"),1,NULL);
    BOOL ok=NO;
    if(destination && output) { CGImageDestinationAddImage(destination,output,NULL); ok=CGImageDestinationFinalize(destination); }
    if(destination) CFRelease(destination);
    if(output) CGImageRelease(output);
    CGContextRelease(ctx);
    return ok;
}
int main(int argc,char **argv) { @autoreleasepool {
    if(argc!=2) { fprintf(stderr,"usage: MakeIcons source-image\n"); return 2; }
    NSURL *input=[NSURL fileURLWithPath:@(argv[1])];
    CGImageSourceRef source=CGImageSourceCreateWithURL((__bridge CFURLRef)input,NULL);
    if(!source) return 3;
    NSDictionary *options=@{(id)kCGImageSourceCreateThumbnailFromImageAlways:@YES,(id)kCGImageSourceCreateThumbnailWithTransform:@YES,(id)kCGImageSourceThumbnailMaxPixelSize:@1024};
    CGImageRef image=CGImageSourceCreateThumbnailAtIndex(source,0,(__bridge CFDictionaryRef)options);
    CFRelease(source); if(!image) return 4;
    BOOL ok=WriteIcon(image,1024,@"apelin-icon.png",NO) &&
        WriteIcon(image,29,@"Preferences/Resources/icon.png",YES) &&
        WriteIcon(image,58,@"Preferences/Resources/icon@2x.png",YES) &&
        WriteIcon(image,87,@"Preferences/Resources/icon@3x.png",YES);
    CGImageRelease(image);
    if(ok) puts("Generated project icon 1024px and preference icons 29/58/87px.");
    return ok?0:5;
} }
