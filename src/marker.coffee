{extend, isEqual, omit, pick, size} = require 'underscore-plus'
{Emitter} = require 'event-kit'
Grim = require 'grim'
Delegator = require 'delegato'
Point = require './point'
Range = require './range'

OptionKeys = new Set(['reversed', 'tailed', 'invalidate', 'persistent'])

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
    if inputParams?
      @handleDeprecatedParams(inputParams) if Grim.includeDeprecatedAPIs
      for key in Object.keys(inputParams)
        if OptionKeys.has(key)
          outputParams[key] = inputParams[key]
        else
          outputParams.properties ?= {}
          outputParams.properties[key] = inputParams[key]
    outputParams

  @delegatesMethods 'containsPoint', 'containsRange', 'intersectsRow', toMethod: 'getRange'

  constructor: (@id, @store, range, params) ->
    {@tailed, @reversed, @valid, @invalidate, @persistent, @properties} = params
    @emitter = new Emitter
    @tailed ?= true
    @reversed ?= false
    @valid ?= true
    @invalidate ?= 'overlap'
    @persistent ?= true
    @properties ?= {}
    @hasChangeObservers = false
    @rangeWhenDestroyed = null
    Object.freeze(@properties)
    @store.setMarkerHasTail(@id, @tailed)

  ###
  Section: Event Subscription
  ###

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
    unless @hasChangeObservers
      @previousEventState = @getSnapshot(@getRange())
      @hasChangeObservers = true
    @emitter.on 'did-change', callback

  # Public: Returns the current {Range} of the marker. The range is immutable.
  getRange: ->
    @rangeWhenDestroyed ? @store.getMarkerRange(@id)

  # Public: Sets the range of the marker.
  #
  # * `range` A {Range} or range-compatible {Array}. The range will be clipped
  #   before it is assigned.
  # * `properties` (optional) {Object} properties to associate with the marker.
  #   * `reversed`  {Boolean} If true, the marker will to be in a reversed orientation.
  setRange: (range, properties) ->
    params = @extractParams(properties)
    params.tailed = true
    params.range = Range.fromObject(range, true)
    @update(@getRange(), params)

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
  # * `properties` (optional) {Object} properties to associate with the marker.
  setHeadPosition: (position, properties) ->
    position = Point.fromObject(position)
    params = @extractParams(properties)
    oldRange = @getRange()

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
  # * `properties` (optional) {Object} properties to associate with the marker.
  setTailPosition: (position, properties) ->
    position = Point.fromObject(position)
    params = @extractParams(properties)
    params.tailed = true
    oldRange = @getRange()

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
  getStartPosition: ->
    @rangeWhenDestroyed?.start ? @store.getMarkerStartPosition(@id)

  # Public: Returns a {Point} representing the end position of the marker,
  # which could be the head or tail position, depending on its orientation.
  getEndPosition: ->
    @rangeWhenDestroyed?.end ? @store.getMarkerEndPosition(@id)

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
    @update(@getRange(), params)

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
    @update(@getRange(), params)

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
    @rangeWhenDestroyed?

  # Public: Returns a {Boolean} indicating whether this marker is equivalent to
  # another marker, meaning they have the same range and options.
  #
  # * `other` {Marker} other marker
  isEqual: (other) ->
    @invalidate is other.invalidate and
      @tailed is other.tailed and
      @persistent is other.persistent and
      @reversed is other.reversed and
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
    snapshot = @getSnapshot(null)
    options = Marker.extractParams(options)
    @store.createMarker(@getRange(), extend(
      {}
      snapshot,
      options,
      properties: extend({}, snapshot.properties, options.properties)
    ))

  # Public: Destroys the marker, causing it to emit the 'destroyed' event. Once
  # destroyed, a marker cannot be restored by undo/redo operations.
  destroy: ->
    @rangeWhenDestroyed = @getRange()
    @store.destroyMarker(@id)
    @emitter.emit 'did-destroy'
    @emit 'destroyed' if Grim.includeDeprecatedAPIs

  extractParams: (params) ->
    params = @constructor.extractParams(params)
    params.properties = extend({}, @properties, params.properties) if params.properties?
    params

  # Public: Compares this marker to another based on their ranges.
  #
  # * `other` {Marker}
  compare: (other) ->
    @getRange().compare(other.getRange())

  # Returns whether this marker matches the given parameters. The parameters
  # are the same as {MarkerManager::findMarkers}.
  matchesParams: (params) ->
    for key in Object.keys(params)
      return false unless @matchesParam(key, params[key])
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

  update: (oldRange, {range, reversed, tailed, valid, properties}, textChanged=false) ->
    updated = propertiesChanged = false

    if range? and not range.isEqual(oldRange)
      @store.setMarkerRange(@id, range)
      updated = true

    if reversed? and reversed isnt @reversed
      @reversed = reversed
      updated = true

    if tailed? and tailed isnt @tailed
      @tailed = tailed
      @store.setMarkerHasTail(@id, @tailed)
      updated = true

    if valid? and valid isnt @valid
      @valid = valid
      updated = true

    if properties? and not isEqual(properties, @properties)
      @properties = Object.freeze(properties)
      propertiesChanged = true
      updated = true

    @emitChangeEvent(range ? oldRange, textChanged, propertiesChanged)
    updated

  getSnapshot: (range) ->
    Object.freeze({range, @properties, @reversed, @tailed, @valid, @invalidate})

  toString: ->
    "[Marker #{@id}, #{@getRange()}]"

  ###
  Section: Private
  ###

  emitChangeEvent: (currentRange, textChanged, propertiesChanged) ->
    @store.markerUpdated(@id) unless textChanged
    return unless @hasChangeObservers
    oldState = @previousEventState

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

if Grim.includeDeprecatedAPIs
  EmitterMixin = require('emissary').Emitter
  EmitterMixin.includeInto(Marker)

  Marker::on = (eventName) ->
    switch eventName
      when 'changed'
        Grim.deprecate("Use Marker::onDidChange instead")
      when 'destroyed'
        Grim.deprecate("Use Marker::onDidDestroy instead")
      else
        Grim.deprecate("Marker::on is deprecated. Use event subscription methods instead.")

    EmitterMixin::on.apply(this, arguments)

  Marker::matchesAttributes = (args...) ->
    Grim.deprecate("Use Marker::matchesParams instead.")
    @matchesParams(args...)

  Marker::getAttributes = ->
    Grim.deprecate("Use Marker::getProperties instead.")
    @getProperties()

  Marker::setAttributes = (args...) ->
    Grim.deprecate("Use Marker::setProperties instead.")
    @setProperties(args...)

  Marker.handleDeprecatedParams = (params) ->
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
