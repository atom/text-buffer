Point = require './point'

SpliceArrayChunkSize = 100000

MULTI_LINE_REGEX_REGEX = /\r|\n|^\[\^|[^\\]\[\^/

module.exports =
  spliceArray: (originalArray, start, length, insertedArray=[]) ->
    if insertedArray.length < SpliceArrayChunkSize
      originalArray.splice(start, length, insertedArray...)
    else
      removedValues = originalArray.splice(start, length)
      for chunkStart in [0..insertedArray.length] by SpliceArrayChunkSize
        chunkEnd = chunkStart + SpliceArrayChunkSize
        chunk = insertedArray.slice(chunkStart, chunkEnd)
        originalArray.splice(start + chunkStart, 0, chunk...)
      removedValues

  newlineRegex: /\r\n|\n|\r/g

  normalizePatchChanges: (changes) ->
    changes.map (change) -> {
      start: Point.fromObject(change.newStart)
      oldExtent: Point.fromObject(change.oldExtent)
      newExtent: Point.fromObject(change.newExtent)
      newText: change.newText
    }

  regexIsSingleLine: (regex) ->
    not MULTI_LINE_REGEX_REGEX.test(regex.source)
