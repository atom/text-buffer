{clone} = require "underscore-plus"
{Emitter} = require 'event-kit'
Point = require "./point"
Range = require "./range"
Marker = require "./marker"
MarkerIndex = require "./marker-index"
{intersectSet} = require "./set-helpers"

SerializationVersion = 2

module.exports =
class MarkerLayer
  @deserialize: (delegate, state) ->
    store = new MarkerLayer(delegate, 0)
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

  ###
  Section: Lifecycle
  ###

  constructor: (@delegate, @id) ->
    @emitter = new Emitter
    @index = new MarkerIndex
    @markersById = {}
    @historiedMarkers = new Set
    @nextMarkerId = 0
    @destroyed = false

  # Public: Remove the {MarkerLayer} from the {TextBuffer}
  destroy: ->
    @destroyed = true
    @delegate.markerLayerDestroyed(this)

  isAlive: ->
    not @destroyed

  isDestroyed: ->
    @destroyed

  ###
  Section: Public interface
  ###

  # Public: Get an existing marker by its id.
  getMarker: (id) ->
    @markersById[id]

  # Public: Get all existing markers on the buffer.
  #
  # Returns an {Array} of {Marker}s.
  getMarkers: ->
    marker for id, marker of @markersById

  # Public: Get the number of markers in the buffer.
  #
  # Returns a {Number}.
  getMarkerCount: ->
    Object.keys(@markersById).length

  # Public: Find markers conforming to the given parameters.
  #
  # See the documentation for {TextBuffer::findMarkers}.
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

  # Public: Create a marker with the given range.
  #
  # See the documentation for {TextBuffer::markRange}
  markRange: (range, options={}) ->
    @createMarker(@delegate.clipRange(range), Marker.extractParams(options))

  # Public: Create a marker with the given position and no tail.
  #
  # See the documentation for {TextBuffer::markPosition}
  markPosition: (position, options={}) ->
    options.tailed ?= false
    position = @delegate.clipPosition(position)
    @markRange(new Range(position, position), options)

  onDidUpdate: (callback) ->
    @emitter.on 'did-update', callback

  ###
  Section: Private - TextBuffer interface
  ###

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
    return unless snapshots?

    createdIds = new Set
    snapshotIds = Object.keys(snapshots)
    existingMarkerIds = Object.keys(@markersById)

    for id in snapshotIds
      snapshot = snapshots[id]
      if marker = @markersById[id]
        marker.update(marker.getRange(), snapshot, true)
      else
        newMarker = @createMarker(snapshot.range, snapshot)
        createdIds.add(newMarker.id)

    for id in existingMarkerIds
      if (marker = @markersById[id]) and (not snapshots[id]?)
        if @historiedMarkers.has(id)
          marker.destroy()
        else
          marker.emitChangeEvent(marker.getRange(), true, false)

    @delegate.markersUpdated()
    return

  createSnapshot: (emitChangeEvents=false) ->
    result = {}
    ranges = @index.dump(@historiedMarkers)
    for id in Object.keys(@markersById)
      if marker = @markersById[id]
        if marker.maintainHistory
          result[id] = marker.getSnapshot(ranges[id], false)
        if emitChangeEvents
          marker.emitChangeEvent(ranges[id], true, false)
    @delegate.markersUpdated() if emitChangeEvents
    result

  serialize: ->
    ranges = @index.dump()
    markersById = {}
    for id in Object.keys(@markersById)
      marker = @markersById[id]
      markersById[id] = marker.getSnapshot(ranges[id], false) if marker.persistent
    {@nextMarkerId, @id, markersById, version: SerializationVersion}

  deserialize: (state) ->
    return unless state.version is SerializationVersion
    @id = state.id
    @nextMarkerId = state.nextMarkerId
    for id, markerState of state.markersById
      range = Range.fromObject(markerState.range)
      delete markerState.range
      @addMarker(id, range, markerState)
    return

  ###
  Section: Private - Marker interface
  ###

  markerUpdated: ->
    @delegate.markersUpdated()
    @scheduleUpdateEvent()

  destroyMarker: (id) ->
    delete @markersById[id]
    @historiedMarkers.delete(id)
    @index.delete(id)
    @delegate.markersUpdated()
    @scheduleUpdateEvent()

  getMarkerRange: (id) ->
    @index.getRange(id)

  getMarkerStartPosition: (id) ->
    @index.getStart(id)

  getMarkerEndPosition: (id) ->
    @index.getEnd(id)

  setMarkerRange: (id, range) ->
    {start, end} = Range.fromObject(range)
    start = @delegate.clipPosition(start)
    end = @delegate.clipPosition(end)
    @index.delete(id)
    @index.insert(id, start, end)

  setMarkerHasTail: (id, hasTail) ->
    @index.setExclusive(id, not hasTail)

  createMarker: (range, params) ->
    id = @id + '-' + @nextMarkerId++
    marker = @addMarker(id, range, params)
    @delegate.markerCreated(marker)
    @delegate.markersUpdated()
    @scheduleUpdateEvent()
    marker

  ###
  Section: Internal
  ###

  addMarker: (id, range, params) ->
    Point.assertValid(range.start)
    Point.assertValid(range.end)
    marker = new Marker(id, this, range, params)
    @markersById[id] = marker
    @index.insert(id, range.start, range.end)
    if marker.getInvalidationStrategy() is 'inside'
      @index.setExclusive(id, true)
    if marker.maintainHistory
      @historiedMarkers.add(id)
    marker

  scheduleUpdateEvent: ->
    unless @didUpdateEventScheduled
      @didUpdateEventScheduled = true
      process.nextTick =>
        @didUpdateEventScheduled = false
        @emitter.emit 'did-update'

filterSet = (set1, set2) ->
  if set1
    intersectSet(set1, set2)
    set1
  else
    set2
