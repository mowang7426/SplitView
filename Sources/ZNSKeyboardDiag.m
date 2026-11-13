#import "ZNSKeyboardDiag.h"
#import <CoreFoundation/CoreFoundation.h>
#import <os/log.h>
#import <unistd.h>
#import <fcntl.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <math.h>

#define ZNS_DIAG_PATH @"/var/mobile/Library/Logs/com.zengniu.splitview-keyboard.jsonl"
#define ZNS_DIAG_LIMIT (1024 * 1024)
static os_log_t ZNSKeyboardDiagLog(void) {
    static os_log_t log; static dispatch_once_t once;
    dispatch_once(&once, ^{ log=os_log_create("com.zengniu.splitview", "keyboard-diag"); });
    return log;
}
BOOL ZNSKeyboardDiagEnabled(void) {
    CFPreferencesAppSynchronize(CFSTR("com.zengniu.splitview"));
    id value=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("KeyboardDiagnosticsEnabled"),CFSTR("com.zengniu.splitview")));
    return value ? ([value respondsToSelector:@selector(boolValue)] && [value boolValue]) :
#if defined(ZNS_KEYBOARD_DIAG_DEFAULT_ON)
        YES;
#else
        NO;
#endif
}
static NSString *ZNSDiagSafe(id value) {
    if ([value isKindOfClass:NSNumber.class]) return [NSString stringWithFormat:@"%@",value];
    if(![value isKindOfClass:NSString.class]) return @"invalid";
    NSString *s=value; if(s.length>32) return @"invalid";
    NSCharacterSet *allowed=[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.:"];
    if ([s rangeOfCharacterFromSet:allowed.invertedSet].location!=NSNotFound) return @"invalid";
    return s.length?s:@"unknown";
}
static BOOL ZNSDiagAllow(void) {
    static NSMutableDictionary *last; static dispatch_once_t once;
    dispatch_once(&once,^{last=[NSMutableDictionary new];});
    NSString *key=[NSString stringWithFormat:@"%d",getpid()]; NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    NSNumber *previous=last[key]; if(previous && now-previous.doubleValue<0.12) return NO;
    last[key]=@(now); return YES;
}
static void ZNSDiagAppend(NSDictionary *record) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        (void)mkdir("/var/mobile/Library/Logs",0700);
        const char *path=ZNS_DIAG_PATH.fileSystemRepresentation;
        int fd=open(path,O_CREAT|O_RDWR|O_CLOEXEC,0600);
        if(fd<0) return;
        if(flock(fd,LOCK_EX)==0) {
            struct stat st; if(fstat(fd,&st)==0) {
                NSMutableData *data=[NSMutableData dataWithContentsOfFile:ZNS_DIAG_PATH];
                NSArray *lines=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].componentsSeparatedByString:@"\n";
                if(data.length>(NSUInteger)ZNS_DIAG_LIMIT || lines.count>1501) {
                    NSArray *kept=lines.count>1501?[lines subarrayWithRange:NSMakeRange(lines.count-1501,1500)]:lines;
                    data=[[[kept componentsJoinedByString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
                    if(data.length>ZNS_DIAG_LIMIT) { NSUInteger start=data.length-ZNS_DIAG_LIMIT; const uint8_t *bytes=data.bytes; while(start<data.length && bytes[start]!='\n') start++; if(start<data.length) [data replaceBytesInRange:NSMakeRange(0,start+1) withBytes:NULL length:0]; }
                    (void)ftruncate(fd,0); (void)lseek(fd,0,SEEK_SET); (void)write(fd,data.bytes,data.length);
                }
            }
            NSData *line=[NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingFragmentsAllowed error:nil];
            if(line) { (void)lseek(fd,0,SEEK_END); (void)write(fd,line.bytes,line.length); (void)write(fd,"\n",1); }
            (void)fchmod(fd,0600); (void)flock(fd,LOCK_UN);
        }
        close(fd);
    });
}
void ZNSKeyboardDiagEmit(ZNSKeyboardDiagPhase phase, NSUInteger generation, NSUInteger serial, NSDictionary *fields) {
    static NSString *names[]={@"",@"WillShow",@"DidShow",@"WillChange",@"DidChange",@"WillHide",@"DidHide"};
    if(phase<1 || phase>6 || !ZNSKeyboardDiagEnabled() || !ZNSDiagAllow()) return;
    NSArray *allowed=@[@"visibleProof",@"ownerMatch",@"focusMatch",@"sceneCount",@"activeSceneCount",@"sceneMatch",@"windowMatch",@"canvasMatch",@"frameInScreen",@"placementVisible",@"expanded",@"restoreAuth",@"restoreReason",@"pollAttempt",@"ack",@"sceneApplied",@"handoff",@"layoutEpoch",@"swipe",@"animation"];
    NSMutableDictionary *safe=[@{@"event":names[phase],@"generation":@(generation),@"serial":@(serial),@"pid":@(getpid()),@"time":@([[NSDate date] timeIntervalSince1970])} mutableCopy];
    for(NSString *key in allowed) if(fields[key]) safe[key]=ZNSDiagSafe(fields[key]);
    ZNSDiagAppend(safe);
    os_log(ZNSKeyboardDiagLog(),"%{public}s",[[NSString stringWithFormat:@"ZNSKeyboardDiag %@ gen=%lu serial=%lu",names[phase],(unsigned long)generation,(unsigned long)serial] UTF8String]);
}
void ZNSKeyboardDiagDecision(NSString *decision, NSUInteger generation, NSDictionary *fields) {
    NSString *safeEvent=[NSString stringWithFormat:@"Decision_%@",ZNSDiagSafe(decision)];
    if(!ZNSKeyboardDiagEnabled() || !ZNSDiagAllow()) return;
    NSMutableDictionary *record=[@{@"event":safeEvent,@"generation":@(generation),@"pid":@(getpid()),@"time":@([[NSDate date] timeIntervalSince1970])} mutableCopy];
    NSArray *allowed=@[@"visibleProof",@"ownerMatch",@"focusMatch",@"sceneCount",@"activeSceneCount",@"sceneMatch",@"windowMatch",@"canvasMatch",@"frameInScreen",@"placementVisible",@"expanded",@"restoreAuth",@"restoreReason",@"pollAttempt",@"ack",@"sceneApplied",@"handoff",@"layoutEpoch",@"swipe",@"animation"];
    for(NSString *key in allowed) if(fields[key]) record[key]=ZNSDiagSafe(fields[key]);
    ZNSDiagAppend(record);
    os_log(ZNSKeyboardDiagLog(),"%{public}s",safeEvent.UTF8String);
}
NSString *ZNSKeyboardDiagLogPath(void) { return ZNS_DIAG_PATH; }
NSString *ZNSKeyboardDiagRead(void) {
    NSData *data=[NSData dataWithContentsOfFile:ZNS_DIAG_PATH options:NSDataReadingMappedIfSafe error:nil];
    if(!data.length) return @"尚无诊断记录，或当前进程无权读取共享日志文件。";
    NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return text.length?text:@"日志文件编码无效。";
}
BOOL ZNSKeyboardDiagClear(void) {
    int fd=open(ZNS_DIAG_PATH.fileSystemRepresentation,O_CREAT|O_WRONLY|O_CLOEXEC,0600);
    if(fd<0) return NO; BOOL ok=flock(fd,LOCK_EX)==0; if(ok) { ok=ftruncate(fd,0)==0; fchmod(fd,0600); flock(fd,LOCK_UN); } close(fd); return ok;
}
