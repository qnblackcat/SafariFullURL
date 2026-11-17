#pragma once
#import <UIKit/UIKit.h>

// Safari (iPhone, bottom tab bar layout): while editing, the URL field wraps onto
// several lines and the capsule, its keyboard backdrop and the input accessory
// spacer grow upward to match.

#ifndef SAFARIFULLURL_DEBUG
#define SAFARIFULLURL_DEBUG 0
#endif

// Shared between the source files, not exported from the dylib.
#define FUB_HIDDEN __attribute__((visibility("hidden")))

#if SAFARIFULLURL_DEBUG
// Debug builds log to <Safari container>/tmp/SafariFullURL.log (path is printed via NSLog
// on launch) and to NSLog with the [SafariFullURL] prefix.
FUB_HIDDEN void FUBLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
#define LOG(...) FUBLog(__VA_ARGS__)
#else
#define LOG(...) do {} while (0)
#endif

@interface UnifiedField : UITextField
@property (nonatomic, assign) CGFloat fub_extra;      // extra height for lines beyond the first
@property (nonatomic, assign) BOOL fub_fits;          // all lines fit in the grown field
@property (nonatomic, assign) CGFloat fub_contentHeight; // height of all the text (with padding) when it does not fit
@property (nonatomic, assign) CGFloat fub_baseHeight; // stock one-line capsule height, read before growing
@property (nonatomic, assign) BOOL fub_wrapped;       // we switched the field editor to wrapping
@property (nonatomic, assign) NSInteger fub_savedLineBreakMode;
@property (nonatomic, strong) NSParagraphStyle *fub_savedParagraphStyle;
@property (nonatomic, assign) BOOL fub_expanded;      // second tap (or an edit) unfolded the full URL
@property (nonatomic, assign) BOOL fub_sawSelectAll;  // Safari selected the whole URL after focusing
- (UIScrollView *)_fieldEditor;
@end

@interface UIFieldEditor : UIScrollView <UITextInput>
@property (nonatomic, readonly) NSTextContainer *textContainer;
- (CGPoint)textContainerOrigin;
@end

@interface UITextInteractionAssistant : NSObject
- (UIView *)view;
@end

@interface UITextSelectionView : UIView
- (UITextInteractionAssistant *)interactionAssistant;
@end

@interface _UITextInteractionEditMenuAssistant : NSObject // iOS 17+
@property (readonly, weak, nonatomic) UITextInteractionAssistant *interactionAssistant;
@end

@interface SFCapsuleView : UIView
@property (nonatomic, retain) UIView *contentView;
@end

@interface SFCapsuleURLField : UIView
@property (nonatomic, readonly) UITextField *textField;
- (void)setShowsVoiceSearchButton:(BOOL)shows;
@end

@interface SFCapsuleInputAccessorySpacerView : UIView
@property (nonatomic) double capsuleHeight;
@end

@interface SFCapsuleCollectionView : UIView
- (void)_layOutKeyboardBackdrop;
@end

// Tweak.xm
FUB_HIDDEN extern CGFloat gExtra;   // extra height of the field being edited
FUB_HIDDEN extern BOOL gUpdating;   // caret rect queries can lay out again and call back into us

FUB_HIDDEN UnifiedField *GrownField(UITextField *tf);
FUB_HIDDEN UnifiedField *GrownFieldInEditor(UIFieldEditor *fe);
FUB_HIDDEN UnifiedField *WrappedFieldInEditor(UIFieldEditor *fe);
FUB_HIDDEN UnifiedField *GrownFieldForCapsule(SFCapsuleView *capsule);
FUB_HIDDEN SFCapsuleView *CapsuleOf(UIView *view);
FUB_HIDDEN BOOL PinsOffset(UnifiedField *field);
FUB_HIDDEN BOOL ScrollsVertically(UnifiedField *field);
FUB_HIDDEN CGPoint ClampedOffset(UnifiedField *field, UIFieldEditor *fe, CGPoint offset);
FUB_HIDDEN void ScrollCaretVisible(UnifiedField *field);
FUB_HIDDEN void AutoScrollForFloatingCursor(UnifiedField *field, CGPoint point);
FUB_HIDDEN UITextPosition *EditorPosition(UnifiedField *field, CGPoint point, UITextRange *range);
FUB_HIDDEN CGFloat BaseHeight(UnifiedField *field);
FUB_HIDDEN CGFloat TopPad(UnifiedField *field);
FUB_HIDDEN void ApplyExtra(UnifiedField *field, CGFloat extra);
FUB_HIDDEN void UpdateFieldEditor(UIFieldEditor *fe);

#if SAFARIFULLURL_DEBUG
FUB_HIDDEN NSInteger Offset(UITextField *field, UITextPosition *position); // for logging
#endif
