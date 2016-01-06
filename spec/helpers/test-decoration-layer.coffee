MarkerIndex = require 'marker-index'
comparePoints = require('../../src/point-helpers').compare
Point = require '../../src/point'

module.exports =
class TestDecorationLayer
  constructor: (decorations) ->
    @nextMarkerId = 1
    @markerIndex = new MarkerIndex
    @tagsByMarkerId = {}

    for [tag, [rangeStart, rangeEnd]] in decorations
      markerId = @nextMarkerId++
      @markerIndex.insert(markerId, Point.fromObject(rangeStart), Point.fromObject(rangeEnd))
      @tagsByMarkerId[markerId] = tag

  buildIterator: ->
    new TestDecorationLayerIterator(this)

class TestDecorationLayerIterator
  constructor: (@layer) ->
    {markerIndex, tagsByMarkerId} = @layer

    markersSortedByStart = Object.keys(tagsByMarkerId).map (id) -> parseInt(id)
    markersSortedByStart.sort (a, b) -> comparePoints(markerIndex.getStart(a), markerIndex.getStart(b))
    markersSortedByEnd = Object.keys(tagsByMarkerId).map (id) -> parseInt(id)
    markersSortedByEnd.sort (a, b) -> comparePoints(markerIndex.getEnd(a), markerIndex.getEnd(b))

    @tokens = []
    containing = []

    previousTokenEnd = Point(0, 0)
    loop
      token = {
        startPosition: previousTokenEnd
        endPosition: null
        openTags: []
        closeTags: []
        containingTags: containing.slice()
      }

      while markersSortedByStart.length > 0 and comparePoints(markerIndex.getStart(markersSortedByStart[0]), previousTokenEnd) is 0
        openTag = tagsByMarkerId[markersSortedByStart.shift()]
        token.openTags.push(openTag)
        containing.push(openTag)

      nextMarkerStart = markersSortedByStart.length > 0 and markerIndex.getStart(markersSortedByStart[0])
      nextMarkerEnd = markersSortedByEnd.length > 0 and markerIndex.getEnd(markersSortedByEnd[0])
      if nextMarkerStart and comparePoints(nextMarkerStart, nextMarkerEnd) < 0
        token.endPosition = nextMarkerStart
      else if nextMarkerEnd
        closeTag = tagsByMarkerId[markersSortedByEnd.shift()]
        token.closeTags.push(closeTag)
        containing.splice(containing.lastIndexOf(closeTag), 1)
        token.endPosition = nextMarkerEnd
        while markersSortedByEnd.length > 0 and comparePoints(markerIndex.getEnd(markersSortedByEnd[0]), token.endPosition) is 0
          token.closeTags.push(tagsByMarkerId[markersSortedByEnd.shift()])
      else
        break

      @tokens.push(token)
      previousTokenEnd = token.endPosition

  seek: (position) ->
    for token, index in @tokens
      if comparePoints(token.endPosition, position) > 0
        @tokenIndex = index
        return token.containingTags

  moveToSuccessor: ->
    @tokenIndex++
    @tokenIndex < @tokens.length

  getStartPosition: ->
    @tokens[@tokenIndex].startPosition

  getEndPosition: ->
    @tokens[@tokenIndex].endPosition

  getOpenTags: ->
    @tokens[@tokenIndex].openTags

  getCloseTags: ->
    @tokens[@tokenIndex].closeTags
