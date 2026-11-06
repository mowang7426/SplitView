// Production event classifier; imported verbatim by PortraitEventTests.
static NSDictionary *ZNSPortraitVisibilityEvent(NSDictionary *presentation,
    NSDictionary *previous, NSDictionary *restoreTiming, BOOL continuity) {
    if (presentation) return presentation;
    if (previous && continuity) {
        // Last verified owner reports App shown, but UIKit has not supplied a
        // usable frame/window. Never convert that uncertainty into DidHide.
        return @{@"bundle":previous[@"bundle"], @"continuity":@YES,
                 @"duration":@0.25, @"options":@0};
    }
    return restoreTiming?:@{@"duration":@0.25,@"options":@0,@"ended":@NO};
}
