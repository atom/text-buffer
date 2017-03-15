const Point = require('./point')
const {traversal} = require('./point-helpers')

const MULTI_LINE_REGEX_REGEX = /\\s|\\r|\\n|\r|\n|^\[\^|[^\\]\[\^/

exports.newlineRegex = /\r\n|\n|\r/g

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
  return changes.map((change) => ({
    start: Point.fromObject(change.newStart),
    oldExtent: traversal(change.oldEnd, change.oldStart),
    newExtent: traversal(change.newEnd, change.newStart),
    oldText: change.oldText,
    newText: change.newText
  }))
}

exports.regexIsSingleLine = function (regex) {
  return !MULTI_LINE_REGEX_REGEX.test(regex.source)
}
