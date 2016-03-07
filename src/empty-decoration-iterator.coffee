Point = require './point'

module.exports =
class EmptyDecorationIterator
  seek: (position) -> []

  moveToSuccessor: -> false

  getPosition: -> Point.INFINITY

  getCloseTags: -> []

  getOpenTags: -> []
