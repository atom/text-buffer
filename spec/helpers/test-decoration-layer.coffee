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

  containingTagsForPosition: (position) ->
    containingIds = @markerIndex.findContaining(position)
    @markerIndex.findEndingAt(position).forEach (id) -> containingIds.delete(id)
    Array.from(containingIds).map (id) => @tagsByMarkerId[id]

  bufferDidChange: ({oldRange, newRange}) ->
    @invalidatedRanges = [Range.fromObject(newRange)]
    {overlap} = @markerIndex.splice(oldRange.start, oldRange.getExtent(), newRange.getExtent())
    overlap.forEach (id) => @invalidatedRanges.push(@markerIndex.getRange(id))

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

    @boundaries = []

    nextEmptyMarkerStart = -> emptyMarkers.length > 0 and markerIndex.getStart(emptyMarkers[0])
    nextMarkerStart = -> markersSortedByStart.length > 0 and markerIndex.getStart(markersSortedByStart[0])
    nextMarkerEnd = -> markersSortedByEnd.length > 0 and markerIndex.getEnd(markersSortedByEnd[0])

    while emptyMarkers.length > 0 or markersSortedByStart.length > 0 or markersSortedByEnd.length > 0
      boundary = {
        position: Point.INFINITY
        closeTags: []
        openTags: []
      }

      if nextMarkerStart()
        boundary.position = minPoint(boundary.position, nextMarkerStart())
      if nextEmptyMarkerStart()
        boundary.position = minPoint(boundary.position, nextEmptyMarkerStart())
      if nextMarkerEnd()
        boundary.position = minPoint(boundary.position, nextMarkerEnd())

      while nextMarkerEnd() and isEqualPoint(nextMarkerEnd(), boundary.position)
        boundary.closeTags.push(tagsByMarkerId[markersSortedByEnd.shift()])

      emptyTags = []
      while nextEmptyMarkerStart() and isEqualPoint(nextEmptyMarkerStart(), boundary.position)
        emptyTags.push(tagsByMarkerId[emptyMarkers.shift()])

      if emptyTags.length > 0
        boundary.openTags.push(emptyTags...)
        @boundaries.push(boundary)
        boundary = {
          position: boundary.position
          closeTags: []
          openTags: []
        }
        boundary.closeTags.push(emptyTags...)

      while nextMarkerStart() and isEqualPoint(nextMarkerStart(), boundary.position)
        boundary.openTags.push(tagsByMarkerId[markersSortedByStart.shift()])

      @boundaries.push(boundary)

  seek: (position) ->
    containingTags = []
    for boundary, index in @boundaries
      if comparePoints(boundary.position, position) >= 0
        @boundaryIndex = index
        return containingTags
      else
        for tag in boundary.closeTags
          containingTags.splice(containingTags.lastIndexOf(tag), 1)
        containingTags.push(boundary.openTags...)
    @boundaryIndex = @boundaries.length
    containingTags

  moveToSuccessor: ->
    @boundaryIndex++

  getPosition: ->
    @boundaries[@boundaryIndex]?.position ? Point.INFINITY

  getCloseTags: ->
    @boundaries[@boundaryIndex]?.closeTags ? []

  getOpenTags: ->
    @boundaries[@boundaryIndex]?.openTags ? []
