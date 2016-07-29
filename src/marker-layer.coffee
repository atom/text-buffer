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
    @persistent = options?.persistent ? false
    @emitter = new Emitter
    @index = new MarkerIndex
    @markersById = new Map
    @markers = []
    @markersIdsWithChangeSubscriptions = new Set
    @createdMarkers = new Set
    @destroyedMarkers = new Set
    @updatedMarkers = new Set
    @touchedMarkers = new Set
    @setDisableDidUpdateEvent(false)
    @destroyed = false
    @emitCreateMarkerEvents = false

  # Public: Create a copy of this layer with markers in the same state and
  # locations.
  copy: ->
    copy = @delegate.addMarkerLayer({@maintainHistory})
    @markersById.forEach (marker, id) ->
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
    @markersById.get(id)

  # Public: Get the last (in terms of time) non-destroyed marker added to this layer.
  #
  # Returns a {Marker}.
  getLastMarker: ->
    @getMarker(@markers[@markers.length - 1])

  # Public: Get all existing markers on the marker layer.
  #
  # Returns an {Array} of {Marker}s.
  getMarkers: ->
    markers = []
    @markersById.forEach (marker) -> markers.push(marker)
    markers

  # Public: Get the number of markers in the marker layer.
  #
  # Returns a {Number}.
  getMarkerCount: ->
    @markersById.size

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

    result = []
    if markerIds?
      markerIds.forEach (markerId) =>
        marker = @markersById.get(markerId)
        if marker.matchesParams(params)
          result.push(marker)
    else
      @markersById.forEach (marker) ->
        if marker.matchesParams(params)
          result.push(marker)

    result.sort (a, b) -> a.compare(b)

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

  # Public: Subscribe to be notified whenever markers are created, updated,
  # touched (moved because of a textual change), or destroyed on this layer.
  # *Prefer this method for optimal performance when interacting with layers
  # that could contain large numbers of markers.*
  #
  # * `callback` A {Function} that will be called with no arguments when changes
  #   occur on this layer.
  #
  # Subscribers are notified once when any number of changes occur in this
  # {MarkerLayer}. The notification gets scheduled either at the end of a
  # transaction, or synchronously when a marker changes and no transaction is
  # present. You should re-query the layer to determine the state of markers in
  # which you're interested in: it may be counter-intuitive, but this is much
  # more efficient than subscribing to events on individual markers, which are
  # expensive to deliver.
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
      marker = @markersById.get(id)
      @touchedMarkers.add(id)
      if invalidated[marker.getInvalidationStrategy()]?.has(id)
        if @destroyInvalidatedMarkers
          marker.destroy()
        else
          marker.valid = false
    @emitDidUpdateEvent()

  restoreFromSnapshot: (snapshots) ->
    return unless snapshots?

    snapshotIds = Object.keys(snapshots)
    existingMarkerIds = Array.from(@markersById.keys())

    for id in snapshotIds
      snapshot = snapshots[id]
      if marker = @markersById.get(parseInt(id))
        marker.update(marker.getRange(), snapshot, true)
      else
        newMarker = @createMarker(snapshot.range, snapshot)

    for id in existingMarkerIds
      if (marker = @markersById.get(parseInt(id))) and (not snapshots[id]?)
        marker.destroy()

    @delegate.markersUpdated(this)

  createSnapshot: ->
    result = {}
    ranges = @index.dump()
    @markersById.forEach (marker, id) ->
      result[id] = marker.getSnapshot(Range.fromObject(ranges[id]), false)
    result

  emitChangeEvents: (snapshot) ->
    @markersIdsWithChangeSubscriptions.forEach (id) =>
      if marker = @markersById.get(id) # event handlers could destroy markers
        marker.emitChangeEvent(snapshot?[id]?.range, true, false)
    @delegate.markersUpdated(this)

  serialize: ->
    ranges = @index.dump()
    markersById = {}
    @markersById.forEach (marker, id) ->
      markersById[id] = marker.getSnapshot(Range.fromObject(ranges[id]), false)
    {@id, @maintainHistory, @persistent, markersById, version: SerializationVersion}

  deserialize: (state) ->
    return unless state.version is SerializationVersion
    @id = state.id
    @maintainHistory = state.maintainHistory
    @persistent = state.persistent
    for id, markerState of state.markersById
      range = Range.fromObject(markerState.range)
      delete markerState.range
      @addMarker(parseInt(id), range, markerState)
    return

  ###
  Section: Private - Marker interface
  ###

  markerUpdated: (id) ->
    @updatedMarkers.add(id)
    @emitDidUpdateEvent()
    @delegate.markersUpdated(this)

  destroyMarker: (id) ->
    if @markersById.has(id)
      @markersById.delete(id)
      index = @indexForMarkerId(id)
      @markers.splice(index, 1) if index isnt -1
      @markersIdsWithChangeSubscriptions.delete(id)
      @index.delete(id)
      @destroyedMarkers.add(id)
      @emitDidUpdateEvent()
      @delegate.markersUpdated(this)

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

  setMarkerIsExclusive: (id, exclusive) ->
    @index.setExclusive(id, exclusive)

  createMarker: (range, params) ->
    id = @delegate.getNextMarkerId()
    marker = @addMarker(id, range, params)
    @createdMarkers.add(id)
    @emitDidUpdateEvent()
    @emitter.emit 'did-create-marker', marker if @emitCreateMarkerEvents
    @delegate.markerCreated(this, marker)
    @delegate.markersUpdated(this)
    marker

  ###
  Section: Internal
  ###

  addMarker: (id, range, params) ->
    Point.assertValid(range.start)
    Point.assertValid(range.end)
    @index.insert(id, range.start, range.end)
    marker = new Marker(id, this, range, params)
    @markersById.set(id, marker)
    @markers.push(id)
    marker

  indexForMarkerId: (id) ->
    low = 0
    high = @markers.length - 1
    while low <= high
      index = low + ((high - low) >> 1)
      if id < @markers[index]
        high = index - 1
      else if id is @markers[index]
        return index
      else
        low = index + 1
    -1

  setDisableDidUpdateEvent: (@didUpdateEventDisabled) ->

  emitDidUpdateEvent: ->
    return if @didUpdateEventDisabled

    if @createdMarkers.size > 0 or @destroyedMarkers.size > 0 or @touchedMarkers.size > 0 or @updatedMarkers.size > 0
      event = {created: @createdMarkers, destroyed: @destroyedMarkers, touched: @touchedMarkers, updated: @updatedMarkers}
      @createdMarkers = new Set
      @destroyedMarkers = new Set
      @touchedMarkers = new Set
      @updatedMarkers = new Set
      @emitter.emit 'did-update', event

filterSet = (set1, set2) ->
  if set1
    intersectSet(set1, set2)
    set1
  else
    set2
