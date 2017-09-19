Point = require './point'

module.exports =
class NullLanguageMode
  buildIterator: -> new NullLanguageModeIterator

  bufferDidChange: ->

  getInvalidatedRanges: -> []

class NullLanguageModeIterator
  seek: (position) -> []

  moveToSuccessor: -> false

  getPosition: -> Point.INFINITY

  getCloseTags: -> []

  getOpenTags: -> []
