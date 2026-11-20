#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

// Debug builds only: Enabled switch (the tweak reads it) and the log buttons.

static const NSUInteger kMaxCopyBytes = 512 * 1024; // the tail of the log is what matters

@interface FUBRootListController : PSListController
@end

@implementation FUBRootListController

- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    return _specifiers;
}

// The log is written into Safari's data container; its folder name is a UUID, so find the
// container whose metadata says it is Safari's.
static NSString *LogPath(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *root = @"/var/mobile/Containers/Data/Application";
    for (NSString *uuid in [fm contentsOfDirectoryAtPath:root error:NULL]) {
        NSString *meta = [NSString stringWithFormat:@"%@/%@/.com.apple.mobile_container_manager.metadata.plist", root, uuid];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:meta];
        if ([info[@"MCMMetadataIdentifier"] isEqual:@"com.apple.mobilesafari"]) {
            return [NSString stringWithFormat:@"%@/%@/tmp/SafariFullURL.log", root, uuid];
        }
    }
    return nil;
}

- (void)showAlert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// The path of an existing log, or an alert saying why there is none.
- (NSString *)existingLogPath {
    NSString *path = LogPath();
    if (!path) {
        [self showAlert:@"No log" message:@"Safari's data container was not found. Open Safari once."];
        return nil;
    }
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
        [self showAlert:@"No log" message:@"Nothing logged yet: open Safari and tap the address bar (this needs the debug build)."];
        return nil;
    }
    return path;
}

- (void)shareLog {
    NSString *path = [self existingLogPath];
    if (!path) return;
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data) {
        [self showAlert:@"Cannot read the log" message:path];
        return;
    }
    // Share a copy from this app's own temp folder, not the file in Safari's container.
    NSString *copy = [NSTemporaryDirectory() stringByAppendingPathComponent:@"SafariFullURL.log"];
    [data writeToFile:copy atomically:YES];
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[[NSURL fileURLWithPath:copy]] applicationActivities:nil];
    share.popoverPresentationController.sourceView = self.view; // iPad
    share.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    [self presentViewController:share animated:YES completion:nil];
}

- (void)copyLog {
    NSString *path = [self existingLogPath];
    if (!path) return;
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) {
        [self showAlert:@"Cannot read the log" message:path];
        return;
    }
    unsigned long long size = [handle seekToEndOfFile];
    unsigned long long start = size > kMaxCopyBytes ? size - kMaxCopyBytes : 0;
    [handle seekToFileOffset:start];
    NSData *data = [handle readDataToEndOfFile];
    [handle closeFile];
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    UIPasteboard.generalPasteboard.string = text;
    [self showAlert:@"Copied" message:[NSString stringWithFormat:@"%lu characters%@.", (unsigned long)text.length, start ? @" (the end of the log)" : @""]];
}

- (void)clearLog {
    NSString *path = [self existingLogPath];
    if (!path) return;
    // Truncate in place: Safari keeps the file open, a new file would never be written to.
    if (truncate(path.fileSystemRepresentation, 0) == 0) [self showAlert:@"Cleared" message:nil];
    else [self showAlert:@"Cannot clear the log" message:[NSString stringWithUTF8String:strerror(errno)]];
}

@end
