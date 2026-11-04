#import "../Sources/ZNSKeyboardPolicy.h"
#import <assert.h>
#import <stdio.h>

int main(void) { @autoreleasepool {
    assert(!ZNSKeyboardExternalValue(nil));
    for (id value in @[@"inner", @"external", @"window", @"bad", @1, @{}, NSNull.null]) assert(!ZNSKeyboardExternalValue(value));
    assert(ZNSKeyboardExternalValue(@"outer"));
    assert(!ZNSKeyboardMoveValue(nil));
    assert(!ZNSKeyboardMoveValue(@"YES"));
    assert(!ZNSKeyboardMoveValue(@{}));
    assert(!ZNSKeyboardMoveValue(@NO));
    assert(ZNSKeyboardMoveValue(@YES));
    for (int landscape=0;landscape<2;landscape++)
        for (int p=0;p<2;p++) for (int l=0;l<2;l++) {
            BOOL external=ZNSKeyboardExternalForDirection(landscape,p,l);
            assert(external==(landscape?l:p));
            for (int enabled=0;enabled<2;enabled++)
                assert(ZNSKeyboardCanMove(landscape,external,enabled)==(landscape&&external&&enabled));
        }
    NSDictionary *root=[NSDictionary dictionaryWithContentsOfFile:@"Preferences/Resources/Root.plist"];
    assert(root);
    NSMutableDictionary *rows=[NSMutableDictionary new];
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"Preferences/Resources" error:NULL]) {
        if(![name.pathExtension isEqualToString:@"plist"]) continue;
        NSDictionary *page=[NSDictionary dictionaryWithContentsOfFile:[@"Preferences/Resources" stringByAppendingPathComponent:name]];
        assert(page);
        for (NSDictionary *row in page[@"items"]) if (row[@"key"]) rows[row[@"key"]]=row;
    }
    assert(!rows[@"KeyboardMode"]);
    for (NSString *key in @[@"KeyboardPortraitPlacement",@"KeyboardLandscapePlacement"]) {
        NSDictionary *row=rows[key]; assert(row);
        assert([row[@"default"] isEqual:@"inner"]);
        assert([row[@"validValues"] isEqual:(@[@"inner",@"outer"])]);
        assert([row[@"PostNotification"] isEqual:@"com.zengniu.splitview/changed"]);
        assert(!ZNSKeyboardExternalValue(row[@"default"]));
    }
    assert(rows[@"KeyboardLandscapeMovable"]);
    assert(!ZNSKeyboardMoveValue(rows[@"KeyboardLandscapeMovable"][@"default"]));
    NSUInteger keyboardRows=0;
    for (NSString *key in rows) if ([key hasPrefix:@"Keyboard"]) keyboardRows++;
    assert(keyboardRows==3);
    for (NSString *path in @[@"Preferences/Resources/Guide.plist",@"Preferences/Resources/Gestures.plist",@"Preferences/Info.plist"]) assert([NSDictionary dictionaryWithContentsOfFile:path]);
    NSDictionary *info=[NSDictionary dictionaryWithContentsOfFile:@"Preferences/Info.plist"];
    assert([info[@"CFBundleVersion"] isEqual:@"66"]);
    NSDictionary *project=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@"apelin-project.json"] options:0 error:NULL];
    assert([project[@"package"][@"version"] isEqual:@"0.1.0~alpha66"]);
    assert([rows[@"DipEnabled"][@"default"] boolValue]);
    assert([rows[@"DipEnabled"][@"PostNotification"] isEqual:@"com.zengniu.splitview/changed"]);
    assert(![rows[@"FollowDeviceRotation"][@"default"] boolValue]);
    assert([rows[@"FollowDeviceRotation"][@"PostNotification"] isEqual:@"com.zengniu.splitview/changed"]);
    NSString *source=[NSString stringWithContentsOfFile:@"Sources/ZNSKeyboardPlacement.m" encoding:NSUTF8StringEncoding error:NULL];
    assert(source);
    for (NSString *removed in @[@"publishZoom",@"landscapeZoom",@"zoomChanged",@"zoomRequested",@"zoom:(BOOL)"]) assert(![source containsString:removed]);
    puts("PASS: keyboard policy matrix, safe defaults, three setting rows, plist/JSON versions, removed zoom symbols. No UI or system keyboard exercised.");
} return 0; }
