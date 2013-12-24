{isEqual, extend} = require 'underscore'
{Emitter} = require 'emissary'
Point = require './point'
Range = require './range'

module.exports =
class Marker
  Emitter.includeInto(this)

  constructor: (params) ->
    {@id, @range, @tailed, @reversed} = params
    {@valid, @invalidate, @persistent, @state} = params
    Object.freeze(@state)

  getRange: ->
    @range

  getHeadPosition: ->
    if @reversed
      @range.start
    else
      @range.end

  setHeadPosition: (position, state) ->
    position = Point.fromObject(position, true)

    params = {}
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

    params.state = extend({}, @getState(), state) if state?

    @update(params)

  getTailPosition: ->
    if @reversed
      @range.end
    else
      @range.start

  setTailPosition: (position, state) ->
    position = Point.fromObject(position, true)

    params = {}
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

    params.state = extend({}, @getState(), state) if state?

    @update(params)

  isReversed: ->
    @tailed and @reversed

  hasTail: ->
    @tailed

  isValid: ->
    true

  getInvalidationStrategy: ->
    @invalidate

  getState: ->
    @state

  update: (params) ->
    oldHeadPosition = @getHeadPosition()
    oldTailPosition = @getTailPosition()
    wasValid = @isValid()
    hadTail = @hasTail()
    oldState = @getState()

    {range, reversed, state} = params
    @range = range.freeze() if range?
    @reversed = reversed if reversed?
    @state = Object.freeze(state) if state?

    bufferChanged = false
    newHeadPosition = @getHeadPosition()
    newTailPosition = @getTailPosition()
    isValid = @isValid()
    hasTail = @hasTail()
    newState = @getState()

    updated = false
    updated = true unless isValid is wasValid
    updated = true unless updated or hasTail is hadTail
    updated = true unless updated or newHeadPosition.isEqual(oldHeadPosition)
    updated = true unless updated or newTailPosition.isEqual(oldTailPosition)
    updated = true unless updated or isEqual(newState, oldState)

    if updated
      @emit 'changed', {
        oldHeadPosition, newHeadPosition, oldTailPosition, newTailPosition
        wasValid, isValid, hadTail, hasTail, oldState, newState, bufferChanged
      }
      true
    else
      false
