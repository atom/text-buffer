{clone} = require "underscore-plus"
{Emitter} = require 'event-kit'
Point = require "./point"
Range = require "./range"
Marker = require "./marker"
MarkerIndex = require "marker-index"
{intersectSet} = require "./set-helpers"

SerializationVersion = 2

# Public: *Experimental:* A container for a related set of markers.
#
# This API is experimental and subject to change on any release.
module.exports =
class MarkerLayer
  @deserialize: (delegate, state) ->
    store = new MarkerLayer(delegate, 0)
    store.deserialize(state)
    store

  @serializeSnapshot: (snapshot) ->
    result = {}
    for layerId, markerSnapshots of snapshot
      result[layerId] = {}
      for markerId, markerSnapshot of markerSnapshots
        result[layerId][markerId] = clone(markerSnapshot)
        result[layerId][markerId].range = markerSnapshot.range.serialize()
    result

  @deserializeSnapshot: (snapshot) ->
    result = {}
    for layerId, markerSnapshots of snapshot
      result[layerId] = {}
      for markerId, markerSnapshot of markerSnapshots
        result[layerId][markerId] = clone(markerSnapshot)
        result[layerId][markerId].range = Range.deserialize(markerSnapshot.range)
    result

  ###
  Section: Lifecycle
  ###

  constructor: (@delegate, @id, options) ->
    @maintainHistory = options?.maintainHistory ? false
    @emitter = new Emitter
    @index = new MarkerIndex
    @markersById = {}
    @markersIdsWithChangeSubscriptions = new Set
    @destroyed = false
    @emitCreateMarkerEvents = false

  # Public: Create a copy of this layer with markers in the same state and
  # locations.
  copy: ->
    copy = @delegate.addMarkerLayer({@maintainHistory})
    for markerId, marker of @markersById
      snapshot = marker.getSnapshot(null)
      copy.createMarker(marker.getRange(), marker.getSnapshot())
    copy

  # Public: Destroy this layer.
  destroy: ->
    @destroyed = true
    @delegate.markerLayerDestroyed(this)
    @emitter.emit 'did-destroy'
    @emitter.dispose()

  # Public: Determine whether this layer has been destroyed.
  isDestroyed: ->
    @destroyed

  isAlive: ->
    not @destroyed

  ###
  Section: Querying
  ###

  # Public: Get an existing marker by its id.
  #
  # Returns a {Marker}.
  getMarker: (id) ->
    @markersById[id]

  # Public: Get all existing markers on the marker layer.
  #
  # Returns an {Array} of {Marker}s.
  getMarkers: ->
    marker for id, marker of @markersById

  # Public: Get the number of markers in the marker layer.
  #
  # Returns a {Number}.
  getMarkerCount: ->
    Object.keys(@markersById).length

  # Public: Find markers in the layer conforming to the given parameters.
  #
  # See the documentation for {TextBuffer::findMarkers}.
  findMarkers: (params) ->
    markerIds = null

    for key in Object.keys(params)
      value = params[key]
      switch key
        when 'startPosition'
          markerIds = filterSet(markerIds, @index.findStartingAt(Point.fromObject(value)))
        when 'endPosition'
          markerIds = filterSet(markerIds, @index.findEndingAt(Point.fromObject(value)))
        when 'containsPoint', 'containsPosition'
          position = Point.fromObject(value)
          markerIds = filterSet(markerIds, @index.findContaining(position, position))
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

  ###
  Section: Marker creation
  ###

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

  ###
  Section: Event subscription
  ###

  # Public: Subscribe to be notified asynchronously whenever markers are
  # created, updated, or destroyed on this layer. *Prefer this method for
  # optimal performance when interacting with layers that could contain large
  # numbers of markers.*
  #
  # * `callback` A {Function} that will be called with no arguments when changes
  #   occur on this layer.
  #
  # Subscribers are notified once, asynchronously when any number of changes
  # occur in a given tick of the event loop. You should re-query the layer
  # to determine the state of markers in which you're interested in. It may
  # be counter-intuitive, but this is much more efficient than subscribing to
  # events on individual markers, which are expensive to deliver.
  #
  # Returns a {Disposable}.
  onDidUpdate: (callback) ->
    @emitter.on 'did-update', callback

  # Public: Subscribe to be notified synchronously whenever markers are created
  # on this layer. *Avoid this method for optimal performance when interacting
  # with layers that could contain large numbers of markers.*
  #
  # * `callback` A {Function} that will be called with a {Marker} whenever a
  #   new marker is created.
  #
  # You should prefer {onDidUpdate} when synchronous notifications aren't
  # absolutely necessary.
  #
  # Returns a {Disposable}.
  onDidCreateMarker: (callback) ->
    @emitCreateMarkerEvents = true
    @emitter.on 'did-create-marker', callback

  # Public: Subscribe to be notified synchronously when this layer is destroyed.
  #
  # Returns a {Disposable}.
  onDidDestroy: (callback) ->
    @emitter.on 'did-destroy', callback

  ###
  Section: Private - TextBuffer interface
  ###

  splice: (start, oldExtent, newExtent) ->
    invalidated = @index.splice(start, oldExtent, newExtent)
    invalidated.touch.forEach (id) =>
      marker = @markersById[id]
      if invalidated[marker.getInvalidationStrategy()]?.has(id)
        marker.valid = false
    @scheduleUpdateEvent()

  restoreFromSnapshot: (snapshots) ->
    return unless snapshots?

    snapshotIds = Object.keys(snapshots)
    existingMarkerIds = Object.keys(@markersById)

    for id in snapshotIds
      snapshot = snapshots[id]
      if marker = @markersById[id]
        marker.update(marker.getRange(), snapshot, true)
      else
        newMarker = @createMarker(snapshot.range, snapshot)

    for id in existingMarkerIds
      if (marker = @markersById[id]) and (not snapshots[id]?)
        marker.destroy()

    @delegate.markersUpdated(this)

  createSnapshot: ->
    result = {}
    ranges = @index.dump()
    for id in Object.keys(@markersById)
      marker = @markersById[id]
      result[id] = marker.getSnapshot(Range.fromObject(ranges[id]), false)
    result

  emitChangeEvents: (snapshot) ->
    @markersIdsWithChangeSubscriptions.forEach (id) =>
      if marker = @markersById[id] # event handlers could destroy markers
        marker.emitChangeEvent(snapshot?[id]?.range, true, false)
    @delegate.markersUpdated(this)

  serialize: ->
    ranges = @index.dump()
    markersById = {}
    for id in Object.keys(@markersById)
      marker = @markersById[id]
      markersById[id] = marker.getSnapshot(Range.fromObject(ranges[id]), false) if marker.persistent
    {@id, @maintainHistory, markersById, version: SerializationVersion}

  deserialize: (state) ->
    return unless state.version is SerializationVersion
    @id = state.id
    @maintainHistory = state.maintainHistory
    for id, markerState of state.markersById
      range = Range.fromObject(markerState.range)
      delete markerState.range
      @addMarker(id, range, markerState)
    return

  ###
  Section: Private - Marker interface
  ###

  markerUpdated: ->
    @delegate.markersUpdated(this)
    @scheduleUpdateEvent()

  destroyMarker: (id) ->
    if @markersById.hasOwnProperty(id)
      delete @markersById[id]
      @markersIdsWithChangeSubscriptions.delete(id)
      @index.delete(id)
      @delegate.markersUpdated(this)
      @scheduleUpdateEvent()

  getMarkerRange: (id) ->
    Range.fromObject(@index.getRange(id))

  getMarkerStartPosition: (id) ->
    Point.fromObject(@index.getStart(id))

  getMarkerEndPosition: (id) ->
    Point.fromObject(@index.getEnd(id))

  compareMarkers: (id1, id2) ->
    @index.compare(id1, id2)

  setMarkerRange: (id, range) ->
    {start, end} = Range.fromObject(range)
    start = @delegate.clipPosition(start)
    end = @delegate.clipPosition(end)
    @index.delete(id)
    @index.insert(id, start, end)

  setMarkerHasTail: (id, hasTail) ->
    @index.setExclusive(id, not hasTail)

  createMarker: (range, params) ->
    id = @delegate.getNextMarkerId()
    marker = @addMarker(id, range, params)
    @delegate.markerCreated(this, marker)
    @delegate.markersUpdated(this)
    @scheduleUpdateEvent()
    @emitter.emit 'did-create-marker', marker if @emitCreateMarkerEvents
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
