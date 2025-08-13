import escapeStringRegexp from 'escape-string-regexp';
import React, { useCallback, useMemo, useRef, useState } from 'react';
import { Linking, View, ActivityIndicator, Text, Platform } from 'react-native';
import {
  OnShouldStartLoadWithRequest,
  ShouldStartLoadRequestEvent,
  WebViewError,
  WebViewErrorEvent,
  WebViewMessageEvent,
  WebViewMessage,
  WebViewNavigationEvent,
  WebViewOpenWindowEvent,
  WebViewProgressEvent,
  WebViewNativeEvent,
} from './WebViewTypes';
import styles from './WebView.styles';

const defaultOriginWhitelist = ['https://*'] as const;
const defaultDeeplinkWhitelist = ['https:'] as const;
const defaultDeeplinkBlocklist = [`http:`, `file:`, `javascript:`] as const;

const stringWhitelistToRegex = (originWhitelist: string): RegExp =>
  new RegExp(`^${escapeStringRegexp(originWhitelist).replace(/\\\*/g, '.*')}$`);

const matchWithRegexList = (
  compiledRegexList: readonly RegExp[],
  value: string,
) => {
  return compiledRegexList.some(x => x.test(value));
};

const matchWithStringList = (
  prefixes: readonly string[],
  value: string,
) => {
  if (typeof value !== 'string') throw new Error(`value was not a string`)
  return Array.prototype.includes.call(prefixes, value)
};

const _passesWhitelist = (
  compiledWhitelist: readonly RegExp[],
  url: string,
) => {
  try {
    const { href, origin } = new URL(url)

    if (origin && origin !== 'null') {
      return matchWithRegexList(compiledWhitelist, origin);
    }

    return matchWithRegexList(compiledWhitelist, href)
  } catch {
    return false
  }
};

const compileWhitelist = (
  originWhitelist: readonly string[],
): readonly RegExp[] =>
['about:blank', ...(originWhitelist || [])].map(stringWhitelistToRegex);

const isDownloadMessageAllowed = ({
  data,
  url,
  downloadWhitelist,
}: {
  data: string;
  url: string;
  downloadWhitelist: { origin: string; allowedFileExtensions: string[] }[];
}): boolean => {
  let parsedData;
  
  try {
    parsedData = JSON.parse(data);
  } catch {
    return true; // Invalid JSON — treat as non-download message
  }

  if (parsedData.method !== 'download') {
    return true;
  }

  const { origin } = new URL(url);
  const fileExtension = parsedData.params?.fileName?.split('.').pop()?.toLowerCase();
  
  if (!fileExtension || !origin) {
    return false;
  }

  return Boolean(downloadWhitelist.find((rule) => rule.origin === origin && rule.allowedFileExtensions.includes(fileExtension)));
};

const urlToProtocolScheme = (url: string): string | null => {
  try {
    return new URL(url).protocol
  } catch {
    // Protocol schemes must start with a letter and cannot start with digits, underscores etc.
    // e.g 0invalid, _invalid, +invalid,  -invalid, .invalid will all become null
    return null
  }
}

const createOnShouldStartLoadWithRequest = (
  loadRequest: (
    shouldStart: boolean,
    url: string,
    lockIdentifier: number,
  ) => void,
  originWhitelist: readonly string[],
  deepLinkWhitelist: readonly string[],
  onShouldStartLoadWithRequest?: OnShouldStartLoadWithRequest,
) => {
  const compiledWhiteList = compileWhitelist(originWhitelist)

  return ({ nativeEvent }: ShouldStartLoadRequestEvent) => {
    let shouldStart = true;
    const { url, lockIdentifier, isTopFrame } = nativeEvent;

    /** Check if the url passes the origin whitelist */
    if (!_passesWhitelist(compiledWhiteList, url)) {
      const protocol = urlToProtocolScheme(url)
      
      /* Check that the protocol was properly parsed */
      if (protocol !== null) {
        /** Check if the protocol passes the hardcoded deeplink blocklist */
        const foundMatchInBlocklist = matchWithStringList(defaultDeeplinkBlocklist, protocol)
        if (!foundMatchInBlocklist) {
          /** Check if the protocol passes the dynamic deeplink allow list */
          const foundMatchInAllowlist = matchWithStringList(deepLinkWhitelist, protocol)
    
          if (foundMatchInAllowlist) {
            Linking.canOpenURL(url).then((supported) => {
              if ((supported && isTopFrame) || protocol.startsWith('mailto:')) {
                return Linking.openURL(url);
              }
              console.warn(`Can't open url: ${url}`);
              return undefined;
            }).catch(e => {
              console.warn('Error opening URL: ', e);
            });
          } else {
            console.warn(`Failed to pass whitelist for deep link url: ${url}`);
          }
        } else {
          console.warn(`Failed to pass default block list for deep link url: ${url}`);
        }
      }

      shouldStart = false;
    } else if (onShouldStartLoadWithRequest) {
      shouldStart = onShouldStartLoadWithRequest(nativeEvent);
    }

    loadRequest(shouldStart, url, lockIdentifier);
  };
};

const defaultRenderLoading = () => (
  <View style={styles.loadingOrErrorView}>
    <ActivityIndicator />
  </View>
);
const defaultRenderError = (
  errorDomain: string | undefined,
  errorCode: number,
  errorDesc: string,
) => (
  <View style={styles.loadingOrErrorView}>
    <Text style={styles.errorTextTitle}>Error loading page</Text>
    <Text style={styles.errorText}>{`Domain: ${errorDomain}`}</Text>
    <Text style={styles.errorText}>{`Error Code: ${errorCode}`}</Text>
    <Text style={styles.errorText}>{`Description: ${errorDesc}`}</Text>
  </View>
);

export {
  defaultOriginWhitelist,
  defaultDeeplinkWhitelist,
  createOnShouldStartLoadWithRequest,
  defaultRenderLoading,
  defaultRenderError,
};

export const useWebWiewLogic = ({
  downloadWhitelist,
  startInLoadingState,
  onLoadStart,
  onLoad,
  onLoadEnd,
  onError,
  onMessageProp,
  onOpenWindowProp,
  originWhitelist,
  deeplinkWhitelist,
  onShouldStartLoadWithRequestProp,
  onShouldStartLoadWithRequestCallback,
  validateMeta,
  validateData,
}: {
  downloadWhitelist: { origin: string; allowedFileExtensions: string[] }[];
  startInLoadingState?: boolean
  onLoadStart?: (event: WebViewNavigationEvent) => void;
  onLoad?: (event: WebViewNavigationEvent) => void;
  onLoadEnd?: (event: WebViewNavigationEvent | WebViewErrorEvent) => void;
  onError?: (event: WebViewErrorEvent) => void;
  onMessageProp?: (event: WebViewMessage) => void;
  onOpenWindowProp?: (event: WebViewOpenWindowEvent) => void;
  originWhitelist: readonly string[];
  deeplinkWhitelist: readonly string[];
  onShouldStartLoadWithRequestProp?: OnShouldStartLoadWithRequest;
  onShouldStartLoadWithRequestCallback: (shouldStart: boolean, url: string, lockIdentifier?: number | undefined) => void;
  validateMeta: (event: WebViewNativeEvent) => WebViewNativeEvent;
  validateData: (data: object) => object;
}) => {

  const [viewState, setViewState] = useState<'IDLE' | 'LOADING' | 'ERROR'>(startInLoadingState ? "LOADING" : "IDLE");
  const [lastErrorEvent, setLastErrorEvent] = useState<WebViewError | null>(null);
  const startUrl = useRef<string | null>(null)

  const passesWhitelist = (url: string) => {
    if (!url || typeof url !== 'string') return false;
    return _passesWhitelist(compileWhitelist(originWhitelist), url);
  }

  const passesWhitelistUse = useCallback(passesWhitelist, [originWhitelist])

  const extractMeta = (nativeEvent: WebViewNativeEvent): WebViewNativeEvent => ({
    url: String(nativeEvent.url),
    loading: Boolean(nativeEvent.loading),
    title: String(nativeEvent.title).slice(0, 512),
    canGoBack: Boolean(nativeEvent.canGoBack),
    canGoForward: Boolean(nativeEvent.canGoForward),
    lockIdentifier: Number(nativeEvent.lockIdentifier),
  });

  const onLoadingStart = useCallback((event: WebViewNavigationEvent) => {
    // Needed for android
    startUrl.current = event.nativeEvent.url;
    // !Needed for android

    onLoadStart?.(event);
  }, [onLoadStart]);

  const onLoadingError = useCallback((event: WebViewErrorEvent) => {
    event.persist();
    if (onError) {
      onError(event);
    } else {
      console.warn('Encountered an error loading page', event.nativeEvent);
    }
    onLoadEnd?.(event);
    if (event.isDefaultPrevented()) { return };
    setViewState('ERROR');
    setLastErrorEvent(event.nativeEvent);
  }, [onError, onLoadEnd]);

  const onLoadingFinish = useCallback((event: WebViewNavigationEvent) => {
    onLoad?.(event);
    onLoadEnd?.(event);
    const { nativeEvent: { url } } = event;
    if (!passesWhitelistUse(url)) return;

    // on Android, only if url === startUrl
    if (Platform.OS !== "android" || url === startUrl.current) {
      setViewState('IDLE');
    }
    // !on Android, only if url === startUrl
    // REMOVED: updateNavigationState(event);
  }, [onLoad, onLoadEnd, passesWhitelistUse]);

  const onMessage = useCallback((event: WebViewMessageEvent) => {
    const { nativeEvent } = event;
    if (!passesWhitelistUse(nativeEvent.url)) return;

    // TODO: can/should we perform any other validation?
    try {
      const parsedData = JSON.parse(nativeEvent.data);
      const validatedData = validateData(parsedData);

      if (!isDownloadMessageAllowed({
        data: (validatedData as { data?: string })?.data ?? '',
        downloadWhitelist,
        url: nativeEvent.url,
      })) {
        console.warn('Download request rejected: origin not in download whitelist or file extension not allowed');
        return;
      }

      const data = JSON.stringify(validatedData);
      const meta = validateMeta(extractMeta(nativeEvent));

      onMessageProp?.({ ...meta, data });
    } catch (err) {
      console.error('Error parsing WebView message', err);
    }
  }, [onMessageProp, passesWhitelistUse, validateData, validateMeta, downloadWhitelist]);

  const onLoadingProgress = useCallback((event: WebViewProgressEvent) => {
    const { nativeEvent: { progress } } = event;
    if (!passesWhitelistUse(event.nativeEvent.url)) return;

    // patch for Android only
    if (Platform.OS === "android" && progress === 1) {
      setViewState(prevViewState => prevViewState === 'LOADING' ? 'IDLE' : prevViewState);
    }
    // !patch for Android only
    // REMOVED: onLoadProgress?.(event);
  }, [passesWhitelistUse]);

  const onShouldStartLoadWithRequest = useMemo(() =>  createOnShouldStartLoadWithRequest(
      onShouldStartLoadWithRequestCallback,
      originWhitelist,
      deeplinkWhitelist,
      onShouldStartLoadWithRequestProp,
    )
  , [originWhitelist, deeplinkWhitelist, onShouldStartLoadWithRequestProp, onShouldStartLoadWithRequestCallback])

  // Android Only
  const onOpenWindow = useCallback((event: WebViewOpenWindowEvent) => {
    onOpenWindowProp?.(event);
  }, [onOpenWindowProp]);
  // !Android Only

  return {
    onShouldStartLoadWithRequest,
    onLoadingStart,
    onLoadingProgress,
    onLoadingError,
    onLoadingFinish,
    onMessage,
    onOpenWindow,
    passesWhitelist,
    viewState,
    setViewState,
    lastErrorEvent,
  }
};

export const versionPasses = (version: string | undefined, minimum: string | undefined): boolean => {
  if (!version || !minimum) return false
  if (typeof version !== 'string' || typeof minimum !== 'string') return false

  if (minimum.includes(', ')) {
    // We have a set of possible versions
    const variants = minimum.split(', ')
    // Every entry but the last one should be with an upper bound
    if (!variants.slice(0, -1).every(x => x.includes(' <'))) return false
    return variants.some(x => versionPasses(version, x)) // Any match passes
  }

  if (minimum.includes(' <')) {
    const [min, max, ...rest] = minimum.split(' <')
    if (rest.length > 0) return false
    // Last check is required for correctness/formatting validation
    return versionPasses(version, min) && !versionPasses(version, max) && versionPasses(max, version)
  }

  const versionRegex = /^[0-9]+(\.[0-9]+)*$/
  if (!versionRegex.test(version) || !versionRegex.test(minimum)) return false
  const versionParts = version.split('.').map(Number)
  const minimumParts = minimum.split('.').map(Number)
  const len = Math.max(versionParts.length, minimumParts.length)
  for (let i = 0; i < len; i += 1) {
    const ver = versionParts[i] || 0
    const min = minimumParts[i] || 0
    if (ver > min) return true
    if (ver < min) return false
  }
  return true // equals
}
