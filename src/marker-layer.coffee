{clone} = require "underscore-plus"
{Emitter} = require 'event-kit'
Point = require "./point"
Range = require "./range"
Marker = require "./marker"
{MarkerIndex} = require "superstring"
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

  @deserializeSnapshot: (snapshot) ->
    result = {}
    for layerId, markerSnapshots of snapshot
      result[layerId] = {}
      for markerId, markerSnapshot of markerSnapshots
        result[layerId][markerId] = clone(markerSnapshot)
        result[layerId][markerId].range = Range.fromObject(markerSnapshot.range)
    result

  ###
  Section: Lifecycle
  ###

  constructor: (@delegate, @id, options) ->
    @maintainHistory = options?.maintainHistory ? false
    @destroyInvalidatedMarkers = options?.destroyInvalidatedMarkers ? false
    @role = options?.role
    @delegate.registerSelectionsMarkerLayer(this) if @role is "selections"
    @persistent = options?.persistent ? false
    @emitter = new Emitter
    @index = new MarkerIndex
    @markersById = {}
    @markersWithChangeListeners = new Set
    @markersWithDestroyListeners = new Set
    @displayMarkerLayers = new Set
    @destroyed = false
    @emitCreateMarkerEvents = false

  # Public: Create a copy of this layer with markers in the same state and
  # locations.
  copy: ->
    copy = @delegate.addMarkerLayer({@maintainHistory, @role})
    for markerId, marker of @markersById
      snapshot = marker.getSnapshot(null)
      copy.createMarker(marker.getRange(), marker.getSnapshot())
    copy

  # Public: Destroy this layer.
  destroy: ->
    return if @destroyed
    @clear()
    @delegate.markerLayerDestroyed(this)
    @displayMarkerLayers.forEach (displayMarkerLayer) -> displayMarkerLayer.destroy()
    @displayMarkerLayers.clear()
    @destroyed = true
    @emitter.emit 'did-destroy'
    @emitter.clear()

  # Public: Remove all markers from this layer.
  clear: ->
    @markersWithDestroyListeners.forEach (marker) -> marker.destroy()
    @markersWithDestroyListeners.clear()
    @markersById = {}
    @index = new MarkerIndex
    @displayMarkerLayers.forEach (layer) -> layer.didClearBufferMarkerLayer()
    @delegate.markersUpdated(this)

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
        when 'startsInRange'
          {start, end} = Range.fromObject(value)
          markerIds = filterSet(markerIds, @index.findStartingIn(start, end))
        when 'endsInRange'
          {start, end} = Range.fromObject(value)
          markerIds = filterSet(markerIds, @index.findEndingIn(start, end))
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
    markerIds.forEach (markerId) =>
      marker = @markersById[markerId]
      return unless marker.matchesParams(params)
      result.push(marker)
    result.sort (a, b) -> a.compare(b)

  # Public: Get the role of the marker layer e.g. `atom.selection`.
  #
  # Returns a {String}.
  getRole: ->
    @role

  ###
  Section: Marker creation
  ###

  # Public: Create a marker with the given range.
  #
  # * `range` A {Range} or range-compatible {Array}
  # * `options` A hash of key-value pairs to associate with the marker. There
  #   are also reserved property names that have marker-specific meaning.
  #   * `reversed` (optional) {Boolean} Creates the marker in a reversed
  #     orientation. (default: false)
  #   * `invalidate` (optional) {String} Determines the rules by which changes
  #     to the buffer *invalidate* the marker. (default: 'overlap') It can be
  #     any of the following strategies, in order of fragility:
  #     * __never__: The marker is never marked as invalid. This is a good choice for
  #       markers representing selections in an editor.
  #     * __surround__: The marker is invalidated by changes that completely surround it.
  #     * __overlap__: The marker is invalidated by changes that surround the
  #       start or end of the marker. This is the default.
  #     * __inside__: The marker is invalidated by changes that extend into the
  #       inside of the marker. Changes that end at the marker's start or
  #       start at the marker's end do not invalidate the marker.
  #     * __touch__: The marker is invalidated by a change that touches the marked
  #       region in any way, including changes that end at the marker's
  #       start or start at the marker's end. This is the most fragile strategy.
  #   * `exclusive` {Boolean} indicating whether insertions at the start or end
  #     of the marked range should be interpreted as happening *outside* the
  #     marker. Defaults to `false`, except when using the `inside`
  #     invalidation strategy or when when the marker has no tail, in which
  #     case it defaults to true. Explicitly assigning this option overrides
  #     behavior in all circumstances.
  #
  # Returns a {Marker}.
  markRange: (range, options={}) ->
    @createMarker(@delegate.clipRange(range), Marker.extractParams(options))

  # Public: Create a marker at with its head at the given position with no tail.
  #
  # * `position` {Point} or point-compatible {Array}
  # * `options` (optional) An {Object} with the following keys:
  #   * `invalidate` (optional) {String} Determines the rules by which changes
  #     to the buffer *invalidate* the marker. (default: 'overlap') It can be
  #     any of the following strategies, in order of fragility:
  #     * __never__: The marker is never marked as invalid. This is a good choice for
  #       markers representing selections in an editor.
  #     * __surround__: The marker is invalidated by changes that completely surround it.
  #     * __overlap__: The marker is invalidated by changes that surround the
  #       start or end of the marker. This is the default.
  #     * __inside__: The marker is invalidated by changes that extend into the
  #       inside of the marker. Changes that end at the marker's start or
  #       start at the marker's end do not invalidate the marker.
  #     * __touch__: The marker is invalidated by a change that touches the marked
  #       region in any way, including changes that end at the marker's
  #       start or start at the marker's end. This is the most fragile strategy.
  #   * `exclusive` {Boolean} indicating whether insertions at the start or end
  #     of the marked range should be interpreted as happening *outside* the
  #     marker. Defaults to `false`, except when using the `inside`
  #     invalidation strategy or when when the marker has no tail, in which
  #     case it defaults to true. Explicitly assigning this option overrides
  #     behavior in all circumstances.
  #
  # Returns a {Marker}.
  markPosition: (position, options={}) ->
    position = @delegate.clipPosition(position)
    options = Marker.extractParams(options)
    options.tailed = false
    @createMarker(@delegate.clipRange(new Range(position, position)), options)

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
  # You should prefer {::onDidUpdate} when synchronous notifications aren't
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
        if @destroyInvalidatedMarkers
          marker.destroy()
        else
          marker.valid = false

  restoreFromSnapshot: (snapshots, alwaysCreate) ->
    return unless snapshots?

    snapshotIds = Object.keys(snapshots)
    existingMarkerIds = Object.keys(@markersById)

    for id in snapshotIds
      snapshot = snapshots[id]
      if alwaysCreate
        @createMarker(snapshot.range, snapshot, true)
        continue

      if marker = @markersById[id]
        marker.update(marker.getRange(), snapshot, true, true)
      else
        {marker} = snapshot
        if marker
          @markersById[marker.id] = marker
          {range} = snapshot
          @index.insert(marker.id, range.start, range.end)
          marker.update(marker.getRange(), snapshot, true, true)
          @emitter.emit 'did-create-marker', marker if @emitCreateMarkerEvents
        else
          newMarker = @createMarker(snapshot.range, snapshot, true)

    for id in existingMarkerIds
      if (marker = @markersById[id]) and (not snapshots[id]?)
        marker.destroy(true)

  createSnapshot: ->
    result = {}
    ranges = @index.dump()
    for id in Object.keys(@markersById)
      marker = @markersById[id]
      result[id] = marker.getSnapshot(Range.fromObject(ranges[id]))
    result

  emitChangeEvents: (snapshot) ->
    @markersWithChangeListeners.forEach (marker) ->
      unless marker.isDestroyed() # event handlers could destroy markers
        marker.emitChangeEvent(snapshot?[marker.id]?.range, true, false)

  serialize: ->
    ranges = @index.dump()
    markersById = {}
    for id in Object.keys(@markersById)
      marker = @markersById[id]
      snapshot = marker.getSnapshot(Range.fromObject(ranges[id]), false)
      markersById[id] = snapshot

    {@id, @maintainHistory, @role, @persistent, markersById, version: SerializationVersion}

  deserialize: (state) ->
    return unless state.version is SerializationVersion
    @id = state.id
    @maintainHistory = state.maintainHistory
    @role = state.role
    @delegate.registerSelectionsMarkerLayer(this) if @role is "selections"
    @persistent = state.persistent
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

  destroyMarker: (marker, suppressMarkerLayerUpdateEvents=false) ->
    if @markersById.hasOwnProperty(marker.id)
      delete @markersById[marker.id]
      @index.remove(marker.id)
      @markersWithChangeListeners.delete(marker)
      @markersWithDestroyListeners.delete(marker)
      @displayMarkerLayers.forEach (displayMarkerLayer) -> displayMarkerLayer.destroyMarker(marker.id)
      @delegate.markersUpdated(this) unless suppressMarkerLayerUpdateEvents

  hasMarker: (id) ->
    not @destroyed and @index.has(id)

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
    @index.remove(id)
    @index.insert(id, start, end)

  setMarkerIsExclusive: (id, exclusive) ->
    @index.setExclusive(id, exclusive)

  createMarker: (range, params, suppressMarkerLayerUpdateEvents=false) ->
    id = @delegate.getNextMarkerId()
    marker = @addMarker(id, range, params)
    @delegate.markerCreated(this, marker)
    @delegate.markersUpdated(this) unless suppressMarkerLayerUpdateEvents
    marker.trackDestruction = @trackDestructionInOnDidCreateMarkerCallbacks ? false
    @emitter.emit 'did-create-marker', marker if @emitCreateMarkerEvents
    marker.trackDestruction = false
    marker

  ###
  Section: Internal
  ###

  addMarker: (id, range, params) ->
    range = Range.fromObject(range)
    Point.assertValid(range.start)
    Point.assertValid(range.end)
    @index.insert(id, range.start, range.end)
    @markersById[id] = new Marker(id, this, range, params)

  emitUpdateEvent: ->
    @emitter.emit('did-update')

filterSet = (set1, set2) ->
  if set1
    intersectSet(set1, set2)
    set1
  else
    set2
