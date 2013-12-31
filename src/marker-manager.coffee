IntervalSkipList = require 'interval-skip-list'
Serializable = require 'nostalgia'
{omit, defaults, values, clone, compact, intersection} = require 'underscore'
Marker = require './marker'
Point = require './point'
Range = require './range'

module.exports =
class MarkerManager extends Serializable
  nextMarkerId: 1

  constructor: (@buffer, @markers) ->
    @intervals ?= @buildIntervals()
    @markers ?= {}

  buildIntervals: ->
    new IntervalSkipList
      compare: (a, b) -> a.compare(b)
      minIndex: new Point(-Infinity, -Infinity)
      maxIndex: new Point(Infinity, Infinity)

  serializeParams: ->
    markers = {}
    for id, marker of @markers
      markers[id] = marker.serialize()
    {markers}

  deserializeParams: (state) ->
    @intervals = @buildIntervals()
    for id, markerState of state.markers
      state.markers[id] = Marker.deserialize(markerState, manager: this)
    state

  markRange: (range, params) ->
    range = @buffer.clipRange(Range.fromObject(range, true)).freeze()
    params = Marker.extractParams(params)
    params.range = range
    @createMarker(params)

  markPosition: (position, options) ->
    @markRange([position, position], defaults({hasTail: false}, options))

  getMarker: (id) ->
    @markers[id]

  getMarkers: ->
    values(@markers)

  findMarkers: (params) ->
    params = clone(params)
    candidateIds = []
    for key, value of params
      switch key
        when 'startPosition'
          candidateIds.push(@intervals.findStartingAt(Point.fromObject(value)))
          delete params[key]
        when 'endPosition'
          candidateIds.push(@intervals.findEndingAt(Point.fromObject(value)))
          delete params[key]
        when 'containsPoint'
          candidateIds.push(@intervals.findContaining(Point.fromObject(value)))
          delete params[key]
        when 'containsRange'
          range = Range.fromObject(value)
          candidateIds.push(@intervals.findContaining(range.start, range.end))
          delete params[key]
        when 'startRow'
          candidateIds.push(@intervals.findStartingIn(new Point(value, 0), new Point(value, Infinity)))
          delete params[key]
        when 'endRow'
          candidateIds.push(@intervals.findEndingIn(new Point(value, 0), new Point(value, Infinity)))
          delete params[key]
        when 'intersectsRow'
          candidateIds.push(@intervals.findIntersecting(new Point(value, 0), new Point(value, Infinity)))
          delete params[key]

    if candidateIds.length > 0
      candidates = compact(intersection(candidateIds...).map((id) => @getMarker(id)))
    else
      candidates = @getMarkers()
    markers = candidates.filter (marker) -> marker.matchesParams(params)
    markers.sort (a, b) -> a.compare(b)

  createMarker: (params) ->
    params.manager = this
    params.id = @nextMarkerId++
    marker = new Marker(params)
    @markers[marker.id] = marker
    @buffer.emit 'marker-created', marker
    marker

  removeMarker: (id) ->
    delete @markers[id]

  recordMarkerPatch: (patch) ->
    if @buffer.isTransacting()
      @buffer.history.recordNewPatch(patch)

  handleBufferChange: (patch) ->
    marker.handleBufferChange(patch) for id, marker of @markers

  applyPatches: (markerPatches, bufferChanged) ->
    for id, patch of markerPatches
      @getMarker(id)?.applyPatch(patch, bufferChanged)

  pauseChangeEvents: ->
    marker.pauseEvents('changed') for marker in @getMarkers()

  resumeChangeEvents: ->
    marker.resumeEvents('changed') for marker in @getMarkers()
