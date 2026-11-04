#import <Foundation/Foundation.h>
@class ZNSSceneSession;
// Call only after a main window has successfully opened/restored. Weak requests
// wait until the switcher is hidden; stopped sessions never create cards.
void ZNSPromoteRecentApp(ZNSSceneSession *session);
