Point = require './point'

module.exports =
class EmptyDecorationLayer
  buildIterator: -> new EmptyDecorationIterator

  getInvalidatedRanges: -> []

class EmptyDecorationIterator
  seek: (position) -> []

  moveToSuccessor: -> false

  getPosition: -> Point.INFINITY

  getCloseTags: -> []

  getOpenTags: -> []
