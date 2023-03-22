package com.reactnativecommunity.webview;

import android.webkit.WebView;

import com.facebook.react.bridge.Promise;
import com.facebook.react.bridge.ReactApplicationContext;
import com.facebook.react.bridge.ReactContextBaseJavaModule;
import com.facebook.react.uimanager.ThemedReactContext;
import com.facebook.react.bridge.ReactMethod;
import com.facebook.react.bridge.UiThreadUtil;

public class RNCWebViewUtils extends ReactContextBaseJavaModule {
  public static final String NAME = "RNCWebViewUtils";

  ReactApplicationContext mCallerContext;

  public RNCWebViewUtils(ReactApplicationContext reactContext) {
    super(reactContext);
    mCallerContext = reactContext;
  }

  @Override
  public String getName() {
    return NAME;
  }

  @ReactMethod
  public void getWebViewDefaultUserAgent(final Promise promise) {
    UiThreadUtil.runOnUiThread(new Runnable() {
        @Override
        public void run() {
          try {
            WebView webView = new WebView(mCallerContext);

            // in case we ever use our own UA we need to unset it first the get the original
            String currentUA = webView.getSettings().getUserAgentString();
            webView.getSettings().setUserAgentString(null);
            String webViewUA = webView.getSettings().getUserAgentString();

            // Revert to overriden UA string
            webView.getSettings().setUserAgentString(currentUA);

            promise.resolve(webViewUA);
          }
          catch (Exception e) {
            promise.reject(NAME, e.getMessage());
          }
        }
    });
  }
}
