{extend, isEqual, omit, pick, size} = require 'underscore-plus'
EmitterMixin = require('emissary').Emitter
{Emitter} = require 'event-kit'
Grim = require 'grim'
Delegator = require 'delegato'
Serializable = require 'serializable'
MarkerPatch = require './marker-patch'
Point = require './point'
Range = require './range'

OptionKeys = ['reversed', 'tailed', 'invalidate', 'persistent']

# Private: Represents a buffer annotation that remains logically stationary
# even as the buffer changes. This is used to represent cursors, folds, snippet
# targets, misspelled words, and anything else that needs to track a logical
# location in the buffer over time.
#
# Head and Tail:
# Markers always have a *head* and sometimes have a *tail*. If you think of a
# marker as an editor selection, the tail is the part that's stationary and the
# head is the part that moves when the mouse is moved. A marker without a tail
# always reports an empty range at the head position. A marker with a head position
# greater than the tail is in a "normal" orientation. If the head precedes the
# tail the marker is in a "reversed" orientation.
#
# Validity:
# Markers are considered *valid* when they are first created. Depending on the
# invalidation strategy you choose, certain changes to the buffer can cause a
# marker to become invalid, for example if the text surrounding the marker is
# deleted. See {TextBuffer::markRange} for invalidation strategies.
module.exports =
class Marker
  EmitterMixin.includeInto(this)
  Delegator.includeInto(this)
  Serializable.includeInto(this)

  @extractParams: (inputParams) ->
    outputParams = {}
    if inputParams?
      @handleDeprecatedParams(inputParams)
      extend(outputParams, pick(inputParams, OptionKeys))
      properties = omit(inputParams, OptionKeys)
      outputParams.properties = properties if size(properties) > 0
    outputParams

  @handleDeprecatedParams: (params) ->
    if params.isReversed?
      Grim.deprecate("The option `isReversed` is deprecated, use `reversed` instead")
      params.reversed = params.isReversed
      delete params.isReversed

    if params.hasTail?
      Grim.deprecate("The option `hasTail` is deprecated, use `tailed` instead")
      params.tailed = params.hasTail
      delete params.hasTail

    if params.persist?
      Grim.deprecate("The option `persist` is deprecated, use `persistent` instead")
      params.persistent = params.persist
      delete params.persist

    if params.invalidation
      Grim.deprecate("The option `invalidation` is deprecated, use `invalidate` instead")
      params.invalidate = params.invalidation
      delete params.invalidation

  @serializeSnapshot: (snapshot) ->
    return unless snapshot?
    serializedSnapshot = {}
    for id, {range, valid} of snapshot
      serializedSnapshot[id] = {range: range.serialize(), valid}
    serializedSnapshot

  @deserializeSnapshot: (serializedSnapshot) ->
    return unless serializedSnapshot?
    snapshot = {}
    for id, {range, valid} of serializedSnapshot
      snapshot[id] = {range: Range.deserialize(range), valid}
    snapshot

  @delegatesMethods 'containsPoint', 'containsRange', 'intersectsRow', toProperty: 'range'
  @delegatesMethods 'clipPosition', 'clipRange', toProperty: 'manager'

  deferredChangeEvents: null

  constructor: (params) ->
    {@manager, @id, @range, @tailed, @reversed} = params
    {@valid, @invalidate, @persistent, @properties} = params
    @emitter = new Emitter
    @tailed ?= true
    @reversed ?= false
    @valid ?= true
    @invalidate ?= 'overlap'
    @persistent ?= true
    @properties ?= {}
    @destroyed = false
    Object.freeze(@properties)
    @updateIntervals()

  # Used by {Serializable} during serialization.
  serializeParams: ->
    range = @range.serialize()
    {@id, range, @tailed, @reversed, @valid, @invalidate, @persistent, @properties}

  # Used by {Serializable} during deserialization.
  deserializeParams: (state) ->
    state.range = Range.deserialize(state.range)
    state

  # Public: Invoke the given callback when the marker is destroyed.
  #
  # * `callback` {Function} to be called when the marker is destroyed.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  onDidDestroy: (callback) ->
    @emitter.on 'did-destroy', callback

  # Public: Invoke the given callback when the state of the marker changes.
  #
  # * `callback` {Function} to be called when the marker changes.
  #   * `event` {Object} with the following keys:
  #     * `oldHeadPosition` {Point} representing the former head position
  #     * `newHeadPosition` {Point} representing the new head position
  #     * `oldTailPosition` {Point} representing the former tail position
  #     * `newTailPosition` {Point} representing the new tail position
  #     * `wasValid` {Boolean} indicating whether the marker was valid before the change
  #     * `isValid` {Boolean} indicating whether the marker is now valid
  #     * `hadTail` {Boolean} indicating whether the marker had a tail before the change
  #     * `hasTail` {Boolean} indicating whether the marker now has a tail
  #     * `oldProperties` {Object} containing the marker's custom properties before the change.
  #     * `newProperties` {Object} containing the marker's custom properties after the change.
  #     * `textChanged` {Boolean} indicating whether this change was caused by a textual change
  #       to the buffer or whether the marker was manipulated directly via its public API.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  onDidChange: (callback) ->
    @emitter.on 'did-change', callback

  on: (eventName) ->
    switch eventName
      when 'changed'
        Grim.deprecate("Use Marker::onDidChange instead")
      when 'destroyed'
        Grim.deprecate("Use Marker::onDidDestroy instead")
      else
        Grim.deprecate("Marker::on is deprecated. Use event subscription methods instead.")

    EmitterMixin::on.apply(this, arguments)

  # Public: Returns the current {Range} of the marker. The range is immutable.
  getRange: ->
    @range

  # Public: Sets the range of the marker.
  #
  # * `range` A {Range} or range-compatible {Array}. The range will be clipped
  #   before it is assigned.
  # * `properties` (optional) {Object} properties to associate with the marker.
  #   * `reversed`  {Boolean} If true, the marker will to be in a reversed orientation.
  setRange: (range, properties) ->
    params = @extractParams(properties)
    params.tailed = true
    params.range = @clipRange(Range.fromObject(range, true))
    @update(params)

  # Public: Returns a {Point} representing the marker's current head position.
  getHeadPosition: ->
    if @reversed
      @range.start
    else
      @range.end

  # Public: Sets the head position of the marker.
  #
  # * `position` A {Point} or point-compatible {Array}. The position will be
  #   clipped before it is assigned.
  # * `properties` (optional) {Object} properties to associate with the marker.
  setHeadPosition: (position, properties) ->
    position = @clipPosition(Point.fromObject(position, true))
    params = @extractParams(properties)

    if @hasTail()
      if @isReversed()
        if position.isLessThan(@range.end)
          params.range = new Range(position, @range.end)
        else
          params.reversed = false
          params.range = new Range(@range.end, position)
      else
        if position.isLessThan(@range.start)
          params.reversed = true
          params.range = new Range(position, @range.start)
        else
          params.range = new Range(@range.start, position)
    else
      params.range = new Range(position, position)


    @update(params)

  # Public: Returns a {Point} representing the marker's current tail position.
  # If the marker has no tail, the head position will be returned instead.
  getTailPosition: ->
    if @hasTail()
      if @reversed
        @range.end
      else
        @range.start
    else
      @getHeadPosition()

  # Public: Sets the head position of the marker. If the marker doesn't have a
  # tail, it will after calling this method.
  #
  # * `position` A {Point} or point-compatible {Array}. The position will be
  #   clipped before it is assigned.
  # * `properties` (optional) {Object} properties to associate with the marker.
  setTailPosition: (position, properties) ->
    position = @clipPosition(Point.fromObject(position, true))
    params = @extractParams(properties)
    params.tailed = true

    if @reversed
      if position.isLessThan(@range.start)
        params.reversed = false
        params.range = new Range(position, @range.start)
      else
        params.range = new Range(@range.start, position)
    else
      if position.isLessThan(@range.end)
        params.range = new Range(position, @range.end)
      else
        params.reversed = true
        params.range = new Range(@range.end, position)

    @update(params)

  # Public: Returns a {Point} representing the start position of the marker,
  # which could be the head or tail position, depending on its orientation.
  getStartPosition: ->
    if @reversed
      @getHeadPosition()
    else
      @getTailPosition()

  # Public: Returns a {Point} representing the end position of the marker,
  # which could be the head or tail position, depending on its orientation.
  getEndPosition: ->
    if @reversed
      @getTailPosition()
    else
      @getHeadPosition()

  # Public: Removes the marker's tail. After calling the marker's head position
  # will be reported as its current tail position until the tail is planted
  # again.
  #
  # * `properties` (optional) {Object} properties to associate with the marker.
  clearTail: (properties) ->
    params = @extractParams(properties)
    params.tailed = false
    headPosition = @getHeadPosition()
    params.range = new Range(headPosition, headPosition)
    @update(params)

  # Public: Plants the marker's tail at the current head position. After calling
  # the marker's tail position will be its head position at the time of the
  # call, regardless of where the marker's head is moved.
  #
  # * `properties` (optional) {Object} properties to associate with the marker.
  plantTail: (properties) ->
    params = @extractParams(properties)
    unless @hasTail()
      params.tailed = true
      params.range = new Range(@getHeadPosition(), @getHeadPosition())
    @update(params)

  # Public: Returns a {Boolean} indicating whether the head precedes the tail.
  isReversed: ->
    @tailed and @reversed

  # Public: Returns a {Boolean} indicating whether the marker has a tail.
  hasTail: ->
    @tailed

  # Public: Is the marker valid?
  #
  # Returns a {Boolean}.
  isValid: ->
    not @isDestroyed() and @valid

  # Public: Is the marker destroyed?
  #
  # Returns a {Boolean}.
  isDestroyed: ->
    @destroyed

  # Public: Returns a {Boolean} indicating whether this marker is equivalent to
  # another marker, meaning they have the same range and options.
  #
  # * `other` {Marker} other marker
  isEqual: (other) ->
    isEqual(@toParams(true), other.toParams(true))

  # Public: Get the invalidation strategy for this marker.
  #
  # Valid values include: `never`, `surround`, `overlap`, `inside`, and `touch`.
  #
  # Returns a {String}.
  getInvalidationStrategy: ->
    @invalidate

  # Deprecated: Use ::getProperties instead
  getAttributes: ->
    Grim.deprecate("Use Marker::getProperties instead.")
    @getProperties()

  # Deprecated: Use ::setProperties instead
  setAttributes: (args...) ->
    Grim.deprecate("Use Marker::setProperties instead.")
    @setProperties(args...)

  # Public: Returns an {Object} containing any custom properties associated with
  # the marker.
  getProperties: ->
    @properties

  # Public: Merges an {Object} containing new properties into the marker's
  # existing properties.
  #
  # * `properties` {Object}
  setProperties: (properties) ->
    @update(properties: extend({}, @getProperties(), properties))

  # Public: Creates and returns a new {Marker} with the same properties as this
  # marker.
  #
  # * `params` {Object}
  copy: (params) ->
    @manager.createMarker(extend(@toParams(), @extractParams(params)))

  # Public: Destroys the marker, causing it to emit the 'destroyed' event. Once
  # destroyed, a marker cannot be restored by undo/redo operations.
  destroy: ->
    @destroyed = true
    @manager.removeMarker(@id)
    @manager.intervals.remove(@id)
    @emitter.emit 'did-destroy'
    @emit 'destroyed'

  extractParams: (params) ->
    params = @constructor.extractParams(params)
    params.properties = extend({}, @properties, params.properties) if params.properties?
    params

  # Public: Compares this marker to another based on their ranges.
  #
  # * `other` {Marker}
  compare: (other) ->
    @range.compare(other.range)

  # Deprecated: Use ::matchesParams instead
  matchesAttributes: (args...) ->
    @matchesParams(args...)

  # Returns whether this marker matches the given parameters. The parameters
  # are the same as {MarkerManager::findMarkers}.
  matchesParams: (params) ->
    for key, value of params
      return false unless @matchesParam(key, value)
    true

  # Returns whether this marker matches the given parameter name and value.
  # The parameters are the same as {MarkerManager::findMarkers}.
  matchesParam: (key, value) ->
    switch key
      when 'startPosition'
        @getStartPosition().isEqual(value)
      when 'endPosition'
        @getEndPosition().isEqual(value)
      when 'containsPoint', 'containsPosition'
        @containsPoint(value)
      when 'containsRange'
        @containsRange(value)
      when 'startRow'
        @getStartPosition().row is value
      when 'endRow'
        @getEndPosition().row is value
      when 'intersectsRow'
        @intersectsRow(value)
      when 'invalidate', 'reversed', 'tailed', 'persistent'
        isEqual(@[key], value)
      else
        isEqual(@properties[key], value)

  toParams: (omitId) ->
    params = {@range, @reversed, @tailed, @invalidate, @persistent, @properties, @valid}
    params.id = @id unless omitId
    params

  # Adjusts the marker's start and end positions and possibly its validity
  # based on the given {BufferPatch}.
  handleBufferChange: (patch) ->
    {oldRange, newRange, newMarkersSnapshot} = patch

    if stateToRestore = newMarkersSnapshot?[@id]
      return @update(stateToRestore, true)

    rowDelta = newRange.end.row - oldRange.end.row
    columnDelta = newRange.end.column - oldRange.end.column
    markerStart = @range.start
    markerEnd = @range.end

    return if markerEnd.isLessThan(oldRange.start)

    switch @getInvalidationStrategy()
      when 'never'
        valid = true
      when 'surround'
        valid = markerStart.isLessThan(oldRange.start) or oldRange.end.isLessThanOrEqual(markerEnd)
      when 'overlap'
        valid = !oldRange.containsPoint(markerStart, true) and !oldRange.containsPoint(markerEnd, true)
      when 'inside'
        if @hasTail()
          valid = oldRange.end.isLessThanOrEqual(markerStart) or markerEnd.isLessThanOrEqual(oldRange.start)
        else
          valid = @valid
      when 'touch'
        valid = oldRange.end.isLessThan(markerStart) or markerEnd.isLessThan(oldRange.start)

    newMarkerRange = @range.copy()

    exclusive = not @hasTail() or @getInvalidationStrategy() is 'inside'
    changePrecedesMarkerStart = oldRange.end.isLessThan(markerStart) or (exclusive and oldRange.end.isLessThanOrEqual(markerStart))
    changeSurroundsMarkerStart = not changePrecedesMarkerStart and oldRange.start.isLessThan(markerStart)
    changePrecedesMarkerEnd = changePrecedesMarkerStart or oldRange.end.isLessThan(markerEnd) or (not exclusive and oldRange.end.isLessThanOrEqual(markerEnd))
    changeSurroundsMarkerEnd = not changePrecedesMarkerEnd and oldRange.start.isLessThan(markerEnd)

    if changePrecedesMarkerStart
      newMarkerRange.start.row += rowDelta
      newMarkerRange.start.column += columnDelta if oldRange.end.row is markerStart.row
    else if changeSurroundsMarkerStart
      newMarkerRange.start = newRange.end

    if changePrecedesMarkerEnd
      newMarkerRange.end.row += rowDelta
      newMarkerRange.end.column += columnDelta if oldRange.end.row is markerEnd.row
    else if changeSurroundsMarkerEnd
      newMarkerRange.end = newRange.end

    if not changePrecedesMarkerStart or valid isnt @valid
      patch.oldMarkersSnapshot ?= {}
      patch.oldMarkersSnapshot[@id] = {@range, @valid}

    @update({valid, range: newMarkerRange}, true)

  update: ({range, reversed, tailed, valid, properties}, textChanged=false) ->
    oldHeadPosition = @getHeadPosition()
    oldTailPosition = @getTailPosition()
    wasValid = @isValid()
    hadTail = @hasTail()
    oldProperties = @getProperties()

    patch = new MarkerPatch(@id)

    if range? and not range.isEqual(@range)
      range = range.freeze()
      patch.oldParams.range = @range
      patch.newParams.range = range
      @range = range
      @updateIntervals()
      updated = true

    if reversed? and reversed isnt @reversed
      patch.oldParams.reversed = @reversed
      patch.newParams.reversed = reversed
      @reversed = reversed
      updated = true

    if tailed? and tailed isnt @tailed
      patch.oldParams.tailed = @tailed
      patch.newParams.tailed = tailed
      @tailed = tailed
      updated = true

    if valid? and valid isnt @valid
      patch.oldParams.valid = @valid
      patch.newParams.valid = valid
      @valid = valid
      updated = true

    if properties? and not isEqual(properties, @properties)
      properties = Object.freeze(properties)
      patch.oldParams.properties = @properties
      patch.newParams.properties = properties
      @properties = properties
      updated = true

    return false unless updated

    @manager.recordMarkerPatch(patch) unless textChanged

    newHeadPosition = @getHeadPosition()
    newTailPosition = @getTailPosition()
    isValid = @isValid()
    hasTail = @hasTail()
    newProperties = @getProperties()

    event = {
      oldHeadPosition, newHeadPosition, oldTailPosition, newTailPosition
      wasValid, isValid, hadTail, hasTail, oldProperties, newProperties, textChanged
    }
    if @deferredChangeEvents?
      @deferredChangeEvents.push(event)
    else
      @emitter.emit 'did-change', event
      @emit 'changed', event
    true

  # Updates the interval index on the marker manager with the marker's current
  # range.
  updateIntervals: ->
    @manager.intervals.update(@id, @range.start, @range.end)

  pauseChangeEvents: ->
    @deferredChangeEvents = []

  resumeChangeEvents: ->
    if deferredChangeEvents = @deferredChangeEvents
      @deferredChangeEvents = null

      for event in deferredChangeEvents
        @emitter.emit 'did-change', event
        @emit 'changed', event
