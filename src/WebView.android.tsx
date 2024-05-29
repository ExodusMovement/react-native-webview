import React, { forwardRef, useCallback, useEffect, useImperativeHandle, useMemo, useRef, useState } from 'react';

import {
  Text,
  View,
  NativeModules,
} from 'react-native';

import BatchedBridge from 'react-native/Libraries/BatchedBridge/BatchedBridge';
// @ts-expect-error react-native doesn't have this type
import codegenNativeCommandsUntyped from 'react-native/Libraries/Utilities/codegenNativeCommands';

import invariant from 'invariant';

import RNCWebView from "./WebViewNativeComponent.android";
import {
  defaultOriginWhitelist,
  defaultDeeplinkWhitelist,
  defaultRenderError,
  defaultRenderLoading,
  useWebWiewLogic,
  versionPasses,
} from './WebViewShared';
import {
  AndroidWebViewProps,
  NativeWebViewAndroid,
} from './WebViewTypes';

import styles from './WebView.styles';

const { getWebViewDefaultUserAgent } = NativeModules.RNCWebViewUtils;

let userAgentPromise: Promise<string> | undefined

async function getUserAgent(): Promise<string> {
  if (!userAgentPromise) userAgentPromise = getWebViewDefaultUserAgent()
  const userAgent = await userAgentPromise
  return userAgent || 'unknown'
}

const codegenNativeCommands = codegenNativeCommandsUntyped as <T extends {}>(options: { supportedCommands: (keyof T)[] }) => T;

const Commands = codegenNativeCommands({
  supportedCommands: ['goBack', 'goForward', 'reload', 'stopLoading', /* 'injectJavaScript', */ 'requestFocus', 'postMessage', 'clearFormData', 'clearCache', 'clearHistory', 'loadUrl'],
});

/**
 * A simple counter to uniquely identify WebView instances. Do not use this for anything else.
 */
let uniqueRef = 0;

/**
 * Harcoded default for security.
 */
const mediaPlaybackRequiresUserAction = true;
// Android only
const setSupportMultipleWindows = true;
const mixedContentMode = 'never'
const hardMinimumChromeVersion = '100.0' // TODO: determinime a good lower bound

const WebViewComponent = forwardRef<{}, AndroidWebViewProps>(({
  overScrollMode = 'always',
  javaScriptEnabled = true,
  thirdPartyCookiesEnabled = true,
  scalesPageToFit = true,
  saveFormDataDisabled = false,
  cacheEnabled = true,
  androidHardwareAccelerationDisabled = false,
  androidLayerType = "none",
  originWhitelist = defaultOriginWhitelist,
  deeplinkWhitelist = defaultDeeplinkWhitelist,
  setBuiltInZoomControls = true,
  setDisplayZoomControls = false,
  nestedScrollEnabled = false,
  startInLoadingState,
  onLoadStart,
  onError,
  onLoad,
  onLoadEnd,
  onMessage: onMessageProp,
  onOpenWindow: onOpenWindowProp,
  renderLoading,
  renderError,
  style,
  containerStyle,
  source,
  onShouldStartLoadWithRequest: onShouldStartLoadWithRequestProp,
  validateMeta,
  validateData,
  minimumChromeVersion,
  unsupportedVersionComponent: UnsupportedVersionComponent,
  ...otherProps
}, ref) => {
  const messagingModuleName = useRef<string>(`WebViewMessageHandler${uniqueRef += 1}`).current;
  const webViewRef = useRef<NativeWebViewAndroid | null>(null);

  const onShouldStartLoadWithRequestCallback = useCallback((shouldStart: boolean,
    url: string,
    lockIdentifier?: number) => {
    if (lockIdentifier) {
      NativeModules.RNCWebView.onShouldStartLoadWithRequestCallback(shouldStart, lockIdentifier);
    } else if (shouldStart) {
      Commands.loadUrl(webViewRef.current, url);
    }
  }, []);

  const { onLoadingStart, onShouldStartLoadWithRequest, onMessage, viewState, setViewState, lastErrorEvent, onLoadingError, onLoadingFinish, onLoadingProgress, onOpenWindow, passesWhitelist } = useWebWiewLogic({
    onLoad,
    onError,
    onLoadEnd,
    onLoadStart,
    onMessageProp,
    onOpenWindowProp,
    startInLoadingState,
    originWhitelist,
    deeplinkWhitelist,
    onShouldStartLoadWithRequestProp,
    onShouldStartLoadWithRequestCallback,
    validateMeta,
    validateData,
  })

  useImperativeHandle(ref, () => ({
    goForward: () => webViewRef.current && Commands.goForward(webViewRef.current),
    goBack: () => webViewRef.current && Commands.goBack(webViewRef.current),
    reload: () => {
      setViewState(
        'LOADING',
      ); 
      if (webViewRef.current) {
        Commands.reload(webViewRef.current)
      }
    },
    stopLoading: () => webViewRef.current && Commands.stopLoading(webViewRef.current),
    postMessage: (data: string) => webViewRef.current && Commands.postMessage(webViewRef.current, data),
    // injectJavaScript: (data: string) => Commands.injectJavaScript(webViewRef.current, data),
    requestFocus: () => webViewRef.current && Commands.requestFocus(webViewRef.current),
    clearFormData: () => webViewRef.current && Commands.clearFormData(webViewRef.current),
    clearCache: (includeDiskFiles: boolean) => webViewRef.current && Commands.clearCache(webViewRef.current, includeDiskFiles),
    clearHistory: () => webViewRef.current && Commands.clearHistory(webViewRef.current),
  }), [setViewState, webViewRef]);

  const directEventCallbacks = useMemo(() => ({
    onShouldStartLoadWithRequest,
    onMessage,
  }), [onMessage, onShouldStartLoadWithRequest]);

  useEffect(() => {
    BatchedBridge.registerCallableModule(messagingModuleName, directEventCallbacks);
  }, [messagingModuleName, directEventCallbacks])

  const [userAgent, setUserAgent] = useState<string>()

  useEffect(() => {
    getUserAgent().then(setUserAgent)
  }, [])

  if (!userAgent) return null // stop the rendering until userAgent is known
  const version = userAgent.match(/chrome\/((?:[0-9]+\.)+[0-9]+)/i)?.[1]
  if (!(versionPasses(version, minimumChromeVersion) && versionPasses(version, hardMinimumChromeVersion))) {
    if (UnsupportedVersionComponent) {
      return <UnsupportedVersionComponent />
    }
    return (
      <View style={{ alignSelf: 'flex-start' }}>
        <Text style={{ color: 'red' }}>
          Chrome version is outdated and insecure. Update it to continue.
        </Text>
      </View>
    );
  }

  let otherView = null;
  if (viewState === 'LOADING') {
    otherView = (renderLoading || defaultRenderLoading)();
  } else if (viewState === 'ERROR') {
    invariant(lastErrorEvent != null, 'lastErrorEvent expected to be non-null');
    otherView = (renderError || defaultRenderError)(
      lastErrorEvent.domain,
      lastErrorEvent.code,
      lastErrorEvent.description,
    );
  } else if (viewState !== 'IDLE') {
    console.error(`RNCWebView invalid state encountered: ${viewState}`);
  }

  const webViewStyles = [styles.container, styles.webView, style];
  const webViewContainerStyle = [styles.container, containerStyle];

  if (typeof source !== "number" && source && 'method' in source) {
    if (source.method === 'POST' && source.headers) {
      console.warn(
        'WebView: `source.headers` is not supported when using POST.',
      );
    } else if (source.method === 'GET' && source.body) {
      console.warn('WebView: `source.body` is not supported when using GET.');
    }
  }

  if (typeof source === "object" && 'uri' in source && !passesWhitelist(source.uri)){
    // eslint-disable-next-line
    source = {uri: "about:blank"};
  }

  const NativeWebView = RNCWebView;

  const webView = <NativeWebView
    key="webViewKey"
    {...otherProps}
    messagingEnabled={typeof onMessageProp === 'function'}
    messagingModuleName={messagingModuleName}

    onLoadingError={onLoadingError}
    onLoadingFinish={onLoadingFinish}
    onLoadingProgress={onLoadingProgress}
    onLoadingStart={onLoadingStart}
    onMessage={onMessage}
    onOpenWindow={onOpenWindow}
    onShouldStartLoadWithRequest={onShouldStartLoadWithRequest}
    
    ref={webViewRef}
    // TODO: find a better way to type this.
    source={source}
    style={webViewStyles}
    overScrollMode={overScrollMode}
    javaScriptEnabled={javaScriptEnabled}
    thirdPartyCookiesEnabled={thirdPartyCookiesEnabled}
    scalesPageToFit={scalesPageToFit}
    saveFormDataDisabled={saveFormDataDisabled}
    cacheEnabled={cacheEnabled}
    androidHardwareAccelerationDisabled={androidHardwareAccelerationDisabled}
    androidLayerType={androidLayerType}
    setSupportMultipleWindows={setSupportMultipleWindows}
    setBuiltInZoomControls={setBuiltInZoomControls}
    setDisplayZoomControls={setDisplayZoomControls}
    mixedContentMode={mixedContentMode}
    nestedScrollEnabled={nestedScrollEnabled}
    mediaPlaybackRequiresUserAction={mediaPlaybackRequiresUserAction}
  />

  return (
    <View style={webViewContainerStyle}>
      {webView}
      {otherView}
    </View>
  );
});

// native implementation should return "true" only for Android 5+
const isFileUploadSupported: () => Promise<boolean>
  = NativeModules.RNCWebView.isFileUploadSupported();

const WebView = Object.assign(WebViewComponent, {isFileUploadSupported});

export default WebView;
