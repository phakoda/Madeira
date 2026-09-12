#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include "embedded.h"
#include "ios_view.h"
#include <vector>

@interface MadeiraWine32Probe : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow* window;
@property(nonatomic, strong) CADisplayLink* clock;
@property(nonatomic, strong) NSURL* documents;
@property(nonatomic, strong) NSURL* payload;
@property(nonatomic, strong) NSArray<NSDictionary*>* stages;
@property(nonatomic) NSUInteger stage;
@property(nonatomic) CFTimeInterval started;
@property(nonatomic) BOOL pumping;
@end

@implementation MadeiraWine32Probe
- (void)record:(NSString*)status detail:(NSString*)detail {
    NSDictionary* result = @{@"status":status, @"detail":detail ?: @"",
        @"completedStages":@(self.stage), @"totalStages":@(self.stages.count)};
    NSData* data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToURL:[self.documents URLByAppendingPathComponent:@"wine32-result.json"] options:NSDataWritingAtomic error:nil];
    NSLog(@"Wine32 %@: %@", status, detail);
}
- (void)fail:(NSString*)detail {
    [self.clock invalidate];
    self.clock = nil;
    madeira_wine32_stop();
    [self record:@"failed" detail:detail];
}
- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [UIViewController new];
    self.window.rootViewController.view.backgroundColor = UIColor.blackColor;
    [self.window makeKeyAndVisible];
    madeira_wine32_set_view_host(self.window.rootViewController);
    self.documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    self.payload = [self.documents URLByAppendingPathComponent:@"payload" isDirectory:YES];
    self.stages = @[
        @{@"name":@"runtime", @"args":@[@"D:\\probe.exe"], @"file":@"32 bit result.txt", @"expected":@"native-x86-wine-memory-threads-registry-file-ok"},
        @{@"name":@"msi", @"args":@[@"cmd", @"/c", @"D:\\install.cmd"], @"file":@"installer-result.txt", @"expected":@"msi-installed-ok"},
        @{@"name":@"installed", @"args":@[@"C:\\Program Files\\Madeira32Probe\\probe.exe"], @"file":@"32 bit result.txt", @"expected":@"native-x86-wine-memory-threads-registry-file-ok"},
        @{@"name":@"graphics", @"args":@[@"D:\\graphics.exe"], @"file":@"graphics result.txt", @"expected":@"native-x86-d3d9-render-target-pixels-ok"}
    ];
    NSError* error = nil;
    NSURL* bundled = [NSBundle.mainBundle URLForResource:@"payload" withExtension:nil];
    if (!bundled || ![NSFileManager.defaultManager copyItemAtURL:bundled toURL:self.payload error:&error]) {
        [self fail:error.localizedDescription ?: @"Missing Windows fixtures"];
        return YES;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ [self startStage]; });
    return YES;
}
- (void)startStage {
    if (self.stage == self.stages.count) {
        [self.clock invalidate];
        self.clock = nil;
        [self record:@"passed" detail:@"Wine32 runtime, MSI, installed EXE, and Direct3D 9 completed in the iOS host"];
        return;
    }
    NSDictionary* stage = self.stages[self.stage];
    [NSFileManager.defaultManager removeItemAtURL:[self.payload URLByAppendingPathComponent:stage[@"file"]] error:nil];
    NSURL* prefix = [self.documents URLByAppendingPathComponent:@"prefix" isDirectory:YES];
    NSError* error = nil;
    if (![NSFileManager.defaultManager createDirectoryAtURL:prefix withIntermediateDirectories:YES attributes:nil error:&error]) {
        [self fail:error.localizedDescription]; return;
    }
    NSString* rootfs = [NSBundle.mainBundle pathForResource:@"wine11" ofType:@"zip"];
    NSString* graphics = [NSBundle.mainBundle pathForResource:@"madeira-graphics" ofType:@"zip"];
    if (!rootfs || !graphics) { [self fail:@"Missing Wine32 filesystem or guest graphics bridge"]; return; }
    NSMutableArray<NSString*>* arguments = [@[@"madeira-wine32", @"-root", prefix.path,
        @"-zip", graphics, @"-zip", rootfs,
        @"-mount_drive", self.payload.path, @"d", @"-opengl", @"osmesa", @"-nosound",
        @"-env", @"WINEDEBUG=-all,err+all", @"-env", @"WINEDLLOVERRIDES=mscoree,mshtml=",
        @"-env", @"MADEIRA_VERIFY_PRESENTATION=1", @"/bin/wine"] mutableCopy];
    [arguments addObjectsFromArray:stage[@"args"]];
    std::vector<const char*> argv;
    for (NSString* argument in arguments) argv.push_back(argument.UTF8String);
    [self record:@"running" detail:stage[@"name"]];
    if (!madeira_wine32_start((int)argv.size(), argv.data())) {
        [self fail:[NSString stringWithUTF8String:madeira_wine32_error()]]; return;
    }
    self.started = CACurrentMediaTime();
    if (!self.clock) {
        self.clock = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
        [self.clock addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
}
- (void)tick:(CADisplayLink*)clock {
    if (self.pumping) return;
    self.pumping = YES;
    const int state = madeira_wine32_tick();
    self.pumping = NO;
    NSDictionary* stage = self.stages[self.stage];
    NSString* actual = [NSString stringWithContentsOfURL:[self.payload URLByAppendingPathComponent:stage[@"file"]]
        encoding:NSUTF8StringEncoding error:nil];
    if ([[actual stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] isEqualToString:stage[@"expected"]]) {
        if (!madeira_wine32_stop()) { [self fail:[NSString stringWithUTF8String:madeira_wine32_error()]]; return; }
        self.stage++;
        [self startStage];
    } else if (state < 0) {
        [self fail:[NSString stringWithUTF8String:madeira_wine32_error()]];
    } else if (state == 0) {
        [self fail:[NSString stringWithFormat:@"%@ exited without its expected result", stage[@"name"]]];
    } else if (CACurrentMediaTime() - self.started > 300) {
        [self fail:[NSString stringWithFormat:@"%@ timed out", stage[@"name"]]];
    }
}
@end

int main(int argc, char** argv) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(MadeiraWine32Probe.class));
    }
}
