#import "Tweak.h"

BOOL enabled = true; // Set to false to disable the tweak.

extern CFNotificationCenterRef CFNotificationCenterGetDistributedCenter(void);

//-MARK: Utility
static dispatch_queue_t getBBServerQueue() {
    static dispatch_queue_t queue;
    static dispatch_once_t predicate;
    dispatch_once(&predicate, ^{
        void *handle = dlopen(NULL, RTLD_GLOBAL);
        if (handle) {
            dispatch_queue_t *pointer = (dispatch_queue_t *) dlsym(handle, "__BBServerQueue");
            if (pointer) {
                queue = *pointer;
            }
            dlclose(handle);
        }
    });
    return queue;
}

//cf. http://iphonedevwiki.net/index.php/CFNotificationCenter
static bool distributedCenterIsAvailable()
{
    void *handle = dlopen("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation", RTLD_LAZY);
    if (handle) {
        return dlsym(handle, "CFNotificationCenterGetDistributedCenter"); // Available.
    }
    
    return false;
}

//-MARK: For SpringBoard
static NSString *targetSectionID = @"";
static NSString *targetProcessName = @""; // Set to the process name of the target app.

static bool isConnected() {
    id appInstance = [UIApplication sharedApplication];
    
    NSLog(@"App instance: \n%@", appInstance);
    if ([WCSession isSupported]) {
        WCSession* session = [WCSession defaultSession];
        session.delegate = appInstance;
        [session activateSession];
        
        NSLog(@"WCSession is supported.");
        return session.paired;
    }
    return false;
}

static BBSound *getBBSound()
{
    TLAlertConfiguration *toneAlertConfig = [[%c(TLAlertConfiguration) alloc] initWithType: 1];
    [toneAlertConfig setShouldRepeat:false];
    
    BBSound *sound = [[%c(BBSound) alloc] initWithToneAlertConfiguration: toneAlertConfig];
    return sound;
}

//Thanks for Nepeta. (Notifica)
static id bbServer = nil;
static void fakeNotification(NSString *sectionID, NSString *appName, NSString *message) {
    BBBulletin *bulletin = [[%c(BBBulletin) alloc] init];
    NSDate *date = [NSDate date];
    
    bulletin.title = appName;
    bulletin.message = message;
    bulletin.sectionID = sectionID;
    bulletin.bulletinID = [[NSProcessInfo processInfo] globallyUniqueString];
    bulletin.recordID = [[NSProcessInfo processInfo] globallyUniqueString];
    bulletin.publisherBulletinID = [[NSProcessInfo processInfo] globallyUniqueString];
    bulletin.date = date;
    
    
    bulletin.sound = getBBSound(); // If bulletin.sound is not set, AppleWatch's vibration doesn't work.
    bulletin.defaultAction = [%c(BBAction) actionWithLaunchBundleID:sectionID callblock:nil];
    
    if ([bbServer respondsToSelector:@selector(publishBulletin:destinations:alwaysToLockScreen:)]) {
        dispatch_sync(getBBServerQueue(), ^{
            [bbServer publishBulletin:bulletin destinations:4 alwaysToLockScreen:YES];
        });
    } else if ([bbServer respondsToSelector:@selector(publishBulletin:destinations:)]) {
        dispatch_sync(getBBServerQueue(), ^{
            [bbServer publishBulletin:bulletin destinations:4];
        });
    }
}


static void sliceNotification(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo)  //called on SpringBoard.
{
    NSLog(@"sliceNotification");
    if(enabled)
    {
        NSLog(@"userInfo: %@",userInfo);
        
        //メモリ管理をARCに委譲するCFBridgingReleaseを呼ぶとなぜかクラッシュするので、コード上でメモリ管理を行うよう__bridgeキャストを用いた。
        //(CFBridgingReleaseは参照カウンタを一つ減らす)
        //なお、メモリの開放については、"多分"reportNewIncomingCallWithUUID内のCFReleaseで解放できてるはず
        
        NSDictionary *reciever = (NSDictionary *)(__bridge userInfo);
        
        NSString *target = reciever[@"targetSectionID"];
        NSString *targetProcess = reciever[@"targetProcessName"];
        NSString *displayName = reciever[@"displayName"];
        NSString *video = reciever[@"hasVideo"];
        NSLog(@"target: %@\ndisplayName: %@\nvideo: %@", target, displayName, video);
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            fakeNotification(target,targetProcess,
                             [NSString stringWithFormat:@"%@Call from %@!", video, displayName]);
        });
    }
    
    NSLog(@"sliceNotification - end");
}

//cf. Ny comments in %ctor
static bool preparedDC = false;
static void prepareDistributedCenter(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo)
{
    //cf. http://iphonedevwiki.net/index.php/CFNotificationCenter
    if(distributedCenterIsAvailable() && !preparedDC)
    {
        NSLog(@"DistributedCenter is available.");
        
        CFNotificationCenterAddObserver(CFNotificationCenterGetDistributedCenter(),
                                        NULL,
                                        sliceNotification,
                                        (CFStringRef)@"com.yuigawada.callslicer/push-notification",
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        
        preparedDC = true;
    }
}

%hook BBServer

- (id)init {
    id me = %orig;
    bbServer = me;
    return me;
}

-(id)initWithQueue:(id)arg1 {
    bbServer = %orig;
    return bbServer;
}

-(id)initWithQueue:(id)arg1 dataProviderManager:(id)arg2 syncService:(id)arg3 dismissalSyncCache:(id)arg4 observerListener:(id)arg5 utilitiesListener:(id)arg6 conduitListener:(id)arg7 systemStateListener:(id)arg8 settingsListener:(id)arg9 {
    bbServer = %orig;
    return bbServer;
}

- (void)dealloc {
    if (bbServer == self) {
        bbServer = nil;
    }
    %orig;
}

%end


//-MARK: For Third-Party Calling Apps
%hook CXProvider

- (void)reportNewIncomingCallWithUUID:(id)arg1 update:(id)arg2 completion:(id /* block */)arg3 {
    
    bool needSlicing = isConnected();
    NSLog(@"AppleWatch: %d",needSlicing);
    
    //    NSArray *sender = @[targetSectionID,@"displayName"];
    
    if(distributedCenterIsAvailable())
    {
        CXCallUpdate *callInfo = (CXCallUpdate *)arg2;
        NSString *displayName = callInfo.localizedCallerName;
        
        CFMutableDictionaryRef dictionary = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFDictionaryAddValue(dictionary, @"targetProcessName", targetProcessName);
        CFDictionaryAddValue(dictionary, @"targetSectionID", targetSectionID);
        CFDictionaryAddValue(dictionary, @"displayName", displayName);
        CFDictionaryAddValue(dictionary, @"hasVideo", callInfo.hasVideo ? @"Video " : @"");
        
        CFNotificationCenterPostNotification(CFNotificationCenterGetDistributedCenter(), (CFStringRef)@"com.yuigawada.callslicer/push-notification", nil, dictionary, true);
        CFRelease(dictionary);
    }
    %orig;
}

%end

//-MARK: init

%ctor
{
    NSString *processName = [NSProcessInfo processInfo].processName;
    bool isSpringboard = [@"SpringBoard" isEqualToString:processName];
    if (isSpringboard && enabled) {
        //For prepareing DistributedCenter
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        prepareDistributedCenter,
                                        CFSTR("com.yuigawada.callslicer/prepare-DistributedCenter"),
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);            
        
    }
    else {
        targetProcessName = processName;
        targetSectionID = [[NSBundle mainBundle] bundleIdentifier];
        NSLog(@"targetSectionID: %@",targetSectionID);
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (CFStringRef)@"com.yuigawada.callslicer/prepare-DistributedCenter", nil, nil, true);
    }
}
