#import <Preferences/PSListController.h>
#import <math.h>
#import <stdlib.h>
#import <notify.h>
#import "../Sources/ZNSAuthorization.h"

// Every functional page shares the same read/write gate, including callbacks
// from PSListItemsController. Authorization input is never a preference row.
@interface ZNSAuthorizationListController : PSListController
@property(nonatomic,strong) UILabel *znsAuthorizationStatus;
@property(nonatomic,strong) UILabel *znsAuthorizationSubtitle;
@property(nonatomic) int znsAuthorizationToken;
@property(nonatomic) BOOL znsAuthorizationObserving;
@property(nonatomic) BOOL znsAuthorizationGranted;
- (NSString *)znsPageIdentifier;
- (void)znsRefreshAuthorization;
- (void)znsShowAuthorizationMessage:(NSString *)message;
@end

@implementation ZNSAuthorizationListController
- (NSString *)znsPageIdentifier { return @"root"; }
- (NSArray *)specifiers {
    if(!_specifiers) {
        // Keep all page data in an already packaged resource. A group marker
        // selects the page for that group and its following rows.
        NSArray *all=[self loadSpecifiersFromPlistName:@"Root" target:self];
        NSMutableArray *selected=[NSMutableArray array];
        NSString *page=@"root";
        for(PSSpecifier *row in all) {
            NSString *marker=[row propertyForKey:@"ZNSPage"];
            if(marker.length) page=marker;
            if(![page isEqualToString:[self znsPageIdentifier]]) continue;
            if(UIDevice.currentDevice.userInterfaceIdiom==UIUserInterfaceIdiomPad &&
               [[row propertyForKey:@"key"] isEqual:@"DesktopRotationEnabled"]) continue;
            if([row propertyForKey:@"key"]) {
                id available=[row propertyForKey:@"enabled"];
                [row setProperty:available?@([available boolValue]):@YES forKey:@"ZNSInitiallyAvailable"];
            }
            [selected addObject:row];
        }
        _specifiers=selected;
    }
    return _specifiers;
}
- (id)readPreferenceValue:(PSSpecifier *)specifier {
    if(specifier.cellType==PSSwitchCell && !ZNSReadAuthorization(YES)) return @NO;
    return [super readPreferenceValue:specifier];
}
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    if(!ZNSReadAuthorization(YES)) {
        ZNSDisableFeatureSwitches();
        notify_post(APELIN_PACKAGE_ID "/changed");
        [self reloadSpecifier:specifier];
        return;
    }
    NSNumber *available=[specifier propertyForKey:@"ZNSInitiallyAvailable"];
    if(available && !available.boolValue) {
        [self reloadSpecifier:specifier];
        return;
    }
    [super setPreferenceValue:value specifier:specifier];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.znsAuthorizationStatus=[UILabel new];
    self.znsAuthorizationStatus.font=[UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    self.znsAuthorizationStatus.textAlignment=NSTextAlignmentCenter;
    self.znsAuthorizationStatus.accessibilityIdentifier=@"ZNSAuthorizationStatus";
    self.znsAuthorizationSubtitle=[UILabel new];
    self.znsAuthorizationSubtitle.font=[UIFont systemFontOfSize:11];
    self.znsAuthorizationSubtitle.textAlignment=NSTextAlignmentCenter;
    self.znsAuthorizationSubtitle.textColor=UIColor.secondaryLabelColor;
    UIStackView *status=[[UIStackView alloc] initWithArrangedSubviews:@[self.znsAuthorizationStatus,self.znsAuthorizationSubtitle]];
    status.axis=UILayoutConstraintAxisVertical;
    status.alignment=UIStackViewAlignmentCenter;
    status.distribution=UIStackViewDistributionFill;
    status.spacing=2;
    status.userInteractionEnabled=NO;
    status.frame=CGRectMake(0,0,126,40);
    [status.widthAnchor constraintEqualToConstant:126].active=YES;
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithCustomView:status];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(znsApplicationActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
    __weak typeof(self) weakSelf=self;
    int token=0;
    if(notify_register_dispatch(APELIN_PACKAGE_ID "/changed",&token,dispatch_get_main_queue(),^(int value){
        (void)value; [weakSelf znsRefreshAuthorization];
    })==NOTIFY_STATUS_OK) {
        self.znsAuthorizationToken=token;
        self.znsAuthorizationObserving=YES;
    }
    [self znsRefreshAuthorization];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self znsRefreshAuthorization];
}
- (void)znsApplicationActive:(NSNotification *)notification {
    (void)notification; [self znsRefreshAuthorization];
}
- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if(_znsAuthorizationObserving) notify_cancel(_znsAuthorizationToken);
}
- (void)znsRefreshAuthorization {
    BOOL authorized=ZNSReadAuthorization(YES);
    if(!authorized && ZNSDisableFeatureSwitches()) notify_post(APELIN_PACKAGE_ID "/changed");
    self.znsAuthorizationGranted=authorized;
    self.znsAuthorizationStatus.text=authorized?@"已授权":@"未授权";
    self.znsAuthorizationStatus.textColor=authorized?UIColor.systemGreenColor:UIColor.secondaryLabelColor;
    self.znsAuthorizationSubtitle.text=authorized?@"您是内部授权人员":@"";
    self.znsAuthorizationSubtitle.hidden=!authorized;
    for(PSSpecifier *row in [[self specifiers] copy]) {
        if(![row propertyForKey:@"key"]) continue;
        NSNumber *available=[row propertyForKey:@"ZNSInitiallyAvailable"];
        if(!available) {
            id original=[row propertyForKey:@"enabled"];
            available=original?@([original boolValue]):@YES;
            [row setProperty:available forKey:@"ZNSInitiallyAvailable"];
        }
        [row setProperty:@(authorized && available.boolValue) forKey:@"enabled"];
        [self reloadSpecifier:row];
    }
}
- (void)znsShowAuthorizationMessage:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(),^{
        void (^presentResult)(void)=^{
            if(!self.view.window || self.presentedViewController) return;
            UIAlertController *result=[UIAlertController alertControllerWithTitle:@"分屏授权" message:message preferredStyle:UIAlertControllerStyleAlert];
            [result addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:result animated:YES completion:nil];
        };
        UIViewController *current=self.presentedViewController;
        if([current isKindOfClass:UIAlertController.class]) {
            id<UIViewControllerTransitionCoordinator> transition=current.transitionCoordinator;
            if(current.isBeingDismissed && transition) {
                BOOL queued=[transition animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context){
                    (void)context; presentResult();
                }];
                if(queued) return;
            }
            [self dismissViewControllerAnimated:YES completion:presentResult];
        } else if(!current) presentResult();
    });
}
- (void)znsResetAuthorization {
    if(self.presentedViewController || !self.view.window) return;
    [self.view endEditing:YES];
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"重置授权" message:@"重置后将变为未授权，停止分屏并释放现有主分屏、空挂、下探和悬浮图标。其他选项保留，功能开关停用；再次使用请在主设置页面输入授权码。确定重置吗？" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf=self;
    [alert addAction:[UIAlertAction actionWithTitle:@"重置授权" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){
        (void)action;
        ZNSAuthorizationListController *self=weakSelf;
        if(!self) return;
        CFPreferencesSetAppValue(ZNSAuthorizationKey,kCFBooleanFalse,CFSTR(APELIN_PACKAGE_ID));
        BOOL saved=CFPreferencesAppSynchronize(CFSTR(APELIN_PACKAGE_ID));
        id value=CFBridgingRelease(CFPreferencesCopyAppValue(ZNSAuthorizationKey,CFSTR(APELIN_PACKAGE_ID)));
        BOOL revoked=saved && [value isKindOfClass:NSNumber.class] &&
            CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID() &&
            !CFBooleanGetValue((__bridge CFBooleanRef)value);
        uint32_t posted=notify_post(APELIN_PACKAGE_ID "/changed");
        [self znsRefreshAuthorization];
        if(!revoked) {
            [self znsShowAuthorizationMessage:@"未能确认授权重置已保存，请稍后重试。当前授权状态以页面刷新结果为准。"];
        } else if(posted!=NOTIFY_STATUS_OK) {
            [self znsShowAuthorizationMessage:@"授权已重置，但刷新通知发送失败。请重新打开设置检查状态，并注销桌面以确保已有分屏全部关闭。"];
        } else {
            [self znsShowAuthorizationMessage:@"授权已重置，已通知分屏停用。再次使用请在主设置页面输入授权码并点击授权。"];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end

@interface ZNSRootListController : ZNSAuthorizationListController
@property(nonatomic,strong) UIView *znsAuthorizationHeader;
@property(nonatomic,strong) UITextField *znsAuthorizationCode;
@property(nonatomic,strong) UIButton *znsAuthorizeButton;
@property(nonatomic,strong) UILabel *znsAuthorizationHint;
@property(nonatomic,copy) NSString *znsDecoration;
@property(nonatomic,copy) NSString *znsVerificationDisplay;
- (void)znsLayoutAuthorizationHeader;
@end

// No new resource paths: each child selects its marked groups in Root.plist.
#define ZNS_SETTINGS_PAGE(CLASS, PAGE, TITLE) \
@interface CLASS : ZNSAuthorizationListController @end \
@implementation CLASS \
- (NSString *)znsPageIdentifier { return PAGE; } \
- (void)viewDidLoad { [super viewDidLoad]; self.title=TITLE; } \
@end
ZNS_SETTINGS_PAGE(ZNSAnimationsListController, @"animations", @"浮窗动画")
ZNS_SETTINGS_PAGE(ZNSBasicListController, @"basic", @"主分屏与桌面手势")
ZNS_SETTINGS_PAGE(ZNSParkedListController, @"parked", @"空挂与旋转")
ZNS_SETTINGS_PAGE(ZNSDipListController, @"dip", @"分屏的奇特形态")
ZNS_SETTINGS_PAGE(ZNSActivationListController, @"activation", @"状态栏长按与切换器手势")
ZNS_SETTINGS_PAGE(ZNSKeyboardListController, @"keyboard", @"键盘呼出方式(待更新)")
ZNS_SETTINGS_PAGE(ZNSNotificationListController, @"notification", @"通知的打开方式")
ZNS_SETTINGS_PAGE(ZNSExcludedListController, @"excluded", @"排除应用")
#undef ZNS_SETTINGS_PAGE

@interface ZNSDanmuListController : ZNSAuthorizationListController
- (void)znsUpdateDanmuLabels;
@end
@implementation ZNSDanmuListController
- (NSString *)znsPageIdentifier { return @"danmu"; }
- (void)viewDidLoad { [super viewDidLoad]; self.title=@"横屏弹幕通知"; [self znsUpdateDanmuLabels]; }
- (void)znsUpdateDanmuLabels {
    for(PSSpecifier *row in [self specifiers]) {
        NSString *key=[row propertyForKey:@"key"];
        BOOL size=[key isEqual:@"DanmuScale"], opacity=[key isEqual:@"DanmuOpacity"];
        if(!size && !opacity) continue;
        id value=[super readPreferenceValue:row];
        double percent=[value respondsToSelector:@selector(doubleValue)]?[value doubleValue]:(size?100:88);
        row.name=[NSString stringWithFormat:@"%@ %.0f%%",size?@"弹幕大小":@"不透明度",percent];
        [self reloadSpecifier:row];
    }
}
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key=[specifier propertyForKey:@"key"];
    if([key isEqual:@"DanmuScale"] || [key isEqual:@"DanmuOpacity"]) {
        double number=[value respondsToSelector:@selector(doubleValue)]?[value doubleValue]:NAN;
        if(!isfinite(number)) return;
        value=@(round(MAX([key isEqual:@"DanmuScale"]?60:20,MIN([key isEqual:@"DanmuScale"]?160:100,number))));
    }
    [super setPreferenceValue:value specifier:specifier];
    [self znsUpdateDanmuLabels];
}
- (void)znsSendDanmuTest {
    if(!ZNSReadAuthorization(YES)) return;
    notify_post(APELIN_PACKAGE_ID "/danmu-test");
}
- (void)znsResetDanmu {
    if(!ZNSReadAuthorization(YES) || self.presentedViewController) return;
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"恢复默认设置" message:@"仅重置横屏弹幕通知：启用、深色、大小100%、不透明度88%、点击打开主分屏。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf=self;
    [alert addAction:[UIAlertAction actionWithTitle:@"恢复" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action){
        (void)action;
        if(!ZNSReadAuthorization(YES)) return;
        NSDictionary *defaults=@{@"DanmuEnabled":@YES,@"DanmuLight":@NO,@"DanmuScale":@100,@"DanmuOpacity":@88,@"DanmuOpenMode":@"main"};
        for(PSSpecifier *row in [weakSelf specifiers]) {
            id value=defaults[[row propertyForKey:@"key"] ?: @""];
            if(value) [weakSelf setPreferenceValue:value specifier:row];
        }
        [weakSelf reloadSpecifiers]; [weakSelf znsUpdateDanmuLabels];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end

// Retain legacy controllers for already-open navigation stacks, not root links.
@interface ZNSGuideListController : ZNSAuthorizationListController @end
@implementation ZNSGuideListController
- (NSArray *)specifiers {
    if(!_specifiers) _specifiers=[self loadSpecifiersFromPlistName:@"Guide" target:self];
    return _specifiers;
}
- (void)viewDidLoad { [super viewDidLoad]; self.title=@"操作说明与更新内容"; }
@end
@interface ZNSGesturesListController : ZNSAuthorizationListController @end
@implementation ZNSGesturesListController
- (NSArray *)specifiers {
    if(!_specifiers) _specifiers=[self loadSpecifiersFromPlistName:@"Gestures" target:self];
    return _specifiers;
}
- (void)viewDidLoad { [super viewDidLoad]; self.title=@"手势介绍"; }
@end

static UITableView *ZNSFindSettingsTable(UIView *view) {
    if([view isKindOfClass:UITableView.class]) return (UITableView *)view;
    for(UIView *child in view.subviews) {
        UITableView *table=ZNSFindSettingsTable(child);
        if(table) return table;
    }
    return nil;
}

static NSString *ZNSDecorativeAuthorizationText(void) {
    // Always ten alphanumeric characters, with at least one digit and letter.
    // This is decoration only, never passed to authorization or preferences.
    const char *alphabet="0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    char text[11]={0};
    text[0]=alphabet[arc4random_uniform(10)];
    text[1]=alphabet[10+arc4random_uniform(52)];
    for(uint32_t i=2;i<10;i++) text[i]=alphabet[arc4random_uniform(62)];
    for(uint32_t i=9;i>0;i--) {
        uint32_t j=arc4random_uniform(i+1);
        char temporary=text[i]; text[i]=text[j]; text[j]=temporary;
    }
    return [NSString stringWithUTF8String:text];
}

@implementation ZNSRootListController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title=@"曾牛-分屏🐮";
    self.znsAuthorizationHeader=[UIView new];
    self.znsAuthorizationCode=[UITextField new];
    self.znsAuthorizationCode.borderStyle=UITextBorderStyleRoundedRect;
    self.znsAuthorizationCode.placeholder=@""; // Filled with the six-digit display below.
    self.znsAuthorizationCode.keyboardType=UIKeyboardTypeNumberPad;
    self.znsAuthorizationCode.secureTextEntry=YES;
    self.znsAuthorizationCode.autocorrectionType=UITextAutocorrectionTypeNo;
    self.znsAuthorizationCode.autocapitalizationType=UITextAutocapitalizationTypeNone;
    self.znsAuthorizationCode.spellCheckingType=UITextSpellCheckingTypeNo;
    self.znsAuthorizationCode.accessibilityIdentifier=@"ZNSAuthorizationCode";
    self.znsAuthorizationCode.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.znsAuthorizationCode.adjustsFontForContentSizeCategory=YES;
    self.znsAuthorizeButton=[UIButton buttonWithType:UIButtonTypeSystem];
    [self.znsAuthorizeButton setTitle:@"授权" forState:UIControlStateNormal];
    [self.znsAuthorizeButton addTarget:self action:@selector(znsRequestAuthorization) forControlEvents:UIControlEventTouchUpInside];
    self.znsAuthorizeButton.accessibilityIdentifier=@"ZNSAuthorizeButton";
    self.znsAuthorizationHint=[UILabel new];
    self.znsAuthorizationHint.numberOfLines=0;
    self.znsAuthorizationHint.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.znsAuthorizationHint.adjustsFontForContentSizeCategory=YES;
    self.znsAuthorizationHint.textColor=UIColor.secondaryLabelColor;
    [self.znsAuthorizationHeader addSubview:self.znsAuthorizationCode];
    [self.znsAuthorizationHeader addSubview:self.znsAuthorizeButton];
    [self.znsAuthorizationHeader addSubview:self.znsAuthorizationHint];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(znsClearInput:) name:UIApplicationWillResignActiveNotification object:nil];
    [self znsRefreshAuthorization];
}
- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self znsClearInput:nil];
}
- (void)znsClearInput:(NSNotification *)notification {
    (void)notification;
    [self.znsAuthorizationCode resignFirstResponder];
    if(!self.znsAuthorizationGranted) self.znsAuthorizationCode.text=@"";
}
- (void)znsRefreshAuthorization {
    BOOL previouslyAuthorized=self.znsAuthorizationGranted;
    [super znsRefreshAuthorization];
    BOOL authorized=self.znsAuthorizationGranted;
    if(authorized) {
        [self.znsAuthorizationCode resignFirstResponder];
        if(!self.znsDecoration) self.znsDecoration=ZNSDecorativeAuthorizationText();
        self.znsAuthorizationCode.secureTextEntry=NO;
        self.znsAuthorizationCode.placeholder=@"";
        self.znsAuthorizationCode.text=self.znsDecoration;
    } else {
        self.znsDecoration=nil;
        if(!self.znsVerificationDisplay || previouslyAuthorized)
            self.znsVerificationDisplay=[NSString stringWithFormat:@"%06u",100000u+arc4random_uniform(900000)];
        // Keep the displayed challenge separate from the actual authorization
        // input. It remains visible when empty and cannot be submitted as a key.
        self.znsAuthorizationCode.placeholder=self.znsVerificationDisplay;
        self.znsAuthorizationCode.secureTextEntry=YES;
        if(previouslyAuthorized) self.znsAuthorizationCode.text=@"";
    }
    self.znsAuthorizationCode.enabled=!authorized;
    self.znsAuthorizationCode.accessibilityLabel=authorized?@"授权装饰码，不参与验证":@"授权码";
    self.znsAuthorizeButton.enabled=!authorized;
    self.znsAuthorizationHint.text=authorized?@"授权完成。输入框仅显示装饰码；请自行开启“启用分屏”。":@"请用6 位验证码联系作者获取授权码";
    self.znsAuthorizationHint.textColor=authorized?UIColor.secondaryLabelColor:UIColor.systemRedColor;
    [self.viewIfLoaded setNeedsLayout];
}
- (void)znsRequestAuthorization {
    if(self.presentedViewController) return;
    if(ZNSReadAuthorization(YES)) { [self znsRefreshAuthorization]; return; }
    // Only this editable field supplies validation input; discard it immediately.
    NSString *input=[self.znsAuthorizationCode.text copy];
    self.znsAuthorizationCode.text=@"";
    [self.znsAuthorizationCode resignFirstResponder];
    BOOL matches=ZNSAuthorizationMatchesNow(input);
    input=nil;
    if(!matches) {
        [self znsRefreshAuthorization];
        [self znsShowAuthorizationMessage:@"授权码无效，请在页面输入框重新输入。"];
        return;
    }
    ZNSDisableFeatureSwitches();
    id previous=CFBridgingRelease(CFPreferencesCopyAppValue(ZNSAuthorizationKey,CFSTR(APELIN_PACKAGE_ID)));
    id previousDip=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("DipEnabled"),CFSTR(APELIN_PACKAGE_ID)));
    CFPreferencesSetAppValue(ZNSAuthorizationKey,kCFBooleanTrue,CFSTR(APELIN_PACKAGE_ID));
    CFPreferencesSetAppValue(CFSTR("DipEnabled"),kCFBooleanTrue,CFSTR(APELIN_PACKAGE_ID));
    if(!CFPreferencesAppSynchronize(CFSTR(APELIN_PACKAGE_ID)) || !ZNSReadAuthorization(YES)) {
        CFPreferencesSetAppValue(ZNSAuthorizationKey,(__bridge CFPropertyListRef)previous,CFSTR(APELIN_PACKAGE_ID));
        CFPreferencesSetAppValue(CFSTR("DipEnabled"),(__bridge CFPropertyListRef)previousDip,CFSTR(APELIN_PACKAGE_ID));
        CFPreferencesAppSynchronize(CFSTR(APELIN_PACKAGE_ID));
        [self znsRefreshAuthorization];
        [self znsShowAuthorizationMessage:@"授权状态保存失败，尚未完成授权，请稍后重试。"];
        return;
    }
    uint32_t posted=notify_post(APELIN_PACKAGE_ID "/changed");
    [self znsRefreshAuthorization];
    [self znsShowAuthorizationMessage:posted==NOTIFY_STATUS_OK?@"授权成功，已默认启用下探。请自行开启“启用分屏”总开关。":@"授权已保存并默认启用下探，但刷新通知发送失败。请重新打开设置检查状态，再自行开启“启用分屏”。"];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self znsLayoutAuthorizationHeader];
}
- (void)znsLayoutAuthorizationHeader {
    if(!self.znsAuthorizationHeader) return;
    UITableView *table=ZNSFindSettingsTable(self.view);
    CGFloat width=CGRectGetWidth(table.bounds);
    if(!table || width<=0) return;
    CGFloat margin=MIN(20,width*0.08), contentWidth=MAX(1,width-2*margin);
    CGFloat rowHeight=MAX(44,ceil(self.znsAuthorizationCode.font.lineHeight)+20);
    CGFloat buttonWidth=64, gap=10;
    self.znsAuthorizationCode.frame=CGRectMake(margin,16,MAX(1,contentWidth-buttonWidth-gap),rowHeight);
    self.znsAuthorizeButton.frame=CGRectMake(width-margin-buttonWidth,16,buttonWidth,rowHeight);
    CGFloat hintHeight=ceil([self.znsAuthorizationHint sizeThatFits:CGSizeMake(contentWidth,CGFLOAT_MAX)].height);
    self.znsAuthorizationHint.frame=CGRectMake(margin,16+rowHeight+8,contentWidth,hintHeight);
    CGSize size=CGSizeMake(width,16+rowHeight+8+hintHeight+12);
    BOOL changed=!CGSizeEqualToSize(self.znsAuthorizationHeader.frame.size,size);
    if(changed) self.znsAuthorizationHeader.frame=(CGRect){CGPointZero,size};
    if(changed || table.tableHeaderView!=self.znsAuthorizationHeader) table.tableHeaderView=self.znsAuthorizationHeader;
}
@end
