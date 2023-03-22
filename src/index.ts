import { NativeModules } from 'react-native';

import WebView from './WebView';

export const RNCWebViewUtils = NativeModules.RNCWebViewUtils
export const getWebViewDefaultUserAgent = RNCWebViewUtils.getWebViewDefaultUserAgent;

export { WebView };
export default WebView;
