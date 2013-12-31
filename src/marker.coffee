{extend, omit, pick, size} = require 'underscore'
isEqual = require 'tantamount'
{Emitter} = require 'emissary'
Delegator = require 'delegato'
Serializable = require 'nostalgia'
MarkerPatch = require './marker-patch'
Point = require './point'
Range = require './range'

OptionKeys = ['reversed', 'tailed', 'invalidate', 'persistent']

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

  @delegatesMethods 'containsPoint', 'containsRange', 'intersectsRow', toProperty: 'range'

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

  serializeParams: ->
    range = @range.serialize()
    {@id, range, @tailed, @reversed, @valid, @invalidate, @persistent, @properties}

  deserializeParams: (state) ->
    state.range = Range.deserialize(state.range)
    state

  getRange: ->
    if @hasTail()
      @range
    else
      new Range(@getHeadPosition(), @getHeadPosition())

  setRange: (range, params) ->
    params = @extractParams(params)
    params.range = Range.fromObject(range, true)
    @update(params)

  getHeadPosition: ->
    if @reversed
      @range.start
    else
      @range.end

  setHeadPosition: (position, params) ->
    position = Point.fromObject(position, true)
    params = @extractParams(params)

    if @reversed
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

    @update(params)

  getTailPosition: ->
    if @hasTail()
      if @reversed
        @range.end
      else
        @range.start
    else
      @getHeadPosition()

  setTailPosition: (position, params) ->
    position = Point.fromObject(position, true)
    params = @extractParams(params)

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

  getStartPosition: ->
    if @reversed
      @getHeadPosition()
    else
      @getTailPosition()

  getEndPosition: ->
    if @reversed
      @getTailPosition()
    else
      @getHeadPosition()

  clearTail: (params) ->
    params = @extractParams(params)
    params.tailed = false
    @update(params)

  plantTail: (params) ->
    params = @extractParams(params)
    unless @hasTail()
      params.tailed = true
      params.range = new Range(@getHeadPosition(), @getHeadPosition())
    @update(params)

  isReversed: ->
    @tailed and @reversed

  hasTail: ->
    @tailed

  isValid: ->
    not @isDestroyed() and @valid

  isDestroyed: ->
    @destroyed

  isEqual: (other) ->
    isEqual(@toParams(true), other.toParams(true))

  getInvalidationStrategy: ->
    @invalidate

  getProperties: ->
    @properties

  copy: (params) ->
    @manager.createMarker(extend(@toParams(), @extractParams(params)))

  destroy: ->
    @destroyed = true
    @manager.removeMarker(@id)
    @emit 'destroyed'

  extractParams: (params) ->
    params = @constructor.extractParams(params)
    params.properties = extend({}, @properties, params.properties) if params.properties?
    params

  compare: (other) ->
    @range.compare(other.range)

  matchesParams: (params) ->
    for key, value of params
      return false unless @matchesParam(key, value)
    true

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

    # Calculate new marker start position
    changeIsInsideMarker = @hasTail() and @range.containsRange(oldRange)
    if oldRange.start.isLessThanOrEqual(markerStart) and not changeIsInsideMarker
      if oldRange.end.isLessThanOrEqual(markerStart)
        # Change precedes marker start position; shift position according to row/column delta
        newMarkerRange.start.row += rowDelta
        newMarkerRange.start.column += columnDelta if oldRange.end.row is markerStart.row
      else
        # Change surrounds marker start position; move position to the end of the change
        newMarkerRange.start = newRange.end

    # Calculate new marker end position
    if oldRange.start.isLessThanOrEqual(markerEnd)
      if oldRange.end.isLessThanOrEqual(markerEnd)
        # Precedes marker end position; shift position according to row/column delta
        newMarkerRange.end.row += rowDelta
        newMarkerRange.end.column += columnDelta if oldRange.end.row is markerEnd.row
      else if oldRange.start.isLessThan(markerEnd)
        # Change surrounds marker end position; move position to the end of the change
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

  applyPatch: (patch, bufferChanged=false) ->
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
      wasValid, isValid, hadTail, hasTail, oldProperties, newProperties, bufferChanged
    }
    true

  updateIntervals: ->
    @manager.intervals.update(@id, @range.start, @range.end)
