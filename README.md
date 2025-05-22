# React Native WebView - a Modern, Cross-Platform WebView for React Native

[![star this repo](http://githubbadges.com/star.svg?user=react-native-webview&repo=react-native-webview&style=flat)](https://github.com/react-native-webview/react-native-webview)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg?style=flat-square)](http://makeapullrequest.com)
[![All Contributors](https://img.shields.io/badge/all_contributors-16-orange.svg?style=flat-square)](#contributors)
[![Known Vulnerabilities](https://snyk.io/test/github/react-native-webview/react-native-webview/badge.svg?style=flat-square)](https://snyk.io/test/github/react-native-webview/react-native-webview)
[![NPM Version](https://img.shields.io/npm/v/react-native-webview.svg?style=flat-square)](https://www.npmjs.com/package/react-native-webview)
[![Lean Core Extracted](https://img.shields.io/badge/Lean%20Core-Extracted-brightgreen.svg?style=flat-square)][lean-core-issue]

**React Native WebView** is a modern, well-supported, and cross-platform WebView for React Native. It is intended to be a replacement for the built-in WebView (which will be [removed from core](https://github.com/react-native-community/discussions-and-proposals/pull/3)).

## Core Maintainers - Sponsoring companies

_This project is a fork of https://github.com/react-native-webview/react-native-webview. 
Please refer to that repository for full credits._

## Platforms Supported

- [x] iOS
- [x] Android
- [x] macOS
- [x] Windows
- [x] Expo (Android, iOS)

## Getting Started

Read our [Getting Started Guide](docs/Getting-Started.md). If any step seems unclear, please create a detailed issue.

## Versioning

This project follows [semantic versioning](https://semver.org/). We do not hesitate to release breaking changes but they will be in a major version.

**Breaking History:**

Current Version: ![version](https://img.shields.io/npm/v/react-native-webview.svg)

- [11.0.0](https://github.com/react-native-webview/react-native-webview/releases/tag/v11.0.0) - Android setSupportMultipleWindows.
- [10.0.0](https://github.com/react-native-webview/react-native-webview/releases/tag/v10.0.0) - Android Gradle plugin is only required when opening the project stand-alone
- [9.0.0](https://github.com/react-native-webview/react-native-webview/releases/tag/v9.0.0) - props updates to injectedJavaScript are no longer immutable.
- [8.0.0](https://github.com/react-native-webview/react-native-webview/releases/tag/v8.0.0) - onNavigationStateChange now triggers with hash url changes
- [7.0.1](https://github.com/react-native-webview/react-native-webview/releases/tag/v7.0.1) - Removed UIWebView
- [6.0.**2**](https://github.com/react-native-webview/react-native-webview/releases/tag/v6.0.2) - Update to AndroidX. Make sure to enable it in your project's `android/gradle.properties`. See [Getting Started Guide](docs/Getting-Started.md).
- [5.0.**1**](https://github.com/react-native-webview/react-native-webview/releases/tag/v5.0.0) - Refactored the old postMessage implementation for communication from webview to native.
- [4.0.0](https://github.com/react-native-webview/react-native-webview/releases/tag/v4.0.0) - Added cache (enabled by default).
- [3.0.0](https://github.com/react-native-webview/react-native-webview/releases/tag/v3.0.0) - WKWebview: Add shared process pool so cookies and localStorage are shared across webviews in iOS (enabled by default).
- [2.0.0](https://github.com/react-native-webview/react-native-webview/releases/tag/v2.0.0) - First release this is a replica of the core webview component

**Upcoming:**

- this.webView.postMessage() removal (never documented and less flexible than injectJavascript) -> [how to migrate](https://github.com/react-native-webview/react-native-webview/issues/809)
- Kotlin rewrite
- Maybe Swift rewrite

## Usage

Import the `WebView` component from `react-native-webview` and use it like so:

```jsx
import React, { Component } from 'react';
import { StyleSheet, Text, View } from 'react-native';
import { WebView } from 'react-native-webview';

// ...
class MyWebComponent extends Component {
  render() {
    return <WebView source={{ uri: 'https://reactnative.dev/' }} />;
  }
}
```

For more, read the [API Reference](./docs/Reference.md) and [Guide](./docs/Guide.md). If you're interested in contributing, check out the [Contributing Guide](./docs/Contributing.md).

## Common issues

- If you're getting `Invariant Violation: Native component for "RNCWebView does not exist"` it likely means you forgot to run `react-native link` or there was some error with the linking process
- If you encounter a build error during the task `:app:mergeDexRelease`, you need to enable multidex support in `android/app/build.gradle` as discussed in [this issue](https://github.com/react-native-webview/react-native-webview/issues/1344#issuecomment-650544648)

## Contributing

See [Contributing.md](https://github.com/react-native-webview/react-native-webview/blob/master/docs/Contributing.md)

## Contributors

_This project is a fork of https://github.com/react-native-webview/react-native-webview. 
Please refer to that repository for full credits._

## License

MIT

## Translations

This readme is available in:

- [Brazilian portuguese](docs/README.portuguese.md)
- [French](docs/README.french.md)

[lean-core-issue]: https://github.com/facebook/react-native/issues/23313
