// Stable, narrowly scoped Keychain client. No app version or timestamps.
// Only the live, signed parent NearClip process may read/write this one item.
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <LocalAuthentication/LocalAuthentication.h>
#include <sys/stat.h>
#include <unistd.h>

static BOOL authorizedParent(void) {
    struct stat inStat, outStat;
    if (fstat(STDIN_FILENO, &inStat) || fstat(STDOUT_FILENO, &outStat) ||
        !S_ISFIFO(inStat.st_mode) || !S_ISFIFO(outStat.st_mode)) return NO;
    pid_t parent = getppid();
    if (parent <= 1) return NO;
    SecCodeRef own = NULL, caller = NULL;
    SecRequirementRef ownRequirement = NULL, required = NULL;
    CFStringRef ownText = NULL;
    BOOL valid = NO;
    NSString *text = nil, *identifier = @"identifier \"dev.nearclip.keystore\"";
    NSDictionary *attributes = nil;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &own) != errSecSuccess ||
        SecCodeCopyDesignatedRequirement(own, kSecCSDefaultFlags, &ownRequirement) != errSecSuccess ||
        SecRequirementCopyString(ownRequirement, kSecCSDefaultFlags, &ownText) != errSecSuccess) goto done;
    text = (__bridge NSString *)ownText;
    // Refuse ad-hoc requirements and unpinned caller identities.
    if (![text containsString:identifier] || ![text containsString:@"certificate"] || [text containsString:@"cdhash"]) goto done;
    text = [text stringByReplacingOccurrencesOfString:identifier withString:@"identifier \"dev.nearclip.mac\""];
    if (SecRequirementCreateWithString((__bridge CFStringRef)text, kSecCSDefaultFlags, &required) != errSecSuccess) goto done;
    attributes = @{(__bridge id)kSecGuestAttributePid: @(parent)};
    if (SecCodeCopyGuestWithAttributes(NULL, (__bridge CFDictionaryRef)attributes, kSecCSDefaultFlags, &caller) != errSecSuccess) goto done;
    valid = SecCodeCheckValidity(caller, kSecCSStrictValidate, required) == errSecSuccess && getppid() == parent;
done:
    if (own) CFRelease(own);
    if (caller) CFRelease(caller);
    if (ownRequirement) CFRelease(ownRequirement);
    if (required) CFRelease(required);
    if (ownText) CFRelease(ownText);
    return valid;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (!authorizedParent()) return 77;
        if (argc != 2) return 64;
        BOOL check = !strcmp(argv[1], "check");
        BOOL load = check || !strcmp(argv[1], "load");
        BOOL save = !strcmp(argv[1], "save");
        if (!load && !save) return 64;
        NSMutableDictionary *query = [@{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService: @"local.nearclip.pairing.v1",
            (__bridge id)kSecAttrAccount: @"pairing-code"
        } mutableCopy];
        OSStatus status;
        if (load) {
            query[(__bridge id)kSecReturnData] = @YES;
            query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
            if (check) {
                // This item uses the macOS file-based login Keychain. LAContext
                // alone does not suppress its legacy ACL confirmation dialog.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                if (SecKeychainSetUserInteractionAllowed(false) != errSecSuccess) return 1;
#pragma clang diagnostic pop
                LAContext *context = [LAContext new]; context.interactionNotAllowed = YES;
                query[(__bridge id)kSecUseAuthenticationContext] = context;
            }
            CFTypeRef result = NULL;
            status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
            if (status == errSecItemNotFound) return 2;
            if (status == errSecSuccess && result && CFGetTypeID(result) == CFDataGetTypeID()) {
                NSData *data = CFBridgingRelease(result);
                if (data.length != 32) return 65;
                if (!check && fwrite(data.bytes, 1, data.length, stdout) != data.length) return 74;
                return 0;
            }
            if (result) CFRelease(result);
        } else {
            unsigned char bytes[33] = {0};
            size_t count = fread(bytes, 1, sizeof(bytes), stdin);
            if (count != 32) return 65;
            for (size_t i = 0; i < count; ++i) {
                if (!((bytes[i] >= '0' && bytes[i] <= '9') || (bytes[i] >= 'A' && bytes[i] <= 'F'))) return 65;
            }
            NSData *data = [NSData dataWithBytes:bytes length:count];
            memset_s(bytes, sizeof(bytes), 0, sizeof(bytes));
            status = SecItemUpdate((__bridge CFDictionaryRef)query,
                (__bridge CFDictionaryRef)@{(__bridge id)kSecValueData: data});
            if (status == errSecItemNotFound) {
                query[(__bridge id)kSecValueData] = data;
                query[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
                status = SecItemAdd((__bridge CFDictionaryRef)query, NULL);
            }
            if (status == errSecSuccess) return 0;
        }
        // Error numbers only; never emit secret bytes or item metadata on failure.
        fprintf(stderr, "Keychain status=%d\n", (int)status);
        return 1;
    }
}
