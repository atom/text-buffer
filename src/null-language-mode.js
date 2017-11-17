const {Disposable} = require('event-kit')
const Point = require('./point')

const EMPTY = []

module.exports =
class NullLanguageMode {
  bufferDidChange () {}
  buildHighlightIterator () { return new NullHighlightIterator() }
  onDidChangeHighlighting () { return new Disposable(() => {}) }
  getLanguageName () { return 'None' }
}

class NullHighlightIterator {
  seek (position) { return EMPTY }
  moveToSuccessor () { return false }
  getPosition () { return Point.INFINITY }
  getCloseTags () { return EMPTY }
  getOpenTags () { return EMPTY }
}