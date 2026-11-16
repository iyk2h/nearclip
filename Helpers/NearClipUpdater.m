#import <AppKit/AppKit.h>
#import <Security/Security.h>
#import <Sparkle/Sparkle.h>

static NSString * const Feed = @"https://raw.githubusercontent.com/iyk2h/nearclip/main/updates/appcast.xml";
static BOOL validHost(NSURL *url) {
    SecCodeRef own = NULL; SecStaticCodeRef ownStatic = NULL, host = NULL;
    SecRequirementRef requirement = NULL, hostRequirement = NULL; CFStringRef raw = NULL;
    BOOL valid = NO;
    NSString *text = nil;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &own) != errSecSuccess ||
        SecCodeCopyStaticCode(own, kSecCSDefaultFlags, &ownStatic) != errSecSuccess ||
        SecCodeCopyDesignatedRequirement(ownStatic, kSecCSDefaultFlags, &requirement) != errSecSuccess ||
        SecRequirementCopyString(requirement, kSecCSDefaultFlags, &raw) != errSecSuccess) goto done;
    text = (__bridge NSString *)raw;
    if (![text containsString:@"identifier \"dev.nearclip.updater\""] ||
        ![text containsString:@"certificate"] || [text containsString:@"cdhash"]) goto done;
    text = [text stringByReplacingOccurrencesOfString:@"identifier \"dev.nearclip.updater\"" withString:@"identifier \"dev.nearclip.mac\""];
    if (SecRequirementCreateWithString((__bridge CFStringRef)text, kSecCSDefaultFlags, &hostRequirement) != errSecSuccess ||
        SecStaticCodeCreateWithPath((__bridge CFURLRef)url, kSecCSDefaultFlags, &host) != errSecSuccess) goto done;
    valid = SecStaticCodeCheckValidity(host, kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode,
                                      hostRequirement) == errSecSuccess;
done:
    if (own) CFRelease(own); if (ownStatic) CFRelease(ownStatic); if (host) CFRelease(host);
    if (requirement) CFRelease(requirement); if (hostRequirement) CFRelease(hostRequirement); if (raw) CFRelease(raw);
    return valid;
}

@interface UpdaterDelegate : NSObject <NSApplicationDelegate, SPUUpdaterDelegate>
@property(nonatomic, strong) SPUUpdater *updater;
@property(nonatomic, strong) NSBundle *host;
@property(nonatomic) BOOL probe;
@property(nonatomic) BOOL found;
@end
@implementation UpdaterDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    NSArray *args = NSProcessInfo.processInfo.arguments;
    self.probe = [args containsObject:@"--probe"];
    BOOL diagnostic = self.probe || [args containsObject:@"--configuration-check"];
    [NSApp setActivationPolicy:diagnostic ? NSApplicationActivationPolicyProhibited : NSApplicationActivationPolicyAccessory];
    // The only target is the signed app containing this helper. No arbitrary
    // target paths, executable commands, or update URLs are accepted.
    NSURL *url = NSBundle.mainBundle.bundleURL.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent;
    self.host = [NSBundle bundleWithURL:url];
    NSDictionary *info = self.host.infoDictionary;
    BOOL configured = [self.host.bundleIdentifier isEqualToString:@"dev.nearclip.mac"] &&
        [info[@"SUFeedURL"] isEqualToString:Feed] &&
        [[NSData alloc] initWithBase64EncodedString:info[@"SUPublicEDKey"] ?: @"" options:0].length == 32 &&
        [info[@"SUVerifyUpdateBeforeExtraction"] boolValue] && [info[@"SURequireSignedFeed"] boolValue] &&
        [info[@"SURequireFeedBundleIdentifier"] boolValue] &&
        [info[@"SUSignedFeedFailureExpirationInterval"] isEqual:@0];
    if (!configured || !validHost(url)) {
        if (!diagnostic) {
            NSAlert *alert = [NSAlert new]; alert.messageText = @"업데이트 구성요소를 확인할 수 없어요.";
            alert.informativeText = @"공식 NearClip 앱을 다시 설치해 주세요. 기존 앱은 변경하지 않았어요.";
            [alert runModal];
        }
        fprintf(stderr, "FAIL: update configuration or host signature invalid.\n"); exit(2);
    }
    if ([args containsObject:@"--configuration-check"]) {
        printf("PASS: signed host, pinned feed, archive verification and signed-feed policy.\n"); exit(0);
    }
    SPUStandardUserDriver *driver = [[SPUStandardUserDriver alloc] initWithHostBundle:self.host delegate:nil];
    self.updater = [[SPUUpdater alloc] initWithHostBundle:self.host applicationBundle:self.host userDriver:driver delegate:self];
    NSError *error = nil;
    if (![self.updater startUpdater:&error]) {
        if (!diagnostic) { NSAlert *alert = [NSAlert alertWithError:error]; [alert runModal]; }
        fprintf(stderr, "FAIL: updater could not start.\n"); exit(2);
    }
    if (self.probe) [self.updater checkForUpdateInformation];
    else { [NSApp activateIgnoringOtherApps:YES]; [self.updater checkForUpdates]; }
}
- (NSString *)feedURLStringForUpdater:(SPUUpdater *)updater {
    (void)updater;
#ifdef NEARCLIP_UPDATE_TESTING
    // Used only in a separately signed local test fixture, never distribution.
    NSString *test = self.host.infoDictionary[@"NearClipTestFeedURL"];
    if ([test hasPrefix:@"http://127.0.0.1:"]) return test;
#endif
    return Feed;
}
- (BOOL)updater:(SPUUpdater *)updater shouldProceedWithUpdate:(SUAppcastItem *)item updateCheck:(SPUUpdateCheck)check error:(NSError **)error {
    (void)updater; (void)check;
    NSURL *url = item.fileURL;
    BOOL trusted = [url.scheme isEqualToString:@"https"] && [url.host isEqualToString:@"github.com"] &&
        [url.path hasPrefix:@"/iyk2h/nearclip/releases/download/"] && !url.user && !url.password && !url.port && !url.query && !url.fragment;
#ifdef NEARCLIP_UPDATE_TESTING
    trusted = trusted || ([url.scheme isEqualToString:@"http"] && [url.host isEqualToString:@"127.0.0.1"]);
#endif
    if (!trusted && error) *error = [NSError errorWithDomain:@"dev.nearclip.updater" code:1 userInfo:@{NSLocalizedDescriptionKey:@"공식 배포 주소가 아닌 업데이트는 설치할 수 없어요."}];
    return trusted;
}
- (void)updater:(SPUUpdater *)updater didFindValidUpdate:(SUAppcastItem *)item { (void)updater; (void)item; self.found = YES; }
- (void)updater:(SPUUpdater *)updater didFinishUpdateCycleForUpdateCheck:(SPUUpdateCheck)check error:(NSError *)error {
    (void)updater; (void)check;
    if (self.probe) {
        if (self.found && !error) { printf("PASS: authenticated update available.\n"); exit(0); }
        if (error && error.code != SUNoUpdateError) { fprintf(stderr, "FAIL: update feed rejected (%ld).\n", (long)error.code); exit(2); }
        printf("PASS: no newer eligible update.\n"); exit(1);
    }
    [NSApp terminate:nil];
}
@end
int main(void) {
    @autoreleasepool { NSApplication *app = NSApplication.sharedApplication; UpdaterDelegate *delegate = [UpdaterDelegate new]; app.delegate = delegate; [app run]; }
    return 0;
}
