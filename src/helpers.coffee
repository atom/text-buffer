SpliceArrayChunkSize = 100000

exports.spliceArray = (originalArray, start, length, insertedArray=[]) ->
  if insertedArray.length < SpliceArrayChunkSize
    originalArray.splice(start, length, insertedArray...)
  else
    removedValues = originalArray.splice(start, length)
    for chunkStart in [0..insertedArray.length] by SpliceArrayChunkSize
      chunkEnd = chunkStart + SpliceArrayChunkSize
      chunk = insertedArray.slice(chunkStart, chunkEnd)
      originalArray.splice(start + chunkStart, 0, chunk...)
    removedValues
