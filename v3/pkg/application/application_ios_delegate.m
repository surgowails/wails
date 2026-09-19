//go:build ios
#import "application_ios_delegate.h"
#import "../events/events_ios.h"
#import "application_ios.h"
extern void processApplicationEvent(unsigned int, void* data);
extern void processWindowEvent(unsigned int, unsigned int);
extern bool hasListeners(unsigned int);
extern void iosApplicationDidLaunch(void);
// WailsIOSMain (app's generated main_ios.go) runs the user's main()/app.Run().
// The delegate starts it AFTER UIKit has launched (see below).
extern void WailsIOSMain(void);
// Registers the UNUserNotificationCenter delegate so local notifications are
// shown while the app is in the foreground (and taps are handled). Apple
// requires this be set before launch finishes, hence the call below.
extern void ios_notifications_init(void);

static dispatch_once_t wailsGoMainOnce;

static UIColor *WailsLaunchBackgroundColor(void) {
    return [UIColor colorNamed:@"LaunchBackground"] ?: [UIColor whiteColor];
}

static void WailsApplyConfiguredBackgroundToWindow(UIWindow *window) {
    if (!window) {
        return;
    }
    unsigned char r = 255, g = 255, b = 255, a = 255;
    if (ios_get_app_background_color(&r, &g, &b, &a)) {
        CGFloat fr = ((CGFloat)r) / 255.0;
        CGFloat fg = ((CGFloat)g) / 255.0;
        CGFloat fb = ((CGFloat)b) / 255.0;
        CGFloat fa = ((CGFloat)a) / 255.0;
        UIColor *color = [UIColor colorWithRed:fr green:fg blue:fb alpha:fa];
        window.backgroundColor = color;
        window.rootViewController.view.backgroundColor = color;
    }
}

static UIWindow *WailsCreateInitialWindow(UIWindowScene *scene) {
    UIColor *launchBG = WailsLaunchBackgroundColor();
    UIWindow *window = scene ? [[UIWindow alloc] initWithWindowScene:scene] : [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    window.backgroundColor = launchBG;
    UIViewController *rootVC = [[UIViewController alloc] init];
    rootVC.view.backgroundColor = launchBG;
    window.rootViewController = rootVC;
    WailsApplyConfiguredBackgroundToWindow(window);
    [window makeKeyAndVisible];
    return window;
}

static void WailsEnsureViewControllerStorage(WailsAppDelegate *delegate) {
    if (delegate && !delegate.viewControllers) {
        delegate.viewControllers = [NSMutableArray array];
    }
}

static void WailsStartGoMainOnce(void) {
    dispatch_once(&wailsGoMainOnce, ^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            WailsIOSMain();
        });
    });
}

@implementation WailsAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    appDelegate = self;
    WailsEnsureViewControllerStorage(self);
    // Register the notification-center delegate before launch finishes so local
    // notifications appear while the app is foregrounded (otherwise iOS delivers
    // them silently and no banner is shown).
    ios_notifications_init();
    // Unconditional launch signal for the Go runtime. platformRun waits on
    // this and emits ApplicationDidFinishLaunching from the Go side once the
    // event listeners are wired up - emitting it from here would race the Go
    // runtime's startup and the event could be dropped.
    // In scene-based apps the first window is created by WailsSceneDelegate
    // after this method returns. Keep a legacy non-scene path for older generated
    // bundles so UIApplicationMain still has a visible window before Go starts.
    if (self.window == nil && ![[[NSBundle mainBundle] objectForInfoDictionaryKey:@"UIApplicationSceneManifest"] isKindOfClass:[NSDictionary class]]) {
        self.window = WailsCreateInitialWindow(nil);
        WailsStartGoMainOnce();
    }
    // Start the Go runtime only after UIKit has delivered launch and a window
    // exists. Starting Go earlier (concurrently with UIApplicationMain)
    // intermittently corrupts the FrontBoard launch handshake on a physical
    // device, so this method never fires (blank cold launch / 0x8BADF00D). Run it
    // on a background thread so app.Run()'s blocking loop never touches the main
    // thread. WailsIOSMain -> user main() -> app.Run(); the window's run() then
    // creates the WebView (appDelegate/window are already set by the delegate or
    // scene delegate).
    return YES;
}

- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession options:(UISceneConnectionOptions *)options API_AVAILABLE(ios(13.0)) {
    return [[UISceneConfiguration alloc] initWithName:@"Default Configuration" sessionRole:connectingSceneSession.role];
}

// GENERATED EVENTS START
- (void)applicationDidBecomeActive:(UIApplication *)application {
    if( hasListeners(EventApplicationDidBecomeActive) ) {
        processApplicationEvent(EventApplicationDidBecomeActive, NULL);
    }
}

- (void)applicationDidEnterBackground:(UIApplication *)application {
    if( hasListeners(EventApplicationDidEnterBackground) ) {
        processApplicationEvent(EventApplicationDidEnterBackground, NULL);
    }
}

- (void)applicationDidFinishLaunching:(UIApplication *)application {
    if( hasListeners(EventApplicationDidFinishLaunching) ) {
        processApplicationEvent(EventApplicationDidFinishLaunching, NULL);
    }
}

- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application {
    if( hasListeners(EventApplicationDidReceiveMemoryWarning) ) {
        processApplicationEvent(EventApplicationDidReceiveMemoryWarning, NULL);
    }
}

- (void)applicationWillEnterForeground:(UIApplication *)application {
    if( hasListeners(EventApplicationWillEnterForeground) ) {
        processApplicationEvent(EventApplicationWillEnterForeground, NULL);
    }
}

- (void)applicationWillResignActive:(UIApplication *)application {
    if( hasListeners(EventApplicationWillResignActive) ) {
        processApplicationEvent(EventApplicationWillResignActive, NULL);
    }
}

- (void)applicationWillTerminate:(UIApplication *)application {
    if( hasListeners(EventApplicationWillTerminate) ) {
        processApplicationEvent(EventApplicationWillTerminate, NULL);
    }
}

// GENERATED EVENTS END
@end

@implementation WailsSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions API_AVAILABLE(ios(13.0)) {
    if (![scene isKindOfClass:[UIWindowScene class]]) {
        return;
    }
    WailsAppDelegate *delegate = (WailsAppDelegate *)UIApplication.sharedApplication.delegate;
    appDelegate = delegate;
    WailsEnsureViewControllerStorage(delegate);

    self.window = WailsCreateInitialWindow((UIWindowScene *)scene);
    delegate.window = self.window;
    WailsStartGoMainOnce();
}

- (void)sceneDidBecomeActive:(UIScene *)scene API_AVAILABLE(ios(13.0)) {
    if( hasListeners(EventApplicationDidBecomeActive) ) {
        processApplicationEvent(EventApplicationDidBecomeActive, NULL);
    }
}

- (void)sceneWillResignActive:(UIScene *)scene API_AVAILABLE(ios(13.0)) {
    if( hasListeners(EventApplicationWillResignActive) ) {
        processApplicationEvent(EventApplicationWillResignActive, NULL);
    }
}

- (void)sceneWillEnterForeground:(UIScene *)scene API_AVAILABLE(ios(13.0)) {
    if( hasListeners(EventApplicationWillEnterForeground) ) {
        processApplicationEvent(EventApplicationWillEnterForeground, NULL);
    }
}

- (void)sceneDidEnterBackground:(UIScene *)scene API_AVAILABLE(ios(13.0)) {
    if( hasListeners(EventApplicationDidEnterBackground) ) {
        processApplicationEvent(EventApplicationDidEnterBackground, NULL);
    }
}
@end
