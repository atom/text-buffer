{isEqual, extend, omit, pick, size} = require 'underscore'
{Emitter} = require 'emissary'
Point = require './point'
Range = require './range'

module.exports =
class Marker
  Emitter.includeInto(this)

  @reservedKeys: ['isReversed', 'hasTail', 'invalidate', 'persistent', 'persist']

  @paramsFromOptions: (options) ->
    params = {}
    if options?
      extend(params, pick(options, @reservedKeys))
      params.reversed = options.isReversed if options.isReversed?
      params.tailed = options.hasTail if options.hasTail?
      params.invalidate = options.invalidate if options.invalidate?
      params.persistent = options.persistent if options.persistent?
      params.persistent = options.persist if options.persist?
      state = omit(options, @reservedKeys)
      params.state = state if size(state) > 0
    params

  constructor: (params) ->
    {@id, @range, @tailed, @reversed} = params
    {@valid, @invalidate, @persistent, @state} = params
    @tailed ?= true
    @reversed ?= false
    @valid ?= true
    @invalidate ?= 'surround'
    @persistent ?= true
    @state ?= {}
    Object.freeze(@state)

  getRange: ->
    @range

  setRange: (range, options) ->
    params = @paramsFromOptions(options)
    params.range = Range.fromObject(range, true)
    @update(params)

  getHeadPosition: ->
    if @reversed
      @range.start
    else
      @range.end

  setHeadPosition: (position, options) ->
    position = Point.fromObject(position, true)
    params = @paramsFromOptions(options)

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
    if @reversed
      @range.end
    else
      @range.start

  setTailPosition: (position, options) ->
    position = Point.fromObject(position, true)
    params = @paramsFromOptions(options)

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

  paramsFromOptions: (options) ->
    params = @constructor.paramsFromOptions(options)
    params.state = extend({}, @state, params.state) if params.state?
    params

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
