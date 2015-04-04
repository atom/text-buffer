Point = require "./point"

module.exports =
class Patch
  constructor: ->
    @hunks = [{
      content: null
      extent: Point.infinity()
      inputExtent: Point.infinity()
    }]

  buildIterator: ->
    new PatchIterator(this)

class PatchIterator
  constructor: (@patch) ->
    @seek(Point.zero())

  seek: (@position) ->
    position = Point.zero()
    inputPosition = Point.zero()

    for hunk, index in @patch.hunks
      nextPosition = position.traverse(hunk.extent)
      nextInputPosition = inputPosition.traverse(hunk.inputExtent)

      if nextPosition.compare(@position) > 0 or position.compare(@position) is 0
        @index = index
        @hunkOffset = @position.traversalFrom(position)
        @inputPosition = Point.min(inputPosition.traverse(@hunkOffset), nextInputPosition)
        return

      position = nextPosition
      inputPosition = nextInputPosition

    # This shouldn't happen because the last hunk's extent is infinite.
    throw new Error("No hunk found for position #{@position}")

  next: ->
    if hunk = @patch.hunks[@index]
      value = hunk.content?.slice(@hunkOffset.column) ? null

      remainingExtent = hunk.extent.traversalFrom(@hunkOffset)
      remainingInputExtent = hunk.inputExtent.traversalFrom(@hunkOffset)

      @position = @position.traverse(remainingExtent)
      if remainingInputExtent.isPositive()
        @inputPosition = @inputPosition.traverse(remainingInputExtent)

      @index++
      @hunkOffset = Point.zero()
      {value, done: false}
    else
      {value: null, done: true}

  splice: (oldExtent, newContent) ->
    newHunks = []
    startIndex = @index
    startPosition = @position
    startInputPosition = @inputPosition

    unless @hunkOffset.isZero()
      hunkToSplit = @patch.hunks[@index]
      newHunks.push({
        extent: @hunkOffset
        inputExtent: Point.min(@hunkOffset, hunkToSplit.inputExtent)
        content: hunkToSplit.content?.substring(0, @hunkOffset.column) ? null
      })

    @seek(@position.traverse(oldExtent))

    inputExtent = @inputPosition.traversalFrom(startInputPosition)
    newExtent = Point(0, newContent.length)
    newHunks.push({
      extent: newExtent
      inputExtent: inputExtent
      content: newContent
    })

    hunkToSplit = @patch.hunks[@index]
    newHunks.push({
      extent: hunkToSplit.extent.traversalFrom(@hunkOffset)
      inputExtent: Point.max(Point.zero(), hunkToSplit.inputExtent.traversalFrom(@hunkOffset))
      content: hunkToSplit.content?.slice(@hunkOffset.column)
    })

    spliceHunks = []
    lastHunk = null
    for hunk in newHunks
      if lastHunk?.content? and hunk.content?
        lastHunk.content += hunk.content
        lastHunk.inputExtent = lastHunk.inputExtent.traverse(hunk.inputExtent)
        lastHunk.extent = lastHunk.extent.traverse(hunk.extent)
      else
        spliceHunks.push(hunk)
        lastHunk = hunk

    @patch.hunks.splice(startIndex, @index - startIndex + 1, spliceHunks...)

    @seek(startPosition.traverse(newExtent))

  getPosition: ->
    @position.copy()

  getInputPosition: ->
    @inputPosition.copy()
