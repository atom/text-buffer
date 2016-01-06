Point = require './point'
Range = require './range'
{traverse, traversal, compare, characterIndexForPoint} = require './point-helpers'

module.exports =
class TokenIterator
  constructor: (@buffer, @patchIterator, @decorationIterators) ->
    @reset()

  getStartBufferPosition: -> Point.fromObject(@startBufferPosition)

  getStartScreenPosition: -> Point.fromObject(@startScreenPosition)

  getEndBufferPosition: -> Point.fromObject(@endBufferPosition)

  getEndScreenPosition: -> Point.fromObject(@endScreenPosition)

  getText: -> @text

  reset: ->
    @patchIterator.reset()
    @startBufferPosition = null
    @startScreenPosition = null
    @endBufferPosition = null
    @endScreenPosition = null
    @text = null
    @iteratorsToAdvance = []
    @atLineEnd = false

  seekToScreenRow: (screenRow) ->
    @startScreenPosition = Point(screenRow, 0)
    @patchIterator.seekToOutputPosition(@startScreenPosition)
    @startBufferPosition = @patchIterator.translateOutputPosition(@startScreenPosition)

    for decorationIterator in @decorationIterators
      decorationIterator.seek(@startBufferPosition)

    @assignEndPositionsAndText()

  moveToSuccessor: ->
    if @atLineEnd
      @startScreenPosition = traverse(@endScreenPosition, Point(1, 0))
      @startBufferPosition = @patchIterator.translateOutputPosition(@startScreenPosition)
      return false if compare(@startBufferPosition, @buffer.getEndPosition()) > 0
    else
      @startScreenPosition = @endScreenPosition
      @startBufferPosition = @endBufferPosition

    for iterator in @iteratorsToAdvance
      unless iterator.moveToSuccessor()
        if iterator is @patchIterator
          return false
        else
          @decorationIterators.splice(@decorationIterators.indexOf(iterator), 1)

    @assignEndPositionsAndText()
    true

  getOpenTags: ->

  getCloseTags: ->

  assignEndPositionsAndText: ->
    @iteratorsToAdvance.length = 0

    if @patchIterator.getOutputEnd().row is @startScreenPosition.row
      @atLineEnd = false
      @endScreenPosition = @patchIterator.getOutputEnd()
      @endBufferPosition = @patchIterator.getInputEnd()
      @iteratorsToAdvance.push(@patchIterator)

      if @patchIterator.inChange()
        characterIndexInChangeText = characterIndexForPoint(@patchIterator.getReplacementText(), traversal(@startScreenPosition, @patchIterator.getOutputStart()))
        @text = @patchIterator.getReplacementText().substring(characterIndexInChangeText)
      else
        @text = @buffer.getTextInRange(Range(@startBufferPosition, @endBufferPosition))
    else
      @atLineEnd = true
      if @patchIterator.inChange()
        nextNewlineIndex = @patchIterator.getReplacementText().indexOf('\n', @characterIndexInChangeText)
        @text = @patchIterator.getReplacementText().substring(@characterIndexInChangeText, nextNewlineIndex)
        @endScreenPosition = traverse(@startScreenPosition, Point(0, @text.length))
        @endBufferPosition = @patchIterator.translateOutputPosition(@endScreenPosition)
      else
        @text = @buffer.lineForRow(@startBufferPosition.row).substring(@startBufferPosition.column)
        @endBufferPosition = traverse(@startBufferPosition, Point(0, @text.length))
        @endScreenPosition = @patchIterator.translateInputPosition(@endBufferPosition)

    for decorationIterator in @decorationIterators
      decorationIteratorEndPosition = decorationIterator.getEndPosition()
      comparison = compare(decorationIteratorEndPosition, @endBufferPosition)
      if comparison < 0
        @iteratorsToAdvance.length = 0
        @endBufferPosition = decorationIteratorEndPosition
        @endScreenPosition = @patchIterator.translateInputPosition(@endBufferPosition)
        @text = @text.substring(0, @endScreenPosition.column - @startScreenPosition.column)
        @atLineEnd = false

      if comparison <= 0
        @iteratorsToAdvance.push(decorationIterator)
