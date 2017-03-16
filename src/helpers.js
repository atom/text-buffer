const Range = require('./range')

const MULTI_LINE_REGEX_REGEX = /\\s|\\r|\\n|\r|\n|^\[\^|[^\\]\[\^/

exports.newlineRegex = /\r\n|\n|\r/g

exports.regexIsSingleLine = function (regex) {
  return !MULTI_LINE_REGEX_REGEX.test(regex.source)
}

exports.spliceArray = function (array, start, removedCount, insertedItems = []) {
  const oldLength = array.length
  const insertedCount = insertedItems.length
  removedCount = Math.min(removedCount, oldLength - start)
  const lengthDelta = insertedCount - removedCount
  const newLength = oldLength + lengthDelta

  if (lengthDelta > 0) {
    array.length = newLength
    for (let i = newLength - 1, end = start + insertedCount; i >= end; i--) {
      array[i] = array[i - lengthDelta]
    }
  } else {
    for (let i = start + insertedCount, end = newLength; i < end; i++) {
      array[i] = array[i - lengthDelta]
    }
    array.length = newLength
  }

  for (let i = 0; i < insertedItems.length; i++) {
    array[start + i] = insertedItems[i]
  }
}

exports.normalizePatchChanges = function (changes) {
  return changes.map((change) =>
    new TextChange(
      Range(change.oldStart, change.oldEnd),
      Range(change.newStart, change.newEnd),
      change.oldText, change.newText
    )
  )
}

class TextChange {
  constructor (oldRange, newRange, oldText, newText) {
    this.oldRange = oldRange
    this.newRange = newRange
    this.oldText = oldText
    this.newText = newText
  }
}

Object.defineProperty(TextChange.prototype, 'start', {
  get: function () {
    return this.newRange.start
  },
  enumerable: false
})

Object.defineProperty(TextChange.prototype, 'oldExtent', {
  get: function () {
    return this.oldRange.getExtent()
  },
  enumerable: false
})

Object.defineProperty(TextChange.prototype, 'newExtent', {
  get: function () {
    return this.newRange.getExtent()
  },
  enumerable: false
})
