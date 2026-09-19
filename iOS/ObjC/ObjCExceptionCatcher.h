#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Rattrape une exception Objective-C (NSException) levée par un framework Apple, injoignable depuis Swift.
/// Sans ça, `installTap` ou `AVAudioEngine.start` sur un format audio invalide fait avorter l'app.
@interface ObjCExceptionCatcher : NSObject
+ (BOOL)tryBlock:(void (NS_NOESCAPE ^)(void))block error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(run(_:));
@end

NS_ASSUME_NONNULL_END
