{clone} = require "underscore-plus"
Point = require "./point"
Range = require "./range"
Marker = require "./marker"
MarkerIndex = require "./marker-index"
{intersectSet} = require "./set-helpers"

SerializationVersion = 2

module.exports =
class MarkerStore
  @deserialize: (delegate, state) ->
    store = new MarkerStore(delegate)
    store.deserialize(state)
    store

  @serializeSnapshot: (snapshot) ->
    result = {}
    for id, markerSnapshot of snapshot
      result[id] = clone(markerSnapshot)
      result[id].range = markerSnapshot.range.serialize()
    result

  @deserializeSnapshot: (snapshot) ->
    result = {}
    for id, markerSnapshot of snapshot
      result[id] = clone(markerSnapshot)
      result[id].range = Range.deserialize(markerSnapshot.range)
    result

  constructor: (@delegate) ->
    @index = new MarkerIndex
    @markersById = {}
    @nextMarkerId = 0

  ###
  Section: TextBuffer API
  ###

  getMarker: (id) ->
    @markersById[id]

  getMarkers: ->
    marker for id, marker of @markersById

  getMarkerCount: ->
    Object.keys(@markersById).length

  findMarkers: (params) ->
    markerIds = null

    for key in Object.keys(params)
      value = params[key]
      switch key
        when 'startPosition'
          markerIds = filterSet(markerIds, @index.findStartingIn(Point.fromObject(value)))
        when 'endPosition'
          markerIds = filterSet(markerIds, @index.findEndingIn(Point.fromObject(value)))
        when 'containsPoint', 'containsPosition'
          markerIds = filterSet(markerIds, @index.findContaining(Point.fromObject(value)))
        when 'containsRange'
          {start, end} = Range.fromObject(value)
          markerIds = filterSet(markerIds, @index.findContaining(start, end))
        when 'intersectsRange'
          {start, end} = Range.fromObject(value)
          markerIds = filterSet(markerIds, @index.findIntersecting(start, end))
        when 'startRow'
          markerIds = filterSet(markerIds, @index.findStartingIn(Point(value, 0), Point(value, Infinity)))
        when 'endRow'
          markerIds = filterSet(markerIds, @index.findEndingIn(Point(value, 0), Point(value, Infinity)))
        when 'intersectsRow'
          markerIds = filterSet(markerIds, @index.findIntersecting(Point(value, 0), Point(value, Infinity)))
        when 'intersectsRowRange'
          markerIds = filterSet(markerIds, @index.findIntersecting(Point(value[0], 0), Point(value[1], Infinity)))
        when 'containedInRange'
          {start, end} = Range.fromObject(value)
          markerIds = filterSet(markerIds, @index.findContainedIn(start, end))
        else
          continue
      delete params[key]

    markerIds ?= new Set(Object.keys(@markersById))

    result = []
    markerIds.forEach (id) =>
      marker = @markersById[id]
      result.push(marker) if marker.matchesParams(params)
    result.sort (a, b) -> a.compare(b)

  markRange: (range, options={}) ->
    @createMarker(Range.fromObject(range), Marker.extractParams(options))

  markPosition: (position, options={}) ->
    options.tailed ?= false
    @markRange(Range(position, position), options)

  splice: (start, oldExtent, newExtent) ->
    end = start.traverse(oldExtent)

    intersecting = @index.findIntersecting(start, end)
    endingAt = @index.findEndingIn(start)
    startingAt = @index.findStartingIn(end)
    startingIn = @index.findStartingIn(start.traverse(Point(0, 1)), end.traverse(Point(0, -1)))
    endingIn = @index.findEndingIn(start.traverse(Point(0, 1)), end.traverse(Point(0, -1)))

    for id in Object.keys(@markersById)
      marker = @markersById[id]
      switch marker.getInvalidationStrategy()
        when 'touch'
          invalid = intersecting.has(id)
        when 'inside'
          invalid = intersecting.has(id) and not (startingAt.has(id) or endingAt.has(id))
        when 'overlap'
          invalid = startingIn.has(id) or endingIn.has(id)
        when 'surround'
          invalid = startingIn.has(id) and endingIn.has(id)
        when 'never'
          invalid = false
      marker.valid = false if invalid

    @index.splice(start, oldExtent, newExtent)

  restoreFromSnapshot: (snapshots) ->
    markersUpdated = false
    for id in Object.keys(@markersById)
      if marker = @markersById[id]
        if snapshot = snapshots[id]
          marker.update(marker.getRange(), snapshot, true)
        else
          marker.emitChangeEvent(marker.getRange(), true, false)
    @delegate.markersUpdated()
    return

  createSnapshot: (filterPersistent, emitChangeEvents) ->
    result = {}
    ranges = @index.dump()
    for id in Object.keys(@markersById)
      if marker = @markersById[id]
        if marker.persistent or not filterPersistent
          result[id] = marker.getSnapshot(ranges[id], false)
        if emitChangeEvents
          marker.emitChangeEvent(ranges[id], true, false)
    @delegate.markersUpdated() if emitChangeEvents
    result

  serialize: ->
    version: SerializationVersion
    nextMarkerId: @nextMarkerId
    markersById: @createSnapshot(true)

  deserialize: (state) ->
    return unless state.version is SerializationVersion
    @nextMarkerId = state.nextMarkerId
    for id, markerState of state.markersById
      range = Range.fromObject(markerState.range)
      delete markerState.range
      @index.insert(id, range.start, range.end)
      marker = new Marker(id, this, range, markerState)
      @markersById[id] = marker
    return

  ###
  Section: Marker interface
  ###

  markerUpdated: ->
    @delegate.markersUpdated()

  destroyMarker: (id) ->
    delete @markersById[id]
    @index.delete(id)
    @delegate.markersUpdated()

  getMarkerRange: (id) ->
    @index.getRange(id)

  getMarkerStartPosition: (id) ->
    @index.getStart(id)

  getMarkerEndPosition: (id) ->
    @index.getEnd(id)

  setMarkerRange: (id, range) ->
    @index.delete(id)
    {start, end} = Range.fromObject(range)
    @index.insert(id, @delegate.clipPosition(start), @delegate.clipPosition(end))

  setMarkerHasTail: (id, hasTail) ->
    @index.setExclusive(id, not hasTail)

  createMarker: (range, params) ->
    id = String(@nextMarkerId++)
    marker = new Marker(id, this, range, params)
    @markersById[id] = marker
    @index.insert(id, range.start, range.end)
    if marker.getInvalidationStrategy() is 'inside'
      @index.setExclusive(id, true)
    @delegate.markerCreated(marker)
    @delegate.markersUpdated()
    marker

filterSet = (set1, set2) ->
  if set1
    intersectSet(set1, set2)
    set1
  else
    set2
