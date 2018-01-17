{extend, isEqual, omit, pick, size} = require 'underscore-plus'
{Emitter} = require 'event-kit'
Delegator = require 'delegato'
Point = require './point'
Range = require './range'
Grim = require 'grim'

OptionKeys = new Set(['reversed', 'tailed', 'invalidate', 'exclusive'])

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
  Delegator.includeInto(this)

  @extractParams: (inputParams) ->
    outputParams = {}
    containsCustomProperties = false
    if inputParams?
      for key in Object.keys(inputParams)
        if OptionKeys.has(key)
          outputParams[key] = inputParams[key]
        else if key is 'clipDirection' or key is 'skipSoftWrapIndentation'
          # TODO: Ignore these two keys for now. Eventually, when the
          # deprecation below will be gone, we can remove this conditional as
          # well, and just return standard marker properties.
        else
          containsCustomProperties = true
          outputParams.properties ?= {}
          outputParams.properties[key] = inputParams[key]

    # TODO: Remove both this deprecation and the conditional above on the
    # release after the one where we'll ship `DisplayLayer`.
    if containsCustomProperties
      Grim.deprecate("""
      Assigning custom properties to a marker when creating/copying it is
      deprecated. Please, consider storing the custom properties you need in
      some other object in your package, keyed by the marker's id property.
      """)

    outputParams

  @delegatesMethods 'containsPoint', 'containsRange', 'intersectsRow', toMethod: 'getRange'

  constructor: (@id, @layer, range, params, exclusivitySet = false) ->
    {@tailed, @reversed, @valid, @invalidate, @exclusive, @properties} = params
    @emitter = new Emitter
    @tailed ?= true
    @reversed ?= false
    @valid ?= true
    @invalidate ?= 'overlap'
    @properties ?= {}
    @hasChangeObservers = false
    Object.freeze(@properties)
    @layer.setMarkerIsExclusive(@id, @isExclusive()) unless exclusivitySet

  ###
  Section: Event Subscription
  ###

  # Public: Invoke the given callback when the marker is destroyed.
  #
  # * `callback` {Function} to be called when the marker is destroyed.
  #
  # Returns a {Disposable} on which `.dispose()` can be called to unsubscribe.
  onDidDestroy: (callback) ->
    @layer.markersWithDestroyListeners.add(this)
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
    unless @hasChangeObservers
      @previousEventState = @getSnapshot(@getRange())
      @hasChangeObservers = true
      @layer.markersWithChangeListeners.add(this)
    @emitter.on 'did-change', callback

  # Public: Returns the current {Range} of the marker. The range is immutable.
  getRange: -> @layer.getMarkerRange(@id)

  # Public: Sets the range of the marker.
  #
  # * `range` A {Range} or range-compatible {Array}. The range will be clipped
  #   before it is assigned.
  # * `params` (optional) An {Object} with the following keys:
  #   * `reversed`  {Boolean} indicating the marker will to be in a reversed
  #      orientation.
  #   * `exclusive` {Boolean} indicating that changes occurring at either end of
  #     the marker will be considered *outside* the marker rather than inside.
  #     This defaults to `false` unless the marker's invalidation strategy is
  #     `inside` or the marker has no tail, in which case it defaults to `true`.
  setRange: (range, params) ->
    params ?= {}
    @update(@getRange(), {reversed: params.reversed, tailed: true, range: Range.fromObject(range, true), exclusive: params.exclusive})

  # Public: Returns a {Point} representing the marker's current head position.
  getHeadPosition: ->
    if @reversed
      @getStartPosition()
    else
      @getEndPosition()

  # Public: Sets the head position of the marker.
  #
  # * `position` A {Point} or point-compatible {Array}. The position will be
  #   clipped before it is assigned.
  setHeadPosition: (position) ->
    position = Point.fromObject(position)
    oldRange = @getRange()
    params = {}

    if @hasTail()
      if @isReversed()
        if position.isLessThan(oldRange.end)
          params.range = new Range(position, oldRange.end)
        else
          params.reversed = false
          params.range = new Range(oldRange.end, position)
      else
        if position.isLessThan(oldRange.start)
          params.reversed = true
          params.range = new Range(position, oldRange.start)
        else
          params.range = new Range(oldRange.start, position)
    else
      params.range = new Range(position, position)
    @update(oldRange, params)

  # Public: Returns a {Point} representing the marker's current tail position.
  # If the marker has no tail, the head position will be returned instead.
  getTailPosition: ->
    if @reversed
      @getEndPosition()
    else
      @getStartPosition()

  # Public: Sets the tail position of the marker. If the marker doesn't have a
  # tail, it will after calling this method.
  #
  # * `position` A {Point} or point-compatible {Array}. The position will be
  #   clipped before it is assigned.
  setTailPosition: (position) ->
    position = Point.fromObject(position)
    oldRange = @getRange()
    params = {tailed: true}

    if @reversed
      if position.isLessThan(oldRange.start)
        params.reversed = false
        params.range = new Range(position, oldRange.start)
      else
        params.range = new Range(oldRange.start, position)
    else
      if position.isLessThan(oldRange.end)
        params.range = new Range(position, oldRange.end)
      else
        params.reversed = true
        params.range = new Range(oldRange.end, position)

    @update(oldRange, params)

  # Public: Returns a {Point} representing the start position of the marker,
  # which could be the head or tail position, depending on its orientation.
  getStartPosition: -> @layer.getMarkerStartPosition(@id)

  # Public: Returns a {Point} representing the end position of the marker,
  # which could be the head or tail position, depending on its orientation.
  getEndPosition: -> @layer.getMarkerEndPosition(@id)

  # Public: Removes the marker's tail. After calling the marker's head position
  # will be reported as its current tail position until the tail is planted
  # again.
  clearTail: ->
    headPosition = @getHeadPosition()
    @update(@getRange(), {tailed: false, reversed: false, range: Range(headPosition, headPosition)})

  # Public: Plants the marker's tail at the current head position. After calling
  # the marker's tail position will be its head position at the time of the
  # call, regardless of where the marker's head is moved.
  plantTail: ->
    unless @hasTail()
      headPosition = @getHeadPosition()
      @update(@getRange(), {tailed: true, range: new Range(headPosition, headPosition)})

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
    not @layer.hasMarker(@id)

  # Public: Returns a {Boolean} indicating whether changes that occur exactly at
  # the marker's head or tail cause it to move.
  isExclusive: ->
    if @exclusive?
      @exclusive
    else
      @getInvalidationStrategy() is 'inside' or not @hasTail()

  # Public: Returns a {Boolean} indicating whether this marker is equivalent to
  # another marker, meaning they have the same range and options.
  #
  # * `other` {Marker} other marker
  isEqual: (other) ->
    @invalidate is other.invalidate and
      @tailed is other.tailed and
      @reversed is other.reversed and
      @exclusive is other.exclusive and
      isEqual(@properties, other.properties) and
      @getRange().isEqual(other.getRange())

  # Public: Get the invalidation strategy for this marker.
  #
  # Valid values include: `never`, `surround`, `overlap`, `inside`, and `touch`.
  #
  # Returns a {String}.
  getInvalidationStrategy: ->
    @invalidate

  # Public: Returns an {Object} containing any custom properties associated with
  # the marker.
  getProperties: ->
    @properties

  # Public: Merges an {Object} containing new properties into the marker's
  # existing properties.
  #
  # * `properties` {Object}
  setProperties: (properties) ->
    @update(@getRange(), properties: extend({}, @properties, properties))

  # Public: Creates and returns a new {Marker} with the same properties as this
  # marker.
  #
  # * `params` {Object}
  copy: (options={}) ->
    snapshot = @getSnapshot()
    options = Marker.extractParams(options)
    @layer.createMarker(@getRange(), extend(
      {}
      snapshot,
      options,
      properties: extend({}, snapshot.properties, options.properties)
    ))

  # Public: Destroys the marker, causing it to emit the 'destroyed' event.
  destroy: (suppressMarkerLayerUpdateEvents) ->
    return if @isDestroyed()

    if @trackDestruction
      error = new Error
      Error.captureStackTrace(error)
      @destroyStackTrace = error.stack

    @layer.destroyMarker(this, suppressMarkerLayerUpdateEvents)
    @emitter.emit 'did-destroy'
    @emitter.clear()

  # Public: Compares this marker to another based on their ranges.
  #
  # * `other` {Marker}
  compare: (other) ->
    @layer.compareMarkers(@id, other.id)

  # Returns whether this marker matches the given parameters. The parameters
  # are the same as {MarkerLayer::findMarkers}.
  matchesParams: (params) ->
    for key in Object.keys(params)
      return false unless @matchesParam(key, params[key])
    true

  # Returns whether this marker matches the given parameter name and value.
  # The parameters are the same as {MarkerLayer::findMarkers}.
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
      when 'invalidate', 'reversed', 'tailed'
        isEqual(@[key], value)
      when 'valid'
        @isValid() is value
      else
        isEqual(@properties[key], value)

  update: (oldRange, {range, reversed, tailed, valid, exclusive, properties}, textChanged=false, suppressMarkerLayerUpdateEvents=false) ->
    return if @isDestroyed()

    oldRange = Range.fromObject(oldRange)
    range = Range.fromObject(range) if range?

    wasExclusive = @isExclusive()
    updated = propertiesChanged = false

    if range? and not range.isEqual(oldRange)
      @layer.setMarkerRange(@id, range)
      updated = true

    if reversed? and reversed isnt @reversed
      @reversed = reversed
      updated = true

    if tailed? and tailed isnt @tailed
      @tailed = tailed
      updated = true

    if valid? and valid isnt @valid
      @valid = valid
      updated = true

    if exclusive? and exclusive isnt @exclusive
      @exclusive = exclusive
      updated = true

    if wasExclusive isnt @isExclusive()
      @layer.setMarkerIsExclusive(@id, @isExclusive())
      updated = true

    if properties? and not isEqual(properties, @properties)
      @properties = Object.freeze(properties)
      propertiesChanged = true
      updated = true

    @emitChangeEvent(range ? oldRange, textChanged, propertiesChanged)
    @layer.markerUpdated() if updated and not suppressMarkerLayerUpdateEvents
    updated

  getSnapshot: (range, includeMarker=true) ->
    snapshot = {range, @properties, @reversed, @tailed, @valid, @invalidate, @exclusive}
    snapshot.marker = this if includeMarker
    Object.freeze(snapshot)

  toString: ->
    "[Marker #{@id}, #{@getRange()}]"

  ###
  Section: Private
  ###

  inspect: ->
    @toString()

  emitChangeEvent: (currentRange, textChanged, propertiesChanged) ->
    return unless @hasChangeObservers
    oldState = @previousEventState

    currentRange ?= @getRange()

    return false unless propertiesChanged or
      oldState.valid isnt @valid or
      oldState.tailed isnt @tailed or
      oldState.reversed isnt @reversed or
      oldState.range.compare(currentRange) isnt 0

    newState = @previousEventState = @getSnapshot(currentRange)

    if oldState.reversed
      oldHeadPosition = oldState.range.start
      oldTailPosition = oldState.range.end
    else
      oldHeadPosition = oldState.range.end
      oldTailPosition = oldState.range.start

    if newState.reversed
      newHeadPosition = newState.range.start
      newTailPosition = newState.range.end
    else
      newHeadPosition = newState.range.end
      newTailPosition = newState.range.start

    @emitter.emit("did-change", {
      wasValid: oldState.valid, isValid: newState.valid
      hadTail: oldState.tailed, hasTail: newState.tailed
      oldProperties: oldState.properties, newProperties: newState.properties
      oldHeadPosition, newHeadPosition, oldTailPosition, newTailPosition
      textChanged
    })
    true
