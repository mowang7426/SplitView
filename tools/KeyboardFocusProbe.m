#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#include <stdio.h>
// Metadata only. Never obtains singletons, reads UI, or changes focus.
int main(int argc,char **argv) { @autoreleasepool {
    for(NSString *framework in @[@"UIKitCore",@"FrontBoard"]) {
        NSString *path=[NSString stringWithFormat:@"/System/Library/PrivateFrameworks/%@.framework/%@",framework,framework];
        void *handle=dlopen(path.UTF8String,RTLD_LAZY);
        printf("LOAD %s %s\n",framework.UTF8String,handle?"ok":"unavailable");
    }
    unsigned count=0; Class *classes=objc_copyClassList(&count);
    for(unsigned i=0;i<count;i++) {
        NSString *name=NSStringFromClass(classes[i]);
        BOOL selected=argc>1?NO:([name containsString:@"KeyboardFocus"] || [name containsString:@"KeyboardArbiter"] || [name containsString:@"SceneSettings"] || [name isEqualToString:@"SBSceneHandle"] || [name isEqualToString:@"SBMainWorkspace"]);
        for(int j=1;j<argc;j++) if([name isEqualToString:@(argv[j])]) selected=YES;
        if(!selected) continue;
        printf("CLASS %s\n",name.UTF8String);
        for(int meta=0;meta<2;meta++) {
            unsigned n=0; Method *methods=class_copyMethodList(meta?object_getClass(classes[i]):classes[i],&n);
            for(unsigned k=0;k<n;k++) {
                NSString *sel=NSStringFromSelector(method_getName(methods[k]));
                if(argc>1 || [sel localizedCaseInsensitiveContainsString:@"focus"] || [sel localizedCaseInsensitiveContainsString:@"keyboard"] || [sel containsString:@"shared"])
                    printf("%c %s %s\n",meta?'+':'-',sel.UTF8String,method_getTypeEncoding(methods[k]));
            }
            free(methods);
        }
    }
    free(classes);
} return 0; }
