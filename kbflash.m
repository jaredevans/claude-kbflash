// kbflash — breathe the MacBook keyboard backlight N times (default 5).
// Uses the private CoreBrightness framework; no public API exists for this.
//
// Sequence: save current brightness → set to maximum → breathe (fade down,
// hold 1 s at off, fade up) → restore original brightness and turn
// auto-brightness on.
//
// Build: clang -framework Foundation -o kbflash kbflash.m
// Usage: ./kbflash [count]     count 0 = breathe until SIGTERM/SIGINT
//        ./kbflash -w [count]  breathe count times, then backlight off and
//                              wait for SIGTERM/SIGINT
//
// On SIGTERM/SIGINT the current breath (or the -w dark wait) is abandoned
// and brightness is restored before exit, so killing the process always
// leaves the keyboard in its original state.

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <signal.h>

@interface KeyboardBrightnessClient : NSObject
- (NSArray<NSNumber *> *)copyKeyboardBacklightIDs;
- (float)brightnessForKeyboard:(uint64_t)keyboardID;
- (BOOL)setBrightness:(float)brightness forKeyboard:(uint64_t)keyboardID;
- (BOOL)enableAutoBrightness:(BOOL)enable forKeyboard:(uint64_t)keyboardID;
@end

static volatile sig_atomic_t gStop = 0;
static void onSignal(int sig) { (void)sig; gStop = 1; }

int main(int argc, char *argv[]) {
    @autoreleasepool {
        int count = 5;
        BOOL waitAfter = NO; // -w: after the breaths, backlight off until signaled
        int argi = 1;
        if (argi < argc && strcmp(argv[argi], "-w") == 0) {
            waitAfter = YES;
            count = 2;
            argi++;
        }
        if (argi < argc) {
            count = atoi(argv[argi]);
            if (count < 0) count = 5;
        }

        // No SA_RESTART: a signal must interrupt usleep so we react promptly.
        struct sigaction sa = { .sa_handler = onSignal };
        sigaction(SIGTERM, &sa, NULL);
        sigaction(SIGINT, &sa, NULL);

        if (!dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)) {
            fprintf(stderr, "kbflash: failed to load CoreBrightness framework\n");
            return 1;
        }
        Class cls = NSClassFromString(@"KeyboardBrightnessClient");
        if (!cls) {
            fprintf(stderr, "kbflash: KeyboardBrightnessClient class not found\n");
            return 1;
        }
        KeyboardBrightnessClient *client = [[cls alloc] init];
        NSArray<NSNumber *> *ids = [client copyKeyboardBacklightIDs];
        if (ids.count == 0) {
            fprintf(stderr, "kbflash: no backlit keyboard found\n");
            return 1;
        }

        NSMutableDictionary<NSNumber *, NSNumber *> *savedBrightness = [NSMutableDictionary dictionary];
        for (NSNumber *kid in ids) {
            float b = [client brightnessForKeyboard:kid.unsignedLongLongValue];
            savedBrightness[kid] = @(b);
            printf("backlight brightness level saved (%.2f)\n", b);
        }

        for (NSNumber *kid in ids) [client setBrightness:1.0f forKeyboard:kid.unsignedLongLongValue];
        printf("backlight brightness level set to 1 (maximum)\n");

        if (count == 0) printf("start flashing (until stopped)\n");
        else            printf("start flashing (%d breaths)\n", count);
        // One breath = fade max -> off, hold at off for 1 s, fade off -> max.
        const int rampSteps = 30;
        const useconds_t stepDelay = 25000;   // 30 steps x 25 ms = ~0.75 s per ramp
        const useconds_t holdDelay = 1000000; // 1 s at lowest brightness
        for (int i = 0; (count == 0 || i < count) && !gStop; i++) {
            for (int s = 1; s <= rampSteps && !gStop; s++) {
                float b = (1.0f + cosf((float)M_PI * s / rampSteps)) / 2.0f;
                for (NSNumber *kid in ids) [client setBrightness:b forKeyboard:kid.unsignedLongLongValue];
                usleep(stepDelay);
            }
            if (!gStop) usleep(holdDelay);
            for (int s = 1; s <= rampSteps && !gStop; s++) {
                float b = (1.0f - cosf((float)M_PI * s / rampSteps)) / 2.0f;
                for (NSNumber *kid in ids) [client setBrightness:b forKeyboard:kid.unsignedLongLongValue];
                usleep(stepDelay);
            }
        }

        if (waitAfter && !gStop) {
            // Breaths end at max; ease down to off rather than snapping.
            for (int s = 1; s <= rampSteps && !gStop; s++) {
                float b = (1.0f + cosf((float)M_PI * s / rampSteps)) / 2.0f;
                for (NSNumber *kid in ids) [client setBrightness:b forKeyboard:kid.unsignedLongLongValue];
                usleep(stepDelay);
            }
            for (NSNumber *kid in ids) [client setBrightness:0.0f forKeyboard:kid.unsignedLongLongValue];
            printf("backlight off, waiting for stop signal\n");
            while (!gStop) pause();
        }

        for (NSNumber *kid in ids) {
            uint64_t k = kid.unsignedLongLongValue;
            [client setBrightness:savedBrightness[kid].floatValue forKeyboard:k];
            [client enableAutoBrightness:YES forKeyboard:k];
        }
        printf("flashing ended, brightness restored to original (%.2f), auto-brightness on\n",
               savedBrightness.allValues.firstObject.floatValue);
        return 0;
    }
}
