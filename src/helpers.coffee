Point = require './point'
Patch = require 'atom-patch'

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

  combineBufferChanges: (changes) ->
    combinedChanges = new Patch
    for {oldRange, newRange} in changes
      combinedChanges.splice(oldRange.start, oldRange.getExtent(), newRange.getExtent())
    module.exports.normalizePatchChanges(combinedChanges.getChanges())

  normalizePatchChanges: (changes) ->
    changes.map (change) -> {
      start: Point.fromObject(change.newStart)
      oldStart: Point.fromObject(change.oldStart)
      oldExtent: Point.fromObject(change.oldExtent)
      newExtent: Point.fromObject(change.newExtent)
      newText: change.newText
    }
