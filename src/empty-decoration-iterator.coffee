Point = require './point'

module.exports =
class EmptyDecorationIterator
  seek: (position) ->

  moveToSuccessor: ->

  getPosition: ->
    Point.INFINITY

  getCloseTags: ->
    []

  getOpenTags: ->
    []
