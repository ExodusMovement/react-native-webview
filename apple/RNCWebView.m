/**
 * Copyright (c) 2015-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "RNCWebView.h"
#import <React/RCTConvert.h>
#import <React/RCTAutoInsetsProtocol.h>
#import "RNCWKProcessPoolManager.h"
#if !TARGET_OS_OSX
#import <UIKit/UIKit.h>
#else
#import <React/RCTUIKit.h>
#endif // !TARGET_OS_OSX

#import "objc/runtime.h"

static NSTimer *keyboardTimer;
static NSString *const HistoryShimName = @"ReactNativeHistoryShim";
static NSString *const MessageHandlerName = @"ReactNativeWebView";
static NSURLCredential* clientAuthenticationCredential;
static NSDictionary* customCertificatesForHost;
static NSSet *cameraPermissionWhitelist;

NSString *const CUSTOM_SELECTOR = @"_CUSTOM_SELECTOR_";

#if !TARGET_OS_OSX
// runtime trick to remove WKWebView keyboard default toolbar
// see: http://stackoverflow.com/questions/19033292/ios-7-uiwebview-keyboard-issue/19042279#19042279
@interface __SwizzleHelperWK : UIView
@property (nonatomic, copy) WKWebView *webView;
@end
@implementation __SwizzleHelperWK
-(id)inputAccessoryView
{
  if (_webView == nil) {
    return nil;
  }
  
  if ([_webView respondsToSelector:@selector(inputAssistantItem)]) {
    UITextInputAssistantItem *inputAssistantItem = [_webView inputAssistantItem];
    inputAssistantItem.leadingBarButtonGroups = @[];
    inputAssistantItem.trailingBarButtonGroups = @[];
  }
  return nil;
}
@end
#endif // !TARGET_OS_OSX

@interface RNCWebView () <WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler, WKHTTPCookieStoreObserver,
#if !TARGET_OS_OSX
UIScrollViewDelegate,
#endif // !TARGET_OS_OSX
RCTAutoInsetsProtocol>

@property (nonatomic, copy) RCTDirectEventBlock onLoadingStart;
@property (nonatomic, copy) RCTDirectEventBlock onLoadingFinish;
@property (nonatomic, copy) RCTDirectEventBlock onLoadingError;
@property (nonatomic, copy) RCTDirectEventBlock onLoadingProgress;
@property (nonatomic, copy) RCTDirectEventBlock onShouldStartLoadWithRequest;
@property (nonatomic, copy) RCTDirectEventBlock onMessage;
@property (nonatomic, copy) RCTDirectEventBlock onScroll;
@property (nonatomic, copy) RCTDirectEventBlock onContentProcessDidTerminate;
#if !TARGET_OS_OSX
@property (nonatomic, copy) WKWebView *webView;
#else
@property (nonatomic, copy) RNCWKWebView *webView;
#endif // !TARGET_OS_OSX
@property (nonatomic, strong) WKUserScript *postMessageScript;
@property (nonatomic, strong) WKUserScript *atStartScript;
@property (nonatomic, strong) WKUserScript *atEndScript;
@end

@implementation RNCWebView
{
#if !TARGET_OS_OSX
  UIColor * _savedBackgroundColor;
#else
  RCTUIColor * _savedBackgroundColor;
#endif // !TARGET_OS_OSX
  BOOL _savedHideKeyboardAccessoryView;
  BOOL _savedKeyboardDisplayRequiresUserAction;
  
  // Workaround for StatusBar appearance bug for iOS 12
  // https://github.com/react-native-webview/react-native-webview/issues/62
  BOOL _isFullScreenVideoOpen;
#if !TARGET_OS_OSX
  UIStatusBarStyle _savedStatusBarStyle;
#endif // !TARGET_OS_OSX
  BOOL _savedStatusBarHidden;
  
#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 110000 /* __IPHONE_11_0 */
  UIScrollViewContentInsetAdjustmentBehavior _savedContentInsetAdjustmentBehavior;
#endif
#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000 /* __IPHONE_13_0 */
  BOOL _savedAutomaticallyAdjustsScrollIndicatorInsets;
#endif
}

+ (void)initialize {
    if (self == [RNCWebView class]) {
        cameraPermissionWhitelist = [NSSet setWithArray:@[
            @"alchemy.veriff.com",
            @"magic.veriff.me"
        ]];
    }
}

- (instancetype)initWithFrame:(CGRect)frame
{
  if ((self = [super initWithFrame:frame])) {
#if !TARGET_OS_OSX
    super.backgroundColor = [UIColor clearColor];
#else
    super.backgroundColor = [RCTUIColor clearColor];
#endif // !TARGET_OS_OSX
    _bounces = YES;
    _scrollEnabled = YES;
    _showsHorizontalScrollIndicator = YES;
    _showsVerticalScrollIndicator = YES;
    _directionalLockEnabled = YES;
    _automaticallyAdjustContentInsets = YES;
    _autoManageStatusBarEnabled = YES;
    _contentInset = UIEdgeInsetsZero;
    _savedKeyboardDisplayRequiresUserAction = YES;
#if !TARGET_OS_OSX
    _savedStatusBarStyle = RCTSharedApplication().statusBarStyle;
    _savedStatusBarHidden = RCTSharedApplication().statusBarHidden;
#endif // !TARGET_OS_OSX
    _injectedJavaScript = nil;
    _injectedJavaScriptBeforeContentLoaded = nil;
    
#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 110000 /* __IPHONE_11_0 */
    _savedContentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
#endif
#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000 /* __IPHONE_13_0 */
    _savedAutomaticallyAdjustsScrollIndicatorInsets = NO;
#endif
    _enableApplePay = NO;
#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 150000 /* iOS 15 */
    _mediaCapturePermissionGrantType = RNCWebViewPermissionGrantType_Prompt;
#endif
  }
  
#if !TARGET_OS_OSX
  if (@available(iOS 12.0, *)) {
    // Workaround for a keyboard dismissal bug present in iOS 12
    // https://openradar.appspot.com/radar?id=5018321736957952
    [[NSNotificationCenter defaultCenter]
     addObserver:self
     selector:@selector(keyboardWillHide)
     name:UIKeyboardWillHideNotification object:nil];
    [[NSNotificationCenter defaultCenter]
     addObserver:self
     selector:@selector(keyboardWillShow)
     name:UIKeyboardWillShowNotification object:nil];
    
    // Workaround for StatusBar appearance bug for iOS 12
    // https://github.com/react-native-webview/react-native-webview/issues/62
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(showFullScreenVideoStatusBars)
                                                 name:UIWindowDidBecomeVisibleNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(hideFullScreenVideoStatusBars)
                                                 name:UIWindowDidBecomeHiddenNotification
                                               object:nil];
    
  }
#endif // !TARGET_OS_OSX
  return self;
}

#if !TARGET_OS_OSX
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
  // Only allow long press gesture
  if ([otherGestureRecognizer isKindOfClass:[UILongPressGestureRecognizer class]]) {
    return YES;
  }else{
    return NO;
  }
}

// Listener for long presses
- (void)startLongPress:(UILongPressGestureRecognizer *)pressSender
{
  // When a long press ends, bring up our custom UIMenu
  if(pressSender.state == UIGestureRecognizerStateEnded) {
    if (!self.menuItems || self.menuItems.count == 0) {
      return;
    }
    UIMenuController *menuController = [UIMenuController sharedMenuController];
    NSMutableArray *menuControllerItems = [NSMutableArray arrayWithCapacity:self.menuItems.count];
    
    for(NSDictionary *menuItem in self.menuItems) {
      NSString *menuItemLabel = [RCTConvert NSString:menuItem[@"label"]];
      NSString *menuItemKey = [RCTConvert NSString:menuItem[@"key"]];
      NSString *sel = [NSString stringWithFormat:@"%@%@", CUSTOM_SELECTOR, menuItemKey];
      UIMenuItem *item = [[UIMenuItem alloc] initWithTitle: menuItemLabel
                                                    action: NSSelectorFromString(sel)];
      
      [menuControllerItems addObject: item];
    }
    
    menuController.menuItems = menuControllerItems;
    [menuController setMenuVisible:YES animated:YES];
  }
}

#endif // !TARGET_OS_OSX

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  if (@available(iOS 11.0, *)) {
    [self.webView.configuration.websiteDataStore.httpCookieStore removeObserver:self];
  }
}

- (void)tappedMenuItem:(NSString *)eventType
{
  // Get the selected text
  // NOTE: selecting text in an iframe or shadow DOM will not work
  [self.webView evaluateJavaScript: @"window.getSelection().toString()" completionHandler: ^(id result, NSError *error) {
    if (error != nil) {
      RCTLogWarn(@"%@", [NSString stringWithFormat:@"Error evaluating injectedJavaScript: This is possibly due to an unsupported return type. Try adding true to the end of your injectedJavaScript string. %@", error]);
    } else {
      if (self.onCustomMenuSelection) {
        NSPredicate *filter = [NSPredicate predicateWithFormat:@"key contains[c] %@ ",eventType];
        NSArray *filteredMenuItems = [self.menuItems filteredArrayUsingPredicate:filter];
        NSDictionary *selectedMenuItem = filteredMenuItems[0];
        NSString *label = [RCTConvert NSString:selectedMenuItem[@"label"]];
        self.onCustomMenuSelection(@{
          @"key": eventType,
          @"label": label,
          @"selectedText": result
        });
      } else {
        RCTLogWarn(@"Error evaluating onCustomMenuSelection: You must implement an `onCustomMenuSelection` callback when using custom menu items");
      }
    }
  }];
}

// Overwrite method that interprets which action to call upon UIMenu Selection
// https://developer.apple.com/documentation/objectivec/nsobject/1571960-methodsignatureforselector
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel
{
  NSMethodSignature *existingSelector = [super methodSignatureForSelector:sel];
  if (existingSelector) {
    return existingSelector;
  }
  return [super methodSignatureForSelector:@selector(tappedMenuItem:)];
}

// Needed to forward messages to other objects
// https://developer.apple.com/documentation/objectivec/nsobject/1571955-forwardinvocation
- (void)forwardInvocation:(NSInvocation *)invocation
{
  NSString *sel = NSStringFromSelector([invocation selector]);
  NSRange match = [sel rangeOfString:CUSTOM_SELECTOR];
  if (match.location == 0) {
    [self tappedMenuItem:[sel substringFromIndex:17]];
  } else {
    [super forwardInvocation:invocation];
  }
}

// Allows the instance to respond to UIMenuController Actions
- (BOOL)canBecomeFirstResponder
{
  return YES;
}

// Control which items show up on the UIMenuController
- (BOOL)canPerformAction:(SEL)action withSender:(id)sender
{
  NSString *sel = NSStringFromSelector(action);
  // Do any of them have our custom keys?
  NSRange match = [sel rangeOfString:CUSTOM_SELECTOR];
  
  if (match.location == 0) {
    return YES;
  }
  return NO;
}

/**
 * See https://stackoverflow.com/questions/25713069/why-is-wkwebview-not-opening-links-with-target-blank/25853806#25853806 for details.
 */
- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration forNavigationAction:(WKNavigationAction *)navigationAction windowFeatures:(WKWindowFeatures *)windowFeatures
{
  if (!navigationAction.targetFrame.isMainFrame) {
    [webView loadRequest:navigationAction.request];
  }
  return nil;
}

- (WKWebViewConfiguration *)setUpWkWebViewConfig
{
  WKWebViewConfiguration *wkWebViewConfig = [WKWebViewConfiguration new];
  WKPreferences *prefs = [[WKPreferences alloc]init];
  if (!_javaScriptEnabled) {
    prefs.javaScriptEnabled = NO;
  }

  // NOTE: defaults, recheck?
  // [wkWebViewConfig setValue:@FALSE forKey:@"allowUniversalAccessFromFileURLs"];
  // [prefs setValue:@FALSE forKey:@"allowFileAccessFromFileURLs"];

  [prefs setValue:@FALSE forKey:@"javaScriptCanOpenWindowsAutomatically"];
#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 140500 /* iOS 14.5 */
  if (@available(iOS 14.5, *)) {
    if (!_textInteractionEnabled) {
      [prefs setValue:@FALSE forKey:@"textInteractionEnabled"];
    }
  }
#endif
  wkWebViewConfig.preferences = prefs;
  if (_incognito) {
    wkWebViewConfig.websiteDataStore = [WKWebsiteDataStore nonPersistentDataStore];
  } else if (_cacheEnabled) {
    wkWebViewConfig.websiteDataStore = [WKWebsiteDataStore defaultDataStore];
  }
  if(self.useSharedProcessPool) {
    wkWebViewConfig.processPool = [[RNCWKProcessPoolManager sharedManager] sharedProcessPool];
  }
  wkWebViewConfig.userContentController = [WKUserContentController new];
  
#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000 /* iOS 13 */
  if (@available(iOS 13.0, *)) {
    WKWebpagePreferences *pagePrefs = [[WKWebpagePreferences alloc]init];
    pagePrefs.preferredContentMode = _contentMode;
    wkWebViewConfig.defaultWebpagePreferences = pagePrefs;
  }
#endif
  
#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 140000 /* iOS 14 */
  if (@available(iOS 14.0, *)) {
    if ([wkWebViewConfig respondsToSelector:@selector(limitsNavigationsToAppBoundDomains)]) {
      if (_limitsNavigationsToAppBoundDomains) {
        wkWebViewConfig.limitsNavigationsToAppBoundDomains = YES;
      }
    }
  }
#endif
  
  // Shim the HTML5 history API:
  [wkWebViewConfig.userContentController addScriptMessageHandler:[[RNCWeakScriptMessageDelegate alloc] initWithDelegate:self]
                                                            name:HistoryShimName];
  [self resetupScripts:wkWebViewConfig];
  
  if(@available(ios 9.0, *)) {
    wkWebViewConfig.allowsAirPlayForMediaPlayback = NO;
  }
  
#if !TARGET_OS_OSX
  wkWebViewConfig.allowsInlineMediaPlayback = _allowsInlineMediaPlayback;
#if WEBKIT_IOS_10_APIS_AVAILABLE
  wkWebViewConfig.mediaTypesRequiringUserActionForPlayback = _mediaPlaybackRequiresUserAction
  ? WKAudiovisualMediaTypeAll
  : WKAudiovisualMediaTypeNone;
  wkWebViewConfig.dataDetectorTypes = _dataDetectorTypes;
#else
  wkWebViewConfig.mediaPlaybackRequiresUserAction = _mediaPlaybackRequiresUserAction;
#endif
#endif // !TARGET_OS_OSX
  
  return wkWebViewConfig;
}

- (void)didMoveToWindow
{
  if (self.window != nil && _webView == nil) {
    WKWebViewConfiguration *wkWebViewConfig = [self setUpWkWebViewConfig];
#if !TARGET_OS_OSX
    _webView = [[WKWebView alloc] initWithFrame:self.bounds configuration: wkWebViewConfig];
#else
    _webView = [[RNCWKWebView alloc] initWithFrame:self.bounds configuration: wkWebViewConfig];
#endif // !TARGET_OS_OSX
    
    [self setBackgroundColor: _savedBackgroundColor];
#if !TARGET_OS_OSX
    _webView.scrollView.delegate = self;
#endif // !TARGET_OS_OSX
    _webView.UIDelegate = self;
    _webView.navigationDelegate = self;
#if !TARGET_OS_OSX
    if (_pullToRefreshEnabled) {
      [self addPullToRefreshControl];
    }
    _webView.scrollView.scrollEnabled = _scrollEnabled;
    _webView.scrollView.pagingEnabled = _pagingEnabled;
    //For UIRefreshControl to work correctly, the bounces should always be true
    _webView.scrollView.bounces = _pullToRefreshEnabled || _bounces;
    _webView.scrollView.showsHorizontalScrollIndicator = _showsHorizontalScrollIndicator;
    _webView.scrollView.showsVerticalScrollIndicator = _showsVerticalScrollIndicator;
    _webView.scrollView.directionalLockEnabled = _directionalLockEnabled;
#endif // !TARGET_OS_OSX
    _webView.allowsLinkPreview = _allowsLinkPreview;
    [_webView addObserver:self forKeyPath:@"estimatedProgress" options:NSKeyValueObservingOptionOld | NSKeyValueObservingOptionNew context:nil];
    _webView.allowsBackForwardNavigationGestures = _allowsBackForwardNavigationGestures;
    
    _webView.customUserAgent = _userAgent;
#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 110000 /* __IPHONE_11_0 */
    if ([_webView.scrollView respondsToSelector:@selector(setContentInsetAdjustmentBehavior:)]) {
      _webView.scrollView.contentInsetAdjustmentBehavior = _savedContentInsetAdjustmentBehavior;
    }
#endif
#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000 /* __IPHONE_13_0 */
    if (@available(iOS 13.0, *)) {
      _webView.scrollView.automaticallyAdjustsScrollIndicatorInsets = _savedAutomaticallyAdjustsScrollIndicatorInsets;
    }
#endif
    
#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 130300 || \
    __IPHONE_OS_VERSION_MAX_ALLOWED >= 160400 || \
    __TV_OS_VERSION_MAX_ALLOWED >= 160400
    if (@available(macOS 13.3, iOS 16.4, tvOS 16.4, *))
      _webView.inspectable = _webviewDebuggingEnabled;
#endif

    [self addSubview:_webView];
    [self setHideKeyboardAccessoryView: _savedHideKeyboardAccessoryView];
    [self setKeyboardDisplayRequiresUserAction: _savedKeyboardDisplayRequiresUserAction];
    [self visitSource];
  }
#if !TARGET_OS_OSX
  // Allow this object to recognize gestures
  if (self.menuItems != nil) {
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(startLongPress:)];
    longPress.delegate = self;
    
    longPress.minimumPressDuration = 0.4f;
    longPress.numberOfTouchesRequired = 1;
    longPress.cancelsTouchesInView = YES;
    [self addGestureRecognizer:longPress];
  }
#endif // !TARGET_OS_OSX
}

// Update webview property when the component prop changes.
- (void)setAllowsBackForwardNavigationGestures:(BOOL)allowsBackForwardNavigationGestures {
  _allowsBackForwardNavigationGestures = allowsBackForwardNavigationGestures;
  _webView.allowsBackForwardNavigationGestures = _allowsBackForwardNavigationGestures;
}

#if __MAC_OS_X_VERSION_MAX_ALLOWED >= 130300 || \
    __IPHONE_OS_VERSION_MAX_ALLOWED >= 160400 || \
    __TV_OS_VERSION_MAX_ALLOWED >= 160400
- (void)setWebviewDebuggingEnabled:(BOOL)webviewDebuggingEnabled {
  _webviewDebuggingEnabled = webviewDebuggingEnabled;
  if (@available(macOS 13.3, iOS 16.4, tvOS 16.4, *))
      _webView.inspectable = _webviewDebuggingEnabled;
}
#endif

- (void)removeFromSuperview
{
  if (_webView) {
    [_webView.configuration.userContentController removeScriptMessageHandlerForName:HistoryShimName];
    [_webView.configuration.userContentController removeScriptMessageHandlerForName:MessageHandlerName];
    [_webView removeObserver:self forKeyPath:@"estimatedProgress"];
    [_webView removeFromSuperview];
#if !TARGET_OS_OSX
    _webView.scrollView.delegate = nil;
#endif // !TARGET_OS_OSX
    _webView = nil;
  }
  
  [super removeFromSuperview];
}

#if !TARGET_OS_OSX
-(void)showFullScreenVideoStatusBars
{
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  if (!_autoManageStatusBarEnabled) {
    return;
  }
  
  _isFullScreenVideoOpen = YES;
  RCTUnsafeExecuteOnMainQueueSync(^{
    [RCTSharedApplication() setStatusBarStyle:self->_savedStatusBarStyle animated:YES];
  });
#pragma clang diagnostic pop
}

-(void)hideFullScreenVideoStatusBars
{
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  if (!_autoManageStatusBarEnabled) {
    return;
  }
  
  _isFullScreenVideoOpen = NO;
  RCTUnsafeExecuteOnMainQueueSync(^{
    [RCTSharedApplication() setStatusBarHidden:self->_savedStatusBarHidden animated:YES];
    [RCTSharedApplication() setStatusBarStyle:self->_savedStatusBarStyle animated:YES];
  });
#pragma clang diagnostic pop
}

-(void)keyboardWillHide
{
  keyboardTimer = [NSTimer scheduledTimerWithTimeInterval:0 target:self selector:@selector(keyboardDisplacementFix) userInfo:nil repeats:false];
  [[NSRunLoop mainRunLoop] addTimer:keyboardTimer forMode:NSRunLoopCommonModes];
}
-(void)keyboardWillShow
{
  if (keyboardTimer != nil) {
    [keyboardTimer invalidate];
  }
}
-(void)keyboardDisplacementFix
{
  // Additional viewport checks to prevent unintentional scrolls
  UIScrollView *scrollView = self.webView.scrollView;
  double maxContentOffset = scrollView.contentSize.height - scrollView.frame.size.height;
  if (maxContentOffset < 0) {
    maxContentOffset = 0;
  }
  if (scrollView.contentOffset.y > maxContentOffset) {
    // https://stackoverflow.com/a/9637807/824966
    [UIView animateWithDuration:.25 animations:^{
      scrollView.contentOffset = CGPointMake(0, maxContentOffset);
    }];
  }
}
#endif // !TARGET_OS_OSX

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context{
  if ([keyPath isEqual:@"estimatedProgress"] && object == self.webView) {
    if(_onLoadingProgress){
      NSMutableDictionary<NSString *, id> *event = [self baseEvent];
      [event addEntriesFromDictionary:@{@"progress":[NSNumber numberWithDouble:self.webView.estimatedProgress]}];
      _onLoadingProgress(event);
    }
  }else{
    [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
  }
}

#if !TARGET_OS_OSX
- (void)setBackgroundColor:(UIColor *)backgroundColor
#else
- (void)setBackgroundColor:(RCTUIColor *)backgroundColor
#endif // !TARGET_OS_OSX
{
  _savedBackgroundColor = backgroundColor;
  if (_webView == nil) {
    return;
  }
  
  CGFloat alpha = CGColorGetAlpha(backgroundColor.CGColor);
  BOOL opaque = (alpha == 1.0);
#if !TARGET_OS_OSX
  self.opaque = _webView.opaque = opaque;
  _webView.scrollView.backgroundColor = backgroundColor;
  _webView.backgroundColor = backgroundColor;
#endif
}

#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 110000 /* __IPHONE_11_0 */
- (void)setContentInsetAdjustmentBehavior:(UIScrollViewContentInsetAdjustmentBehavior)behavior
{
  _savedContentInsetAdjustmentBehavior = behavior;
  if (_webView == nil) {
    return;
  }
  
  if ([_webView.scrollView respondsToSelector:@selector(setContentInsetAdjustmentBehavior:)]) {
    CGPoint contentOffset = _webView.scrollView.contentOffset;
    _webView.scrollView.contentInsetAdjustmentBehavior = behavior;
    _webView.scrollView.contentOffset = contentOffset;
  }
}
#endif
#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 130000 /* __IPHONE_13_0 */
- (void)setAutomaticallyAdjustsScrollIndicatorInsets:(BOOL)automaticallyAdjustsScrollIndicatorInsets{
  _savedAutomaticallyAdjustsScrollIndicatorInsets = automaticallyAdjustsScrollIndicatorInsets;
  if (_webView == nil) {
    return;
  }
  if ([_webView.scrollView respondsToSelector:@selector(setAutomaticallyAdjustsScrollIndicatorInsets:)]) {
    _webView.scrollView.automaticallyAdjustsScrollIndicatorInsets = automaticallyAdjustsScrollIndicatorInsets;
  }
}
#endif

- (NSMutableDictionary<NSString *, id> *)baseEventWithScriptMessage:(WKScriptMessage *)message {
    WKSecurityOrigin *securityOrigin = message.frameInfo.securityOrigin;
    NSString *protocol = securityOrigin.protocol;
    NSString *host = securityOrigin.host;

    NSString *messageOriginURL = [NSString stringWithFormat:@"%@://%@", protocol, host];
    
    NSMutableDictionary<NSString *, id> *event = [self baseEvent];
    event[@"url"] = messageOriginURL;
    return event;
}

/**
 * This method is called whenever JavaScript running within the web view calls:
 *   - window.webkit.messageHandlers[MessageHandlerName].postMessage
 */
- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message
{
  if ([message.name isEqualToString:HistoryShimName]) {
    if (_onLoadingFinish) {
      NSMutableDictionary<NSString *, id> *event = [self baseEventWithScriptMessage:message];
      [event addEntriesFromDictionary: @{@"navigationType": message.body}];
      _onLoadingFinish(event);
    }
  } else if ([message.name isEqualToString:MessageHandlerName]) {
    if (_onMessage) {
      NSMutableDictionary<NSString *, id> *event = [self baseEventWithScriptMessage:message];
      [event addEntriesFromDictionary: @{@"data": message.body}];
      _onMessage(event);
    }
  }
}

- (void)setSource:(NSDictionary *)source
{
  if (![_source isEqualToDictionary:source]) {
    _source = [source copy];
    
    if (_webView != nil) {
      [self visitSource];
    }
  }
}

#if !TARGET_OS_OSX
- (void)setContentInset:(UIEdgeInsets)contentInset
{
  _contentInset = contentInset;
  [RCTView autoAdjustInsetsForView:self
                    withScrollView:_webView.scrollView
                      updateOffset:NO];
}

- (void)refreshContentInset
{
  [RCTView autoAdjustInsetsForView:self
                    withScrollView:_webView.scrollView
                      updateOffset:YES];
}
#endif // !TARGET_OS_OSX

- (void)visitSource
{
  // Check for a static html source first
  NSString *html = [RCTConvert NSString:_source[@"html"]];
  if (html) {
    NSURL *baseURL = [RCTConvert NSURL:_source[@"baseUrl"]];
    if (!baseURL) {
      baseURL = [NSURL URLWithString:@"about:blank"];
    }
    [_webView loadHTMLString:html baseURL:baseURL];
    return;
  }
  // Add cookie for subsequent resource requests sent by page itself, if cookie was set in headers on WebView
  NSString *headerCookie = [RCTConvert NSString:_source[@"headers"][@"cookie"]];
  if(headerCookie) {
    NSDictionary *headers = [NSDictionary dictionaryWithObjectsAndKeys:headerCookie,@"Set-Cookie",nil];
    NSURL *urlString = [NSURL URLWithString:_source[@"uri"]];
    NSArray *httpCookies = [NSHTTPCookie cookiesWithResponseHeaderFields:headers forURL:urlString];
    [self writeCookiesToWebView:httpCookies completion:nil];
  }
  
  NSURLRequest *request = [self requestForSource:_source];
  
  [self syncCookiesToWebView:^{
    // Because of the way React works, as pages redirect, we actually end up
    // passing the redirect urls back here, so we ignore them if trying to load
    // the same url. We'll expose a call to 'reload' to allow a user to load
    // the existing page.
    if ([request.URL isEqual:_webView.URL]) {
      return;
    }
    if (!request.URL) {
      // Clear the webview
      [_webView loadHTMLString:@"" baseURL:nil];
      return;
    }
    if (request.URL.host) {
      [_webView loadRequest:request];
    }
    else {
      // WARNING: UNREACHABLE, non-host loads (file urls)
      // Clear the webview
      [_webView loadHTMLString:@"" baseURL:nil];
      return;
    }
  }];
}

#if !TARGET_OS_OSX
-(void)setKeyboardDisplayRequiresUserAction:(BOOL)keyboardDisplayRequiresUserAction
{
  if (_webView == nil) {
    _savedKeyboardDisplayRequiresUserAction = keyboardDisplayRequiresUserAction;
    return;
  }
  
  if (_savedKeyboardDisplayRequiresUserAction == true) {
    return;
  }
  
  UIView* subview;
  
  for (UIView* view in _webView.scrollView.subviews) {
    if([[view.class description] hasPrefix:@"WK"])
      subview = view;
  }
  
  if(subview == nil) return;
  
  Class class = subview.class;
  
  NSOperatingSystemVersion iOS_11_3_0 = (NSOperatingSystemVersion){11, 3, 0};
  NSOperatingSystemVersion iOS_12_2_0 = (NSOperatingSystemVersion){12, 2, 0};
  NSOperatingSystemVersion iOS_13_0_0 = (NSOperatingSystemVersion){13, 0, 0};
  
  Method method;
  IMP override;
  
  if ([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion: iOS_13_0_0]) {
    // iOS 13.0.0 - Future
    SEL selector = sel_getUid("_elementDidFocus:userIsInteracting:blurPreviousNode:activityStateChanges:userObject:");
    method = class_getInstanceMethod(class, selector);
    IMP original = method_getImplementation(method);
    override = imp_implementationWithBlock(^void(id me, void* arg0, BOOL arg1, BOOL arg2, BOOL arg3, id arg4) {
      ((void (*)(id, SEL, void*, BOOL, BOOL, BOOL, id))original)(me, selector, arg0, TRUE, arg2, arg3, arg4);
    });
  }
  else if ([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion: iOS_12_2_0]) {
    // iOS 12.2.0 - iOS 13.0.0
    SEL selector = sel_getUid("_elementDidFocus:userIsInteracting:blurPreviousNode:changingActivityState:userObject:");
    method = class_getInstanceMethod(class, selector);
    IMP original = method_getImplementation(method);
    override = imp_implementationWithBlock(^void(id me, void* arg0, BOOL arg1, BOOL arg2, BOOL arg3, id arg4) {
      ((void (*)(id, SEL, void*, BOOL, BOOL, BOOL, id))original)(me, selector, arg0, TRUE, arg2, arg3, arg4);
    });
  }
  else if ([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion: iOS_11_3_0]) {
    // iOS 11.3.0 - 12.2.0
    SEL selector = sel_getUid("_startAssistingNode:userIsInteracting:blurPreviousNode:changingActivityState:userObject:");
    method = class_getInstanceMethod(class, selector);
    IMP original = method_getImplementation(method);
    override = imp_implementationWithBlock(^void(id me, void* arg0, BOOL arg1, BOOL arg2, BOOL arg3, id arg4) {
      ((void (*)(id, SEL, void*, BOOL, BOOL, BOOL, id))original)(me, selector, arg0, TRUE, arg2, arg3, arg4);
    });
  } else {
    // iOS 9.0 - 11.3.0
    SEL selector = sel_getUid("_startAssistingNode:userIsInteracting:blurPreviousNode:userObject:");
    method = class_getInstanceMethod(class, selector);
    IMP original = method_getImplementation(method);
    override = imp_implementationWithBlock(^void(id me, void* arg0, BOOL arg1, BOOL arg2, id arg3) {
      ((void (*)(id, SEL, void*, BOOL, BOOL, id))original)(me, selector, arg0, TRUE, arg2, arg3);
    });
  }
  
  method_setImplementation(method, override);
}

-(void)setHideKeyboardAccessoryView:(BOOL)hideKeyboardAccessoryView
{
  if (_webView == nil) {
    _savedHideKeyboardAccessoryView = hideKeyboardAccessoryView;
    return;
  }
  
  if (_savedHideKeyboardAccessoryView == false) {
    return;
  }
  
  UIView* subview;
  
  for (UIView* view in _webView.scrollView.subviews) {
    if([[view.class description] hasPrefix:@"WK"])
      subview = view;
  }
  
  if(subview == nil) return;
  
  NSString* name = [NSString stringWithFormat:@"%@__SwizzleHelperWK", subview.class.superclass];
  Class newClass = NSClassFromString(name);
  
  if(newClass == nil)
  {
    newClass = objc_allocateClassPair(subview.class, [name cStringUsingEncoding:NSASCIIStringEncoding], 0);
    if(!newClass) return;
    
    Method method = class_getInstanceMethod([__SwizzleHelperWK class], @selector(inputAccessoryView));
    class_addMethod(newClass, @selector(inputAccessoryView), method_getImplementation(method), method_getTypeEncoding(method));
    
    objc_registerClassPair(newClass);
  }
  
  object_setClass(subview, newClass);
}

// UIScrollViewDelegate method
- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView
{
  scrollView.decelerationRate = _decelerationRate;
}
#endif // !TARGET_OS_OSX

- (void)setUserAgent:(NSString*)userAgent
{
  _userAgent = userAgent;
  _webView.customUserAgent = userAgent;
}

- (void)setScrollEnabled:(BOOL)scrollEnabled
{
  _scrollEnabled = scrollEnabled;
#if !TARGET_OS_OSX
  _webView.scrollView.scrollEnabled = scrollEnabled;
#endif // !TARGET_OS_OSX
}

#if !TARGET_OS_OSX
// UIScrollViewDelegate method
- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
  // Don't allow scrolling the scrollView.
  if (!_scrollEnabled) {
    scrollView.bounds = _webView.bounds;
  }
  else if (_onScroll != nil) {
    NSDictionary *event = @{
      @"contentOffset": @{
        @"x": @(scrollView.contentOffset.x),
        @"y": @(scrollView.contentOffset.y)
      },
      @"contentInset": @{
        @"top": @(scrollView.contentInset.top),
        @"left": @(scrollView.contentInset.left),
        @"bottom": @(scrollView.contentInset.bottom),
        @"right": @(scrollView.contentInset.right)
      },
      @"contentSize": @{
        @"width": @(scrollView.contentSize.width),
        @"height": @(scrollView.contentSize.height)
      },
      @"layoutMeasurement": @{
        @"width": @(scrollView.frame.size.width),
        @"height": @(scrollView.frame.size.height)
      },
      @"zoomScale": @(scrollView.zoomScale ?: 1),
    };
    _onScroll(event);
  }
}

- (void)setDirectionalLockEnabled:(BOOL)directionalLockEnabled
{
  _directionalLockEnabled = directionalLockEnabled;
  _webView.scrollView.directionalLockEnabled = directionalLockEnabled;
}

- (void)setShowsHorizontalScrollIndicator:(BOOL)showsHorizontalScrollIndicator
{
  _showsHorizontalScrollIndicator = showsHorizontalScrollIndicator;
  _webView.scrollView.showsHorizontalScrollIndicator = showsHorizontalScrollIndicator;
}

- (void)setShowsVerticalScrollIndicator:(BOOL)showsVerticalScrollIndicator
{
  _showsVerticalScrollIndicator = showsVerticalScrollIndicator;
  _webView.scrollView.showsVerticalScrollIndicator = showsVerticalScrollIndicator;
}
#endif // !TARGET_OS_OSX

- (void)postMessage:(NSString *)message
{
  NSDictionary *eventInitDict = @{@"data": message};
  NSString *source = [NSString
                      stringWithFormat:@"document.dispatchEvent(new MessageEvent('message', %@));",
                      RCTJSONStringify(eventInitDict, NULL)
  ];
  [self injectJavaScript: source];
}

- (void)layoutSubviews
{
  [super layoutSubviews];
  
  // Ensure webview takes the position and dimensions of RNCWebView
  _webView.frame = self.bounds;
#if !TARGET_OS_OSX
  _webView.scrollView.contentInset = _contentInset;
#endif // !TARGET_OS_OSX
}

- (NSMutableDictionary<NSString *, id> *)baseEvent
{
  NSDictionary *event = @{
    @"url": _webView.URL.absoluteString ?: @"",
    @"title": _webView.title ?: @"",
    @"loading" : @(_webView.loading),
    @"canGoBack": @(_webView.canGoBack),
    @"canGoForward" : @(_webView.canGoForward)
  };
  return [[NSMutableDictionary alloc] initWithDictionary: event];
}

+ (void)setClientAuthenticationCredential:(nullable NSURLCredential*)credential {
  clientAuthenticationCredential = credential;
}

+ (void)setCustomCertificatesForHost:(nullable NSDictionary*)certificates {
  customCertificatesForHost = certificates;
}

- (void)                    webView:(WKWebView *)webView
  didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
                  completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential * _Nullable))completionHandler
{
  NSString* host = nil;
  if (webView.URL != nil) {
    host = webView.URL.host;
  }
  if ([[challenge protectionSpace] authenticationMethod] == NSURLAuthenticationMethodClientCertificate) {
    completionHandler(NSURLSessionAuthChallengeUseCredential, clientAuthenticationCredential);
    return;
  }
  if ([[challenge protectionSpace] serverTrust] != nil && customCertificatesForHost != nil && host != nil) {
    SecCertificateRef localCertificate = (__bridge SecCertificateRef)([customCertificatesForHost objectForKey:host]);
    if (localCertificate != nil) {
      NSData *localCertificateData = (NSData*) CFBridgingRelease(SecCertificateCopyData(localCertificate));
      SecTrustRef trust = [[challenge protectionSpace] serverTrust];
      long count = SecTrustGetCertificateCount(trust);
      for (long i = 0; i < count; i++) {
        SecCertificateRef serverCertificate = SecTrustGetCertificateAtIndex(trust, i);
        if (serverCertificate == nil) { continue; }
        NSData *serverCertificateData = (NSData *) CFBridgingRelease(SecCertificateCopyData(serverCertificate));
        if ([serverCertificateData isEqualToData:localCertificateData]) {
          NSURLCredential *useCredential = [NSURLCredential credentialForTrust:trust];
          if (challenge.sender != nil) {
            [challenge.sender useCredential:useCredential forAuthenticationChallenge:challenge];
          }
          completionHandler(NSURLSessionAuthChallengeUseCredential, useCredential);
          return;
        }
      }
    }
  }
  if ([[challenge protectionSpace] authenticationMethod] == NSURLAuthenticationMethodHTTPBasic) {
    NSString *username = [_basicAuthCredential valueForKey:@"username"];
    NSString *password = [_basicAuthCredential valueForKey:@"password"];
    if (username && password) {
      NSURLCredential *credential = [NSURLCredential credentialWithUser:username password:password persistence:NSURLCredentialPersistenceNone];
      completionHandler(NSURLSessionAuthChallengeUseCredential, credential);
      return;
    }
  }
  completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}

#pragma mark - WKNavigationDelegate methods

/**
 * alert
 */
- (void)webView:(WKWebView *)webView runJavaScriptAlertPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(void))completionHandler
{
#if !TARGET_OS_OSX
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"" message:message preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"Ok" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
    completionHandler();
  }]];
  [[self topViewController] presentViewController:alert animated:YES completion:NULL];
#else
  NSAlert *alert = [[NSAlert alloc] init];
  [alert setMessageText:message];
  [alert beginSheetModalForWindow:[NSApp keyWindow] completionHandler:^(__unused NSModalResponse response){
    completionHandler();
  }];
#endif // !TARGET_OS_OSX
}

/**
 * confirm
 */
- (void)webView:(WKWebView *)webView runJavaScriptConfirmPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(BOOL))completionHandler{
#if !TARGET_OS_OSX
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"" message:message preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:@"Ok" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
    completionHandler(YES);
  }]];
  [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
    completionHandler(NO);
  }]];
  [[self topViewController] presentViewController:alert animated:YES completion:NULL];
#else
  NSAlert *alert = [[NSAlert alloc] init];
  [alert setMessageText:message];
  [alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK button")];
  [alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"Cancel button")];
  void (^callbacksHandlers)(NSModalResponse response) = ^void(NSModalResponse response) {
    completionHandler(response == NSAlertFirstButtonReturn);
  };
  [alert beginSheetModalForWindow:[NSApp keyWindow] completionHandler:callbacksHandlers];
#endif // !TARGET_OS_OSX
}

/**
 * prompt
 */
- (void)webView:(WKWebView *)webView runJavaScriptTextInputPanelWithPrompt:(NSString *)prompt defaultText:(NSString *)defaultText initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(NSString *))completionHandler{
#if !TARGET_OS_OSX
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"" message:prompt preferredStyle:UIAlertControllerStyleAlert];
  [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
    textField.text = defaultText;
  }];
  UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"Ok" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
    completionHandler([[alert.textFields lastObject] text]);
  }];
  [alert addAction:okAction];
  UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
    completionHandler(nil);
  }];
  [alert addAction:cancelAction];
  alert.preferredAction = okAction;
  [[self topViewController] presentViewController:alert animated:YES completion:NULL];
#else
  NSAlert *alert = [[NSAlert alloc] init];
  [alert setMessageText:prompt];
  
  const NSRect RCTSingleTextFieldFrame = NSMakeRect(0.0, 0.0, 275.0, 22.0);
  NSTextField *textField = [[NSTextField alloc] initWithFrame:RCTSingleTextFieldFrame];
  textField.cell.scrollable = YES;
  textField.stringValue = defaultText;
  [alert setAccessoryView:textField];
  
  [alert addButtonWithTitle:NSLocalizedString(@"OK", @"OK button")];
  [alert addButtonWithTitle:NSLocalizedString(@"Cancel", @"Cancel button")];
  [alert beginSheetModalForWindow:[NSApp keyWindow] completionHandler:^(NSModalResponse response) {
    if (response == NSAlertFirstButtonReturn) {
      completionHandler([textField stringValue]);
    } else {
      completionHandler(nil);
    }
  }];
#endif // !TARGET_OS_OSX
}

#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED) && __IPHONE_OS_VERSION_MAX_ALLOWED >= 150000 /* iOS 15 */
/**
 * Media capture permissions (prevent multiple prompts)
 */
- (void)                         webView:(WKWebView *)webView
  requestMediaCapturePermissionForOrigin:(WKSecurityOrigin *)origin
                        initiatedByFrame:(WKFrameInfo *)frame
                                    type:(WKMediaCaptureType)type
                         decisionHandler:(void (^)(WKPermissionDecision decision))decisionHandler {
  if (![cameraPermissionWhitelist containsObject:origin.host]) {
    decisionHandler(WKPermissionDecisionDeny);
    return;
  }

  if (_mediaCapturePermissionGrantType == RNCWebViewPermissionGrantType_GrantIfSameHost_ElsePrompt || _mediaCapturePermissionGrantType == RNCWebViewPermissionGrantType_GrantIfSameHost_ElseDeny) {
    if ([origin.host isEqualToString:webView.URL.host]) {
      decisionHandler(WKPermissionDecisionGrant);
    } else {
      WKPermissionDecision decision = _mediaCapturePermissionGrantType == RNCWebViewPermissionGrantType_GrantIfSameHost_ElsePrompt ? WKPermissionDecisionPrompt : WKPermissionDecisionDeny;
      decisionHandler(decision);
    }
  } else if (_mediaCapturePermissionGrantType == RNCWebViewPermissionGrantType_Deny) {
    decisionHandler(WKPermissionDecisionDeny);
  } else if (_mediaCapturePermissionGrantType == RNCWebViewPermissionGrantType_Grant) {
    decisionHandler(WKPermissionDecisionGrant);
  } else {
    decisionHandler(WKPermissionDecisionPrompt);
  }
}
#endif

#if !TARGET_OS_OSX
/**
 * topViewController
 */
-(UIViewController *)topViewController{
  return RCTPresentedViewController();
}

#endif // !TARGET_OS_OSX

/**
 * Decides whether to allow or cancel a navigation.
 * @see https://fburl.com/42r9fxob
 */
- (void)                  webView:(WKWebView *)webView
  decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
                  decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
  static NSDictionary<NSNumber *, NSString *> *navigationTypes;
  static dispatch_once_t onceToken;
  
  dispatch_once(&onceToken, ^{
    navigationTypes = @{
      @(WKNavigationTypeLinkActivated): @"click",
      @(WKNavigationTypeFormSubmitted): @"formsubmit",
      @(WKNavigationTypeBackForward): @"backforward",
      @(WKNavigationTypeReload): @"reload",
      @(WKNavigationTypeFormResubmitted): @"formresubmit",
      @(WKNavigationTypeOther): @"other",
    };
  });
  
  WKNavigationType navigationType = navigationAction.navigationType;
  NSURLRequest *request = navigationAction.request;
  BOOL isTopFrame = [request.URL isEqual:request.mainDocumentURL];
  
  if (_onShouldStartLoadWithRequest) {
    NSMutableDictionary<NSString *, id> *event = [self baseEvent];
    if (request.mainDocumentURL) {
      [event addEntriesFromDictionary: @{
        @"mainDocumentURL": (request.mainDocumentURL).absoluteString,
      }];
    }
    [event addEntriesFromDictionary: @{
      @"url": (request.URL).absoluteString,
      @"navigationType": navigationTypes[@(navigationType)],
      @"isTopFrame": @(isTopFrame)
    }];
    if (![self.delegate webView:self
      shouldStartLoadForRequest:event
                   withCallback:_onShouldStartLoadWithRequest]) {
      decisionHandler(WKNavigationActionPolicyCancel);
      return;
    }
  }
  
  if (_onLoadingStart) {
    // We have this check to filter out iframe requests and whatnot
    if (isTopFrame) {
      NSMutableDictionary<NSString *, id> *event = [self baseEvent];
      [event addEntriesFromDictionary: @{
        @"url": (request.URL).absoluteString,
        @"navigationType": navigationTypes[@(navigationType)]
      }];
      _onLoadingStart(event);
    }
  }
  
  // Allow all navigation by default
  decisionHandler(WKNavigationActionPolicyAllow);
}

/**
 * Called when the web view’s content process is terminated.
 * @see https://developer.apple.com/documentation/webkit/wknavigationdelegate/1455639-webviewwebcontentprocessdidtermi?language=objc
 */
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView
{
  RCTLogWarn(@"Webview Process Terminated");
}

/**
 * Decides whether to allow or cancel a navigation after its response is known.
 * @see https://developer.apple.com/documentation/webkit/wknavigationdelegate/1455643-webview?language=objc
 */
- (void)                    webView:(WKWebView *)webView
  decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse
                    decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler
{
  WKNavigationResponsePolicy policy = WKNavigationResponsePolicyAllow;
  if (navigationResponse.forMainFrame) {
    if ([navigationResponse.response isKindOfClass:[NSHTTPURLResponse class]]) {
      NSHTTPURLResponse *response = (NSHTTPURLResponse *)navigationResponse.response;
      NSInteger statusCode = response.statusCode;
      
      NSString *disposition = nil;
      if (@available(iOS 13, *)) {
        disposition = [response valueForHTTPHeaderField:@"Content-Disposition"];
      }
      BOOL isAttachment = disposition != nil && [disposition hasPrefix:@"attachment"];
      if (isAttachment || !navigationResponse.canShowMIMEType) {
        policy = WKNavigationResponsePolicyCancel;
        // File downloads are cancelled
      }
    }
  }
  
  decisionHandler(policy);
}

/**
 * Called when an error occurs while the web view is loading content.
 * @see https://fburl.com/km6vqenw
 */
- (void)               webView:(WKWebView *)webView
  didFailProvisionalNavigation:(WKNavigation *)navigation
                     withError:(NSError *)error
{
  if (_onLoadingError) {
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) {
      // NSURLErrorCancelled is reported when a page has a redirect OR if you load
      // a new URL in the WebView before the previous one came back. We can just
      // ignore these since they aren't real errors.
      // http://stackoverflow.com/questions/1024748/how-do-i-fix-nsurlerrordomain-error-999-in-iphone-3-0-os
      return;
    }
    
    if ([error.domain isEqualToString:@"WebKitErrorDomain"] &&
        (error.code == 102 || error.code == 101)) {
      // Error code 102 "Frame load interrupted" is raised by the WKWebView
      // when the URL is from an http redirect. This is a common pattern when
      // implementing OAuth with a WebView.
      return;
    }
    
    NSMutableDictionary<NSString *, id> *event = [self baseEvent];
    [event addEntriesFromDictionary:@{
      @"didFailProvisionalNavigation": @YES,
      @"domain": error.domain,
      @"code": @(error.code),
      @"description": error.localizedDescription,
    }];
    _onLoadingError(event);
  }
}

- (void)evaluateJS:(NSString *)js
          thenCall: (void (^)(NSString*)) callback
{
  if (self.enableApplePay) {
    RCTLogWarn(@"Cannot run javascript when apple pay is enabled");
    return;
  }
  [self.webView evaluateJavaScript: js completionHandler: ^(id result, NSError *error) {
    if (callback != nil) {
      callback([NSString stringWithFormat:@"%@", result]);
    }
    if (error != nil) {
      RCTLogWarn(@"%@", [NSString stringWithFormat:@"Error evaluating injectedJavaScript: This is possibly due to an unsupported return type. Try adding true to the end of your injectedJavaScript string. %@", error]);
    }
  }];
}

/**
 * Called when the navigation is complete.
 * @see https://fburl.com/rtys6jlb
 */
- (void)webView:(WKWebView *)webView
didFinishNavigation:(WKNavigation *)navigation
{
  if (_onLoadingFinish) {
    _onLoadingFinish([self baseEvent]);
  }
}

- (void)cookiesDidChangeInCookieStore:(WKHTTPCookieStore *)cookieStore
{
}

- (void)injectJavaScript:(NSString *)script
{
  [self evaluateJS: script thenCall: nil];
}

- (void)goForward
{
  [_webView goForward];
}

- (void)goBack
{
  [_webView goBack];
}

- (void)reload
{
  /**
   * When the initial load fails due to network connectivity issues,
   * [_webView reload] doesn't reload the webpage. Therefore, we must
   * manually call [_webView loadRequest:request].
   */
  NSURLRequest *request = [self requestForSource:self.source];
  
  if (request.URL && !_webView.URL.absoluteString.length) {
    [_webView loadRequest:request];
  } else {
    [_webView reload];
  }
}
#if !TARGET_OS_OSX
- (void)addPullToRefreshControl
{
  UIRefreshControl *refreshControl = [[UIRefreshControl alloc] init];
  _refreshControl = refreshControl;
  [_webView.scrollView addSubview: refreshControl];
  [refreshControl addTarget:self action:@selector(pullToRefresh:) forControlEvents: UIControlEventValueChanged];
}

- (void)pullToRefresh:(UIRefreshControl *)refreshControl
{
  [self reload];
  [refreshControl endRefreshing];
}


- (void)setPullToRefreshEnabled:(BOOL)pullToRefreshEnabled
{
  _pullToRefreshEnabled = pullToRefreshEnabled;
  
  if (pullToRefreshEnabled) {
    [self addPullToRefreshControl];
  } else {
    [_refreshControl removeFromSuperview];
  }
  
  [self setBounces:_bounces];
}
#endif // !TARGET_OS_OSX

- (void)stopLoading
{
  [_webView stopLoading];
}

- (void)requestFocus
{
#if !TARGET_OS_OSX
  [_webView becomeFirstResponder];
#endif // !TARGET_OS_OSX
}

#if !TARGET_OS_OSX
- (void)setBounces:(BOOL)bounces
{
  _bounces = bounces;
  //For UIRefreshControl to work correctly, the bounces should always be true
  _webView.scrollView.bounces = _pullToRefreshEnabled || bounces;
}
#endif // !TARGET_OS_OSX

- (void)setInjectedJavaScript:(NSString *)source {
  _injectedJavaScript = source;
  
  self.atEndScript = source == nil ? nil : [[WKUserScript alloc] initWithSource:source
                                                                  injectionTime:WKUserScriptInjectionTimeAtDocumentEnd
                                                               forMainFrameOnly:YES];
  
  if(_webView != nil){
    [self resetupScripts:_webView.configuration];
  }
}

- (void)setInjectedJavaScriptBeforeContentLoaded:(NSString *)source {
  _injectedJavaScriptBeforeContentLoaded = source;
  
  self.atStartScript = source == nil ? nil : [[WKUserScript alloc] initWithSource:source
                                                                    injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                                 forMainFrameOnly:YES];
  
  if(_webView != nil){
    [self resetupScripts:_webView.configuration];
  }
}

- (void)setMessagingEnabled:(BOOL)messagingEnabled {
  _messagingEnabled = messagingEnabled;
  
  self.postMessageScript = _messagingEnabled ?
  [
    [WKUserScript alloc]
    initWithSource: [
      NSString
      stringWithFormat:
        @"window.%@ = {"
      "  postMessage: function (data) {"
      "    window.webkit.messageHandlers.%@.postMessage(String(data));"
      "  }"
      "};", MessageHandlerName, MessageHandlerName
    ]
    injectionTime:WKUserScriptInjectionTimeAtDocumentStart
    forMainFrameOnly:YES
  ] :
  nil;
  
  if(_webView != nil){
    [self resetupScripts:_webView.configuration];
  }
}

- (void)writeCookiesToWebView:(NSArray<NSHTTPCookie *>*)cookies completion:(void (^)(void))completion {
  if (completion) {
    completion();
  }
}

- (void)syncCookiesToWebView:(void (^)(void))completion {
  NSArray<NSHTTPCookie *> *cookies = [[NSHTTPCookieStorage sharedHTTPCookieStorage] cookies];
  [self writeCookiesToWebView:cookies completion:completion];
}

- (void)resetupScripts:(WKWebViewConfiguration *)wkWebViewConfig {
  [wkWebViewConfig.userContentController removeAllUserScripts];
  [wkWebViewConfig.userContentController removeScriptMessageHandlerForName:MessageHandlerName];
  if(self.enableApplePay){
    if (self.postMessageScript){
      [wkWebViewConfig.userContentController addScriptMessageHandler:[[RNCWeakScriptMessageDelegate alloc] initWithDelegate:self]
                                                                name:MessageHandlerName];
    }
    return;
  }
  
  NSString *html5HistoryAPIShimSource = [NSString stringWithFormat:
                                           @"(function(history) {\n"
                                         "  function notify(type) {\n"
                                         "    setTimeout(function() {\n"
                                         "      window.webkit.messageHandlers.%@.postMessage(type)\n"
                                         "    }, 0)\n"
                                         "  }\n"
                                         "  function shim(f) {\n"
                                         "    return function pushState() {\n"
                                         "      notify('other')\n"
                                         "      return f.apply(history, arguments)\n"
                                         "    }\n"
                                         "  }\n"
                                         "  history.pushState = shim(history.pushState)\n"
                                         "  history.replaceState = shim(history.replaceState)\n"
                                         "  window.addEventListener('popstate', function() {\n"
                                         "    notify('backforward')\n"
                                         "  })\n"
                                         "})(window.history)\n", HistoryShimName
  ];
  WKUserScript *script = [[WKUserScript alloc] initWithSource:html5HistoryAPIShimSource injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:YES];
  [wkWebViewConfig.userContentController addUserScript:script];
  
  if(_messagingEnabled){
    if (self.postMessageScript){
      [wkWebViewConfig.userContentController addScriptMessageHandler:[[RNCWeakScriptMessageDelegate alloc] initWithDelegate:self]
                                                                name:MessageHandlerName];
      [wkWebViewConfig.userContentController addUserScript:self.postMessageScript];
    }
    if (self.atEndScript) {
      [wkWebViewConfig.userContentController addUserScript:self.atEndScript];
    }
  }
  // Whether or not messaging is enabled, add the startup script if it exists.
  if (self.atStartScript) {
    [wkWebViewConfig.userContentController addUserScript:self.atStartScript];
  }
}

- (NSURLRequest *)requestForSource:(id)json {
  NSURLRequest *request = [RCTConvert NSURLRequest:self.source];
  
  return request;
}

@end

@implementation RNCWeakScriptMessageDelegate

- (instancetype)initWithDelegate:(id<WKScriptMessageHandler>)scriptDelegate {
  self = [super init];
  if (self) {
    _scriptDelegate = scriptDelegate;
  }
  return self;
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
  [self.scriptDelegate userContentController:userContentController didReceiveScriptMessage:message];
}

@end
