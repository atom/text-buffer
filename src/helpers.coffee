Point = require './point'

SpliceArrayChunkSize = 100000

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

  normalizeChangesObject: (changes) ->
    changes.map (change) -> {
      start: Point.fromObject(change.start)
      oldExtent: Point.fromObject(change.oldExtent)
      newExtent: Point.fromObject(change.newExtent)
      newText: change.newText
    }
