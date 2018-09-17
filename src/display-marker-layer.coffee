{Emitter, CompositeDisposable} = require 'event-kit'
DisplayMarker = require './display-marker'
Range = require './range'
Point = require './point'

# Public: *Experimental:* A container for a related set of markers at the
# {DisplayLayer} level. Wraps an underlying {MarkerLayer} on the {TextBuffer}.
#
# This API is experimental and subject to change on any release.
module.exports =
class DisplayMarkerLayer
  constructor: (@displayLayer, @bufferMarkerLayer, @ownsBufferMarkerLayer) ->
    {@id} = @bufferMarkerLayer
    @bufferMarkerLayer.displayMarkerLayers.add(this)
    @markersById = {}
    @destroyed = false
    @emitter = new Emitter
    @subscriptions = new CompositeDisposable
    @markersWithDestroyListeners = new Set
    @subscriptions.add(@bufferMarkerLayer.onDidUpdate(@emitDidUpdate.bind(this)))

  ###
  Section: Lifecycle
  ###

  # Essential: Destroy this layer.
  destroy: ->
    return if @destroyed
    @destroyed = true
    @clear() if @ownsBufferMarkerLayer
    @subscriptions.dispose()
    @bufferMarkerLayer.displayMarkerLayers.delete(this)
    @bufferMarkerLayer.destroy() if @ownsBufferMarkerLayer
    @displayLayer.didDestroyMarkerLayer(@id)
    @emitter.emit('did-destroy')
    @emitter.clear()

  # Public: Destroy all markers in this layer.
  clear: ->
    @bufferMarkerLayer.clear()

  didClearBufferMarkerLayer: ->
    @markersWithDestroyListeners.forEach (marker) -> marker.didDestroyBufferMarker()
    @markersById = {}

  # Essential: Determine whether this layer has been destroyed.
  #
  # Returns a {Boolean}.
  isDestroyed: ->
    @destroyed

  ###
  Section: Event Subscription
  ###

  # Public: Subscribe to be notified synchronously when this layer is destroyed.
  #
  # Returns a {Disposable}.
  onDidDestroy: (callback) ->
    @emitter.on('did-destroy', callback)

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
    @emitter.on('did-update', callback)

  # Public: Subscribe to be notified synchronously whenever markers are created
  # on this layer. *Avoid this method for optimal performance when interacting
  # with layers that could contain large numbers of markers.*
  #
  # * `callback` A {Function} that will be called with a {TextEditorMarker}
  #   whenever a new marker is created.
  #
  # You should prefer {::onDidUpdate} when synchronous notifications aren't
  # absolutely necessary.
  #
  # Returns a {Disposable}.
  onDidCreateMarker: (callback) ->
    @bufferMarkerLayer.onDidCreateMarker (bufferMarker) =>
      callback(@getMarker(bufferMarker.id))

  ###
  Section: Marker creation
  ###

  # Public: Create a marker with the given screen range.
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
  #   * `clipDirection` {String} If `'backward'`, returns the first valid
  #     position preceding an invalid position. If `'forward'`, returns the
  #     first valid position following an invalid position. If `'closest'`,
  #     returns the first valid position closest to an invalid position.
  #     Defaults to `'closest'`. Applies to the start and end of the given range.
  #
  # Returns a {DisplayMarker}.
  markScreenRange: (screenRange, options) ->
    screenRange = Range.fromObject(screenRange)
    bufferRange = @displayLayer.translateScreenRange(screenRange, options)
    @getMarker(@bufferMarkerLayer.markRange(bufferRange, options).id)

  # Public: Create a marker on this layer with its head at the given screen
  # position and no tail.
  #
  # * `screenPosition` A {Point} or point-compatible {Array}
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
  #   * `clipDirection` {String} If `'backward'`, returns the first valid
  #     position preceding an invalid position. If `'forward'`, returns the
  #     first valid position following an invalid position. If `'closest'`,
  #     returns the first valid position closest to an invalid position.
  #     Defaults to `'closest'`.
  #
  # Returns a {DisplayMarker}.
  markScreenPosition: (screenPosition, options) ->
    screenPosition = Point.fromObject(screenPosition)
    bufferPosition = @displayLayer.translateScreenPosition(screenPosition, options)
    @getMarker(@bufferMarkerLayer.markPosition(bufferPosition, options).id)

  # Public: Create a marker with the given buffer range.
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
  # Returns a {DisplayMarker}.
  markBufferRange: (bufferRange, options) ->
    bufferRange = Range.fromObject(bufferRange)
    @getMarker(@bufferMarkerLayer.markRange(bufferRange, options).id)

  # Public: Create a marker on this layer with its head at the given buffer
  # position and no tail.
  #
  # * `bufferPosition` A {Point} or point-compatible {Array}
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
  # Returns a {DisplayMarker}.
  markBufferPosition: (bufferPosition, options) ->
    @getMarker(@bufferMarkerLayer.markPosition(Point.fromObject(bufferPosition), options).id)

  ###
  Section: Querying
  ###

  # Essential: Get an existing marker by its id.
  #
  # Returns a {DisplayMarker}.
  getMarker: (id) ->
    if displayMarker = @markersById[id]
      displayMarker
    else if bufferMarker = @bufferMarkerLayer.getMarker(id)
      @markersById[id] = new DisplayMarker(this, bufferMarker)

  # Essential: Get all markers in the layer.
  #
  # Returns an {Array} of {DisplayMarker}s.
  getMarkers: ->
    @bufferMarkerLayer.getMarkers().map ({id}) => @getMarker(id)

  # Public: Get the number of markers in the marker layer.
  #
  # Returns a {Number}.
  getMarkerCount: ->
    @bufferMarkerLayer.getMarkerCount()

  # Public: Find markers in the layer conforming to the given parameters.
  #
  # This method finds markers based on the given properties. Markers can be
  # associated with custom properties that will be compared with basic equality.
  # In addition, there are several special properties that will be compared
  # with the range of the markers rather than their properties.
  #
  # * `properties` An {Object} containing properties that each returned marker
  #   must satisfy. Markers can be associated with custom properties, which are
  #   compared with basic equality. In addition, several reserved properties
  #   can be used to filter markers based on their current range:
  #   * `startBufferPosition` Only include markers starting at this {Point} in buffer coordinates.
  #   * `endBufferPosition` Only include markers ending at this {Point} in buffer coordinates.
  #   * `startScreenPosition` Only include markers starting at this {Point} in screen coordinates.
  #   * `endScreenPosition` Only include markers ending at this {Point} in screen coordinates.
  #   * `startsInBufferRange` Only include markers starting inside this {Range} in buffer coordinates.
  #   * `endsInBufferRange` Only include markers ending inside this {Range} in buffer coordinates.
  #   * `startsInScreenRange` Only include markers starting inside this {Range} in screen coordinates.
  #   * `endsInScreenRange` Only include markers ending inside this {Range} in screen coordinates.
  #   * `startBufferRow` Only include markers starting at this row in buffer coordinates.
  #   * `endBufferRow` Only include markers ending at this row in buffer coordinates.
  #   * `startScreenRow` Only include markers starting at this row in screen coordinates.
  #   * `endScreenRow` Only include markers ending at this row in screen coordinates.
  #   * `intersectsBufferRowRange` Only include markers intersecting this {Array}
  #      of `[startRow, endRow]` in buffer coordinates.
  #   * `intersectsScreenRowRange` Only include markers intersecting this {Array}
  #      of `[startRow, endRow]` in screen coordinates.
  #   * `containsBufferRange` Only include markers containing this {Range} in buffer coordinates.
  #   * `containsBufferPosition` Only include markers containing this {Point} in buffer coordinates.
  #   * `containedInBufferRange` Only include markers contained in this {Range} in buffer coordinates.
  #   * `containedInScreenRange` Only include markers contained in this {Range} in screen coordinates.
  #   * `intersectsBufferRange` Only include markers intersecting this {Range} in buffer coordinates.
  #   * `intersectsScreenRange` Only include markers intersecting this {Range} in screen coordinates.
  #
  # Returns an {Array} of {DisplayMarker}s
  findMarkers: (params) ->
    params = @translateToBufferMarkerLayerFindParams(params)
    @bufferMarkerLayer.findMarkers(params).map (stringMarker) => @getMarker(stringMarker.id)

  ###
  Section: Private
  ###

  translateBufferPosition: (bufferPosition, options) ->
    @displayLayer.translateBufferPosition(bufferPosition, options)

  translateBufferRange: (bufferRange, options) ->
    @displayLayer.translateBufferRange(bufferRange, options)

  translateScreenPosition: (screenPosition, options) ->
    @displayLayer.translateScreenPosition(screenPosition, options)

  translateScreenRange: (screenRange, options) ->
    @displayLayer.translateScreenRange(screenRange, options)

  emitDidUpdate: ->
    @emitter.emit('did-update')

  notifyObserversIfMarkerScreenPositionsChanged: ->
    for marker in @getMarkers()
      marker.notifyObservers(false)
    return

  destroyMarker: (id) ->
    if marker = @markersById[id]
      marker.didDestroyBufferMarker()

  didDestroyMarker: (marker) ->
    @markersWithDestroyListeners.delete(marker)
    delete @markersById[marker.id]

  translateToBufferMarkerLayerFindParams: (params) ->
    bufferMarkerLayerFindParams = {}
    for key, value of params
      switch key
        when 'startBufferPosition'
          key = 'startPosition'
        when 'endBufferPosition'
          key = 'endPosition'
        when 'startScreenPosition'
          key = 'startPosition'
          value = @displayLayer.translateScreenPosition(value)
        when 'endScreenPosition'
          key = 'endPosition'
          value = @displayLayer.translateScreenPosition(value)
        when 'startsInBufferRange'
          key = 'startsInRange'
        when 'endsInBufferRange'
          key = 'endsInRange'
        when 'startsInScreenRange'
          key = 'startsInRange'
          value = @displayLayer.translateScreenRange(value)
        when 'endsInScreenRange'
          key = 'endsInRange'
          value = @displayLayer.translateScreenRange(value)
        when 'startBufferRow'
          key = 'startRow'
        when 'endBufferRow'
          key = 'endRow'
        when 'startScreenRow'
          key = 'startsInRange'
          startBufferPosition = @displayLayer.translateScreenPosition(Point(value, 0))
          endBufferPosition = @displayLayer.translateScreenPosition(Point(value, Infinity))
          value = Range(startBufferPosition, endBufferPosition)
        when 'endScreenRow'
          key = 'endsInRange'
          startBufferPosition = @displayLayer.translateScreenPosition(Point(value, 0))
          endBufferPosition = @displayLayer.translateScreenPosition(Point(value, Infinity))
          value = Range(startBufferPosition, endBufferPosition)
        when 'intersectsBufferRowRange'
          key = 'intersectsRowRange'
        when 'intersectsScreenRowRange'
          key = 'intersectsRange'
          [startScreenRow, endScreenRow] = value
          startBufferPosition = @displayLayer.translateScreenPosition(Point(startScreenRow, 0))
          endBufferPosition = @displayLayer.translateScreenPosition(Point(endScreenRow, Infinity))
          value = Range(startBufferPosition, endBufferPosition)
        when 'containsBufferRange'
          key = 'containsRange'
        when 'containsScreenRange'
          key = 'containsRange'
          value = @displayLayer.translateScreenRange(value)
        when 'containsBufferPosition'
          key = 'containsPosition'
        when 'containsScreenPosition'
          key = 'containsPosition'
          value = @displayLayer.translateScreenPosition(value)
        when 'containedInBufferRange'
          key = 'containedInRange'
        when 'containedInScreenRange'
          key = 'containedInRange'
          value = @displayLayer.translateScreenRange(value)
        when 'intersectsBufferRange'
          key = 'intersectsRange'
        when 'intersectsScreenRange'
          key = 'intersectsRange'
          value = @displayLayer.translateScreenRange(value)
      bufferMarkerLayerFindParams[key] = value

    bufferMarkerLayerFindParams
