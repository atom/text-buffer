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

  setHeadPosition: (position) ->
    position = Point.fromObject(position, true)

    return false if position.isEqual(@getHeadPosition())

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
    @update(params)
    true

  getTailPosition: ->
    if @reversed
      @range.end
    else
      @range.start

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

    {range, reversed} = params
    @range = range.freeze() if range?
    @reversed = reversed if reversed?

    bufferChanged = false
    newHeadPosition = @getHeadPosition()
    newTailPosition = @getTailPosition()
    isValid = @isValid()
    hasTail = @hasTail()

    @emit 'changed', {
      oldHeadPosition, newHeadPosition, oldTailPosition, newTailPosition
      isValid, hasTail, bufferChanged,
    }
