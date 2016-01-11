MarkerIndex = require 'marker-index/dist/js/marker-index'
Random = require 'random-seed'
{compare: comparePoints, isEqual: isEqualPoint, min: minPoint} = require('../../src/point-helpers')
Point = require '../../src/point'
Range = require '../../src/range'
WORDS = require './words'

module.exports =
class TestDecorationLayer
  constructor: (decorations, @buffer, @random) ->
    @nextMarkerId = 1
    @markerIndex = new MarkerIndex
    @tagsByMarkerId = {}

    for [tag, [rangeStart, rangeEnd]] in decorations
      markerId = @nextMarkerId++
      @markerIndex.insert(markerId, Point.fromObject(rangeStart), Point.fromObject(rangeEnd))
      @tagsByMarkerId[markerId] = tag

    @buffer?.preemptDidChange(@bufferDidChange.bind(this))

  buildIterator: ->
    new TestDecorationLayerIterator(this)

  getInvalidatedRanges: -> @invalidatedRanges

  bufferDidChange: ({oldRange, newRange}) ->
    @invalidatedRanges = [Range.fromObject(newRange)]
    {overlap} = @markerIndex.splice(oldRange.start, oldRange.getExtent(), newRange.getExtent())
    for id in overlap
      @invalidatedRanges.push(@markerIndex.getRange(id))
      delete @tagsByMarkerId[id]
      @markerIndex.remove(id)

    for i in [0..@random(5)]
      markerId = @nextMarkerId++
      @tagsByMarkerId[markerId] = WORDS[@random(WORDS.length)]
      range = @getRandomRange()
      @markerIndex.insert(markerId, range.start, range.end)
      @invalidatedRanges.push(range)

  getRandomRange: ->
    Range(@getRandomPoint(), @getRandomPoint())

  getRandomPoint: ->
    row = @random(@buffer.getLineCount())
    column = @random(@buffer.lineForRow(row).length + 1)
    Point(row, column)

class TestDecorationLayerIterator
  constructor: (@layer) ->
    {markerIndex, tagsByMarkerId} = @layer

    emptyMarkers = []
    nonEmptyMarkers = []
    for key in Object.keys(tagsByMarkerId)
      id = parseInt(key)
      if isEqualPoint(markerIndex.getStart(id), markerIndex.getEnd(id))
        emptyMarkers.push(id)
      else
        nonEmptyMarkers.push(id)

    emptyMarkers.sort (a, b) ->
      comparePoints(markerIndex.getStart(a), markerIndex.getStart(b)) or a - b

    markersSortedByStart = nonEmptyMarkers.slice().sort (a, b) ->
      comparePoints(markerIndex.getStart(a), markerIndex.getStart(b)) or a - b

    markersSortedByEnd = nonEmptyMarkers.slice().sort (a, b) ->
      comparePoints(markerIndex.getEnd(a), markerIndex.getEnd(b)) or b - a

    @tokens = []
    containing = []

    nextEmptyMarkerStart = -> emptyMarkers.length > 0 and markerIndex.getStart(emptyMarkers[0])
    nextMarkerStart = -> markersSortedByStart.length > 0 and markerIndex.getStart(markersSortedByStart[0])
    nextMarkerEnd = -> markersSortedByEnd.length > 0 and markerIndex.getEnd(markersSortedByEnd[0])
    previousTokenEnd = Point(0, 0)

    while emptyMarkers.length > 0 or markersSortedByStart.length > 0 or markersSortedByEnd.length > 0
      token = {
        startPosition: previousTokenEnd
        endPosition: null
        openTags: []
        closeTags: []
        containingTags: containing.slice()
      }

      while nextMarkerStart() and isEqualPoint(nextMarkerStart(), token.startPosition)
        openTag = tagsByMarkerId[markersSortedByStart.shift()]
        token.openTags.push(openTag)
        containing.push(openTag)

      while nextEmptyMarkerStart() and isEqualPoint(nextEmptyMarkerStart(), token.startPosition)
        token.endPosition = token.startPosition
        tag = tagsByMarkerId[emptyMarkers.shift()]
        token.openTags.push(tag)
        token.closeTags.push(tag)

      unless token.endPosition?
        token.endPosition = Point.INFINITY
        if nextMarkerStart()
          token.endPosition = minPoint(token.endPosition, nextMarkerStart())
        if nextEmptyMarkerStart()
          token.endPosition = minPoint(token.endPosition, nextEmptyMarkerStart())
        if nextMarkerEnd()
          token.endPosition = minPoint(token.endPosition, nextMarkerEnd())

      while nextMarkerEnd() and isEqualPoint(nextMarkerEnd(), token.endPosition)
        closeTag = tagsByMarkerId[markersSortedByEnd.shift()]
        token.closeTags.push(closeTag)
        containing.splice(containing.lastIndexOf(closeTag), 1)

      previousTokenEnd = token.endPosition
      @tokens.push(token)

  seek: (position) ->
    for token, index in @tokens
      endComparison = comparePoints(token.endPosition, position)
      if endComparison > 0 or endComparison is 0 and token.closeTags.length > 0
        @tokenIndex = index
        if comparePoints(token.startPosition, position) < 0
          return token.containingTags.concat(token.openTags)
        else
          return token.containingTags
    return []

  moveToSuccessor: ->
    @tokenIndex++
    @tokenIndex < @tokens.length

  getStartPosition: ->
    @tokens[@tokenIndex]?.startPosition ? Point(0, 0)

  getEndPosition: ->
    @tokens[@tokenIndex]?.endPosition ? @layer.buffer.getEndPosition()

  getOpenTags: ->
    @tokens[@tokenIndex]?.openTags ? []

  getCloseTags: ->
    @tokens[@tokenIndex]?.closeTags ? []
