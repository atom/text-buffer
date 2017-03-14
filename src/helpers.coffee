Point = require './point'
{traversal} = require './point-helpers'

MULTI_LINE_REGEX_REGEX = /\\s|\\r|\\n|\r|\n|^\[\^|[^\\]\[\^/

module.exports =
  spliceArray: (array, start, removedCount, insertedItems=[]) ->
    oldLength = array.length
    insertedCount = insertedItems.length
    removedCount = Math.min(removedCount, oldLength - start)
    lengthDelta = insertedCount - removedCount
    newLength = oldLength + lengthDelta

    if lengthDelta > 0
      array.length = newLength
      for i in [(newLength - 1)..(start + insertedCount)] by -1
        array[i] = array[i - lengthDelta]
    else
      for i in [(start + insertedCount)...newLength] by 1
        array[i] = array[i - lengthDelta]
      array.length = newLength

    for value, i in insertedItems by 1
      array[start + i] = insertedItems[i]
    return

  newlineRegex: /\r\n|\n|\r/g

  normalizePatchChanges: (changes) ->
    changes.map (change) -> {
      start: Point.fromObject(change.newStart)
      oldExtent: traversal(change.oldEnd, change.oldStart)
      newExtent: traversal(change.newEnd, change.newStart)
      oldText: change.oldText
      newText: change.newText
    }

  regexIsSingleLine: (regex) ->
    not MULTI_LINE_REGEX_REGEX.test(regex.source)
