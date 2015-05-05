{extend} = require 'underscore-plus'
{Emitter} = require 'event-kit'
Delegator = require 'delegato'
Point = require './point'
Range = require './range'

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

  @delegatesMethods 'containsPoint', 'containsRange', 'intersectsRow', toProperty: 'range'

  constructor: (@id, @store, range, @properties) ->
    @emitter = new Emitter
    @valid = true
    @destroyed = false

    @persistent = @properties.persistent ? true
    delete @properties.persistent

    @tailed = @properties.tailed ? true
    delete @properties.tailed

    @reversed = @properties.reversed ? false
    delete @properties.reversed

    @invalidationStrategy = @properties.invalidate ? 'overlap'
    delete @properties.invalidate

    @store.setMarkerHasTail(@id, @tailed)
    @previousEventState = @getEventState(range)

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
    @emitter.on 'did-change', callback

  # Public: Returns the current {Range} of the marker. The range is immutable.
  getRange: ->
    @store.getMarkerRange(@id)

  # Public: Sets the range of the marker.
  #
  # * `range` A {Range} or range-compatible {Array}. The range will be clipped
  #   before it is assigned.
  # * `properties` (optional) {Object} properties to associate with the marker.
  #   * `reversed`  {Boolean} If true, the marker will to be in a reversed orientation.
  setRange: (range, properties) ->
    if properties?.reversed?
      reversed = properties.reversed
      delete properties.reversed
    @update({range: Range.fromObject(range), tailed: true, reversed, properties})

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
    @update({headPosition: Point.fromObject(position), properties})

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
    @update({tailPosition: Point.fromObject(position), properties})

  # Public: Returns a {Point} representing the start position of the marker,
  # which could be the head or tail position, depending on its orientation.
  getStartPosition: ->
    @getRange().start

  # Public: Returns a {Point} representing the end position of the marker,
  # which could be the head or tail position, depending on its orientation.
  getEndPosition: ->
    @getRange().end

  # Public: Removes the marker's tail. After calling the marker's head position
  # will be reported as its current tail position until the tail is planted
  # again.
  #
  # * `properties` (optional) {Object} properties to associate with the marker.
  clearTail: ->
    @update({tailed: false})

  # Public: Plants the marker's tail at the current head position. After calling
  # the marker's tail position will be its head position at the time of the
  # call, regardless of where the marker's head is moved.
  #
  # * `properties` (optional) {Object} properties to associate with the marker.
  plantTail: ->
    @update({tailed: true})

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

  # Public: Get the invalidation strategy for this marker.
  #
  # Valid values include: `never`, `surround`, `overlap`, `inside`, and `touch`.
  #
  # Returns a {String}.
  getInvalidationStrategy: ->
    @invalidationStrategy

  # Public: Returns an {Object} containing any custom properties associated with
  # the marker.
  getProperties: ->
    @properties

  # Public: Merges an {Object} containing new properties into the marker's
  # existing properties.
  #
  # * `properties` {Object}
  setProperties: (properties) ->
    @update({properties})

  # Public: Creates and returns a new {Marker} with the same properties as this
  # marker.
  #
  # * `params` {Object}
  copy: (options) ->
    properties = clone(@properties)
    properties[key] = value for key, value of options
    @store.markRange(@getRange(), options)

  # Public: Destroys the marker, causing it to emit the 'destroyed' event. Once
  # destroyed, a marker cannot be restored by undo/redo operations.
  destroy: ->
    @store.destroyMarker(@id)
    @destroyed = true
    @valid = false
    @emitter.emit("did-destroy")

  # Public: Compares this marker to another based on their ranges.
  #
  # * `other` {Marker}
  compare: (other) ->
    @getRange().compare(other.getRange())

  # Returns whether this marker matches the given parameters. The parameters
  # are the same as {MarkerManager::findMarkers}.
  matchesParams: (params) ->
    for key, value of params
      if key is 'invalidate'
        return false unless @invalidationStrategy is value
      else
        return false unless @properties[key] is value
    true

  update: ({range, reversed, tailed, valid, headPosition, tailPosition, properties}, textChanged=false) ->
    changed = propertiesChanged = false

    wasTailed = @tailed
    newRange = oldRange = @getRange()
    if @reversed
      oldHeadPosition = oldRange.start
      oldTailPosition = oldRange.end
    else
      oldHeadPosition = oldRange.end
      oldTailPosition = oldRange.start

    if reversed? and reversed isnt @reversed
      @reversed = reversed
      changed = true

    if valid? and valid isnt @valid
      @valid = valid
      changed = true

    if tailed? and tailed isnt @tailed
      @tailed = tailed
      changed = true
      unless @tailed
        @reversed = false
        newRange = Range(oldHeadPosition, oldHeadPosition)

    if properties? and not @matchesParams(properties)
      extend(@properties, properties)
      changed = true
      propertiesChanged = true

    if range?
      newRange = range

    if headPosition? and not headPosition.isEqual(oldHeadPosition)
      changed = true
      if not @tailed
        newRange = Range(headPosition, headPosition)
      else if headPosition.compare(oldTailPosition) < 0
        @reversed = true
        newRange = Range(headPosition, oldTailPosition)
      else
        @reversed = false
        newRange = Range(oldTailPosition, headPosition)

    if tailPosition? and not tailPosition.isEqual(oldTailPosition)
      changed = true
      @tailed = true
      if tailPosition.compare(oldHeadPosition) < 0
        @reversed = false
        newRange = Range(tailPosition, oldHeadPosition)
      else
        @reversed = true
        newRange = Range(oldHeadPosition, tailPosition)
      changed = true

    unless newRange.isEqual(oldRange)
      @store.setMarkerRange(@id, newRange)
    unless @tailed is wasTailed
      @store.setMarkerHasTail(@id, @tailed)
    @emitChangeEvent(newRange, textChanged, propertiesChanged)
    changed

  toString: ->
    "[Marker #{@id}, #{@getRange()}]"

  ###
  Section: Private
  ###

  emitChangeEvent: (currentRange, textChanged, propertiesChanged) ->
    oldState = @previousEventState
    newState = @previousEventState = @getEventState(currentRange)

    return unless propertiesChanged or
      oldState.valid isnt newState.valid or
      oldState.tailed isnt newState.tailed or
      oldState.headPosition.compare(newState.headPosition) isnt 0 or
      oldState.tailPosition.compare(newState.tailPosition) isnt 0

    @emitter.emit("did-change", {
      wasValid: oldState.valid, isValid: newState.valid
      hadTail: oldState.tailed, hasTail: newState.tailed
      oldProperties: oldState.properties, newProperties: newState.properties
      oldHeadPosition: oldState.headPosition, newHeadPosition: newState.headPosition
      oldTailPosition: oldState.tailPosition, newTailPosition: newState.tailPosition
      textChanged: textChanged
    })

  getEventState: (range) ->
    {
      headPosition: (if @reversed then range.start else range.end)
      tailPosition: (if @reversed then range.end else range.start)
      properties: clone(@properties)
      tailed: @tailed
      valid: true
    }

clone = (object) ->
  result = {}
  result[key] = value for key, value of object
  result
