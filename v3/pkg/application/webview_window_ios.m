//go:build ios
#import "webview_window_ios.h"
#import "application_ios.h"
#import "application_ios_delegate.h"
#import "../events/events_ios.h"
#import "mobile_features_ios_internal.h"
#import <stdlib.h>
#import <os/log.h>
extern void processApplicationEvent(unsigned int, void* data);
extern void iosEmitNativeEvent(const char* name, const char* json);
extern void processWindowEvent(unsigned int, unsigned int);
extern bool hasListeners(unsigned int);
extern void cancelURLRequest(void *);
// Buffer console messages until a WKWebView exists
static NSMutableArray<NSString *> *pendingConsoleJS;
@class WailsWebView;

@interface WailsEditorAccessoryView : UIView
- (instancetype)initWithWebView:(WailsWebView *)webView;
@end

// Subclass that optionally replaces the browser's generic input bar with the
// editor-specific accessory supplied by the frontend.
@interface WailsWebView : WKWebView
@property (nonatomic, assign) BOOL editorAccessoryVisible;
@property (nonatomic, strong) WailsEditorAccessoryView *editorAccessoryView;
@end
@implementation WailsWebView
- (UIView *)inputAccessoryView {
    if (self.editorAccessoryVisible) {
        if (!self.editorAccessoryView) {
            self.editorAccessoryView = [[WailsEditorAccessoryView alloc] initWithWebView:self];
        }
        return self.editorAccessoryView;
    }
    if (ios_is_input_accessory_disabled()) {
        return nil;
    }
    return [super inputAccessoryView];
}
- (void)setEditorAccessoryVisible:(BOOL)visible {
    if (_editorAccessoryVisible == visible) return;
    _editorAccessoryVisible = visible;
    dispatch_async(dispatch_get_main_queue(), ^{ [self reloadInputViews]; });
}
@end

@interface WailsEditorPhotoLibraryDelegate : NSObject <UIImagePickerControllerDelegate, UINavigationControllerDelegate>
@property (nonatomic, weak) WailsWebView *webView;
@end

static WailsEditorPhotoLibraryDelegate *activeEditorPhotoLibraryDelegate = nil;

@implementation WailsEditorPhotoLibraryDelegate
- (void)imagePickerController:(UIImagePickerController *)picker
        didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey, id> *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];
    UIImage *image = info[UIImagePickerControllerOriginalImage];
    NSData *imageData = UIImageJPEGRepresentation(image, 0.9);
    if (!imageData.length || !self.webView) {
        activeEditorPhotoLibraryDelegate = nil;
        return;
    }

    NSString *fileName = [NSString stringWithFormat:@"editor_image_%@.jpg", [[NSUUID UUID] UUIDString]];
    NSString *filePath = [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
    if (![imageData writeToFile:filePath options:NSDataWritingAtomic error:nil]) {
        activeEditorPhotoLibraryDelegate = nil;
        return;
    }

    NSDictionary *detail = @{ @"command": @"image-picked", @"payload": @{ @"filePath": filePath } };
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:detail options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    if (json.length) {
        NSString *javascript = [NSString stringWithFormat:@"window.dispatchEvent(new CustomEvent('multisafe:editor-accessory-command',{detail:%@}));", json];
        [self.webView evaluateJavaScript:javascript completionHandler:nil];
    }
    activeEditorPhotoLibraryDelegate = nil;
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
    activeEditorPhotoLibraryDelegate = nil;
}
@end

@interface WailsEditorAccessoryView ()
- (void)showPhotoLibrary;
@property (nonatomic, weak) WailsWebView *webView;
@property (nonatomic, strong) UIView *toolbar;
@property (nonatomic, strong) UIView *commandPalette;
@property (nonatomic, strong) UIView *inlineLinkPanel;
@property (nonatomic, strong) UIControl *paletteDismissOverlay;
@property (nonatomic, strong) UITextField *inlineLinkURLField;
@property (nonatomic, strong) UITextField *inlineLinkLabelField;
@property (nonatomic, strong) UIButton *inlineLinkInsertButton;
@property (nonatomic, assign) CGFloat commandPaletteHeight;
@property (nonatomic, assign) CGFloat commandPaletteGap;
@end

@implementation WailsEditorAccessoryView
- (instancetype)initWithWebView:(WailsWebView *)webView {
    self = [super initWithFrame:CGRectMake(0, 0, 0, 50)];
    if (self) {
        _webView = webView;
        _commandPaletteGap = 8.0;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        self.backgroundColor = [UIColor colorWithRed:45.0 / 255.0 green:45.0 / 255.0 blue:49.0 / 255.0 alpha:1.0];
        self.toolbar = [[UIView alloc] initWithFrame:CGRectZero];
        self.toolbar.translatesAutoresizingMaskIntoConstraints = NO;
        self.toolbar.backgroundColor = self.backgroundColor;
        [self addSubview:self.toolbar];
        [NSLayoutConstraint activateConstraints:@[
            [self.toolbar.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [self.toolbar.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [self.toolbar.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [self.toolbar.heightAnchor constraintEqualToConstant:50],
        ]];
        UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        stack.axis = UILayoutConstraintAxisHorizontal;
        stack.alignment = UIStackViewAlignmentCenter;
        stack.spacing = 8;
        [self.toolbar addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:self.toolbar.leadingAnchor constant:12],
            [stack.topAnchor constraintEqualToAnchor:self.toolbar.topAnchor],
            [stack.bottomAnchor constraintEqualToAnchor:self.toolbar.bottomAnchor],
        ]];
        NSArray<NSArray<NSString *> *> *parents = @[
            @[@"format", @"Formatting", @"textformat"],
            @[@"insert", @"Insert", @"plus.square"],
            @[@"undo", @"Undo", @"arrow.counterclockwise"],
        ];
        for (NSArray<NSString *> *parent in parents) {
            UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
            button.accessibilityLabel = parent[1];
            button.accessibilityIdentifier = parent[0];
            button.tintColor = [UIColor colorWithRed:199.0 / 255.0 green:199.0 / 255.0 blue:204.0 / 255.0 alpha:1.0];
            [button setImage:[UIImage systemImageNamed:parent[2]] forState:UIControlStateNormal];
            SEL action = [parent[0] isEqualToString:@"undo"] ? @selector(commandTapped:) : @selector(showCommandPalette:);
            [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
            [button.widthAnchor constraintEqualToConstant:44].active = YES;
            [button.heightAnchor constraintEqualToConstant:44].active = YES;
            [stack addArrangedSubview:button];
        }
    }
    return self;
}
- (CGSize)intrinsicContentSize {
    CGFloat paletteGap = self.commandPaletteHeight > 0 ? self.commandPaletteGap : 0;
    return CGSizeMake(UIViewNoIntrinsicMetric, 50 + self.commandPaletteHeight + paletteGap);
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if ([super pointInside:point withEvent:event]) {
        return YES;
    }
    return (self.commandPalette && CGRectContainsPoint(self.commandPalette.frame, point)) ||
        (self.inlineLinkPanel && CGRectContainsPoint(self.inlineLinkPanel.frame, point));
}
- (void)refreshAccessoryHeight {
    CGSize size = self.intrinsicContentSize;
    CGRect frame = self.frame;
    frame.size.height = size.height;
    self.frame = frame;
    [self invalidateIntrinsicContentSize];
    [self setNeedsLayout];
    [self.webView reloadInputViews];
}
- (void)showCommandPalette:(UIButton *)button {
    NSArray<NSDictionary<NSString *, NSString *> *> *items;
    NSInteger columns;
    if ([button.accessibilityIdentifier isEqualToString:@"format"]) {
        columns = 4;
        items = @[
            @{ @"command": @"heading-1", @"title": @"Heading 1", @"label": @"H1" },
            @{ @"command": @"heading-2", @"title": @"Heading 2", @"label": @"H2" },
            @{ @"command": @"heading-3", @"title": @"Heading 3", @"label": @"H3" },
            @{ @"command": @"heading-4", @"title": @"Heading 4", @"label": @"H4" },
            @{ @"command": @"bold", @"title": @"Bold", @"symbol": @"bold" },
            @{ @"command": @"italic", @"title": @"Italic", @"symbol": @"italic" },
            @{ @"command": @"strikethrough", @"title": @"Strikethrough", @"symbol": @"strikethrough" },
            @{ @"command": @"highlight", @"title": @"Highlight", @"symbol": @"highlighter" },
            @{ @"command": @"bulleted-list", @"title": @"Bulleted list", @"symbol": @"list.bullet" },
            @{ @"command": @"numbered-list", @"title": @"Numbered list", @"symbol": @"list.number" },
            @{ @"command": @"code-inline", @"title": @"Inline code", @"symbol": @"curlybraces" },
            @{ @"command": @"code-block", @"title": @"Code block", @"symbol": @"ellipsis.curlybraces" },
        ];
    } else {
        columns = 4;
        items = @[
            @{ @"command": @"image", @"title": @"Add image", @"symbol": @"photo.badge.plus" },
            @{ @"command": @"link", @"title": @"Add link", @"symbol": @"link.badge.plus" },
            @{ @"command": @"table", @"title": @"Add table", @"symbol": @"tablecells" },
            @{ @"command": @"wiki-link", @"title": @"Add wiki link", @"symbol": @"doc.badge.plus" },
        ];
    }

    [self showEmbeddedCommandPaletteWithItems:items columns:columns];
}
- (void)showEmbeddedCommandPaletteWithItems:(NSArray<NSDictionary<NSString *, NSString *> *> *)items columns:(NSInteger)columns {
    [self.commandPalette removeFromSuperview];
    [self.paletteDismissOverlay removeFromSuperview];
    NSInteger rowCount = (items.count + columns - 1) / columns;
    self.commandPaletteHeight = rowCount * 50.0 + 14.0;

    UIControl *dismissOverlay = [[UIControl alloc] initWithFrame:CGRectZero];
    dismissOverlay.translatesAutoresizingMaskIntoConstraints = NO;
    dismissOverlay.accessibilityLabel = @"Dismiss editor menu";
    [dismissOverlay addTarget:self action:@selector(dismissPaletteTapped) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:dismissOverlay];
    self.paletteDismissOverlay = dismissOverlay;
    [NSLayoutConstraint activateConstraints:@[
        [dismissOverlay.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [dismissOverlay.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [dismissOverlay.topAnchor constraintEqualToAnchor:self.topAnchor],
        [dismissOverlay.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];

    UIView *palette = [[UIView alloc] initWithFrame:CGRectZero];
    palette.translatesAutoresizingMaskIntoConstraints = NO;
    palette.backgroundColor = [UIColor colorWithRed:45.0 / 255.0 green:45.0 / 255.0 blue:49.0 / 255.0 alpha:1.0];
    palette.layer.cornerRadius = 10;
    palette.layer.cornerCurve = kCACornerCurveContinuous;
    palette.layer.masksToBounds = YES;
    [self addSubview:palette];
    self.commandPalette = palette;
    [NSLayoutConstraint activateConstraints:@[
        [palette.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8],
        [palette.widthAnchor constraintEqualToConstant:columns * 60.0 + 14.0],
        [palette.bottomAnchor constraintEqualToAnchor:self.toolbar.topAnchor constant:-self.commandPaletteGap],
        [palette.heightAnchor constraintEqualToConstant:self.commandPaletteHeight],
    ]];

    UIStackView *grid = [[UIStackView alloc] initWithFrame:CGRectZero];
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    grid.axis = UILayoutConstraintAxisVertical;
    grid.spacing = 5;
    grid.distribution = UIStackViewDistributionFillEqually;
    [palette addSubview:grid];
    [NSLayoutConstraint activateConstraints:@[
        [grid.topAnchor constraintEqualToAnchor:palette.topAnchor constant:7],
        [grid.leadingAnchor constraintEqualToAnchor:palette.leadingAnchor constant:7],
        [grid.trailingAnchor constraintEqualToAnchor:palette.trailingAnchor constant:-7],
        [grid.bottomAnchor constraintEqualToAnchor:palette.bottomAnchor constant:-7],
    ]];
    for (NSInteger rowStart = 0; rowStart < items.count; rowStart += columns) {
        UIStackView *row = [[UIStackView alloc] initWithFrame:CGRectZero];
        row.axis = UILayoutConstraintAxisHorizontal;
        row.spacing = 5;
        row.distribution = UIStackViewDistributionFillEqually;
        [grid addArrangedSubview:row];
        for (NSInteger column = 0; column < columns; column++) {
            NSInteger itemIndex = rowStart + column;
            if (itemIndex >= items.count) {
                [row addArrangedSubview:[[UIView alloc] initWithFrame:CGRectZero]];
                continue;
            }
            NSDictionary<NSString *, NSString *> *item = items[itemIndex];
            UIButton *commandButton = [UIButton buttonWithType:UIButtonTypeSystem];
            commandButton.accessibilityLabel = item[@"title"];
            commandButton.accessibilityIdentifier = item[@"command"];
            commandButton.tintColor = [UIColor colorWithRed:220.0 / 255.0 green:220.0 / 255.0 blue:224.0 / 255.0 alpha:1.0];
            commandButton.titleLabel.font = [UIFont monospacedSystemFontOfSize:18 weight:UIFontWeightMedium];
            if (item[@"symbol"].length) {
                [commandButton setImage:[UIImage systemImageNamed:item[@"symbol"]] forState:UIControlStateNormal];
            } else {
                [commandButton setTitle:item[@"label"] forState:UIControlStateNormal];
            }
            [commandButton addTarget:self action:@selector(commandTapped:) forControlEvents:UIControlEventTouchUpInside];
            [row addArrangedSubview:commandButton];
        }
    }
    [self refreshAccessoryHeight];
}
- (void)hideEmbeddedCommandPalette {
    [self.commandPalette removeFromSuperview];
    self.commandPalette = nil;
    [self.paletteDismissOverlay removeFromSuperview];
    self.paletteDismissOverlay = nil;
    self.commandPaletteHeight = 0;
    [self refreshAccessoryHeight];
}
- (void)dismissPaletteTapped {
    if (self.inlineLinkPanel) {
        [self hideInlineLinkInsert];
        return;
    }
    [self hideEmbeddedCommandPalette];
}
- (void)commandTapped:(UIButton *)button {
    NSString *command = button.accessibilityIdentifier;
    if (self.commandPalette) {
        [self hideEmbeddedCommandPalette];
    }
    if ([command isEqualToString:@"link"]) {
        [self showInlineLinkInsert];
        return;
    }
    if ([command isEqualToString:@"image"]) {
        [self showPhotoLibrary];
        return;
    }
    [self sendCommand:command];
}

- (void)showPhotoLibrary {
    if (![UIImagePickerController isSourceTypeAvailable:UIImagePickerControllerSourceTypePhotoLibrary]) {
        return;
    }

    UIViewController *presenter = self.webView.window.rootViewController;
    while (presenter.presentedViewController && !presenter.presentedViewController.isBeingDismissed) {
        presenter = presenter.presentedViewController;
    }
    if (!presenter) {
        return;
    }

    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.mediaTypes = @[ @"public.image" ];
    activeEditorPhotoLibraryDelegate = [[WailsEditorPhotoLibraryDelegate alloc] init];
    activeEditorPhotoLibraryDelegate.webView = self.webView;
    picker.delegate = activeEditorPhotoLibraryDelegate;
    [presenter presentViewController:picker animated:YES completion:nil];
}
- (void)sendCommand:(NSString *)command {
    if (!command.length || !self.webView) return;
    NSString *javascript = [NSString stringWithFormat:@"window.dispatchEvent(new CustomEvent('multisafe:editor-accessory-command',{detail:{command:'%@'}}));", command];
    [self.webView evaluateJavaScript:javascript completionHandler:nil];
}
- (void)showInlineLinkInsert {
    self.commandPaletteHeight = 134;

    UIControl *dismissOverlay = [[UIControl alloc] initWithFrame:CGRectZero];
    dismissOverlay.translatesAutoresizingMaskIntoConstraints = NO;
    dismissOverlay.accessibilityLabel = @"Dismiss link insertion";
    [dismissOverlay addTarget:self action:@selector(dismissPaletteTapped) forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:dismissOverlay];
    self.paletteDismissOverlay = dismissOverlay;
    [NSLayoutConstraint activateConstraints:@[
        [dismissOverlay.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [dismissOverlay.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [dismissOverlay.topAnchor constraintEqualToAnchor:self.topAnchor],
        [dismissOverlay.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];

    UIView *panel = [[UIView alloc] initWithFrame:CGRectZero];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    panel.backgroundColor = [UIColor colorWithRed:45.0 / 255.0 green:45.0 / 255.0 blue:49.0 / 255.0 alpha:1.0];
    panel.layer.cornerRadius = 10;
    panel.layer.cornerCurve = kCACornerCurveContinuous;
    panel.layer.masksToBounds = YES;
    [self addSubview:panel];
    self.inlineLinkPanel = panel;
    [NSLayoutConstraint activateConstraints:@[
        [panel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8],
        [panel.widthAnchor constraintEqualToConstant:254],
        [panel.bottomAnchor constraintEqualToAnchor:self.toolbar.topAnchor constant:-self.commandPaletteGap],
        [panel.heightAnchor constraintEqualToConstant:self.commandPaletteHeight],
    ]];

    UIStackView *stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 6;
    [panel addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:panel.topAnchor constant:7],
        [stack.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:7],
        [stack.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-7],
        [stack.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor constant:-7],
    ]];

    self.inlineLinkURLField = [self inlineLinkTextFieldWithPlaceholder:@"URL" keyboardType:UIKeyboardTypeURL returnKey:UIReturnKeyNext];
    self.inlineLinkURLField.textContentType = UITextContentTypeURL;
    self.inlineLinkURLField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.inlineLinkURLField.autocorrectionType = UITextAutocorrectionTypeNo;
    [self.inlineLinkURLField addTarget:self action:@selector(focusInlineLinkLabel) forControlEvents:UIControlEventEditingDidEndOnExit];
    self.inlineLinkLabelField = [self inlineLinkTextFieldWithPlaceholder:@"Description (optional)" keyboardType:UIKeyboardTypeDefault returnKey:UIReturnKeyDone];
    [self.inlineLinkLabelField addTarget:self action:@selector(insertInlineLink) forControlEvents:UIControlEventEditingDidEndOnExit];
    [stack addArrangedSubview:self.inlineLinkURLField];
    [stack addArrangedSubview:self.inlineLinkLabelField];

    self.inlineLinkInsertButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.inlineLinkInsertButton setTitle:@"Insert" forState:UIControlStateNormal];
    self.inlineLinkInsertButton.configuration = [UIButtonConfiguration filledButtonConfiguration];
    [self.inlineLinkInsertButton addTarget:self action:@selector(insertInlineLink) forControlEvents:UIControlEventTouchUpInside];
    [self.inlineLinkInsertButton.heightAnchor constraintEqualToConstant:36].active = YES;
    [stack addArrangedSubview:self.inlineLinkInsertButton];
    [self updateInlineLinkInsertEnabled];
    [self refreshAccessoryHeight];
    dispatch_async(dispatch_get_main_queue(), ^{ [self.inlineLinkURLField becomeFirstResponder]; });
}
- (UITextField *)inlineLinkTextFieldWithPlaceholder:(NSString *)placeholder keyboardType:(UIKeyboardType)keyboardType returnKey:(UIReturnKeyType)returnKey {
    UITextField *field = [[UITextField alloc] initWithFrame:CGRectZero];
    field.borderStyle = UITextBorderStyleRoundedRect;
    field.placeholder = placeholder;
    field.keyboardType = keyboardType;
    field.returnKeyType = returnKey;
    field.inputAccessoryView = self;
    [field addTarget:self action:@selector(updateInlineLinkInsertEnabled) forControlEvents:UIControlEventEditingChanged];
    [field.heightAnchor constraintEqualToConstant:36].active = YES;
    return field;
}
- (void)focusInlineLinkLabel {
    [self.inlineLinkLabelField becomeFirstResponder];
}
- (void)updateInlineLinkInsertEnabled {
    NSString *url = [self.inlineLinkURLField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    self.inlineLinkInsertButton.enabled = url.length > 0;
}
- (void)hideInlineLinkInsert {
    [self.inlineLinkPanel removeFromSuperview];
    self.inlineLinkPanel = nil;
    self.inlineLinkURLField = nil;
    self.inlineLinkLabelField = nil;
    self.inlineLinkInsertButton = nil;
    [self.paletteDismissOverlay removeFromSuperview];
    self.paletteDismissOverlay = nil;
    self.commandPaletteHeight = 0;
    [self refreshAccessoryHeight];
}
- (void)insertInlineLink {
    NSString *url = [self.inlineLinkURLField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!url.length) return;
    NSString *label = [self.inlineLinkLabelField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{ @"url": url, @"label": label } options:0 error:&error];
    if (error || !data) return;
    NSString *payload = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    [self hideInlineLinkInsert];
    NSString *javascript = [NSString stringWithFormat:@"window.dispatchEvent(new CustomEvent('multisafe:editor-accessory-command',{detail:{command:'link-insert',payload:%@}}));", payload];
    [self.webView evaluateJavaScript:javascript completionHandler:nil];
}
@end

@interface WailsEditorAccessoryHandler : NSObject <WKScriptMessageHandler>
@property (nonatomic, weak) WailsWebView *webView;
@end
@implementation WailsEditorAccessoryHandler
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.body isKindOfClass:[NSDictionary class]]) return;
    BOOL visible = [((NSDictionary *)message.body)[@"visible"] boolValue];
    self.webView.editorAccessoryVisible = visible;
}
@end
// MARK: - WailsSchemeHandler
@implementation WailsSchemeHandler
- (instancetype)initWithWindowID:(unsigned int)windowID {
    self = [super init];
    if (self) {
        _windowID = windowID;
    }
    return self;
}
- (void)webView:(WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)urlSchemeTask {
    // Stream captured media (saved in NSTemporaryDirectory) straight from disk
    // with HTTP Range support, so <video> can stream/seek a clip of any length
    // without inlining it as a data URL.
    NSLog(@"[WailsSchemeHandler] start task url=%@", urlSchemeTask.request.URL.absoluteString ?: @"");
    if ([urlSchemeTask.request.URL.path hasPrefix:@"/__capture__/"]) {
        [self serveCaptureTask:urlSchemeTask];
        return;
    }
    ServeAssetRequest(self.windowID, (__bridge void*)urlSchemeTask);
}
- (void)serveCaptureTask:(id<WKURLSchemeTask>)task {
    NSURL *url = task.request.URL;
    // lastPathComponent strips any directory parts → only files directly in the
    // temp dir can be served (no path traversal).
    NSString *name = [url.path lastPathComponent];
    NSString *filePath = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSFileHandle *fh = [fm fileExistsAtPath:filePath]
        ? [NSFileHandle fileHandleForReadingAtPath:filePath] : nil;
    if (!fh) {
        NSHTTPURLResponse *r = [[NSHTTPURLResponse alloc] initWithURL:url statusCode:404
            HTTPVersion:@"HTTP/1.1" headerFields:@{}];
        [task didReceiveResponse:r];
        [task didFinish];
        return;
    }
    @try {
        unsigned long long length = [[fm attributesOfItemAtPath:filePath error:nil] fileSize];
        NSString *ext = [[name pathExtension] lowercaseString];
        NSString *mime = [ext isEqualToString:@"mp4"] ? @"video/mp4"
            : [ext isEqualToString:@"mov"] ? @"video/quicktime"
            : ([ext isEqualToString:@"jpg"] || [ext isEqualToString:@"jpeg"]) ? @"image/jpeg"
            : [ext isEqualToString:@"png"] ? @"image/png" : @"application/octet-stream";
        NSString *range = task.request.allHTTPHeaderFields[@"Range"];
        if (range && [range hasPrefix:@"bytes="]) {
            unsigned long long start = 0, end = length > 0 ? length - 1 : 0;
            NSArray<NSString *> *parts = [[range substringFromIndex:6] componentsSeparatedByString:@"-"];
            if (parts.count >= 1 && parts[0].length) start = strtoull(parts[0].UTF8String, NULL, 10);
            if (parts.count >= 2 && parts[1].length) end = strtoull(parts[1].UTF8String, NULL, 10);
            if (end >= length) end = length > 0 ? length - 1 : 0;
            if (start > end) start = 0;
            unsigned long long count = end - start + 1;
            [fh seekToFileOffset:start];
            NSData *data = [fh readDataOfLength:(NSUInteger)count];
            NSDictionary *headers = @{
                @"Content-Type": mime,
                @"Content-Length": [@(data.length) stringValue],
                @"Content-Range": [NSString stringWithFormat:@"bytes %llu-%llu/%llu", start, end, length],
                @"Accept-Ranges": @"bytes",
                @"Cache-Control": @"no-store",
            };
            NSHTTPURLResponse *r = [[NSHTTPURLResponse alloc] initWithURL:url statusCode:206
                HTTPVersion:@"HTTP/1.1" headerFields:headers];
            [task didReceiveResponse:r];
            [task didReceiveData:data];
            [task didFinish];
        } else {
            NSData *data = [fh readDataToEndOfFile];
            NSDictionary *headers = @{
                @"Content-Type": mime,
                @"Content-Length": [@(data.length) stringValue],
                @"Accept-Ranges": @"bytes",
                @"Cache-Control": @"no-store",
            };
            NSHTTPURLResponse *r = [[NSHTTPURLResponse alloc] initWithURL:url statusCode:200
                HTTPVersion:@"HTTP/1.1" headerFields:headers];
            [task didReceiveResponse:r];
            [task didReceiveData:data];
            [task didFinish];
        }
    } @catch (NSException *e) {
        [task didFailWithError:[NSError errorWithDomain:@"wails.capture" code:500 userInfo:nil]];
    } @finally {
        [fh closeFile];
    }
}
- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id<WKURLSchemeTask>)urlSchemeTask {
    cancelURLRequest((__bridge void*)urlSchemeTask);
    NSLog(@"[WailsSchemeHandler] stop task url=%@", urlSchemeTask.request.URL.absoluteString ?: @"");
}
@end
// MARK: - WailsMessageHandler
@implementation WailsMessageHandler
- (instancetype)initWithWindowID:(unsigned int)windowID {
    self = [super init];
    if (self) {
        _windowID = windowID;
    }
    return self;
}
- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    // Support both plain string messages and structured objects
    if ([message.body isKindOfClass:[NSString class]]) {
        NSString *msg = (NSString *)message.body;
        HandleJSMessage(self.windowID, (char *)[msg UTF8String]);
        return;
    }
    NSError *error = nil;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:message.body options:0 error:&error];
    if (!error && jsonData) {
        NSString *jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
        HandleJSMessage(self.windowID, (char *)[jsonString UTF8String]);
    } else {
        // Fallback: attempt to stringify non-serializable payloads
        NSString *desc = [NSString stringWithFormat:@"%@", message.body];
        HandleJSMessage(self.windowID, (char *)[desc UTF8String]);
    }
}
@end
// MARK: - WailsViewController
@interface WailsViewController ()
- (void)applySafeAreaCSSVariables;
@end

@implementation WailsViewController
- (instancetype)initWithWindowID:(unsigned int)windowID {
    self = [super init];
    if (self) {
        _windowID = windowID;
    }
    return self;
}
// Live light/dark switches arrive here (not via a notification), so emit the
// ios:ThemeChanged application event with the new mode in its context.
- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if (@available(iOS 13.0, *)) {
        UIUserInterfaceStyle now = self.traitCollection.userInterfaceStyle;
        UIUserInterfaceStyle was = previousTraitCollection
            ? previousTraitCollection.userInterfaceStyle
            : UIUserInterfaceStyleUnspecified;
        if (now != was) {
            BOOL dark = (now == UIUserInterfaceStyleDark);
            processApplicationEvent(EventThemeChanged,
                dark ? (void *)"{\"isDarkMode\":true}" : (void *)"{\"isDarkMode\":false}");
        }
    }
}
- (void)viewDidLoad {
    [super viewDidLoad];
    WKWebViewConfiguration *config = [[WKWebViewConfiguration alloc] init];
    config.suppressesIncrementalRendering = YES;
    // Application name for UA (default to "wails.io" if not set)
    const char* appNameForUA = ios_get_app_name_for_user_agent();
    config.applicationNameForUserAgent = appNameForUA ? [NSString stringWithUTF8String:appNameForUA] : @"wails.io";
    // Enable JavaScript using modern API (javaScriptEnabled is deprecated)
    if (@available(iOS 14.0, *)) {
        config.defaultWebpagePreferences.allowsContentJavaScript = YES;
    } else {
        // Fallback for very old iOS versions
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        config.preferences.javaScriptEnabled = YES;
        #pragma clang diagnostic pop
    }
    // Media playback
    config.allowsInlineMediaPlayback = ios_is_inline_media_playback_enabled();
    if (ios_is_autoplay_without_user_action_enabled()) {
        config.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
    } else {
        config.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeAll;
    }
    // URL scheme handler and script bridge
    self.schemeHandler = [[WailsSchemeHandler alloc] initWithWindowID:self.windowID];
    [config setURLSchemeHandler:self.schemeHandler forURLScheme:@"wails"];
    self.messageHandler = [[WailsMessageHandler alloc] initWithWindowID:self.windowID];
    // Register both handler names used by runtimes: "external" (current runtime) and "wails" (legacy)
    [config.userContentController addScriptMessageHandler:self.messageHandler name:@"external"];
    [config.userContentController addScriptMessageHandler:self.messageHandler name:@"wails"];
    self.webView = [[WailsWebView alloc] initWithFrame:self.view.bounds configuration:config];
    self.editorAccessoryHandler = [[WailsEditorAccessoryHandler alloc] init];
    self.editorAccessoryHandler.webView = self.webView;
    [config.userContentController addScriptMessageHandler:self.editorAccessoryHandler name:@"editorAccessory"];
    NSString *accessoryScript = @"(function(){"
        "function setVisible(visible){window.webkit.messageHandlers.editorAccessory.postMessage({visible:!!visible});}"
        "function update(){var active=document.activeElement;setVisible(!!(active&&active.closest&&!active.closest('[data-quick-entry]')&&active.closest('.note-editor-shell')));}"
        "document.addEventListener('focusin',update,true);"
        "document.addEventListener('focusout',function(){setTimeout(update,0);},true);"
        "document.addEventListener('multisafe:atomic-editor-focus',function(event){setVisible(event.detail&&event.detail.visible);});"
        "})();";
    WKUserScript *editorAccessoryScript = [[WKUserScript alloc] initWithSource:accessoryScript
        injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES];
    [config.userContentController addUserScript:editorAccessoryScript];
    // Custom user agent if provided
    const char* userAgent = ios_get_user_agent();
    if (userAgent) {
        self.webView.customUserAgent = [NSString stringWithUTF8String:userAgent];
    }
    self.webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.webView.navigationDelegate = self;
    // Back/forward gestures
    self.webView.allowsBackForwardNavigationGestures = ios_is_back_forward_gestures_enabled();
    // Link preview
    self.webView.allowsLinkPreview = ios_is_link_preview_disabled() ? NO : YES;
    // Configure scrolling & bounce & indicators
    UIScrollView *sv = self.webView.scrollView;
    bool scrollDisabled = ios_is_scroll_disabled();
    bool bounceDisabled = ios_is_bounce_disabled();
    bool indicatorsDisabled = ios_is_scroll_indicators_disabled();
    sv.scrollEnabled = scrollDisabled ? NO : YES;
    sv.bounces = bounceDisabled ? NO : YES;
    sv.alwaysBounceVertical = bounceDisabled ? NO : YES;
    sv.alwaysBounceHorizontal = bounceDisabled ? NO : YES;
    sv.showsVerticalScrollIndicator = indicatorsDisabled ? NO : YES;
    sv.showsHorizontalScrollIndicator = indicatorsDisabled ? NO : YES;
    sv.contentInset = UIEdgeInsetsZero;
    sv.scrollIndicatorInsets = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) {
        sv.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    }
    // Inspector
    BOOL inspectorOn = ios_is_inspectable_disabled() ? NO : YES;
    if (@available(iOS 16.4, *)) {
        self.webView.inspectable = inspectorOn;
    } else {
        @try { [self.webView setValue:@(inspectorOn) forKey:@"inspectable"]; } @catch (__unused NSException *e) {}
    }
    [self.view addSubview:self.webView];
    // NOTE: no initial loadRequest here. The Go side performs the single
    // initial navigation (iosWebviewWindow.run -> setURL); a hardcoded load
    // here caused the page to load twice and lose the runtime-ready
    // handshake in the overlap.
    // Flush any pending console logs now that a webview exists
    dispatch_async(dispatch_get_main_queue(), ^{
        if (pendingConsoleJS.count > 0) {
            for (NSString *js in pendingConsoleJS) {
                [self.webView evaluateJavaScript:js completionHandler:nil];
            }
            [pendingConsoleJS removeAllObjects];
        }
    });
    // Enable native tabs if globally enabled
    BOOL tabsEnabled = ios_native_tabs_is_enabled();
    WailsVLog(@"[WailsViewController] viewDidLoad: ios_native_tabs_is_enabled=%d", tabsEnabled);
    if (tabsEnabled) {
        [self enableNativeTabs:YES];
    }
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    // Layout webView and optional tabBar respecting safe area
    UIEdgeInsets safe = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) {
        safe = self.view.safeAreaInsets;
        // In full-bleed mode the controller view may report zero before UIKit
        // propagates its inset. The window always owns the physical display cutout.
        if (appDelegate.window) {
            UIEdgeInsets windowSafe = appDelegate.window.safeAreaInsets;
            safe.top = MAX(safe.top, windowSafe.top);
            safe.bottom = MAX(safe.bottom, windowSafe.bottom);
            safe.left = MAX(safe.left, windowSafe.left);
            safe.right = MAX(safe.right, windowSafe.right);
        }
    }
    CGFloat width = self.view.bounds.size.width;
    CGFloat height = self.view.bounds.size.height;
    CGFloat tabH = 0;
    if (self.tabBar && !self.tabBar.isHidden) {
        CGSize size = [self.tabBar sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)];
        tabH = size.height;
        self.tabBar.frame = CGRectMake(0, height - safe.bottom - tabH, width, tabH);
    }
    // Let the webview extend under the status bar/notch area so the frontend's
    // background can control that region. The app shell is responsible for
    // respecting env(safe-area-inset-top) for actual content layout.
    CGFloat webTop = 0;
    // Do the same at the home-indicator edge. Native tabs, when present, remain
    // overlaid above the webview; the frontend receives the safe-area insets and
    // keeps interactive UI clear of both the tab bar and system gesture area.
    CGFloat webBottom = 0;
    self.webView.frame = UIEdgeInsetsInsetRect(self.view.bounds, UIEdgeInsetsMake(webTop, 0, webBottom, 0));
    [self applySafeAreaCSSVariables];
}
- (void)applySafeAreaCSSVariables {
    if (!self.webView) return;

    UIEdgeInsets safe = UIEdgeInsetsZero;
    if (@available(iOS 11.0, *)) {
        safe = self.view.safeAreaInsets;
    }
    NSString *js = [NSString stringWithFormat:
        @"document.documentElement.style.setProperty('--wails-safe-area-top','%.0fpx');"
         @"document.documentElement.style.setProperty('--wails-safe-area-bottom','%.0fpx');"
         @"document.documentElement.style.setProperty('--wails-safe-area-left','%.0fpx');"
         @"document.documentElement.style.setProperty('--wails-safe-area-right','%.0fpx');",
        safe.top, safe.bottom, safe.left, safe.right];
    [self.webView evaluateJavaScript:js completionHandler:nil];
}
// Orientation lock and status-bar appearance are driven by global state set
// from Go (see mobile_features_ios.m). These overrides feed UIKit the current
// preference; the setters call the matching setNeeds… to apply it live.
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return mfSupportedOrientations();
}
- (UIStatusBarStyle)preferredStatusBarStyle {
    return mfStatusBarStyle();
}
- (BOOL)prefersStatusBarHidden {
    return mfStatusBarHidden();
}
// Push safe-area changes (rotation, notch) to the frontend so layouts can react
// beyond what CSS env(safe-area-inset-*) already provides.
- (void)viewSafeAreaInsetsDidChange {
    [super viewSafeAreaInsetsDidChange];
    [self applySafeAreaCSSVariables];
    if (@available(iOS 11.0, *)) {
        UIEdgeInsets s = self.view.safeAreaInsets;
        NSString *json = [NSString stringWithFormat:
            @"{\"top\":%d,\"bottom\":%d,\"left\":%d,\"right\":%d}",
            (int)s.top, (int)s.bottom, (int)s.left, (int)s.right];
        iosEmitNativeEvent("common:safeArea", [json UTF8String]);
    }
}
- (void)enableNativeTabs:(BOOL)enabled {
    dispatch_async(dispatch_get_main_queue(), ^{
        WailsVLog(@"[WailsViewController] enableNativeTabs called with enabled=%d, existingTabBar=%@", enabled, self.tabBar ? @"YES" : @"NO");
        if (enabled) {
            if (!self.tabBar) {
                UITabBar *tb = [[UITabBar alloc] init];
                tb.delegate = self;
                if (@available(iOS 13.0, *)) {
                    UITabBarAppearance *appearance = [[UITabBarAppearance alloc] init];
                    [appearance configureWithDefaultBackground];
                    tb.standardAppearance = appearance;
                    if (@available(iOS 15.0, *)) {
                        tb.scrollEdgeAppearance = appearance;
                    }
                }
                // Build items from configured JSON, fallback to defaults
                const char* cjson = ios_native_tabs_get_items_json();
                NSMutableArray<UITabBarItem*> *items = nil;
                if (cjson) {
                    NSString *jsonStr = [NSString stringWithUTF8String:cjson];
                    free((void*)cjson);
                    if (jsonStr.length) {
                        NSData *data = [jsonStr dataUsingEncoding:NSUTF8StringEncoding];
                        NSError *err = nil;
                        id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
                        if (!err && [obj isKindOfClass:[NSArray class]]) {
                            NSArray *arr = (NSArray*)obj;
                            WailsVLog(@"[WailsViewController] Building tab items from JSON, count=%lu", (unsigned long)arr.count);
                            items = [NSMutableArray arrayWithCapacity:arr.count];
                            NSInteger tag = 0;
                            for (id entry in arr) {
                                if (![entry isKindOfClass:[NSDictionary class]]) continue;
                                NSDictionary *d = (NSDictionary*)entry;
                                NSString *title = [d[@"Title"] isKindOfClass:[NSString class]] ? d[@"Title"] : @"";
                                UIImage *img = nil;
                                if (@available(iOS 13.0, *)) {
                                    NSString *symbol = [d[@"SystemImage"] isKindOfClass:[NSString class]] ? d[@"SystemImage"] : nil;
                                    if (symbol.length) {
                                        img = [UIImage systemImageNamed:symbol];
                                    }
                                }
                                UITabBarItem *it = [[UITabBarItem alloc] initWithTitle:(title ?: @"") image:img tag:tag++];
                                [items addObject:it];
                            }
                        }
                        else if (err) {
                            NSLog(@"[WailsViewController] ERROR parsing NativeTabsItems JSON: %@", err);
                        }
                    }
                    else {
                        WailsVLog(@"[WailsViewController] NativeTabsItems JSON string is empty");
                    }
                }
                if (items != nil && items.count > 0) {
                    tb.items = items;
                    tb.selectedItem = items.firstObject;
                    WailsVLog(@"[WailsViewController] TabBar created with %lu item(s) from config", (unsigned long)items.count);
                } else {
                    // Default 3 items
                    UITabBarItem *item0 = [[UITabBarItem alloc] initWithTitle:@"Bindings" image:nil tag:0];
                    UITabBarItem *item1 = [[UITabBarItem alloc] initWithTitle:@"Go Runtime" image:nil tag:1];
                    UITabBarItem *item2 = [[UITabBarItem alloc] initWithTitle:@"JS Runtime" image:nil tag:2];
                    tb.items = @[item0, item1, item2];
                    tb.selectedItem = item0;
                    WailsVLog(@"[WailsViewController] TabBar created with default items (3)" );
                }
                self.tabBar = tb;
                [self.view addSubview:self.tabBar];
                WailsVLog(@"[WailsViewController] TabBar added as subview");
            }
            self.tabBar.hidden = NO;
            WailsVLog(@"[WailsViewController] TabBar set hidden=NO");
        } else {
            if (self.tabBar) {
                self.tabBar.hidden = YES;
                WailsVLog(@"[WailsViewController] TabBar set hidden=YES");
            }
        }
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
        WailsVLog(@"[WailsViewController] Requested layout update (enableNativeTabs)");
    });
}
- (void)selectNativeTabIndex:(NSInteger)index {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.tabBar || self.tabBar.isHidden) return;
        if (index < 0 || index >= (NSInteger)self.tabBar.items.count) return;
        UITabBarItem *item = self.tabBar.items[index];
        self.tabBar.selectedItem = item;
        [self tabBar:self.tabBar didSelectItem:item];
    });
}
#pragma mark - UITabBarDelegate
- (void)tabBar:(UITabBar *)tabBar didSelectItem:(UITabBarItem *)item {
    NSInteger idx = [tabBar.items indexOfObject:item];
    if (idx == NSNotFound) return;
    // Dispatch a CustomEvent to the frontend
    NSString *js = [NSString stringWithFormat:@"window.dispatchEvent(new CustomEvent('nativeTabSelected',{detail:{index:%ld}}));", (long)idx];
    [self executeJavaScript:js];
}
- (void)executeJavaScript:(NSString *)js {
    [self.webView evaluateJavaScript:js completionHandler:^(id result, NSError *error) {
        if (error) {
            NSLog(@"[WailsViewController] JS error: %@", error);
        }
    }];
}
// GENERATED EVENTS START
- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation {
    NSLog(@"[WailsViewController] didStartProvisionalNavigation url=%@", webView.URL.absoluteString ?: @"");
    if( hasListeners(EventWebViewDidStartNavigation) ) {
        processWindowEvent(self.windowID, EventWebViewDidStartNavigation);
    }
}

- (void)webView:(WKWebView *)webView didCommitNavigation:(WKNavigation *)navigation {
    NSLog(@"[WailsViewController] didCommitNavigation url=%@", webView.URL.absoluteString ?: @"");
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    NSLog(@"[WailsViewController] didFinishNavigation url=%@", webView.URL.absoluteString ?: @"");
    [self applySafeAreaCSSVariables];
    if( hasListeners(EventWebViewDidFinishNavigation) ) {
        processWindowEvent(self.windowID, EventWebViewDidFinishNavigation);
    }
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation {
    NSLog(@"[WailsViewController] didFailProvisionalNavigation url=%@ navigation=%@", webView.URL.absoluteString ?: @"", navigation);
    if( hasListeners(EventWebViewDidFailNavigation) ) {
        processWindowEvent(self.windowID, EventWebViewDidFailNavigation);
    }
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    NSLog(@"[WailsViewController] didFailNavigation url=%@ error=%@", webView.URL.absoluteString ?: @"", error);
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    NSLog(@"[WailsViewController] didFailProvisionalNavigation url=%@ error=%@", webView.URL.absoluteString ?: @"", error);
    if( hasListeners(EventWebViewDidFailNavigation) ) {
        processWindowEvent(self.windowID, EventWebViewDidFailNavigation);
    }
}

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    if( hasListeners(EventWebViewDecidePolicyForNavigationAction) ) {
        processWindowEvent(self.windowID, EventWebViewDecidePolicyForNavigationAction);
    }
    decisionHandler(WKNavigationActionPolicyAllow);
}

// GENERATED EVENTS END
@end
// MARK: - C bridges used by Go
unsigned int ios_create_webview(void) {
    __block unsigned int windowID = nextWindowID++;
    if (!appDelegate || !appDelegate.window) {
        return windowID;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        WailsViewController *vc = [[WailsViewController alloc] initWithWindowID:windowID];
        if (!appDelegate.viewControllers) appDelegate.viewControllers = [NSMutableArray array];
        [appDelegate.viewControllers addObject:vc];
        appDelegate.window.rootViewController = vc;
        [vc loadViewIfNeeded];
    });
    return windowID;
}
void* ios_create_webview_with_id(unsigned int wailsID) {
    __block WailsViewController *viewController = nil;
    if (!appDelegate || !appDelegate.window) {
        return NULL;
    }
    void (^createBlock)(void) = ^{
        viewController = [[WailsViewController alloc] initWithWindowID:wailsID];
        if (!appDelegate.viewControllers) appDelegate.viewControllers = [NSMutableArray array];
        [appDelegate.viewControllers addObject:viewController];
        appDelegate.window.rootViewController = viewController;
        [appDelegate.window makeKeyAndVisible];
        // Trigger the view to load exactly once, the UIKit-correct way. Calling
        // -loadView and -viewDidLoad manually made UIKit ALSO load the view
        // automatically, creating two WebViews/viewDidLoad passes: content loaded
        // into one while the other (blank) was displayed → intermittent white
        // screen on cold launch (force-quit + relaunch).
        [viewController loadViewIfNeeded];
    };
    if ([NSThread isMainThread]) {
        createBlock();
    } else {
        dispatch_sync(dispatch_get_main_queue(), createBlock);
    }
    return (__bridge_retained void*)viewController;
}
void ios_execute_javascript(unsigned int windowID, const char* js) {
    if (!js) return;
    NSString *jsString = [NSString stringWithUTF8String:js];
    dispatch_async(dispatch_get_main_queue(), ^{
        for (WailsViewController *vc in appDelegate.viewControllers) {
            if (vc.windowID == windowID) { [vc executeJavaScript:jsString]; break; }
        }
    });
}
void ios_window_exec_js(void* viewController, const char* js) {
    if (!viewController || !js) return;
    WailsViewController *vc = (__bridge WailsViewController *)viewController;
    NSString *jsString = [NSString stringWithUTF8String:js];
    dispatch_async(dispatch_get_main_queue(), ^{ [vc executeJavaScript:jsString]; });
}
void ios_window_load_url(void* viewController, const char* url) {
    if (!viewController || !url) return;
    WailsViewController *vc = (__bridge WailsViewController *)viewController;
    NSString *urlString = [NSString stringWithUTF8String:url];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSURL *nsurl = [NSURL URLWithString:urlString];
        if (!nsurl) {
            NSLog(@"[WailsViewController] loadRequest invalid url=%@", urlString);
            return;
        }
        NSLog(@"[WailsViewController] loadRequest url=%@", urlString);
        [vc.webView loadRequest:[NSURLRequest requestWithURL:nsurl]];
    });
}
void ios_window_set_html(void* viewController, const char* html) {
    if (!viewController || !html) return;
    WailsViewController *vc = (__bridge WailsViewController *)viewController;
    NSString *htmlString = [NSString stringWithUTF8String:html];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"[WailsViewController] load fallback html");
        [vc.webView loadHTMLString:htmlString baseURL:[NSURL URLWithString:@"wails://localhost/"]];
    });
}
unsigned int ios_window_get_id(void* viewController) {
    if (!viewController) return 0;
    WailsViewController *vc = (__bridge WailsViewController *)viewController;
    return vc.windowID;
}
void ios_window_release_handle(void* viewController) {
    if (!viewController) return;
    CFRelease(viewController);
}
// Broadcast a console message to all active WKWebViews
void ios_console_log(const char* level, const char* message) {
    if (!message) return;
    NSString *lvl = level ? [NSString stringWithUTF8String:level] : @"log";
    NSString *msg = [NSString stringWithUTF8String:message];
    // Mirror to system log. Use %@ (NOT %{public}@) so message content is kept
    // private/redacted in release builds — it can contain app/user data.
    os_log(OS_LOG_DEFAULT, "[ios_console_log][%@] %@", lvl, msg);
    // Robustly encode message to avoid JS string escaping issues
    NSData *data = [msg dataUsingEncoding:NSUTF8StringEncoding];
    NSString *b64 = [data base64EncodedStringWithOptions:0];
    NSString *levelJS = ([lvl length] ? [NSString stringWithFormat:@"'%@'", lvl] : @"'log'");
    NSString *js = [NSString stringWithFormat:
                    @"(function(){try{var b=atob('%@');var bytes=new Uint8Array(b.length);for(var i=0;i<b.length;i++){bytes[i]=b.charCodeAt(i);}var msg=new TextDecoder('utf-8').decode(bytes);console[%@](msg);}catch(e){console.log('wails log bridge error:'+e)}})();",
                    b64, levelJS];
    dispatch_async(dispatch_get_main_queue(), ^{
        // Ensure buffer is initialised
        if (pendingConsoleJS == nil) {
            pendingConsoleJS = [NSMutableArray array];
        }
        NSUInteger count = appDelegate.viewControllers.count;
        if (count == 0) {
            // No webviews yet: buffer
            [pendingConsoleJS addObject:js];
            return;
        }
        // Broadcast to all existing webviews
        for (WailsViewController *vc in appDelegate.viewControllers) {
            [vc.webView evaluateJavaScript:js completionHandler:nil];
        }
    });
}
// Set background color (applies to VC view, WKWebView, and app window)
void ios_window_set_background_color(void* viewController, unsigned char r, unsigned char g, unsigned char b, unsigned char a) {
    if (!viewController) return;
    WailsViewController *vc = (__bridge WailsViewController *)viewController;
    CGFloat fr = ((CGFloat)r) / 255.0;
    CGFloat fg = ((CGFloat)g) / 255.0;
    CGFloat fb = ((CGFloat)b) / 255.0;
    CGFloat fa = ((CGFloat)a) / 255.0;
    UIColor *color = [UIColor colorWithRed:fr green:fg blue:fb alpha:fa];
    dispatch_async(dispatch_get_main_queue(), ^{
        vc.view.backgroundColor = color;
        if (vc.webView) {
            vc.webView.opaque = (a == 255);
            vc.webView.backgroundColor = color;
            vc.webView.scrollView.backgroundColor = color;
        }
        if (appDelegate && appDelegate.window) {
            appDelegate.window.backgroundColor = color;
        }
    });
}
