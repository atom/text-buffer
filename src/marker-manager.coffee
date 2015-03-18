IntervalSkipList = require 'interval-skip-list'
Serializable = require 'serializable'
Delegator = require 'delegato'
{omit, defaults, values, clone, compact, intersection, keys, max, size} = require 'underscore-plus'
Marker = require './marker'
Point = require './point'
Range = require './range'

# Manages the markers for a buffer.
module.exports =
class MarkerManager
  Serializable.includeInto(this)
  Delegator.includeInto(this)

  @delegatesMethods 'clipPosition', 'clipRange', toProperty: 'buffer'

  # Counter used to give every marker a unique id.
  nextMarkerId: 1

  constructor: (@buffer, @markers) ->
    @intervals ?= @buildIntervals()
    if @markers?
      @nextMarkerId = max(keys(@markers).map((id) -> parseInt(id))) + 1
    else
      @markers = {}

  # Builds the ::intervals indexing structure, which allows for quick retrieval
  # based on location.
  buildIntervals: ->
    new IntervalSkipList
      compare: (a, b) -> a.compare(b)
      minIndex: new Point(-Infinity, -Infinity)
      maxIndex: new Point(Infinity, Infinity)

  # Called by {Serializable} during serialization
  serializeParams: ->
    markers = {}
    for id, marker of @markers
      markers[id] = marker.serialize() if marker.persistent
    {markers}

  # Called by {Serializable} during deserialization
  deserializeParams: (state) ->
    @intervals = @buildIntervals()
    for id, markerState of state.markers
      state.markers[id] = Marker.deserialize(markerState, manager: this)
    state

  markRange: (range, properties) ->
    range = @clipRange(Range.fromObject(range, true)).freeze()
    params = Marker.extractParams(properties)
    params.range = range
    @createMarker(params)

  markPosition: (position, properties) ->
    @markRange(new Range(position, position), defaults({tailed: false}, properties))

  getMarker: (id) ->
    @markers[id]

  getMarkers: ->
    values(@markers)

  getMarkerCount: ->
    size(@markers)

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
        when 'intersectsRange'
          range = Range.fromObject(value)
          candidateIds.push(@intervals.findIntersecting(range.start, range.end))
          delete params[key]
        when 'containedInRange'
          range = Range.fromObject(value)
          candidateIds.push(@intervals.findContainedIn(range.start, range.end))
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
        when 'intersectsRowRange'
          [startRow, endRow] = value
          candidateIds.push(@intervals.findIntersecting(new Point(startRow, 0), new Point(endRow, Infinity)))
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
    @buffer.markerCreated(marker)
    marker

  removeMarker: (id) ->
    delete @markers[id]

  didChangeMarker: (id, params) ->
    @buffer.history.didChangeMarker(id, params)

  buildSnapshot: (oldSnapshot) ->
    newSnapshot = {}
    for id of oldSnapshot
      newSnapshot[id] = @getMarker(id)?.toParams()
    newSnapshot

  restoreSnapshot: (snapshot) ->
    for id, params of snapshot
      @getMarker(id)?.update(params)
    return

  handleBufferChange: (patch) ->
    marker.handleBufferChange(patch) for id, marker of @markers

  pauseChangeEvents: ->
    marker.pauseChangeEvents() for marker in @getMarkers()

  resumeChangeEvents: ->
    marker.resumeChangeEvents() for marker in @getMarkers()
