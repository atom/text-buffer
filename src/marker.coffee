{extend, isEqual, omit, pick, size} = require 'underscore-plus'
{Emitter} = require 'emissary'
Delegator = require 'delegato'
Serializable = require 'serializable'
MarkerPatch = require './marker-patch'
Point = require './point'
Range = require './range'

OptionKeys = ['reversed', 'tailed', 'invalidate', 'persistent']

# Public: Reprents a buffer annotation that remains logically stationary even
# as the buffer changes. This is used to represent cursors, folds, snippet
# targets, misspelled words, and anything else that needs to track a logical
# location in the buffer over time.
#
# Head and Tail:
# Markers always have a *head* and sometimes have a *tail*. If you think of a
# marker as an editor selection, the head is the part that's stationary and the
# tail is the part that moves when the mouse is moved. A marker without a tail
# always reports an empty range at the head position. A marker with a head position
# greater than the tail is in a "normal" orientation. If the head precedes the
# tail the marker is in a "reversed" orientation.
#
# Validity:
# Markers are considered *valid* when they are first created. Depending on the
# invalidation strategy you choose, certain changes to the buffer can cause a
# marker to become invalid, for example if the text surrounding the marker is
# deleted.
#
# Change events:
# When markers change in position for any reason, the emit a 'changed' event with
# the following properties:
#
# * oldHeadPosition:
#     A {Point} representing the former head position
# * newHeadPosition:
#     A {Point} representing the new head position
# * oldTailPosition:
#     A {Point} representing the former tail position
# * newTailPosition:
#     A {Point} representing the new tail position
# * wasValid:
#     A {Boolean} indicating whether the marker was valid before the change
# * isValid:
#     A {Boolean} indicating whether the marker is now valid
# * hadTail:
#     A {Boolean} indicating whether the marker had a tail before the change
# * hasTail:
#     A {Boolean} indicating whether the marker now has a tail
# * oldProperties:
#     An {Object} containing the marker's custom properties before the change.
# * newProperties:
#     An {Object} containing the marker's custom properties after the change.
# * textChanged:
#     A {Boolean} indicating whether this change was caused by a textual change
#     to the buffer or whether the marker was manipulated directly via its public
#     API.
module.exports =
class Marker
  Emitter.includeInto(this)
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
      params.reversed = params.isReversed
      delete params.isReversed

    if params.hasTail?
      params.tailed = params.hasTail
      delete params.hasTail

    if params.persist?
      params.persistent = params.persist
      delete params.persist

    if params.invalidation
      params.invalidate = params.invalidation
      delete params.invalidation

  @delegatesMethods 'containsPoint', 'containsRange', 'intersectsRow', toProperty: 'range'
  @delegatesMethods 'clipPosition', 'clipRange', toProperty: 'manager'

  constructor: (params) ->
    {@manager, @id, @range, @tailed, @reversed} = params
    {@valid, @invalidate, @persistent, @properties} = params
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

  # Public: Returns the current {Range} of the marker. The range is immutable.
  getRange: ->
    @range

  # Public: Sets the range of the marker.
  #
  # range - A {Range} or range-compatible {Array}. The range will be clipped
  #         before it is assigned.
  # properties - An optional hash of properties to associate with the marker.
  #   :reversed -  If true, the marker will to be in a reversed orientation.
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
  # position - A {Point} or point-compatible {Array}. The position will be
  #            clipped before it is assigned.
  # properties - An optional hash of properties to associate with the marker.
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
  # position - A {Point} or point-compatible {Array}. The position will be
  #            clipped before it is assigned.
  # properties - An optional hash of properties to associate with the marker.
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
  # properties - An optional hash of properties to associate with the marker.
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
  # properties - An optional hash of properties to associate with the marker.
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
  isEqual: (other) ->
    isEqual(@toParams(true), other.toParams(true))

  # Public: Get the invalidation strategy for this marker.
  #
  # Valid values include: `inside`, `never`, `overlap`, and `surround`.
  #
  # Returns a {String}.
  getInvalidationStrategy: ->
    @invalidate

  # Deprecated: Use ::getProperties instead
  getAttributes: ->
    @getProperties()

  # Deprecated: Use ::setProperties instead
  setAttributes: (args...) ->
    @setProperties(args...)

  # Public: Returns an {Object} containing any custom properties associated with
  # the marker.
  getProperties: ->
    @properties

  # Public: Merges an {Object} containing new properties into the marker's
  # existing properties.
  setProperties: (properties) ->
    @update(properties: extend({}, @getProperties(), properties))

  # Public: Creates and returns a new {Marker} with the same properties as this
  # marker.
  copy: (params) ->
    @manager.createMarker(extend(@toParams(), @extractParams(params)))

  # Public: Destroys the marker, causing it to emit the 'destroyed' event. Once
  # destroyed, a marker cannot be restored by undo/redo operations.
  destroy: ->
    @destroyed = true
    @manager.removeMarker(@id)
    @manager.intervals.remove(@id)
    @emit 'destroyed'

  extractParams: (params) ->
    params = @constructor.extractParams(params)
    params.properties = extend({}, @properties, params.properties) if params.properties?
    params

  # Public: Compares this marker to another based on their ranges.
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
    params = {@range, @reversed, @tailed, @invalidate, @persistent, @properties}
    params.id = @id unless omitId
    params

  update: (params) ->
    if patch = @buildPatch(params)
      @manager.recordMarkerPatch(patch)
      @applyPatch(patch)
      true
    else
      false

  # Adjusts the marker's start and end positions and possibly its validity
  # based on the given {BufferPatch}.
  handleBufferChange: (patch) ->
    {oldRange, newRange} = patch
    rowDelta = newRange.end.row - oldRange.end.row
    columnDelta = newRange.end.column - oldRange.end.column
    markerStart = @range.start
    markerEnd = @range.end

    return if markerEnd.isLessThan(oldRange.start)

    valid = @valid
    switch @getInvalidationStrategy()
      when 'surround'
        valid = markerStart.isLessThan(oldRange.start) or oldRange.end.isLessThanOrEqual(markerEnd)
      when 'overlap'
        valid = !oldRange.containsPoint(markerStart, true) and !oldRange.containsPoint(markerEnd, true)
      when 'inside'
        if @hasTail()
          valid = oldRange.end.isLessThan(markerStart) or markerEnd.isLessThan(oldRange.start)

    newMarkerRange = @range.copy()

    changePrecedesMarkerStart = oldRange.end.isLessThan(markerStart) or (not @hasTail() and oldRange.end.isLessThanOrEqual(markerStart))
    changeSurroundsMarkerStart = not changePrecedesMarkerStart and oldRange.start.isLessThan(markerStart)
    changePrecedesMarkerEnd = oldRange.end.isLessThanOrEqual(markerEnd)
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

    if markerPatch = @buildPatch({valid, range: newMarkerRange})
      patch.addMarkerPatch(markerPatch)

  buildPatch: (newParams) ->
    oldParams = {}
    for name, value of newParams
      if isEqual(@[name], value)
        delete newParams[name]
      else
        oldParams[name] = @[name]

    if size(newParams)
      new MarkerPatch(@id, oldParams, newParams)

  applyPatch: (patch, textChanged=false) ->
    oldHeadPosition = @getHeadPosition()
    oldTailPosition = @getTailPosition()
    wasValid = @isValid()
    hadTail = @hasTail()
    oldProperties = @getProperties()

    updated = false
    {range, reversed, tailed, valid, properties} = patch.newParams

    if range? and not range.isEqual(@range)
      @range = range.freeze()
      @updateIntervals()
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

    if properties? and not isEqual(properties, @properties)
      @properties = Object.freeze(properties)
      updated = true

    return false unless updated

    newHeadPosition = @getHeadPosition()
    newTailPosition = @getTailPosition()
    isValid = @isValid()
    hasTail = @hasTail()
    newProperties = @getProperties()

    @emit 'changed', {
      oldHeadPosition, newHeadPosition, oldTailPosition, newTailPosition
      wasValid, isValid, hadTail, hasTail, oldProperties, newProperties, textChanged
    }
    true

  # Updates the interval index on the marker manager with the marker's current
  # range.
  updateIntervals: ->
    @manager.intervals.update(@id, @range.start, @range.end)
