const path = require('path')
const TextBuffer = require('../src/text-buffer')

describe('when a buffer is already open', () => {
  it('replaces foo( with bar( using /\bfoo\\(\b/gim', () => {
    const filePath = path.join(__dirname, 'fixtures', 'sample.js')
    const buffer = new TextBuffer()
    buffer.setPath(filePath)
    buffer.setText('foo(x)')
    buffer.replace(/\bfoo\(\b/gim, 'bar(')

    expect(buffer.getText()).toBe('bar(x)')
  })
})
