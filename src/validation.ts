import invariant from 'invariant'
import type { AndroidWebViewProps, IOSWebViewProps } from './WebViewTypes'

const validateProps = <P extends IOSWebViewProps | AndroidWebViewProps>(props: P): P => {
  if(props.source && 'html' in props.source){
    const { originWhitelist } = props
    invariant(originWhitelist  && originWhitelist.length > 0 && !originWhitelist.includes('*'), 'originWhitelist is required when using source.html prop and cannot include *')
  }

  return props
}

export default validateProps