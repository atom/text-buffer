MarkerIndex = require 'marker-index/dist/js/marker-index'
Random = require 'random-seed'
{Emitter} = require 'event-kit'
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
    @emitter = new Emitter

    for [tag, [rangeStart, rangeEnd]] in decorations
      markerId = @nextMarkerId++
      @markerIndex.insert(markerId, Point.fromObject(rangeStart), Point.fromObject(rangeEnd))
      @tagsByMarkerId[markerId] = tag

    @buffer?.registerTextDecorationLayer(this)

  buildIterator: ->
    new TestDecorationLayerIterator(this)

  getInvalidatedRanges: -> @invalidatedRanges

  onDidInvalidateRange: (fn) ->
    @emitter.on 'did-invalidate-range', fn

  emitInvalidateRangeEvent: (range) ->
    @emitter.emit 'did-invalidate-range', range

  containingTagsForPosition: (position) ->
    containingIds = @markerIndex.findContaining(position)
    @markerIndex.findEndingAt(position).forEach (id) -> containingIds.delete(id)
    Array.from(containingIds).map (id) => @tagsByMarkerId[id]

  bufferDidChange: ({oldRange, newRange}) ->
    @invalidatedRanges = [Range.fromObject(newRange)]
    {inside, overlap} = @markerIndex.splice(oldRange.start, oldRange.getExtent(), newRange.getExtent())
    overlap.forEach (id) => @invalidatedRanges.push(@markerIndex.getRange(id))
    inside.forEach (id) => @invalidatedRanges.push(@markerIndex.getRange(id))

    @insertRandomDecorations(oldRange, newRange)

  insertRandomDecorations: (oldRange, newRange) ->
    @invalidatedRanges ?= []
    for i in [0..@random(5)]
      markerId = @nextMarkerId++
      tag = String.fromCharCode('a'.charCodeAt(0) + @random(27))
      @tagsByMarkerId[markerId] = tag
      range = @getRandomRangeCloseTo(oldRange.union(newRange))
      @markerIndex.insert(markerId, range.start, range.end)
      @invalidatedRanges.push(range)

  getRandomRangeCloseTo: (range) ->
    if @random(10) < 7
      minRow = @constrainRow(range.start.row + @random.intBetween(-20, 20))
    else
      minRow = 0

    if @random(10) < 7
      maxRow = @constrainRow(range.end.row + @random.intBetween(-20, 20))
    else
      maxRow = @buffer.getLastRow()

    startRow = @random.intBetween(minRow, maxRow)
    endRow = @random.intBetween(startRow, maxRow)
    startColumn = @random(@buffer.lineForRow(startRow).length + 1)
    endColumn = @random(@buffer.lineForRow(endRow).length + 1)
    Range(Point(startRow, startColumn), Point(endRow, endColumn))

  constrainRow: (row) ->
    Math.max(0, Math.min(@buffer.getLastRow(), row))

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
