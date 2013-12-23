module.exports =
class Marker
  constructor: (params) ->
    {@id, @range, @tailed, @reversed} = params
    {@valid, @invalidate, @persistent, @attributes} = params

  getRange: ->
    @range

  getHeadPosition: ->
    if @reversed
      @range.start
    else
      @range.end

  getTailPosition: ->
    if @reversed
      @range.end
    else
      @range.start

  isReversed: ->
    @tailed and @reversed

  hasTail: ->
    @tailed
