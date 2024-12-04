import validateProps from '../validation'

describe('validateProps', () => {

  test('throws when providing static html without origin whitelist', () => {
    expect(() => {
      validateProps({
        source: { html: '<h1>Wayne Foundation</h1>'}
      })
    }).toThrow('originWhitelist')
  })

  test('throws when providing static html with wildcard whitelist', () => {
    expect(() => {
      validateProps({
        originWhitelist: ['*', 'http://localhost'],
        source: { html: '<h1>Wayne Foundation</h1>'}
      })
    }).toThrow('originWhitelist')
  })

  test('throws when providing static html with empty whitelist', () => {
    expect(() => {
      validateProps({
        originWhitelist: [],
        source: { html: '<h1>Wayne Foundation</h1>'}
      })
    }).toThrow('originWhitelist')
  })

  test('returns props when origin whitelist present', () => {
    const props = {
      originWhitelist: ['http://localhost'],
      source: { html: '<h1>Wayne Foundation</h1>'}
    }

    expect(validateProps(props)).toBe(props)
  })
})