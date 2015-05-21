Point = require "./point"

module.exports =
class Patch
  constructor: ->
    @hunks = [{
      content: null
      extent: Point.infinity()
      sourceExtent: Point.infinity()
    }]

  buildIterator: ->
    new PatchIterator(this)

class PatchIterator
  constructor: (@patch) ->
    @seek(Point.zero())

  seek: (@position) ->
    position = Point.zero()
    sourcePosition = Point.zero()

    for hunk, index in @patch.hunks
      nextPosition = position.traverse(hunk.extent)
      nextSourcePosition = sourcePosition.traverse(hunk.sourceExtent)

      if nextPosition.compare(@position) > 0 or position.compare(@position) is 0
        @index = index
        @hunkOffset = @position.traversalFrom(position)
        @sourcePosition = Point.min(sourcePosition.traverse(@hunkOffset), nextSourcePosition)
        return

      position = nextPosition
      sourcePosition = nextSourcePosition

    # This shouldn't happen because the last hunk's extent is infinite.
    throw new Error("No hunk found for position #{@position}")

  next: ->
    if hunk = @patch.hunks[@index]
      value = hunk.content?.slice(@hunkOffset.column) ? null

      remainingExtent = hunk.extent.traversalFrom(@hunkOffset)
      remainingSourceExtent = hunk.sourceExtent.traversalFrom(@hunkOffset)

      @position = @position.traverse(remainingExtent)
      if remainingSourceExtent.isPositive()
        @sourcePosition = @sourcePosition.traverse(remainingSourceExtent)

      @index++
      @hunkOffset = Point.zero()
      {value, done: false}
    else
      {value: null, done: true}

  splice: (oldExtent, newContent) ->
    newHunks = []
    startIndex = @index
    startPosition = @position
    startSourcePosition = @sourcePosition

    unless @hunkOffset.isZero()
      hunkToSplit = @patch.hunks[@index]
      newHunks.push({
        extent: @hunkOffset
        sourceExtent: Point.min(@hunkOffset, hunkToSplit.sourceExtent)
        content: hunkToSplit.content?.substring(0, @hunkOffset.column) ? null
      })

    @seek(@position.traverse(oldExtent))

    sourceExtent = @sourcePosition.traversalFrom(startSourcePosition)
    newExtent = Point(0, newContent.length)
    newHunks.push({
      extent: newExtent
      sourceExtent: sourceExtent
      content: newContent
    })

    hunkToSplit = @patch.hunks[@index]
    newHunks.push({
      extent: hunkToSplit.extent.traversalFrom(@hunkOffset)
      sourceExtent: Point.max(Point.zero(), hunkToSplit.sourceExtent.traversalFrom(@hunkOffset))
      content: hunkToSplit.content?.slice(@hunkOffset.column)
    })

    spliceHunks = []
    lastHunk = null
    for hunk in newHunks
      if lastHunk?.content? and hunk.content?
        lastHunk.content += hunk.content
        lastHunk.sourceExtent = lastHunk.sourceExtent.traverse(hunk.sourceExtent)
        lastHunk.extent = lastHunk.extent.traverse(hunk.extent)
      else
        spliceHunks.push(hunk)
        lastHunk = hunk

    @patch.hunks.splice(startIndex, @index - startIndex + 1, spliceHunks...)

    @seek(startPosition.traverse(newExtent))

  getPosition: ->
    @position.copy()

  getSourcePosition: ->
    @sourcePosition.copy()
